package main

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/cookiejar"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Config represents the XUI-Watchdog configuration
type Config struct {
	PanelURL        string  `json:"panel_url"`
	Username        string  `json:"username"`
	Password        string  `json:"password"`
	DBPath          string  `json:"db_path"`
	CheckInterval   float64 `json:"check_interval"`
	RestartCooldown int     `json:"restart_cooldown"`
	Threshold       float64 `json:"threshold"`
}

// UserState represents the state of a single user in memory
type UserState struct {
	UUID   string
	Enable bool
}

// Global state
var (
	appConfig Config
	apiClient *http.Client
	stateMap  = make(map[string]*UserState) // Key: Email
	stateLock sync.RWMutex

	// Ensure we only sync DB once per debounce window
	dbSyncTrigger = make(chan struct{}, 1)

	// Rate Limiting
	lastRestartTime time.Time
	restartLock     sync.Mutex
)

// Initialize HTTP client with cookie jar
func initAPIClient() error {
	jar, err := cookiejar.New(nil)
	if err != nil {
		return err
	}

	customTransport := http.DefaultTransport.(*http.Transport).Clone()
	customTransport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}

	apiClient = &http.Client{
		Jar:       jar,
		Timeout:   10 * time.Second,
		Transport: customTransport,
	}
	return nil
}

// Authenticate to 3x-ui and save the session cookie
func login() error {
	loginURL := fmt.Sprintf("%s/login", appConfig.PanelURL)

	payload := map[string]string{
		"username": appConfig.Username,
		"password": appConfig.Password,
	}
	jsonData, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	req, err := http.NewRequest("POST", loginURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := apiClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("login failed with status: %d", resp.StatusCode)
	}

	var result map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return err
	}

	if success, ok := result["success"].(bool); !ok || !success {
		return fmt.Errorf("login failed, API returned success=false")
	}

	log.Println("[INFO] Successfully authenticated with 3x-ui")
	return nil
}

// Generic API request handler that auto-reauthenticates on 401
func apiRequest(method, endpoint string, body []byte) ([]byte, error) {
	url := fmt.Sprintf("%s%s", appConfig.PanelURL, endpoint)

	doReq := func() (*http.Response, error) {
		var reqBody io.Reader
		if body != nil {
			reqBody = bytes.NewBuffer(body)
		}

		req, err := http.NewRequest(method, url, reqBody)
		if err != nil {
			return nil, err
		}

		req.Header.Set("Accept", "application/json")
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}

		return apiClient.Do(req)
	}

	resp, err := doReq()
	if err != nil {
		return nil, err
	}

	// If unauthorized, re-authenticate and retry once
	if resp.StatusCode == http.StatusUnauthorized {
		resp.Body.Close()
		log.Println("[WARN] Session expired, re-authenticating...")
		if err := login(); err != nil {
			return nil, fmt.Errorf("re-authentication failed: %w", err)
		}

		resp, err = doReq()
		if err != nil {
			return nil, err
		}
	}

	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("API request failed with status: %d", resp.StatusCode)
	}

	return io.ReadAll(resp.Body)
}

// ---------------------------------------------------------------------
// 3x-ui API Responses
// ---------------------------------------------------------------------

// Response structures for parsing 3x-ui API
type BaseResponse struct {
	Success bool            `json:"success"`
	Msg     string          `json:"msg"`
	Obj     json.RawMessage `json:"obj"`
}

type ClientStats struct {
	Id     int    `json:"id"`
	InboundId int  `json:"inboundId"`
	Enable bool   `json:"enable"`
	Email  string `json:"email"`
	Up     int64  `json:"up"`
	Down   int64  `json:"down"`
	ExpiryTime int64 `json:"expiryTime"`
	Total  int64  `json:"total"`
}

type Inbound struct {
	Id          int           `json:"id"`
	Up          int64         `json:"up"`
	Down        int64         `json:"down"`
	Total       int64         `json:"total"`
	Remark      string        `json:"remark"`
	Enable      bool          `json:"enable"`
	ExpiryTime  int64         `json:"expiryTime"`
	ClientStats []ClientStats `json:"clientStats"`
	Port        int           `json:"port"`
	Settings    string        `json:"settings"`
}

type OnlineClient struct {
	Email string `json:"email"` // Used to match inbounds to clients
	IP    string `json:"ip"`
}

// ---------------------------------------------------------------------

// Sync user configs via API
func syncUserConfigs() {
	log.Println("[INFO] Syncing user configurations from API...")

	// Fetch inbounds
	respData, err := apiRequest("GET", "/panel/api/inbounds/list", nil)
	if err != nil {
		log.Printf("[ERROR] Failed to fetch inbounds: %v", err)
		return
	}

	var baseResp BaseResponse
	if err := json.Unmarshal(respData, &baseResp); err != nil {
		log.Printf("[ERROR] Failed to parse inbound response: %v", err)
		return
	}

	var inbounds []Inbound
	if err := json.Unmarshal(baseResp.Obj, &inbounds); err != nil {
		log.Printf("[ERROR] Failed to unmarshal inbounds array: %v", err)
		return
	}

	stateLock.Lock()
	defer stateLock.Unlock()

	// Rebuild map slightly to handle removed users, or just update existing
	// To avoid dropping LastKnownIPs, we update existing or add new.
	// (A more robust way is to mark all stale and prune, but this is simple)

	activeEmails := make(map[string]bool)

	for _, inbound := range inbounds {
		// Parse settings to extract clients
		var settings map[string]interface{}
		if err := json.Unmarshal([]byte(inbound.Settings), &settings); err != nil {
			log.Printf("[WARN] Failed to parse settings for inbound %d: %v", inbound.Id, err)
			continue
		}

		clients, ok := settings["clients"].([]interface{})
		if !ok {
			log.Printf("[WARN] No clients found in settings for inbound %d", inbound.Id)
			continue
		}

		clientMap := make(map[string]map[string]interface{})
		for _, c := range clients {
			if clientObj, ok := c.(map[string]interface{}); ok {
				if email, ok := clientObj["email"].(string); ok {
					clientMap[email] = clientObj
				}
			}
		}

		for _, client := range inbound.ClientStats {
			// Using Email as the UUID/Identifier since 3x-ui onlines API uses Email
			email := client.Email
			if email == "" {
				continue
			}

			clientObj, ok := clientMap[email]
			if !ok {
				continue
			}

			// Extract UUID from clientObj
			uuid := email
			if id, ok := clientObj["id"].(string); ok {
				uuid = id
			}

			activeEmails[email] = true

			if state, exists := stateMap[email]; exists {
				// Detect transition from Enable: true -> Enable: false
				if state.Enable && !client.Enable {
					log.Printf("[ACTION] User %s disabled by panel. Triggering Xray API Restart to flush ghost connections.", email)
					triggerXrayRestart()
				}
				state.Enable = client.Enable
				state.UUID = uuid
			} else {
				stateMap[email] = &UserState{
					UUID:   uuid,
					Enable: client.Enable,
				}
			}

			// Pre-emptive Sub-second Kill Logic
			if client.Enable && client.Total > 0 {
				threshold := appConfig.Threshold
				if threshold <= 0 {
					threshold = 0.995 // Default to 99.5%
				}

				currentUsage := float64(client.Up + client.Down)
				quotaLimit := float64(client.Total)

				if currentUsage >= quotaLimit*threshold {
					log.Printf("[ACTION] User %s exceeded usage threshold (%.2f%%). PRE-EMPTIVELY DISABLING.", email, (currentUsage/quotaLimit)*100)

					// Manually update in-memory state to prevent duplicate triggers
					if state, exists := stateMap[email]; exists {
						state.Enable = false
					}

					// Disable via API
					if err := disableUser(uuid, inbound.Id, clientObj); err != nil {
						log.Printf("[ERROR] Pre-emptive disable failed for user %s: %v", email, err)
					}

					// Trigger restart
					triggerXrayRestart()
				}
			}
		}
	}

	// Optional: Prune deleted users
	for email := range stateMap {
		if !activeEmails[email] {
			delete(stateMap, email)
		}
	}

	log.Printf("[INFO] Synced %d users to memory", len(stateMap))
}

// Disable user via API (Pre-emptive Strike)
func disableUser(uuid string, inboundId int, clientObj map[string]interface{}) error {
	log.Printf("[INFO] Disabling user: %s", uuid)

	endpoint := fmt.Sprintf("/panel/api/inbounds/updateClient/%s", uuid)

	// Mutate client to disable it
	clientObj["enable"] = false

	// Structure the settings string exactly as 3x-ui v2.9.2 expects
	settingsMap := map[string]interface{}{
		"clients": []map[string]interface{}{clientObj},
	}

	settingsBytes, err := json.Marshal(settingsMap)
	if err != nil {
		return err
	}

	payload := map[string]interface{}{
		"id":       inboundId,
		"settings": string(settingsBytes),
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}

	_, err = apiRequest("POST", endpoint, body)
	return err
}

// Trigger Xray Restart via 3x-ui API with Dynamic Cooldown
func triggerXrayRestart() {
	restartLock.Lock()
	defer restartLock.Unlock()

	cooldown := appConfig.RestartCooldown
	if cooldown <= 0 {
		cooldown = 5 // default to 5 seconds if not configured or 0
	}

	if time.Since(lastRestartTime) < time.Duration(cooldown)*time.Second {
		log.Printf("[WARN] Xray restart skipped due to %d-second cooldown limitation.", cooldown)
		return
	}

	log.Println("[INFO] Sending API request to restart Xray core...")

	_, err := apiRequest("POST", "/panel/api/server/restartXrayService", nil)
	if err != nil {
		log.Printf("[ERROR] Failed to restart Xray via API: %v", err)
	} else {
		log.Println("[SUCCESS] Xray core restart triggered successfully via /panel/api/server/restartXrayService.")
		lastRestartTime = time.Now()
	}
}

// Watch DB for changes
func watchDB(dbPath string) {
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		log.Fatalf("[FATAL] Failed to create watcher: %v", err)
	}
	defer watcher.Close()

	// Watch the parent directory so we don't lose the watch if the DB file is replaced/restored
	dbDir := filepath.Dir(dbPath)
	dbBase := filepath.Base(dbPath)
	walBase := dbBase + "-wal"

	if err := watcher.Add(dbDir); err != nil {
		log.Fatalf("[FATAL] Failed to watch DB directory %s: %v", dbDir, err)
	}

	log.Printf("[INFO] Watching database directory: %s for changes to %s...", dbDir, dbBase)

	for {
		select {
		case event, ok := <-watcher.Events:
			if !ok {
				return
			}
			// Only react to changes of the specific db file or its wal file
			baseName := filepath.Base(event.Name)
			if baseName != dbBase && baseName != walBase {
				continue
			}

			if event.Op&fsnotify.Write == fsnotify.Write || event.Op&fsnotify.Create == fsnotify.Create {
				// Debounce: send signal to channel, non-blocking
				select {
				case dbSyncTrigger <- struct{}{}:
				default:
				}
			}
		case err, ok := <-watcher.Errors:
			if !ok {
				return
			}
			log.Printf("[ERROR] Watcher error: %v", err)
		}
	}
}

func main() {
	// 1. Read config path
	configPath := "config.json"
	for i, arg := range os.Args {
		if arg == "-config" && i+1 < len(os.Args) {
			configPath = os.Args[i+1]
		}
	}

	// 2. Load config
	file, err := os.ReadFile(configPath)
	if err != nil {
		log.Fatalf("[FATAL] Failed to read config %s: %v", configPath, err)
	}

	if err := json.Unmarshal(file, &appConfig); err != nil {
		log.Fatalf("[FATAL] Failed to parse config JSON: %v", err)
	}

	// 3. Initialize API and Login
	if err := initAPIClient(); err != nil {
		log.Fatalf("[FATAL] Failed to init HTTP client: %v", err)
	}

	if err := login(); err != nil {
		log.Fatalf("[FATAL] Initial login failed: %v", err)
	}

	// 4. Initial Sync
	syncUserConfigs()

	// 5. Start DB Watcher in goroutine
	go watchDB(appConfig.DBPath)

	// Debouncer for DB syncs
	go func() {
		for range dbSyncTrigger {
			time.Sleep(2 * time.Second) // 2 second debounce
			syncUserConfigs()

			// Drain any additional triggers that arrived during sleep
			select {
			case <-dbSyncTrigger:
			default:
			}
		}
	}()

	// 6. Enforcement Loop
	// The enforcement logic is now implicitly driven by the syncUserConfigs()
	// which is triggered by the DB watcher. We use the ticker here just as a
	// failsafe to periodically sync state in case fsnotify misses an event,
	// and to power the pre-emptive sub-second kill logic.
	checkInterval := appConfig.CheckInterval
	if checkInterval <= 0 {
		checkInterval = 0.5 // default to 0.5 seconds
	}

	tickerDuration := time.Duration(checkInterval * float64(time.Second))
	ticker := time.NewTicker(tickerDuration)
	defer ticker.Stop()

	for range ticker.C {
		syncUserConfigs()
	}
}

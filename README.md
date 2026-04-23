# Aegis-X

Aegis-X is a high-performance, open-source quota enforcer daemon for the 3x-ui (Xray-core) ecosystem. It strictly enforces user quotas via "Surgical Socket Killing" without ever needing to restart the Xray core.

## Features

- **Zero External Dependencies**: A static, single-binary daemon with negligible resource footprint.
- **Surgical Socket Killing**: Uses `ss -K` to terminate active user connections dynamically as soon as their quota is exceeded or time expires, preventing even a single byte of overage.
- **Continuous State Cache**: Keeps a persistent tracking of user's active IPs.
- **DB Watcher**: Uses `fsnotify` to watch `x-ui.db` and trigger low-latency synchronization of states via the 3x-ui API.
- **Offline-first Installer**: Designed for networks with restricted GitHub access.

## Architecture & How It Works

1. **Watch DB**: Aegis-X monitors the 3x-ui SQLite database (`/etc/x-ui/x-ui.db` by default) via `fsnotify`.
2. **Debounce & Fetch**: On DB change, it debounces the events and fetches the latest user limits and state via `/panel/api/inbounds/list`.
3. **Monitor Online Activity**: A goroutine continually fetches online clients and their associated IPs.
4. **Surgical Kill**: If a client is detected to be out of quota or expired, their latest active IPs are extracted, their state is updated to `enable: false` via API, and their sockets are instantly killed using `ss -K dst <USER_IP> dport = :<PROXY_PORT>`.
5. **Graceful Restore**: If an admin restores quota in the panel, `fsnotify` detects the change, Aegis-X recognizes the user is active, and immediately stops killing their sockets.

## Compiling from Source

To compile Aegis-X for Linux (AMD64), ensure you have Go 1.20+ installed, then run:

```bash
# Build the binary
GOOS=linux GOARCH=amd64 go build -o aegis-x-linux-amd64 main.go
```

## Installation

Aegis-X comes with an interactive, colored installer. It can download a release binary from GitHub, or fallback to an offline installation mode if the GitHub release is blocked in your network.

### Recommended / Standard Install

```bash
sudo ./install.sh
```

### Offline Install (For Heavily Filtered Networks)

1. Download or compile the `aegis-x-linux-amd64` (or `aegis-x`) binary on your local machine.
2. Transfer it to your server using SCP/SFTP to the same directory as `install.sh`.
3. Run the installer. It will automatically detect the local binary and install it!

```bash
sudo ./install.sh
```

## Running & Managing

The daemon is managed via systemd:

- **Check Status:** `sudo systemctl status aegis-x`
- **View Live Logs:** `sudo journalctl -u aegis-x -f`
- **Stop Daemon:** `sudo systemctl stop aegis-x`
- **Start Daemon:** `sudo systemctl start aegis-x`

## Configuration

The config file is located at `/etc/aegis-x/config.json`. The installer configures this file automatically, but you can update it if needed.

```json
{
  "panel_url": "http://127.0.0.1:2053",
  "username": "admin",
  "password": "password",
  "db_path": "/etc/x-ui/x-ui.db",
  "check_interval": 5
}
```

After modifying the file, simply restart the daemon to apply the changes.

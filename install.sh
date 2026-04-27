#!/bin/bash

# XUI-Watchdog Installer Script
# This script installs the XUI-Watchdog daemon, ensuring strict enforcement of user quotas for 3x-ui.

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CONFIG_DIR="/etc/xui-watchdog"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_DEST="/usr/local/bin/xui-watchdog"
SERVICE_FILE="/etc/systemd/system/xui-watchdog.service"

echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}      XUI-Watchdog Daemon Installer              ${NC}"
echo -e "${CYAN}=================================================${NC}"

# Root Check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run this installer as root (e.g., sudo ./install.sh)${NC}"
  exit 1
fi

echo -e "\n${YELLOW}Please select an option:${NC}"
echo "  [1] Install or Update Configuration"
echo "  [2] Completely Uninstall"
read -p "Enter choice [1-2]: " MENU_CHOICE

if [ "$MENU_CHOICE" == "2" ]; then
    echo -e "\n${CYAN}>>> Uninstalling XUI-Watchdog...${NC}"

    if systemctl is-active --quiet xui-watchdog; then
        systemctl stop xui-watchdog
    fi
    if systemctl is-enabled --quiet xui-watchdog; then
        systemctl disable xui-watchdog
    fi

    rm -f "$SERVICE_FILE"
    rm -f "$BIN_DEST"
    rm -rf "$CONFIG_DIR"

    systemctl daemon-reload
    echo -e "${GREEN}[SUCCESS] XUI-Watchdog has been completely uninstalled.${NC}"
    exit 0
fi

if [ "$MENU_CHOICE" != "1" ]; then
    echo -e "${RED}[ERROR] Invalid choice. Exiting.${NC}"
    exit 1
fi

# ==========================================
# Install or Update Configuration
# ==========================================

# Default values
DEF_PANEL_URL="http://127.0.0.1:2053"
DEF_USERNAME=""
DEF_PASSWORD=""
DEF_DB_PATH="/etc/x-ui/x-ui.db"
DEF_CHECK_INTERVAL="0.5"
DEF_RESTART_COOLDOWN="5"
DEF_THRESHOLD="0.995"

# Parse existing configuration if it exists
if [ -f "$CONFIG_FILE" ]; then
    echo -e "\n${GREEN}[INFO] Existing configuration found. Reading defaults...${NC}"
    # Use python3 to safely extract json keys without relying on jq (since it's a zero-dep script)
    if command -v python3 &>/dev/null; then
        DEF_PANEL_URL=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('panel_url', '$DEF_PANEL_URL'))" < "$CONFIG_FILE" 2>/dev/null)
        DEF_USERNAME=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('username', ''))" < "$CONFIG_FILE" 2>/dev/null)
        DEF_PASSWORD=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('password', ''))" < "$CONFIG_FILE" 2>/dev/null)
        DEF_DB_PATH=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('db_path', '$DEF_DB_PATH'))" < "$CONFIG_FILE" 2>/dev/null)
        DEF_CHECK_INTERVAL=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('check_interval', '$DEF_CHECK_INTERVAL'))" < "$CONFIG_FILE" 2>/dev/null)
        DEF_RESTART_COOLDOWN=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('restart_cooldown', '$DEF_RESTART_COOLDOWN'))" < "$CONFIG_FILE" 2>/dev/null)
        DEF_THRESHOLD=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('threshold', '$DEF_THRESHOLD'))" < "$CONFIG_FILE" 2>/dev/null)
    else
        # Fallback basic grep/awk parsing if python3 isn't available
        DEF_PANEL_URL=$(grep '"panel_url"' "$CONFIG_FILE" | cut -d '"' -f 4) || DEF_PANEL_URL="http://127.0.0.1:2053"
        DEF_USERNAME=$(grep '"username"' "$CONFIG_FILE" | cut -d '"' -f 4)
        DEF_PASSWORD=$(grep '"password"' "$CONFIG_FILE" | cut -d '"' -f 4)
        DEF_DB_PATH=$(grep '"db_path"' "$CONFIG_FILE" | cut -d '"' -f 4) || DEF_DB_PATH="/etc/x-ui/x-ui.db"
        DEF_CHECK_INTERVAL=$(grep '"check_interval"' "$CONFIG_FILE" | grep -o '[0-9.]*') || DEF_CHECK_INTERVAL="0.5"
        DEF_RESTART_COOLDOWN=$(grep '"restart_cooldown"' "$CONFIG_FILE" | tr -d -c 0-9) || DEF_RESTART_COOLDOWN="5"
        DEF_THRESHOLD=$(grep '"threshold"' "$CONFIG_FILE" | grep -o '[0-9.]*') || DEF_THRESHOLD="0.995"
    fi
fi

echo -e "\n${YELLOW}Please provide the following 3x-ui details (Press Enter to keep defaults):${NC}"

read -p "Panel URL [$DEF_PANEL_URL]: " PANEL_URL
PANEL_URL=${PANEL_URL:-$DEF_PANEL_URL}

read -p "Username [$DEF_USERNAME]: " USERNAME
USERNAME=${USERNAME:-$DEF_USERNAME}
if [ -z "$USERNAME" ]; then
    echo -e "${RED}[ERROR] Username cannot be empty.${NC}"
    exit 1
fi

if [ -n "$DEF_PASSWORD" ]; then
    read -s -p "Password [*** HIDDEN ***]: " PASSWORD
    echo ""
    PASSWORD=${PASSWORD:-$DEF_PASSWORD}
else
    read -s -p "Password: " PASSWORD
    echo ""
fi
if [ -z "$PASSWORD" ]; then
    echo -e "${RED}[ERROR] Password cannot be empty.${NC}"
    exit 1
fi

read -p "Database Path [$DEF_DB_PATH]: " DB_PATH
DB_PATH=${DB_PATH:-$DEF_DB_PATH}

read -p "Check Interval in seconds (e.g., 0.5) [$DEF_CHECK_INTERVAL]: " CHECK_INTERVAL
CHECK_INTERVAL=${CHECK_INTERVAL:-$DEF_CHECK_INTERVAL}

read -p "Usage Threshold (e.g., 0.995 for 99.5%) [$DEF_THRESHOLD]: " THRESHOLD
THRESHOLD=${THRESHOLD:-$DEF_THRESHOLD}

read -p "Restart Cooldown in seconds [$DEF_RESTART_COOLDOWN]: " RESTART_COOLDOWN
RESTART_COOLDOWN=${RESTART_COOLDOWN:-$DEF_RESTART_COOLDOWN}


# Offline-First Logic (Binary Installation)
echo -e "\n${CYAN}>>> Checking for XUI-Watchdog binary...${NC}"

if [ -f "./xui-watchdog" ]; then
    echo -e "${GREEN}[INFO] Local binary 'xui-watchdog' detected. Skipping download.${NC}"
    cp ./xui-watchdog "$BIN_DEST"
elif [ -f "./xui-watchdog-linux-amd64" ]; then
    echo -e "${GREEN}[INFO] Local binary 'xui-watchdog-linux-amd64' detected. Skipping download.${NC}"
    cp ./xui-watchdog-linux-amd64 "$BIN_DEST"
else
    echo -e "${YELLOW}[INFO] Local binary not found. Attempting to download from GitHub...${NC}"
    # MOCK GitHub Release URL - Update this to the actual release URL when available
    MOCK_GITHUB_URL="https://github.com/mock-user/xui-watchdog/releases/latest/download/xui-watchdog-linux-amd64"

    if wget -q --timeout=15 -O "$BIN_DEST" "$MOCK_GITHUB_URL"; then
        echo -e "${GREEN}[INFO] Download successful.${NC}"
    else
        echo -e "${RED}[ERROR] Failed to download XUI-Watchdog from GitHub (Timeout or Blocked).${NC}"
        echo -e "${RED}[ERROR] GitHub is likely blocked. Please download the release ZIP manually,${NC}"
        echo -e "${RED}[ERROR] upload it to this folder, extract it, and run this installer again.${NC}"
        rm -f "$BIN_DEST" # Clean up partial download
        exit 1
    fi
fi

# Make binary executable
chmod +x "$BIN_DEST"
echo -e "${GREEN}[SUCCESS] XUI-Watchdog binary installed at ${BIN_DEST}${NC}"


# Configuration Setup
echo -e "\n${CYAN}>>> Setting up configuration...${NC}"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
{
  "panel_url": "$PANEL_URL",
  "username": "$USERNAME",
  "password": "$PASSWORD",
  "db_path": "$DB_PATH",
  "check_interval": $CHECK_INTERVAL,
  "restart_cooldown": $RESTART_COOLDOWN,
  "threshold": $THRESHOLD
}
EOF

chmod 600 "$CONFIG_FILE" # Secure configuration file
echo -e "${GREEN}[SUCCESS] Configuration created at ${CONFIG_FILE}${NC}"


# Systemd Service Setup
echo -e "\n${CYAN}>>> Creating systemd service...${NC}"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=XUI-Watchdog Quota Enforcer Daemon
After=network.target

[Service]
Type=simple
User=root
ExecStart=$BIN_DEST -config $CONFIG_FILE
Restart=always
RestartSec=5
LimitNOFILE=1048576
# Note: Log rotation is automatically handled by systemd's journald backend.

[Install]
WantedBy=multi-user.target
EOF

echo -e "${GREEN}[SUCCESS] Systemd service created at ${SERVICE_FILE}${NC}"


# Start and Enable Daemon
echo -e "\n${CYAN}>>> Starting XUI-Watchdog service...${NC}"
systemctl daemon-reload
systemctl enable xui-watchdog
systemctl restart xui-watchdog

if systemctl is-active --quiet xui-watchdog; then
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}  XUI-Watchdog installed and running successfully!${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo -e "Use 'systemctl status xui-watchdog' to check its status."
    echo -e "Use 'journalctl -u xui-watchdog -f' to view live logs."
else
    echo -e "${RED}[ERROR] XUI-Watchdog failed to start. Please check the logs: journalctl -u xui-watchdog -e${NC}"
    exit 1
fi

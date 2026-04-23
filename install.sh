#!/bin/bash

# Aegis-X Installer Script
# This script installs the Aegis-X daemon, ensuring strict enforcement of user quotas for 3x-ui.

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

CONFIG_DIR="/etc/aegis-x"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BIN_DEST="/usr/local/bin/aegis-x"
SERVICE_FILE="/etc/systemd/system/aegis-x.service"

echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}         Aegis-X Daemon Installer                ${NC}"
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
    echo -e "\n${CYAN}>>> Uninstalling Aegis-X...${NC}"

    if systemctl is-active --quiet aegis-x; then
        systemctl stop aegis-x
    fi
    if systemctl is-enabled --quiet aegis-x; then
        systemctl disable aegis-x
    fi

    rm -f "$SERVICE_FILE"
    rm -f "$BIN_DEST"
    rm -rf "$CONFIG_DIR"

    systemctl daemon-reload
    echo -e "${GREEN}[SUCCESS] Aegis-X has been completely uninstalled.${NC}"
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
DEF_CHECK_INTERVAL="5"

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
    else
        # Fallback basic grep/awk parsing if python3 isn't available
        DEF_PANEL_URL=$(grep '"panel_url"' "$CONFIG_FILE" | cut -d '"' -f 4) || DEF_PANEL_URL="http://127.0.0.1:2053"
        DEF_USERNAME=$(grep '"username"' "$CONFIG_FILE" | cut -d '"' -f 4)
        DEF_PASSWORD=$(grep '"password"' "$CONFIG_FILE" | cut -d '"' -f 4)
        DEF_DB_PATH=$(grep '"db_path"' "$CONFIG_FILE" | cut -d '"' -f 4) || DEF_DB_PATH="/etc/x-ui/x-ui.db"
        DEF_CHECK_INTERVAL=$(grep '"check_interval"' "$CONFIG_FILE" | tr -d -c 0-9) || DEF_CHECK_INTERVAL="5"
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

read -p "Check Interval in seconds [$DEF_CHECK_INTERVAL]: " CHECK_INTERVAL
CHECK_INTERVAL=${CHECK_INTERVAL:-$DEF_CHECK_INTERVAL}


# Offline-First Logic (Binary Installation)
echo -e "\n${CYAN}>>> Checking for Aegis-X binary...${NC}"

if [ -f "./aegis-x" ]; then
    echo -e "${GREEN}[INFO] Local binary 'aegis-x' detected. Skipping download.${NC}"
    cp ./aegis-x "$BIN_DEST"
elif [ -f "./aegis-x-linux-amd64" ]; then
    echo -e "${GREEN}[INFO] Local binary 'aegis-x-linux-amd64' detected. Skipping download.${NC}"
    cp ./aegis-x-linux-amd64 "$BIN_DEST"
else
    echo -e "${YELLOW}[INFO] Local binary not found. Attempting to download from GitHub...${NC}"
    # MOCK GitHub Release URL - Update this to the actual release URL when available
    MOCK_GITHUB_URL="https://github.com/mock-user/aegis-x/releases/latest/download/aegis-x-linux-amd64"

    if wget -q --timeout=15 -O "$BIN_DEST" "$MOCK_GITHUB_URL"; then
        echo -e "${GREEN}[INFO] Download successful.${NC}"
    else
        echo -e "${RED}[ERROR] Failed to download Aegis-X from GitHub (Timeout or Blocked).${NC}"
        echo -e "${RED}[ERROR] GitHub is likely blocked. Please download the release ZIP manually,${NC}"
        echo -e "${RED}[ERROR] upload it to this folder, extract it, and run this installer again.${NC}"
        rm -f "$BIN_DEST" # Clean up partial download
        exit 1
    fi
fi

# Make binary executable
chmod +x "$BIN_DEST"
echo -e "${GREEN}[SUCCESS] Aegis-X binary installed at ${BIN_DEST}${NC}"


# Configuration Setup
echo -e "\n${CYAN}>>> Setting up configuration...${NC}"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
{
  "panel_url": "$PANEL_URL",
  "username": "$USERNAME",
  "password": "$PASSWORD",
  "db_path": "$DB_PATH",
  "check_interval": $CHECK_INTERVAL
}
EOF

chmod 600 "$CONFIG_FILE" # Secure configuration file
echo -e "${GREEN}[SUCCESS] Configuration created at ${CONFIG_FILE}${NC}"


# Systemd Service Setup
echo -e "\n${CYAN}>>> Creating systemd service...${NC}"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Aegis-X Quota Enforcer Daemon
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
echo -e "\n${CYAN}>>> Starting Aegis-X service...${NC}"
systemctl daemon-reload
systemctl enable aegis-x
systemctl restart aegis-x

if systemctl is-active --quiet aegis-x; then
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}    Aegis-X installed and running successfully!  ${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo -e "Use 'systemctl status aegis-x' to check its status."
    echo -e "Use 'journalctl -u aegis-x -f' to view live logs."
else
    echo -e "${RED}[ERROR] Aegis-X failed to start. Please check the logs: journalctl -u aegis-x -e${NC}"
    exit 1
fi

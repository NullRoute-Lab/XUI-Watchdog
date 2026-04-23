#!/bin/bash

# Aegis-X Installer Script
# This script installs the Aegis-X daemon, ensuring strict enforcement of user quotas for 3x-ui.

# Terminal Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}         Aegis-X Daemon Installer                ${NC}"
echo -e "${CYAN}=================================================${NC}"

# 1. Root Check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run this installer as root (e.g., sudo ./install.sh)${NC}"
  exit 1
fi

# 2. Prompt for Configuration
echo -e "\n${YELLOW}Please provide the following 3x-ui details:${NC}"

read -p "Panel URL (e.g., http://127.0.0.1:2053): " PANEL_URL
if [ -z "$PANEL_URL" ]; then
    PANEL_URL="http://127.0.0.1:2053"
    echo -e "${YELLOW}Using default Panel URL: ${PANEL_URL}${NC}"
fi

read -p "Username: " USERNAME
if [ -z "$USERNAME" ]; then
    echo -e "${RED}[ERROR] Username cannot be empty.${NC}"
    exit 1
fi

read -s -p "Password: " PASSWORD
echo ""
if [ -z "$PASSWORD" ]; then
    echo -e "${RED}[ERROR] Password cannot be empty.${NC}"
    exit 1
fi

read -p "Database Path (default: /etc/x-ui/x-ui.db): " DB_PATH
if [ -z "$DB_PATH" ]; then
    DB_PATH="/etc/x-ui/x-ui.db"
    echo -e "${YELLOW}Using default Database Path: ${DB_PATH}${NC}"
fi


# 3. Offline-First Logic (Binary Installation)
BIN_DEST="/usr/local/bin/aegis-x"
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


# 4. Configuration Setup
CONFIG_DIR="/etc/aegis-x"
CONFIG_FILE="${CONFIG_DIR}/config.json"

echo -e "\n${CYAN}>>> Setting up configuration...${NC}"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
{
  "panel_url": "$PANEL_URL",
  "username": "$USERNAME",
  "password": "$PASSWORD",
  "db_path": "$DB_PATH",
  "check_interval": 5
}
EOF

chmod 600 "$CONFIG_FILE" # Secure configuration file
echo -e "${GREEN}[SUCCESS] Configuration created at ${CONFIG_FILE}${NC}"


# 5. Systemd Service Setup
SERVICE_FILE="/etc/systemd/system/aegis-x.service"

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


# 6. Start and Enable Daemon
echo -e "\n${CYAN}>>> Starting Aegis-X service...${NC}"
systemctl daemon-reload
systemctl enable aegis-x
systemctl start aegis-x

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

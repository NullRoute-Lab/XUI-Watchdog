# XUI-Watchdog

XUI-Watchdog is a high-performance, open-source quota enforcer daemon for the 3x-ui (Xray-core) ecosystem. It provides robust, native-level enforcement of bandwidth and expiration limits dynamically via the 3x-ui API.

## Core Features

- **Zero External Dependencies**: A static, single-binary daemon written in Go with negligible resource footprint.
- **Smart API-Driven Xray Restart**: Instead of using risky OS-level socket killing (`ss -K`), it detects when the 3x-ui panel disables a user and natively flushes their ghost connections via the `/panel/api/server/restartXrayService` endpoint.
- **Dynamic Rate Limiting**: Fully configurable restart cooldown mechanism prevents Xray from entering a restart loop during mass expirations.
- **Pre-emptive Sub-second Detection**: A threshold-based early warning system. By configuring a high-speed usage threshold (e.g., `0.995` or 99.5%), the daemon can intercept high-bandwidth users *before* they cross the line, explicitly disabling them via the 3x-ui API between native panel ticks to prevent over-consumption.
- **Resilient DB Watcher**: Employs `fsnotify` to track the parent directory (`/etc/x-ui/`) for database updates and `-wal` transitions, ensuring the watch isn't dropped during administrative DB restores or backups.
- **Offline-First Installer**: An interactive bash installation script built for heavily filtered networks, capable of installing local binary payloads without relying on GitHub.

## Architecture Overview

1. **Monitor State**: XUI-Watchdog monitors `/etc/x-ui/` for modifications to the SQLite database.
2. **Debounce & Fetch**: On DB modification, the daemon safely debounces the event and fetches the live JSON configurations via the `/panel/api/inbounds/list` API.
3. **Threshold Enforcement**: A sub-second Goroutine evaluates `up + down` data limits natively. If a user crosses the configurable `threshold`, the daemon sends an immediate `POST` payload directly disabling the user and triggering a cooldown-protected Xray API restart.
4. **Native Synchronization**: When an admin restores a user's quota, the DB watcher catches the event, resets the user's `Enable` state in memory, and resets enforcement actions.

## Compiling from Source

To compile XUI-Watchdog for Linux (AMD64), ensure you have Go 1.24+ installed:

```bash
# Build the binary
GOOS=linux GOARCH=amd64 go build -o xui-watchdog-linux-amd64 main.go
```

## Installation

XUI-Watchdog comes with an interactive, colored installer.

### Recommended / Standard Install

```bash
sudo ./install.sh
```

### Offline Install (For Heavily Filtered Networks)

1. Download or compile the `xui-watchdog-linux-amd64` (or `xui-watchdog`) binary on your local machine.
2. Transfer it to your server using SCP/SFTP to the same directory as `install.sh`.
3. Run the installer. It will automatically detect the local binary and install it without network fetches!

```bash
sudo ./install.sh
```

## Running & Managing

The daemon is managed via systemd natively. Log rotation is seamlessly handled via `journald` to prevent disk exhaustion.

- **Check Status:** `sudo systemctl status xui-watchdog`
- **View Live Logs:** `sudo journalctl -u xui-watchdog -f`
- **Stop Daemon:** `sudo systemctl stop xui-watchdog`
- **Start Daemon:** `sudo systemctl start xui-watchdog`

## Configuration

The config file is located at `/etc/xui-watchdog/config.json`. The installer configures this file interactively, but you can update it if needed.

```json
{
  "panel_url": "http://127.0.0.1:2053",
  "username": "admin",
  "password": "password",
  "db_path": "/etc/x-ui/x-ui.db",
  "check_interval": 0.5,
  "restart_cooldown": 5,
  "threshold": 0.995
}
```

After modifying the file, simply run `sudo ./install.sh` and choose Option [1] to rapidly reload your new values.

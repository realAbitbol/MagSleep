#!/bin/bash
# Installs the MagSleep privileged helper. Runs as root, invoked by the app.
# Usage: install-helper.sh <app-resources-dir> <console-user> [app-version]
set -euo pipefail

RESOURCES="$1"
LABEL="com.magsleep.helper"
BIN="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG_DIR="/Library/Logs/MagSleep"
CONFIG_DIR="/Library/Preferences/MagSleep"
APP_VERSION="${3:-unknown}"

launchctl bootout "system/$LABEL" 2>/dev/null || true

mkdir -p /Library/PrivilegedHelperTools "$LOG_DIR" "$CONFIG_DIR"
install -m 755 -o root -g wheel "$RESOURCES/magsleep-helper" "$BIN"
install -m 644 -o root -g wheel "$RESOURCES/$LABEL.plist" "$PLIST"

echo "$APP_VERSION" > "$CONFIG_DIR/helper-version.txt"
chown root:wheel "$CONFIG_DIR/helper-version.txt"
chmod 644 "$CONFIG_DIR/helper-version.txt"

# bootstrap can race with the bootout above (launchd may not have finished
# unloading); retry once after a brief pause instead of failing the whole
# reinstall.
if ! launchctl bootstrap system "$PLIST" 2>/dev/null; then
    sleep 1
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    launchctl bootstrap system "$PLIST"
fi
echo "MagSleep helper installed"
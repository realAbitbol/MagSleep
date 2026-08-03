#!/bin/bash
# Installs the MagSleep privileged helper. Runs as root, invoked by the app.
# Usage: install-helper.sh <app-resources-dir> <console-user>
set -euo pipefail

RESOURCES="$1"
LABEL="com.magsleep.helper"
BIN="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG_DIR="/Library/Logs/MagSleep"

launchctl bootout "system/$LABEL" 2>/dev/null || true

mkdir -p /Library/PrivilegedHelperTools "$LOG_DIR"
install -m 755 -o root -g wheel "$RESOURCES/magsleep-helper" "$BIN"
install -m 644 -o root -g wheel "$RESOURCES/$LABEL.plist" "$PLIST"

launchctl bootstrap system "$PLIST"
echo "MagSleep helper installed"

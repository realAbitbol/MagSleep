#!/bin/bash
# Removes the MagSleep privileged helper and hands the LED back to macOS.
# Runs as root. Usage: uninstall-helper.sh [resources] [user]
set -uo pipefail

LABEL="com.magsleep.helper"
BIN="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG_DIR="/Library/Logs/MagSleep"

launchctl bootout "system/$LABEL" 2>/dev/null || true
[ -x "$BIN" ] && "$BIN" --reset || true

rm -f "$BIN" "$PLIST"
rm -rf "$LOG_DIR"
echo "MagSleep helper removed"

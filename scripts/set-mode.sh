#!/bin/bash
# Sets the MagSleep operation mode and signals the helper to reload.
# Runs as root. Usage: set-mode.sh <mode>
#   mode: "sleep" or "alwaysOff"
set -euo pipefail

MODE="$1"
CONFIG_DIR="/Library/Preferences/MagSleep"
CONFIG_FILE="$CONFIG_DIR/config.plist"
LABEL="com.magsleep.helper"

mkdir -p "$CONFIG_DIR"

# Write config as plist
cat > "$CONFIG_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>mode</key>
    <string>$MODE</string>
</dict>
</plist>
EOF

chown root:wheel "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# Signal helper to reload config
PIDS=$(pgrep -f "$LABEL" 2>/dev/null || true)
for PID in $PIDS; do
    kill -HUP "$PID" 2>/dev/null || true
done

echo "Mode set to $MODE"

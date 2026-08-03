#!/bin/bash
# Disables MagSleep without removing installed files.
# Runs as root. Usage: disable-helper.sh [resources] [user]
set -uo pipefail

LABEL="com.magsleep.helper"
BIN="/Library/PrivilegedHelperTools/$LABEL"

launchctl bootout "system/$LABEL" 2>/dev/null || true
[ -x "$BIN" ] && "$BIN" --reset || true
echo "MagSleep helper disabled"

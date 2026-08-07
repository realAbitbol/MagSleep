#!/bin/bash
# Builds a drag-to-Applications MagSleep DMG into dist/.
# Usage: scripts/build-dmg.sh [version]
# Expects dist/MagSleep.app to already exist (run build-app.sh first).
set -euo pipefail

trap 'echo "" >&2
      echo "build-dmg.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR

cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
DIST="dist"
APP="$DIST/MagSleep.app"
DMG_NAME="MagSleep-${VERSION}"
DMG="$DIST/${DMG_NAME}.dmg"
STAGE="$DIST/dmg-stage"
VOLUME_NAME="MagSleep"
MOUNT_DIR=""

# Clean up the mounted image and temp files on any failure path, so a retry
# never hits "resource busy" or leaves a stale DMG behind.
cleanup() {
    if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    rm -rf "$DIST/${DMG_NAME}.temp.dmg" "$STAGE"
}
trap cleanup EXIT

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run scripts/build-app.sh first" >&2
    exit 1
fi

rm -rf "$STAGE" "$DMG" "$DIST/${DMG_NAME}.temp.dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MagSleep.app"
ln -s /Applications "$STAGE/Applications"

# Create a read/write image, then convert to compressed UDZO.
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDRW \
    "$DIST/${DMG_NAME}.temp.dmg"

# Mount, set a sensible Finder window layout, then compress.
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$DIST/${DMG_NAME}.temp.dmg" \
    | awk '/\/Volumes\//{print $3; exit}')
if [ -z "${MOUNT_DIR:-}" ] || [ ! -d "$MOUNT_DIR" ]; then
    echo "error: failed to mount temporary DMG" >&2
    exit 1
fi

# Best-effort Finder view settings; skip quietly if osascript fails (CI/headless).
osascript <<EOF >/dev/null 2>&1 || true
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 760, 480}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set position of item "MagSleep.app" of container window to {140, 180}
    set position of item "Applications" of container window to {420, 180}
    update without registering applications
    delay 0.5
    close
  end tell
end tell
EOF

sync
hdiutil detach "$MOUNT_DIR" >/dev/null

hdiutil convert "$DIST/${DMG_NAME}.temp.dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG"
rm -f "$DIST/${DMG_NAME}.temp.dmg"
rm -rf "$STAGE"

echo "built $DMG"

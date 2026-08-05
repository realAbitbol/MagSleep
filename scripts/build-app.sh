#!/bin/bash
# Builds MagSleep.app into dist/. Usage: scripts/build-app.sh [version]
set -euo pipefail

trap 'echo "" >&2
      echo "build-app.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR

cd "$(dirname "$0")/.."
VERSION="${1:-1.0.0}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DIST="dist"
APP="$DIST/MagSleep.app"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode Command Line Tools are missing. Install them with:" >&2
    echo "  xcode-select --install" >&2
    exit 1
fi

echo "macOS $(sw_vers -productVersion) · $(swift --version 2>&1 | head -1)"

ARCH_FLAGS="--arch arm64"
swift build -c release $ARCH_FLAGS
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN_DIR/MagSleep" "$APP/Contents/MacOS/MagSleep"
cp "$BIN_DIR/magsleep-helper" "$APP/Contents/Resources/magsleep-helper"
cp packaging/com.magsleep.helper.plist "$APP/Contents/Resources/"
cp packaging/MagSleep.sdef "$APP/Contents/Resources/"
cp scripts/install-helper.sh scripts/uninstall-helper.sh \
    "$APP/Contents/Resources/"
# Sparkle framework (SwiftPM puts it in the build bin dir; versioned bundle,
# so preserve symlinks with cp -R). Signed ad-hoc along with the app below.
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
chmod +x "$APP/Contents/Resources/"*.sh "$APP/Contents/Resources/magsleep-helper"

# Helper revision: the last commit that touched helper-affecting code (the
# helper binary, the shared core it links, its LaunchDaemon plist, or the
# install script). The app compares the revision written at install time
# against this to decide whether to reinstall — so the unchanged helper is
# never reinstalled on a plain app update. "unknown" (no git, e.g. a tarball
# build) keeps the legacy always-reinstall behavior.
HELPER_REV="$(git log -1 --format=%h -- Sources/MagSleepHelper Sources/MagSleepCore packaging scripts/install-helper.sh 2>/dev/null || true)"
if [ -z "$HELPER_REV" ]; then
    HELPER_REV="unknown"
fi
printf '%s' "$HELPER_REV" > "$APP/Contents/Resources/helper-revision.txt"

sed -e "s/MAGSLEEP_VERSION/$VERSION/" -e "s/MAGSLEEP_BUILD/$BUILD_NUMBER/" \
    packaging/Info.plist > "$APP/Contents/Info.plist"

# Minimal template icon via SF Symbol rendered to icns if possible; otherwise skip.
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    ICON_TMP="$DIST/icon-work"
    rm -rf "$ICON_TMP"
    mkdir -p "$ICON_TMP/AppIcon.iconset"
    # Generate a simple PNG with Swift/AppKit if make-icon exists; else use a solid color.
    if [ -f scripts/make-icon.swift ]; then
        swift scripts/make-icon.swift "$ICON_TMP/AppIcon.png" >/dev/null
        for s in 16 32 128 256 512; do
            sips -z $s $s "$ICON_TMP/AppIcon.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
            d=$((s * 2))
            sips -z $d $d "$ICON_TMP/AppIcon.png" --out "$ICON_TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
        done
        iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
    fi
    rm -rf "$ICON_TMP"
fi

codesign --force --sign - "$APP/Contents/Resources/magsleep-helper"
codesign --force --sign - --deep "$APP"

if [ ! -x "$APP/Contents/MacOS/MagSleep" ]; then
    echo "build finished but $APP/Contents/MacOS/MagSleep is missing" >&2
    exit 1
fi

echo "built $APP (version $VERSION)"

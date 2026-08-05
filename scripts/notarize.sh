#!/bin/bash
# Notarizes dist/MagSleep.app if a Developer ID certificate is available.
#
# Notarization requires an Apple Developer Program membership (paid, $99/yr)
# and the notarytool credentials stored via:
#   xcrun notarytool store-credentials "notarytool" --apple-id ... --team-id ... --password ...
#
# Without a Developer ID cert this script exits 0 and prints guidance, so
# `make notarize` is safe to run on any machine.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="dist/MagSleep.app"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found — run scripts/build-app.sh first" >&2
    exit 1
fi

IDENTITY=$(security find-identity -p codesigning -v 2>/dev/null \
    | grep "Developer ID Application" | head -1 || true)

if [ -z "$IDENTITY" ]; then
    echo "No Developer ID certificate found."
    echo "Notarization requires an Apple Developer Program membership (\$99/year)."
    echo "Skipping — the app remains ad-hoc signed. Install from source with 'make install'."
    exit 0
fi

# "Developer ID Application: Name (TEAMID)" -> "Name"
CERT_NAME=$(echo "$IDENTITY" \
    | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]*//' \
    | sed -E 's/[[:space:]]*\([A-Z0-9]*\)[[:space:]]*$//')

echo "Signing with Developer ID: $CERT_NAME"
codesign --force --options runtime --sign "$CERT_NAME" "$APP/Contents/Resources/magsleep-helper"
codesign --force --options runtime --sign "$CERT_NAME" --deep "$APP"

echo "Submitting for notarization…"
if ! xcrun notarytool submit "$APP" --wait --keychain-profile "notarytool" 2>/dev/null; then
    echo "Notarization submission failed." >&2
    echo "Store your credentials first: xcrun notarytool store-credentials \"notarytool\"" >&2
    exit 1
fi

echo "Stapling…"
xcrun stapler staple "$APP"
echo "Notarized $APP"

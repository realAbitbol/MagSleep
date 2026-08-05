#!/bin/bash
# Updates Casks/magsleep.rb with the version and DMG sha256 for a release.
# The sha256 must match the DMG uploaded to GitHub, so it is computed from the
# same artifact `make dmg` produces (and `make release` uploads).
# Usage: make cask VERSION=x.y.z   (requires dist/MagSleep-x.y.z.dmg)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: usage: make cask VERSION=x.y.z" >&2
    exit 1
fi

DMG="dist/MagSleep-$VERSION.dmg"
if [ ! -f "$DMG" ]; then
    echo "error: $DMG not found — run 'make dmg VERSION=$VERSION' first" >&2
    exit 1
fi

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"

sed -i '' -E \
    -e "s/version \"[0-9.]+\"/version \"$VERSION\"/" \
    -e "s/sha256 \"[0-9a-f]{64}\"/sha256 \"$SHA\"/" \
    Casks/magsleep.rb

echo "updated Casks/magsleep.rb (version $VERSION, sha256 $SHA)"

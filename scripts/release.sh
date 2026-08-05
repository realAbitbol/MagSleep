#!/bin/bash
# Creates a tagged release: runs tests, builds the DMG, updates the README
# version references and the Makefile default, commits, tags, pushes branch +
# tag to origin, and publishes a GitHub Release with the DMG attached.
#
# Usage: make release VERSION=X.Y.Z
#
# Safe by design: refuses a dirty tree or an existing tag, never force-pushes,
# and stops on any failure. Publish via `gh` degrades to a warning when gh is
# unavailable.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: usage: make release VERSION=X.Y.Z" >&2
    exit 1
fi
TAG="v$VERSION"
APP="dist/MagSleep.app"
DMG="dist/MagSleep-$VERSION.dmg"
ZIP="dist/MagSleep-$VERSION.zip"
BRANCH="$(git branch --show-current)"

# Locate Sparkle's appcast generator (built via SPM dependency). Must be an
# ABSOLUTE path: it is invoked from a subshell that cd's into the staging dir.
ROOT="$(pwd -P)"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
if [ ! -x "$GENERATE_APPCAST" ]; then
    GENERATE_APPCAST="$(command -v generate_appcast || true)"
fi

# 1. Sanity checks -----------------------------------------------------------
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree has uncommitted changes; commit or stash first" >&2
    exit 1
fi

# 2. Test + build -----------------------------------------------------------
make test
make dmg VERSION="$VERSION"

# 3. Update version references ----------------------------------------------
# README "From source" examples (VERSION=1.0.x) and DMG filenames
# (MagSleep-1.0.x.dmg, e.g. the Gatekeeper guide) to the new version.
sed -i '' -E \
    -e "s/VERSION=1\.[0-9]+\.[0-9]+/VERSION=$VERSION/g" \
    -e "s/MagSleep-1\.[0-9]+\.[0-9]+\.dmg/MagSleep-$VERSION.dmg/g" \
    README.md
# Makefile default so plain `make app`/`make dmg` build the new version
sed -i '' -E "s/^VERSION \?= .*/VERSION ?= $VERSION/" Makefile

# 3.5. Sparkle update archive + appcast --------------------------------------
# The ZIP is what Sparkle downloads for in-app updates; the DMG stays for
# human installs. The appcast (committed at appcast/appcast.xml, served from
# GitHub raw) is regenerated with the new entry, EdDSA-signed from the login
# keychain (generate_keys), and the enclosure URL pointed at the release asset.
if [ -x "$GENERATE_APPCAST" ]; then
    APPCAST_STAGE="dist/appcast-staging"
    mkdir -p "$APPCAST_STAGE"
    if [ -f appcast/appcast.xml ]; then
        cp appcast/appcast.xml "$APPCAST_STAGE/appcast.xml"
    fi
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    cp "$ZIP" "$APPCAST_STAGE/"
    ( cd "$APPCAST_STAGE" && "$GENERATE_APPCAST" . )
    sed -i '' -E "s|url=\"MagSleep-$VERSION\.zip\"|url=\"https://github.com/realAbitbol/MagSleep/releases/download/$TAG/MagSleep-$VERSION.zip\"|" "$APPCAST_STAGE/appcast.xml"
    mkdir -p appcast
    cp "$APPCAST_STAGE/appcast.xml" appcast/appcast.xml
    rm -rf "$APPCAST_STAGE"
else
    echo "warning: generate_appcast not found — Sparkle appcast not updated for $VERSION" >&2
fi

# 4. Commit + tag -----------------------------------------------------------
git add README.md Makefile appcast/appcast.xml
if ! git diff --cached --quiet; then
    git commit -m "Release v$VERSION"
fi
git tag -a "$TAG" -m "MagSleep $VERSION"

# 5. Push -------------------------------------------------------------------
git push origin "$BRANCH"
git push origin "$TAG"

# 6. GitHub Release ---------------------------------------------------------
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release create "$TAG" "$DMG" "$ZIP" \
        --repo realAbitbol/MagSleep \
        --title "MagSleep $VERSION" \
        --notes "MagSleep $VERSION — see the README for installation instructions."
    echo "published GitHub release: https://github.com/realAbitbol/MagSleep/releases/tag/$TAG"
else
    echo "warning: gh not available/authenticated — tag pushed, create the GitHub Release manually" >&2
fi

echo "released $TAG ($DMG, $ZIP)"

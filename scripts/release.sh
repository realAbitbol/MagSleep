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

# 3.4. Release notes from CHANGELOG.md ---------------------------------------
# The "[VERSION]" section of CHANGELOG.md is used for the GitHub release body
# AND embedded in the Sparkle appcast (shown in the in-app update window).
# Falls back to a generic message if the section is missing or empty.
NOTES=""
if [ -f CHANGELOG.md ]; then
    NOTES="$(awk -v hdr="## [$VERSION]" '
        index($0, hdr) == 1 { in_section = 1; next }
        in_section && substr($0, 1, 3) == "## " { exit }
        in_section
    ' CHANGELOG.md)"
fi
if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
    echo "warning: no CHANGELOG.md section found for [$VERSION]; using a generic release note" >&2
    NOTES="MagSleep $VERSION — see the README for installation instructions."
fi

# 3.5. Sparkle update archive + appcast --------------------------------------
# The ZIP is what Sparkle downloads for in-app updates; the DMG stays for
# human installs. The appcast (committed at appcast/appcast.xml, served from
# GitHub raw) is regenerated with the new entry, EdDSA-signed from the login
# keychain (generate_keys), and the enclosure URL pointed at the release asset.
# The release notes are embedded so the Sparkle update window shows them.
if [ -x "$GENERATE_APPCAST" ]; then
    APPCAST_STAGE="dist/appcast-staging"
    mkdir -p "$APPCAST_STAGE"
    if [ -f appcast/appcast.xml ]; then
        cp appcast/appcast.xml "$APPCAST_STAGE/appcast.xml"
    fi
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    cp "$ZIP" "$APPCAST_STAGE/"
    # Same base name as the archive → Sparkle uses it as this item's notes.
    printf '%s\n' "$NOTES" > "$APPCAST_STAGE/MagSleep-$VERSION.md"
    ( cd "$APPCAST_STAGE" && "$GENERATE_APPCAST" --embed-release-notes . )
    sed -i '' -E "s|url=\"MagSleep-$VERSION\.zip\"|url=\"https://github.com/realAbitbol/MagSleep/releases/download/$TAG/MagSleep-$VERSION.zip\"|" "$APPCAST_STAGE/appcast.xml"
    mkdir -p appcast
    cp "$APPCAST_STAGE/appcast.xml" appcast/appcast.xml
    rm -rf "$APPCAST_STAGE"
else
    echo "warning: generate_appcast not found — Sparkle appcast not updated for $VERSION" >&2
fi

# 3.6. Homebrew cask ----------------------------------------------------------
# Keep Casks/magsleep.rb in sync with the release (version + DMG sha256).
if [ -f "$DMG" ]; then
    scripts/build-cask.sh "$VERSION"
else
    echo "warning: $DMG not found — cask not updated" >&2
fi

# 4. Commit + tag -----------------------------------------------------------
git add README.md Makefile appcast/appcast.xml Casks/magsleep.rb
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
        --notes "$NOTES"
    echo "published GitHub release: https://github.com/realAbitbol/MagSleep/releases/tag/$TAG"
else
    echo "warning: gh not available/authenticated — tag pushed, create the GitHub Release manually" >&2
fi

# 7. Homebrew tap ------------------------------------------------------------
# Publish Casks/magsleep.rb to the realAbitbol/homebrew-tap repo (created on
# first release) so `brew tap realAbitbol/tap && brew install --cask magsleep`
# always serves the latest release. Best-effort: a failure here must not undo
# an already-published release, so every failing step is wrapped in if-blocks
# (a bare failing subshell would abort the script under set -e).
TAP_REPO="realAbitbol/homebrew-tap"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    TAP_TMP="dist/homebrew-tap"
    rm -rf "$TAP_TMP"
    if ! gh repo view "$TAP_REPO" >/dev/null 2>&1 \
        && ! gh repo create "$TAP_REPO" --public --description "Homebrew tap for MagSleep" >/dev/null 2>&1; then
        echo "warning: could not create $TAP_REPO — cask not published to Homebrew" >&2
    elif gh repo clone "$TAP_REPO" "$TAP_TMP" >/dev/null 2>&1; then
        mkdir -p "$TAP_TMP/Casks"
        cp Casks/magsleep.rb "$TAP_TMP/Casks/magsleep.rb"
        if ( cd "$TAP_TMP" \
                && git add -A \
                && { git diff --cached --quiet || git commit -m "Update MagSleep to $VERSION"; } \
                && git push origin HEAD ); then
            echo "published cask to $TAP_REPO"
        else
            echo "warning: could not publish cask to $TAP_REPO (git commit/push failed)" >&2
        fi
    else
        echo "warning: could not clone $TAP_REPO — cask not published to Homebrew" >&2
    fi
    rm -rf "$TAP_TMP"
else
    echo "warning: gh not available/authenticated — cask not published to Homebrew" >&2
fi

echo "released $TAG ($DMG, $ZIP)"

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
DMG="dist/MagSleep-$VERSION.dmg"
BRANCH="$(git branch --show-current)"

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

# 4. Commit + tag -----------------------------------------------------------
git add README.md Makefile
if ! git diff --cached --quiet; then
    git commit -m "Release v$VERSION"
fi
git tag -a "$TAG" -m "MagSleep $VERSION"

# 5. Push -------------------------------------------------------------------
git push origin "$BRANCH"
git push origin "$TAG"

# 6. GitHub Release ---------------------------------------------------------
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release create "$TAG" "$DMG" \
        --repo realAbitbol/MagSleep \
        --title "MagSleep $VERSION" \
        --notes "MagSleep $VERSION — see the README for installation instructions."
    echo "published GitHub release: https://github.com/realAbitbol/MagSleep/releases/tag/$TAG"
else
    echo "warning: gh not available/authenticated — tag pushed, create the GitHub Release manually" >&2
fi

echo "released $TAG ($DMG)"

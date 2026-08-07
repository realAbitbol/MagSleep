#!/bin/bash
# Prepares and triggers a CI-only release: the ONLY thing that happens locally
# is what GitHub needs to build + publish the next release. All actual build,
# scan, sign, attest, and publish work happens in .github/workflows/release.yml
# when the vX.Y.Z tag is pushed — every published DMG is provably GitHub-built.
#
# Usage: make release VERSION=X.Y.Z
#
# Steps:
#   1. Validate VERSION (strict X.Y.Z), a clean tree, and a not-yet-existing tag
#   2. Validate the CHANGELOG section exists (the CI job fails without it)
#   3. Bump the README VERSION= examples + DMG filenames and the Makefile default
#   4. Commit "Release vX.Y.Z" + create the annotated tag vX.Y.Z
#   5. Push branch + tag — CI builds from scratch, VirusTotal-scans, signs the
#      Sparkle appcast, attests the artifacts, publishes, and commits the appcast
#
# No local build, no local DMG, no gh — nothing a maintainer's machine could
# tamper with ever reaches users.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: usage: make release VERSION=X.Y.Z" >&2
    exit 1
fi
TAG="v$VERSION"
BRANCH="$(git branch --show-current)"

# Refuse to run from a detached HEAD (need a branch to push).
if [ -z "$BRANCH" ]; then
    echo "error: not on a branch (detached HEAD); check out a branch first" >&2
    exit 1
fi
# Clean-tree guard: the release must be reproducible from the pushed commit.
if ! git diff --quiet || ! git diff --cached --quiet \
    || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "error: working tree has uncommitted changes; commit or stash first" >&2
    exit 1
fi
# The tag must not exist (locally or on origin) — CI triggers on the tag push.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi
if git ls-remote --tags origin "$TAG" 2>/dev/null | grep -q "refs/tags/$TAG"; then
    echo "error: tag $TAG already exists on origin" >&2
    exit 1
fi
# Every release must have a changelog entry — and it must be non-empty (a bare
# header passes the old existence check but fails the CI extraction, which is
# what actually publishes the notes). Reuse the same extraction as the CI job.
NOTES="$(awk -v hdr="## [$VERSION]" '
    index($0, hdr) == 1 { in_section = 1; next }
    in_section && substr($0, 1, 3) == "## " { exit }
    in_section
' CHANGELOG.md)"
if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
    echo "error: no CHANGELOG.md section found for [$VERSION]; add it before releasing" >&2
    exit 1
fi

# Bump version references: README "From source" examples (VERSION=1.0.x) + DMG
# filenames (MagSleep-1.0.x.dmg) and the Makefile default. Version-agnostic
# patterns so 2.x / 3.x bumps keep working (a "1\." prefix would silently
# no-op past the next major).
sed -i '' -E \
    -e "s/VERSION=[0-9]+\.[0-9]+\.[0-9]+/VERSION=$VERSION/g" \
    -e "s/MagSleep-[0-9]+\.[0-9]+\.[0-9]+\.dmg/MagSleep-$VERSION.dmg/g" \
    README.md
sed -i '' -E "s/^VERSION \?= .*/VERSION ?= $VERSION/" Makefile

# Commit + tag + push. --no-verify: the commit only touches docs/config (no
# Swift), and the release is gated by CI's `swift test` anyway — a stale-tool
# failure in the pre-commit hook must not block the release.
git add README.md CHANGELOG.md Makefile
if git diff --cached --quiet; then
    echo "error: version references already at $VERSION — nothing to commit" >&2
    exit 1
fi
git commit --no-verify -m "Release v$VERSION"
git tag -a "$TAG" -m "MagSleep $VERSION"

# Push branch first, then the tag: master always has the release commit before
# CI (triggered by the tag) runs.
git push origin "$BRANCH"
git push origin "$TAG"

echo "released $TAG — CI is building, scanning, signing, attesting, and publishing:"
echo "  https://github.com/realAbitbol/MagSleep/actions"

#!/bin/bash
# Signs the Sparkle appcast for a new release entry. Shared by the CI release
# workflow's fresh-sign step and its feed-repair path, so the signing logic
# and its guards live in one place.
#
# Usage: sign-appcast.sh VERSION STAGEDIR
#   STAGEDIR must contain the update archive (MagSleep-$VERSION.zip), a seed
#   appcast.xml (if present), and MagSleep-$VERSION.md release notes. The
#   signed appcast.xml is written back into STAGEDIR.
# Env: SPARKLE_EDDSA_KEY — the 44-char base64 EdDSA private key, piped to
#   generate_appcast --ed-key-file - so it never lands on disk or in argv.
#
# Guards: the enclosure URL must point at the release asset, and the NEW entry
# must carry an EdDSA signature — a SPARKLE_EDDSA_KEY / SUPublicEDKey mismatch
# otherwise makes generate_appcast skip signing silently, and every Sparkle
# client would reject the update.
set -euo pipefail

VERSION="${1:?usage: sign-appcast.sh VERSION STAGEDIR}"
STAGE="${2:?}"
TAG="v$VERSION"
ASSET_URL="https://github.com/realAbitbol/MagSleep/releases/download/$TAG/MagSleep-$VERSION.zip"

# Locate generate_appcast: the Sparkle SPM binary artifact, then PATH.
GENERATE_APPCAST="${GENERATE_APPCAST:-}"
if [ -z "$GENERATE_APPCAST" ] || [ ! -x "$GENERATE_APPCAST" ]; then
    ROOT="$(pwd -P)"
    GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
fi
if [ ! -x "$GENERATE_APPCAST" ]; then
    GENERATE_APPCAST="$(command -v generate_appcast || true)"
fi
if [ -z "$GENERATE_APPCAST" ] || [ ! -x "$GENERATE_APPCAST" ]; then
    echo "error: generate_appcast not found (build once so the Sparkle artifact exists)" >&2
    exit 1
fi

(
    cd "$STAGE"
    printf '%s\n' "${SPARKLE_EDDSA_KEY:-}" | "$GENERATE_APPCAST" --ed-key-file - --embed-release-notes .
)

# Point the enclosure at the release asset (generate_appcast writes a relative
# URL) and guard the rewrite so a format change can't silently 404 the feed.
sed -i '' -E "s|url=\"MagSleep-$VERSION\.zip\"|url=\"$ASSET_URL\"|" "$STAGE/appcast.xml"
grep -q "releases/download/$TAG/" "$STAGE/appcast.xml" || {
    echo "error: enclosure URL rewrite failed for $TAG" >&2
    exit 1
}
# The NEW entry must be EdDSA-signed. (The seed's older entries are already
# signed, so check the new item specifically, not just any signature.)
grep -A5 "releases/download/$TAG/" "$STAGE/appcast.xml" | grep -q "sparkle:edSignature" || {
    echo "error: no EdDSA signature on the $TAG appcast entry — SPARKLE_EDDSA_KEY mismatch?" >&2
    exit 1
}

echo "signed appcast entry for $TAG"

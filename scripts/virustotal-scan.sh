#!/bin/bash
# Uploads a file to VirusTotal, waits for the analysis verdict, and prints the
# result as key=value lines:
#   sha256=…            permalink=… (results page, always printed)
#   status=skipped|submitted|failed|completed
#   verdict=0 malicious / N engines   (completed)
#   badge=0%20malicious%2FN           (completed, URL-encoded for shields.io)
#
# Usage: scripts/virustotal-scan.sh <file>
# Env:   VIRUSTOTAL_API_KEY  (required; missing -> status=skipped, exit 0)
#
# Best-effort by design: the permalink is derivable from the local sha256, so
# even a total VirusTotal failure still yields a proof link, and the script
# always exits 0 — a release is never blocked by VirusTotal.
set -euo pipefail

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
    echo "error: usage: scripts/virustotal-scan.sh <file>" >&2
    exit 2
fi

if [ -z "${VIRUSTOTAL_API_KEY:-}" ]; then
    echo "status=skipped"
    echo "reason=VIRUSTOTAL_API_KEY not set"
    exit 0
fi

API="https://www.virustotal.com/api/v3"

SHA="$(shasum -a 256 "$FILE" | awk '{print $1}')"
echo "sha256=$SHA"
echo "permalink=https://www.virustotal.com/gui/file/$SHA/detection"

# Parse a single field out of a VirusTotal JSON response.
json_field() {
    # $1 = JSON text, $2 = dotted path, e.g. "data.attributes.status"
    python3 -c '
import json, sys
def lookup(obj, path):
    for key in path.split("."):
        if not isinstance(obj, dict) or key not in obj:
            return ""
        obj = obj[key]
    return obj if isinstance(obj, (str, int, float)) else json.dumps(obj)
print(lookup(json.loads(sys.argv[1]), sys.argv[2]))
' "$1" "$2" 2>/dev/null || true
}

UPLOAD_JSON="$(curl -sS -X POST \
    -H "x-apikey: $VIRUSTOTAL_API_KEY" \
    -F "file=@$FILE" \
    "$API/files" 2>/dev/null || true)"

ANALYSIS_ID="$(json_field "$UPLOAD_JSON" "data.id")"
if [ -z "$ANALYSIS_ID" ]; then
    echo "status=failed"
    echo "reason=upload did not return an analysis id ($(json_field "$UPLOAD_JSON" "error.message"))"
    exit 0
fi

# Poll until completed. Public API allows 4 req/min; polling every 20s stays
# under it. The 15-poll cap (~5 min) is a safety valve only reachable during a
# VirusTotal outage — a normal analysis finishes in ~1-2 min.
POLLS=15
for _ in $(seq 1 "$POLLS"); do
    sleep 20
    RESULT="$(curl -sS \
        -H "x-apikey: $VIRUSTOTAL_API_KEY" \
        "$API/analyses/$ANALYSIS_ID" 2>/dev/null || true)"
    STATUS="$(json_field "$RESULT" "data.attributes.status")"
    if [ "$STATUS" = "completed" ]; then
        python3 - "$RESULT" <<'PY'
import json, sys
from urllib.parse import quote
stats = json.loads(sys.argv[1])["data"]["attributes"]["stats"]
total = sum(stats.values())
malicious = int(stats.get("malicious", 0))
print(f"status=completed")
print(f"verdict={malicious} malicious / {total} engines")
print(f"badge={quote(f'{malicious} malicious/{total}')}")
PY
        exit 0
    fi
done

echo "status=submitted"
echo "reason=analysis still pending after the poll cap (VirusTotal may be slow)"
exit 0

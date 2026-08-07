#!/bin/bash
# Installs the MagSleep privileged helper. Runs as root, invoked by the app.
# Usage: install-helper.sh <app-resources-dir> <console-user> [helper-revision]
# Before touching anything it verifies the source is trustworthy (see the
# "Integrity check" section): the enclosing app bundle must validate, and the
# bundled helper binary's cdhash must match the pin build-app.sh embedded.
set -euo pipefail

RESOURCES="$1"
LABEL="com.magsleep.helper"
BIN="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG_DIR="/Library/Logs/MagSleep"
CONFIG_DIR="/Library/Preferences/MagSleep"
HELPER_REVISION="${3:-unknown}"
LOCK_FILE="$CONFIG_DIR/install.lock"

# Serialize installs with lockf(1) (the recommended macOS lock utility). The
# kernel releases the lock when the holder exits or is killed, so there is no
# stale lock to clean up. Without this, two racing installs (e.g. an old app
# version triggering a second install while one is in flight) both bootout and
# bootstrap, fighting over launchd — a classic cause of "Bootstrap failed: 5:
# Input/output error". With -t 0 a concurrent run fails fast; -s suppresses the
# raw "already locked" stderr so a racing loser gets a friendly message (lockf
# exits 75 = EX_TEMPFAIL when it cannot acquire the lock).
mkdir -p /Library/PrivilegedHelperTools "$LOG_DIR" "$CONFIG_DIR"
if [ -z "${MAGSLEEP_INSTALL_LOCKED:-}" ]; then
    export MAGSLEEP_INSTALL_LOCKED=1
    # Capture lockf's status with `||` (set -e must not abort on the expected
    # 75 = lock-conflict failure). 0 = success, 75 = another install in
    # progress, anything else = the inner script failed (its own stderr
    # already passed through).
    rc=0
    lockf -s -t 0 -k "$LOCK_FILE" /bin/bash "$0" "$@" || rc=$?
    if [ "$rc" -eq 75 ]; then
        echo "Another MagSleep install is already in progress." >&2
    fi
    exit "$rc"
fi

# Integrity check before any privileged write: the helper that will run as
# root must be exactly the one the app shipped. Two independent checks:
#   1. The enclosing app bundle must carry a valid signature. This seals
#      every file we read from $RESOURCES — including helper-cdhash.txt and
#      the .sh scripts — so a modified bundle fails here.
#   2. The bundled helper binary's cdhash must match the pin build-app.sh
#      embedded at build time (helper-cdhash.txt). A tampered binary (even
#      one in a re-signed bundle) still fails this pin.
# Both run before the bootout so a rejected bundle never disturbs the
# currently installed (working) helper.
BUNDLE="$(dirname "$(dirname "$RESOURCES")")"
if ! codesign --verify --deep --strict "$BUNDLE" 2>/dev/null; then
    echo "refusing to install: the MagSleep app bundle failed signature validation (tampered app?)" >&2
    exit 1
fi
if [ -s "$RESOURCES/helper-cdhash.txt" ]; then
    EXPECTED_CDHASH="$(cat "$RESOURCES/helper-cdhash.txt")"
    SRC_CDHASH="$(codesign -dvvv "$RESOURCES/magsleep-helper" 2>&1 | sed -n 's/^CDHash=//p')"
    if [ -z "$EXPECTED_CDHASH" ] || [ -z "$SRC_CDHASH" ] || [ "$SRC_CDHASH" != "$EXPECTED_CDHASH" ]; then
        echo "refusing to install: bundled helper binary does not match the app's recorded cdhash (tampered bundle?)" >&2
        exit 1
    fi
else
    echo "warning: no helper-cdhash.txt in the bundle; skipping the cdhash check" >&2
fi

# Purge any pre-existing job state before installing. An old or half-loaded
# job with the same label (a previous MagSleep version, or a leftover from a
# failed earlier attempt) makes `launchctl bootstrap` fail with a cryptic
# "Bootstrap failed: 5: Input/output error". Boot it out, clear any disabled
# override, then wait until launchd has actually released the job — booting
# out and immediately bootstrapping races with launchd's unload and commonly
# fails with EIO. `launchctl print` exits non-zero only once the job is fully
# gone from the domain.
wait_for_job_gone() {
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! launchctl print "system/$LABEL" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
}

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl enable "system/$LABEL" 2>/dev/null || true
wait_for_job_gone

install -m 755 -o root -g wheel "$RESOURCES/magsleep-helper" "$BIN"
install -m 644 -o root -g wheel "$RESOURCES/$LABEL.plist" "$PLIST"

# Validate before handing the job to launchd, so a broken install fails with a
# clear message instead of a cryptic bootstrap error.
[ -x "$BIN" ] || { echo "installed helper binary is not executable" >&2; exit 1; }
plutil -lint "$PLIST" >/dev/null || { echo "installed helper plist is invalid" >&2; exit 1; }

# Some copy paths (e.g. the app dragged out of a downloaded DMG) can leave a
# quarantine/provenance xattr on bundle contents; launchd is strict about such
# xattrs when validating a daemon, so strip them from the installed files.
xattr -dr com.apple.quarantine "$BIN" "$PLIST" 2>/dev/null || true
xattr -dr com.apple.provenance "$BIN" "$PLIST" 2>/dev/null || true

# Re-sign the installed binary in place. launchd's bootstrap validation is
# stricter than a plain `codesign -v` and fails with "Bootstrap failed: 5:
# Input/output error" for a daemon whose signature wasn't produced at its
# final path (e.g. copied out of a downloaded/quarantined app bundle).
# Re-signing ad-hoc here, as root, at the exact path launchd reads eliminates
# that whole class of failure — this is the fix for the reported EIO. The
# explicit -i identifier must match the one build-app.sh used (ad-hoc signing
# otherwise appends a requirement hash to the basename), or the re-signed
# binary's cdhash would differ from the pin below and a legit install would
# fail its own integrity check.
codesign --force --sign - -i "$LABEL" "$BIN" || { echo "could not sign helper binary" >&2; exit 1; }
codesign -v "$BIN" || { echo "installed helper binary failed signature validation" >&2; exit 1; }
# The installed binary is re-signed with the same identifier the app shipped it
# under (com.magsleep.helper, from the $BIN basename), so its cdhash must equal
# the pin — catches a corrupted copy that happened to pass the source check.
if [ -n "${EXPECTED_CDHASH:-}" ]; then
    INSTALLED_CDHASH="$(codesign -dvvv "$BIN" 2>&1 | sed -n 's/^CDHash=//p')"
    if [ "$INSTALLED_CDHASH" != "$EXPECTED_CDHASH" ]; then
        echo "installed helper binary cdhash mismatch after re-sign" >&2
        exit 1
    fi
fi

# Bootstrap with retries. Each attempt re-bootouts first so a half-unloaded
# previous job can never conflict with the new one. The revision file is
# written only after a successful bootstrap, so a failed install keeps the
# previous revision on disk and the app re-prompts the update on the next
# launch. launchctl's real stderr + exit code are surfaced so a failure is
# diagnosable instead of a generic "bootstrap attempt failed".
BOOTSTRAP_ERR_FILE="$(mktemp "${TMPDIR:-/tmp}/magsleep-bootstrap.XXXXXX")"
trap 'rm -f "$BOOTSTRAP_ERR_FILE"' EXIT
for attempt in 1 2 3; do
    BOOTSTRAP_RC=0
    launchctl bootstrap system "$PLIST" 2>"$BOOTSTRAP_ERR_FILE" || BOOTSTRAP_RC=$?
    if [ "$BOOTSTRAP_RC" -eq 0 ]; then
        echo "$HELPER_REVISION" > "$CONFIG_DIR/helper-version.txt"
        chown root:wheel "$CONFIG_DIR/helper-version.txt"
        chmod 644 "$CONFIG_DIR/helper-version.txt"
        echo "MagSleep helper installed"
        exit 0
    fi
    echo "bootstrap attempt $attempt failed (exit $BOOTSTRAP_RC): $(cat "$BOOTSTRAP_ERR_FILE")" >&2
    sleep 2
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    wait_for_job_gone
done

echo "MagSleep helper bootstrap failed" >&2
exit 1

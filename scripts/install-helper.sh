#!/bin/bash
# Installs the MagSleep privileged helper. Runs as root, invoked by the app.
# Usage: install-helper.sh <app-resources-dir> <console-user> [helper-revision]
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

# Purge any pre-existing job state before installing. An old or half-loaded
# job with the same label (a previous MagSleep version, or a leftover from a
# failed earlier attempt) makes `launchctl bootstrap` fail with a cryptic
# "Bootstrap failed: 5: Input/output error". Boot it out, clear any disabled
# override, then wait until launchd has actually released the job — booting
# out and immediately bootstrapping races with launchd's unload and commonly
# fails with EIO. `launchctl print` exits non-zero only once the job is fully
# gone from the domain.
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl enable "system/$LABEL" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! launchctl print "system/$LABEL" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

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
# that whole class of failure — this is the fix for the reported EIO.
codesign --force --sign - "$BIN" || { echo "could not sign helper binary" >&2; exit 1; }
codesign -v "$BIN" || { echo "installed helper binary failed signature validation" >&2; exit 1; }

# Bootstrap with retries. Each attempt re-bootouts first so a half-unloaded
# previous job can never conflict with the new one. The revision file is
# written only after a successful bootstrap, so a failed install keeps the
# previous revision on disk and the app re-prompts the update on the next
# launch. launchctl's real stderr + exit code are surfaced so a failure is
# diagnosable instead of a generic "bootstrap attempt failed".
BOOTSTRAP_ERR_FILE="$(mktemp /tmp/magsleep-bootstrap.XXXXXX)"
for attempt in 1 2 3; do
    BOOTSTRAP_RC=0
    launchctl bootstrap system "$PLIST" 2>"$BOOTSTRAP_ERR_FILE" || BOOTSTRAP_RC=$?
    if [ "$BOOTSTRAP_RC" -eq 0 ]; then
        rm -f "$BOOTSTRAP_ERR_FILE"
        echo "$HELPER_REVISION" > "$CONFIG_DIR/helper-version.txt"
        chown root:wheel "$CONFIG_DIR/helper-version.txt"
        chmod 644 "$CONFIG_DIR/helper-version.txt"
        echo "MagSleep helper installed"
        exit 0
    fi
    echo "bootstrap attempt $attempt failed (exit $BOOTSTRAP_RC): $(cat "$BOOTSTRAP_ERR_FILE")" >&2
    rm -f "$BOOTSTRAP_ERR_FILE"
    sleep 2
    launchctl bootout "system/$LABEL" 2>/dev/null || true
done

echo "MagSleep helper bootstrap failed" >&2
exit 1

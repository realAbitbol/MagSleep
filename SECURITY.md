# Security Policy

## Supported Versions

Security updates are provided only for the latest stable release of MagSleep.

| Version | Supported |
| ------- | --------- |
| Latest stable release | ✅ |
| Previous releases | ❌ |
| Development / pre-release builds | ❌ |

We strongly recommend updating to the latest version before reporting a security issue, as the vulnerability may already have been resolved.

---

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues, discussions, pull requests, or social media.**

Instead, report vulnerabilities privately by:

- Opening a **Private Vulnerability Report** through GitHub Security Advisories

Please include as much information as possible about the issue:

- the MagSleep version (**About MagSleep…**) and your macOS version
- whether the helper is installed and whether it is running (the menu-bar icon, or **About MagSleep…**)
- the steps to reproduce, and what you expected instead
- any relevant lines from the unified log:
  `log show --last 10m --predicate 'subsystem == "com.magsleep.helper" OR subsystem == "com.magsleep.app"'`

We aim to acknowledge a report within a few days. Only the latest stable release
is supported, so please reproduce on the current version first.

---

## Security model

Several properties are deliberate and worth understanding before reporting:

- **Two processes.** An unprivileged menu bar app plus a root LaunchDaemon
  (`com.magsleep.helper`). The app never touches the SMC or a privileged path;
  installing or updating the helper runs a bundled script as root through the
  system administrator prompt.
- **Local IPC trust boundary.** The daemon listens on `/var/run/magsleep.sock`
  (mode `0666`). That mode is deliberate — it lets the app connect — and
  authorization is decided per request by comparing the peer's uid
  (`getpeereid`) against the current console user, failing closed when that
  cannot be determined. Anything already running as the console user can
  therefore change the LED mode; that is the intended boundary.
- **Root is required for SMC writes**, which is why the helper exists.
- **Ad-hoc signing, not notarized.** There is no Apple Developer ID; updates are
  trusted through Sparkle's EdDSA signature (public key embedded in the app)
  rather than a code-signing identity. See the README's Gatekeeper guide.
- **No telemetry.** MagSleep collects and sends nothing; the only network
  activity is the update check and links you open.

### Install-time integrity check, and its limits

Before any privileged write, `install-helper.sh` requires that (1) the enclosing
app bundle passes `codesign --verify --deep --strict`, and (2) the bundled
helper's cdhash matches the pin recorded at build time (`helper-cdhash.txt`).

This catches **partial** tampering — a swapped binary that leaves the pin stale.
It cannot catch a **wholesale** replacement of the bundle (replace the binary,
refresh the pin, re-sign ad-hoc), because the pin lives inside the bundle it
validates. Writing into `/Applications` already requires root, so this is
defence-in-depth against a mis-shipped bundle, not a privilege boundary against
someone who already controls the machine. Closing that gap properly would need a
Developer ID signature with a pinned team identifier.

## Out of scope

- An attacker who can already run code as your user (the IPC trust boundary) or
  who already has root.
- Gatekeeper/quarantine friction on first install — documented in the README,
  not a vulnerability.
- The MagSafe LED itself: `ACLC` is an undocumented SMC key, so a firmware or
  macOS change that breaks it is a bug to report on GitHub, not a security issue.

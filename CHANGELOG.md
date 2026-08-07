# Changelog

All notable changes to MagSleep are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to [Semantic Versioning](https://semver.org/).

`make release VERSION=x.y.z` extracts this file's `[x.y.z]` section and uses
it for the GitHub release body and the in-app Sparkle update notes.

## [1.3.2] - 2026-08-07

### Fixed

- **Subprocess hang**: the helper and the app could hang forever when a subprocess left a background child holding its output pipe (e.g. `corebrightnessdiag` or the privileged install script) — subprocess runs now always return at their deadline, truncated if necessary
- **Night schedule sunrise**: with the night schedule enabled, the LED stayed off for up to 30 minutes after sunrise; it now returns to macOS control within seconds

### Changed

- **Install hardening**: MagSleep now refuses to install the helper unless the app bundle passes signature validation and the bundled helper binary matches the cdhash recorded at build time — a modified or corrupted app can no longer install a tampered root daemon
- **Release safety**: the release pipeline now fails if the Sparkle update-signing key does not match the public key embedded in the app, instead of shipping an update every client would reject

### Internal

- About-dialog text view extracted from the menu controller; the menu's install-state notification now fires on both install start and finish; the VirusTotal badge update in the release proof is idempotent

## [1.3.1] - 2026-08-07

### Added

- SF Symbol icons on the "Launch at Login" and "Quit MagSleep" menu items

### Removed

- **Notification Blink** (the menu toggle that blinked the LED on incoming notifications, shipped in 1.3.0). It read the Notification Center through the **Accessibility API**, and macOS's TCC records Accessibility grants against the app's code-signing identity: for an ad-hoc-signed app that identity is the binary's cdhash, which changes on every build — so the grant would silently break for users on every Sparkle update. There is no way to make the grant survive updates without a trusted (paid Developer ID) signing identity, so the feature is removed rather than shipped broken. The fix is documented in the repo's git history and can be revived if the app ever moves to Developer ID signing
- VirusTotal scan of the DMG: [0 malicious / 75 engines](https://www.virustotal.com/gui/file/8b0b47107c2d709721a9fa18d29bbf723d1a99442fef9a0464f224f8b41e0057/detection)

## [1.3.0] - 2026-08-07

### Added

- **Night Schedule** (optional): a menu toggle that keeps the MagSafe LED off from **sunset to sunrise** — sun times come from macOS (`corebrightnessdiag`), with a 20:00–07:00 fallback when unavailable. Disabled mode always wins
- **Display-sleep → LED off** (part of Sleep Mode): the LED now turns off when the *display* sleeps (not only at full system sleep) and returns to macOS control on screen wake — via IODisplayWrangler IOKit notifications, which work from the system daemon without a GUI session
- **Notification Blink** (optional): a menu toggle that blinks the LED green 5 times when a new notification arrives. It reads the Notification Center through the **Accessibility API** (the same mechanism notifier apps like Bark use): enabling it asks for Accessibility access; if refused, the toggle stays off. A "Dump Notification Center Tree…" menu item saves the AX tree for tuning on specific Macs
- **CI-built releases with provenance**: every release DMG is now built from scratch on GitHub Actions runners — never on a maintainer's machine — with the VirusTotal scan, Sparkle appcast signing, and a Sigstore **build attestation** all performed in CI. Anyone can verify a DMG was GitHub-built (`gh attestation verify MagSleep-x.y.z.dmg --owner realAbitbol`), and every app embeds a `build-info.json` recording who built it and from which commit/workflow run

### Changed

- `make release VERSION=x.y.z` now only does what GitHub needs: it validates the changelog, bumps the version references, commits, tags `vX.Y.Z`, and pushes — the GitHub Actions workflow then builds, scans, signs, attests, and publishes. Local publishing is disabled by design
- Code-quality refactor: the bounded subprocess wait/drain, unix-socket I/O, and socket request dispatch are extracted into shared, unit-tested `MagSleepCore` helpers (`BoundedProcess`, `UnixSocket`, `SocketCommandHandler`), and the helper install flow is collapsed into a single path
- Test suite grown to **99 tests** (socket dispatch, notification detection, subprocess bounds, sockaddr layout, plus the existing config/LED/protocol coverage); SwiftLint and the Periphery dead-code scan run in the git pre-commit hook
- VirusTotal scan of the DMG: [1 malicious / 75 engines](https://www.virustotal.com/gui/file/0b3b597c2b46bd958c03c510f793ea7700e3e511c7f6a7daad214148f184207a/detection)

## [1.2.10] - 2026-08-05

### Fixed

- The reported **"Bootstrap failed: 5: Input/output error"** on fresh installs is now directly addressed: `install-helper.sh` **purges any pre-existing job state** (bootout + clears a disabled override + waits for launchd to fully release it) and **unconditionally re-signs the daemon binary in place** (at its final path, as root) before bootstrap — launchd's validation is stricter than a plain `codesign -v`, and a signature not produced at the path launchd reads, or stale job state, are the classic EIO causes
- VirusTotal scan of the DMG: [0 malicious / 75 engines](https://www.virustotal.com/gui/file/2936db5072fe25f975b2257a268bf854a920aad48ced402e71b931cbb1b95b6c/detection)

## [1.2.9] - 2026-08-05

### Fixed

- Helper install failing with "bootstrap attempt N failed; retrying" (reported by a fresh-install user): `install-helper.sh` now strips quarantine/provenance xattrs from the installed daemon binary, guarantees a valid ad-hoc signature (re-signing it if a copy path disturbed it), retries with a longer settle, and — most importantly — surfaces **launchctl's real error and exit code** so any future failure is diagnosable instead of a generic retry message
- The Sleep Mode card in the onboarding window was cut off ("LED off while the Mac / sleeps, back on when you…"): the card subtitles now wrap up to 3 lines with the correct measurement width, and the cards are slightly taller
- VirusTotal scan of the DMG: [0 malicious / 75 engines](https://www.virustotal.com/gui/file/109eb3766c39ff2af85c0b77e93020e1cb8c3c64142ad5732df4707d62be3482/detection)

## [1.2.8] - 2026-08-05

### Changed

- Every release DMG is now uploaded to **VirusTotal** before publishing: the verdict appears as a README badge and as a proof line in this changelog (requires the `VIRUSTOTAL_API_KEY` environment variable; the scan is skipped with a warning when it's absent)
- VirusTotal scan of the DMG: [0 malicious / 75 engines](https://www.virustotal.com/gui/file/ecac361ef84760f969ecac169989f67aa763ecfdcde89586b70838c80a7912b1/detection)

## [1.2.7] - 2026-08-05

### Changed

- The menu bar version header is **greyed** again — the same dimmed header other menu-bar apps use — reverting the v1.2.6 "no longer greyed" change (the greyed look reads more naturally)

## [1.2.6] - 2026-08-05

### Changed

- The menu bar **version header is no longer greyed** (bold, normal text color)

### Removed

- **Shortcuts (App Intents)**: the SwiftPM build path cannot emit the AppIntents metadata (`Metadata.appintents`) the Shortcuts app requires, so the actions never appeared — the code was removed rather than shipped dead. **AppleScript remains the automation surface** (fully supported and verified)

## [1.2.5] - 2026-08-05

### Added

- **Automation**: MagSleep is now scriptable from **Shortcuts** (App Intents: Set LED Mode, Turn LED Off, Turn LED On, Get LED Status) and **AppleScript** (`set led mode`, `turn LED off`, `turn LED on`, `get led status`) — both route through the same socket requests as the menu items
- The menu bar menu now shows a **bold "MagSleep v1.2.5" header**

### Changed

- The mode→command mapping is now centralized once in `MagSleepCore.LEDMode` (shared by the menu, Shortcuts, and AppleScript) and pinned to the daemon's `RequestCommand` vocabulary, so the three surfaces can never drift

## [1.2.4] - 2026-08-05

### Changed

- The helper is now reinstalled only when helper-affecting code actually changes: the app compares the installed helper's **revision** (last commit touching the helper, the shared core it links, or its LaunchDaemon plist) against the bundled revision, instead of the app version — so the unchanged helper is no longer reinstalled on every app update. The About window shows "Helper up to date: Yes/No" instead of a helper version number; Report a Problem shows the helper revision for triage

## [1.2.3] - 2026-08-05

### Added

- **First-run onboarding window**: installs the helper, picks Sleep Mode vs Always Off, and sets Launch at Login in one step. Modern macOS layout — app-icon header, tappable mode cards, and a Launch-at-Login switch. Onboarding is mandatory: the app cannot function without the helper, so the only ways out are installing it or **Cancel & Quit** (a declined admin prompt shows an in-window error and lets the user retry)
- **Report a Problem…** menu item: opens the GitHub issue tracker with app/helper versions pre-filled

### Changed

- The menu no longer shows a redundant greyed status line at the top — state is conveyed by the menu bar icon and the mode checkmarks
- The mode checkmark now reflects the persisted config immediately at launch (previously it stayed unchecked until the 15s refresh timer fired when the helper was healthy)
- `make release` uses the release's `CHANGELOG.md` section as the GitHub release body and Sparkle update notes

### Removed

- **Homebrew distribution** (cask + `realAbitbol/homebrew-tap` publishing): Homebrew is phasing out casks that require Gatekeeper overrides for unnotarized apps on September 1, 2026, so the DMG is the sole distribution channel

## [1.2.2] - 2026-08-05

### Removed

- **Copy Diagnostics** menu item (and the now-unused SMC read APIs it relied on)
- `SemanticVersion` from `MagSleepCore` (unused since Sparkle replaced the custom update checker)

### Changed

- Helper daemon entry point now uses `@main` instead of top-level code, so the
  Periphery dead-code scan can trace the real entry point (previously it
  reported the entire daemon as dead code)
- Added a `.swiftlint.yml` and fixed all SwiftLint violations
- Git **pre-commit hook** (`make install-hooks`): runs SwiftLint, Periphery,
  `swift test`, and a warnings-as-errors build; commits are blocked if any fail
- Test coverage expanded from 28 to 49 tests (config decode edge cases,
  socket protocol malformed-input handling, SMC pure logic)

## [1.2.1] - 2026-08-05

### Fixed

- Unix socket permissions (`fchmod` → `chmod`): the app could not connect to
  the helper because the socket stayed at its root-only bind-time mode
- Double admin prompt after a helper update (daemon-recovery reinstall race)

## [1.2.0] - 2026-08-05

### Added

- **In-app updates via Sparkle** (checks twice a day, installs in place) —
  replaces the manual DMG downloads
- `make release` automation: test, DMG + update ZIP, appcast signing, tag,
  push, GitHub Release

### Changed

- Unix-domain socket IPC replaces the `/tmp` request file (request/ack/error,
  peer-UID validation)
- Post-install connection confirmation with a "Can't connect to helper"
  reinstall prompt
- README restructured: user guide first (install/use/update/uninstall), then
  developer docs

## [1.1.1] - 2026-08-05

### Fixed

- Hardened `install-helper.sh`: installs are serialized (`lockf`), wait for
  launchd to release the old job, retry bootstrap, and validate before loading
  (addresses "Bootstrap failed: 5: Input/output error")
- No SMC traffic while Disabled on power-source changes; fail-closed peer auth

## [1.1.0] - 2026-08-05

### Added

- Unix-domain socket IPC replacing the request-file protocol (real request
  acks, `getpeereid` peer checks, no polling)
- XCTest suite for `MagSleepCore` (config decoding, LED target logic, SMC
  layout, socket protocol, version comparison)
- Config-directory watching for instant UI updates; Copy Diagnostics menu item
- `make test`, `make notarize` (graceful without a cert)

### Changed

- Persistent SMC connection (no open/close churn); zero SMC traffic while
  Disabled
- Chained startup prompts (no overlapping dialogs)

## [1.0.1] - 2026-08-04

### Fixed

- First public patch release fixes

## [1.0.0] - 2026-08-03

### Added

- Initial release: turn the MagSafe LED off during sleep (and Always Off mode)
  on Apple Silicon MacBooks with MagSafe 3

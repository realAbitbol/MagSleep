# Changelog

All notable changes to MagSleep are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to [Semantic Versioning](https://semver.org/).

`make release VERSION=x.y.z` extracts this file's `[x.y.z]` section and uses
it for the GitHub release body and the in-app Sparkle update notes.

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

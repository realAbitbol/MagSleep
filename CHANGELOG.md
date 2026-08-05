# Changelog

All notable changes to MagSleep are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to [Semantic Versioning](https://semver.org/).

`make release VERSION=x.y.z` extracts this file's `[x.y.z]` section and uses
it for the GitHub release body and the in-app Sparkle update notes.

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

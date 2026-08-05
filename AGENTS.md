# Agent guidance

## Workflow rules

- **Never commit, push, tag, or run `make release` unless the user explicitly approves.** Make changes in the working tree, report what changed and how it was verified, and wait for approval before any git write operation.

## Project

macOS menu bar app (AppKit) that turns off the MagSafe LED on sleep, restores on wake. Apple Silicon (arm64) only, macOS 14+, Swift 5.10.

## Structure

- `Sources/MagSleep/` — AppKit menu bar app (`@main` in `MagSleepApp.swift`)
- `Sources/MagSleepHelper/` — privileged LaunchDaemon (`magsleep-helper`) that writes to the SMC as root
- `Sources/MagSleepCore/` — shared library: SMC I/O (`SMC.swift`), paths/constants, pure daemon state (`DaemonState.swift`), socket protocol types (`SocketProtocol.swift`)
- `Tests/MagSleepCoreTests/` — XCTest unit tests for the core logic
- `packaging/` — `Info.plist` template (version/build substituted at build time), LaunchDaemon plist
- `scripts/` — `build-app.sh` assembles the `.app` bundle; helper install/uninstall scripts bundled at build time

## Build & Run

All commands are Makefile targets:

| Command | Description |
|---|---|
| `make app` | Build `dist/MagSleep.app` (release, arm64) |
| `make run` | Build and open the app bundle |
| `make install` | Copy app to `/Applications` |
| `make dmg VERSION=X.Y.Z` | Create distributable DMG |
| `make test` | Run `swift test` (MagSleepCoreTests) |
| `make lint` | Run SwiftLint + the Periphery dead-code scan (also runs in the git pre-commit hook) |
| `make release VERSION=X.Y.Z` | Test, build DMG, update README/Makefile versions, commit, tag `vX.Y.Z`, push, publish GitHub Release with the DMG (`gh` required) |
| `make clean` | Remove `.build` and `dist` |

`scripts/build-app.sh` does the real work: `swift build -c release --arch arm64`, copies binaries + helper scripts + plists into the `.app` bundle, and codesigns with an ad-hoc signature.

**The app must be run from the built `.app` bundle** (not directly via `swift run`) because helper scripts and resources are bundled at build time.

## Architecture

Two processes, IPC over a unix-domain socket:

```
MagSleep.app (user)
  ├─ AppleScript "do shell script … with administrator privileges" → runs a bundled .sh as root
  │    (install-helper.sh, uninstall-helper.sh only)
  └─ HelperConnection → connects to /var/run/magsleep.sock (request/ack, no admin)
magsleep-helper (root LaunchDaemon)
  ├─ SocketServer → listens on /var/run/magsleep.sock, one connection per request,
  │    JSON line protocol (SocketRequest/SocketResponse), rejects non-console peers
  └─ event-driven: IORegisterForSystemPower + IOPS power-source changes
```

- **Privileged operations**: install and uninstall run bundled shell scripts via AppleScript. Mode changes, enable, and disable are NOT privileged — the app connects to the daemon's unix socket (`/var/run/magsleep.sock`, mode 0666) and sends `mode:sleep` / `mode:alwaysOff` / `enable` / `disable` as a JSON line; the daemon replies with an ack (success + new config, or an error string). `HelperManager.sendRequest` reports real results — no optimistic success. The daemon validates the connecting peer's uid via `getpeereid` against the console user (`SCDynamicStoreCopyConsoleUser`).
- **Helper lifecycle**: install = `install-helper.sh` (bootout old job, wait for launchd to release it, copy binary + plist, write `helper-version.txt`, validate, bootstrap with retries; serialized with `lockf` so racing installs can't fight over launchd); disable = socket request `disable` (sets `config.enabled = false`, LED back to macOS — does NOT unload the daemon); uninstall = `uninstall-helper.sh` (bootout, `--reset` LED, remove files + config dir + socket + `/tmp/magsleep`).
- **Config**: `/Library/Preferences/MagSleep/config.plist` (root-owned, written by the daemon). Fields: `mode` (`.sleep` default / `.alwaysOff`), `enabled`. Missing/corrupt config falls back to `DaemonConfig.default` on startup. The app reflects it immediately via a config-directory watch (15s timer as fallback).
- **Version tracking**: `install-helper.sh` writes the app version to `helper-version.txt` next to the config. On launch the app compares it to its own `CFBundleShortVersionString`; mismatch triggers an update prompt.
- **SMC**: `ACLC` key via `IOConnectCallStructMethod`. `0` = macOS control (default), `1` = off, `3` = green, `4` = amber. Writes require root, hence the LaunchDaemon. The daemon keeps one persistent `SMC.Connection` (no open/close churn); when Disabled it does zero SMC traffic.
- **Sleep detection**: event-driven via `IORegisterForSystemPower` (also handles `kIOMessageCanSystemSleep` → `IOAllowPowerChange`). The `sleepimage` mtime check is used only once at startup to seed the state if launchd revives the daemon while the Mac is still asleep. `alwaysOff` is re-asserted on power-source changes (`IOPSNotificationCreateRunLoopSource`) and by a slow 3s re-assert timer.

### Key files

- `Sources/MagSleep/MagSleepApp.swift` — entry point, arch/`ACLC` support checks, single-instance guard; quitting is a no-op for helper state (daemon keeps running in the active mode)
- `Sources/MagSleep/HelperManager.swift` — install/uninstall via osascript, socket mode/enable/disable with real acks, socket liveness probe, version check
- `Sources/MagSleep/HelperConnection.swift` — unix socket client (connect/send/read, short timeouts), `probe()` for liveness
- `Sources/MagSleepHelper/main.swift` — `PowerDaemon`: sleep/wake + power-source events, config, LED control
- `Sources/MagSleepHelper/SocketServer.swift` — event-driven unix socket server (accept/read/respond per connection, `getpeereid`, self-healing socket file)
- `Sources/MagSleepCore/SMC.swift` — AppleSMC IOKit client, `MagSafeLED` API, persistent `SMC.Connection`
- `Sources/MagSleepCore/Constants.swift` — paths, labels, `OperationMode`, `DaemonConfig`
- `Sources/MagSleepCore/DaemonState.swift` — pure state transitions (`DaemonConfig.apply`, `DaemonConfig.load`, `LEDTarget`)
- `Sources/MagSleepCore/SocketProtocol.swift` — `SocketRequest`/`SocketResponse` (newline-delimited JSON)
- `Sources/MagSleep/StatusItemController.swift` — menu bar UI (icon per mode), config-dir watch + 15s fallback timer; menu: mode items with checkmarks (Sleep Mode / Always Off / Disabled), Launch at Login, Check for Updates, Report a Problem, Buy me a coffee, Uninstall, About
- `Sources/MagSleep/OnboardingWindowController.swift` — first-run setup window (install helper + pick mode + Launch at Login in one step)

## Development notes

- `install-helper.sh`/`uninstall-helper.sh` are the only scripts invoked at runtime. `disable-helper.sh` and `set-mode.sh` were removed: Disable is a socket request (daemon stays loaded, `enabled=false`), and `set-mode.sh` was never bundled (broken dead code).
- Config is re-read at startup or when a request/socket ack arrives; the app also watches the config directory. SIGINT/SIGTERM are handled via dispatch signal sources that restore the LED to macOS control and exit non-zero — launchd's `KeepAlive` (`SuccessfulExit: false`) then revives the daemon whenever it is killed, so the LED briefly returns to macOS control before the daemon re-applies the active mode. bootout during install/uninstall unloads the job and stops it permanently. The app checks daemon liveness by connecting to the socket (cheap, no pgrep), and re-enables the helper on launch only if it's installed **but not running** — a deliberately "Disabled" helper stays disabled.
- The app offers "Launch at Login" only when running from `/Applications` (`SMAppService.mainApp` pins the bundle path it registers from). "Check for Updates" queries the GitHub Releases API (repo: realAbitbol/MagSleep), throttled to once per day.
- `make release VERSION=X.Y.Z` automates the whole release (`scripts/release.sh`): it refuses dirty trees and existing tags, runs tests + `make dmg`, sed-updates the README `VERSION=1.0.x` examples and the Makefile default, commits, creates an annotated tag, pushes branch + tag to origin, publishes the GitHub Release with the DMG + ZIP via `gh`, updates `Casks/magsleep.rb`, and publishes it to the `realAbitbol/homebrew-tap` repo (`brew tap realAbitbol/tap && brew install --cask magsleep`). Notarization stays a separate manual step (`make notarize`).
- **Every release must have a changelog entry.** Keep the released version's `## [x.y.z]` section in `CHANGELOG.md` updated before running `make release`; `release.sh` extracts that section and publishes it as the GitHub release body and as the embedded release notes in the Sparkle appcast (shown in the in-app update window). If the section is missing, `release.sh` warns and falls back to a generic note — so always write the changelog first.
- Notarization requires a paid Apple Developer Program membership (Developer ID cert); the app is ad-hoc signed and `make notarize` skips gracefully without a cert.

## Tests

`make test` runs `Tests/MagSleepCoreTests` (XCTest): request → config transitions, config decode/fallback, LED target logic, SMC struct layout, constants/paths, and the socket JSON protocol round-trips.

The git **pre-commit hook** (`make install-hooks`) runs SwiftLint, the Periphery dead-code scan, `swift test`, and a warnings-as-errors build; a commit is blocked if any fails. It requires `swiftlint` and `periphery` installed (`brew install swiftlint periphery`). Keep the helper's entry point as `@main` (in `MagSleepHelperMain.swift`) — Periphery cannot trace top-level executable code and would otherwise report the whole daemon as dead. Known false positives are marked in-source with `// periphery:ignore` (SMC kernel-layout struct fields read via `IOConnectCallStructMethod`, and retained-for-lifetime properties).

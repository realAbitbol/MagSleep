# Agent guidance

## Workflow rules

- **Never commit, push, tag, or run `make release` unless the user explicitly approves.** Make changes in the working tree, report what changed and how it was verified, and wait for approval before any git write operation.
- **Never add user-visible items (menu items, UI, alerts) that serve debugging/development purposes without asking first** — the menu is user-facing polish only. Ground feature implementation in real-world code (search GitHub for how mature apps do it) before writing it, especially for macOS private/undocumented APIs.

## Project

macOS menu bar app (AppKit) that turns off the MagSafe LED on sleep, restores on wake. Apple Silicon (arm64) only, macOS 14+, Swift 5.10.

## Structure

- `Sources/MagSleep/` — AppKit menu bar app (`@main` in `MagSleepApp.swift`)
- `Sources/MagSleepHelper/` — privileged LaunchDaemon (`magsleep-helper`) that writes to the SMC as root
- `Sources/MagSleepCore/` — shared library: SMC I/O (`SMC.swift`), paths/constants, pure daemon state (`DaemonState.swift`), socket protocol types (`SocketProtocol.swift`), and the shared plumbing both processes use instead of hand-copying: `UnixSocket` (sockaddr/writeAll), `BoundedProcess` (bounded subprocess wait+drain), `SocketCommandHandler` (pure request dispatch), `NotificationNodeDetector` (+ the `AccessibilityNode` model) for Notification Blink
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
| `make release VERSION=X.Y.Z` | **CI-only release driver**: validate CHANGELOG section, bump README/Makefile version refs, commit, tag `vX.Y.Z`, push — CI builds + publishes (no local build) |
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
- **Helper tracking**: `build-app.sh` embeds the **helper revision** (last commit touching `Sources/MagSleepHelper`, `Sources/MagSleepCore`, `packaging`, or `install-helper.sh`) into the bundle as `helper-revision.txt`. `install-helper.sh` writes it to `helper-version.txt` next to the config. On launch the app compares the installed revision to its own; a mismatch triggers an update prompt — so the unchanged helper is only reinstalled when helper-affecting code actually changed (not on every app release).
- **SMC**: `ACLC` key via `IOConnectCallStructMethod`. `0` = macOS control (default), `1` = off, `3` = green, `4` = amber. Writes require root, hence the LaunchDaemon. The daemon keeps one persistent `SMC.Connection` (no open/close churn); when Disabled it does zero SMC traffic.
- **Sleep detection**: event-driven via `IORegisterForSystemPower` (also handles `kIOMessageCanSystemSleep` → `IOAllowPowerChange`). Display sleep is detected separately via IODisplayWrangler interest notifications (`kIOMessageDeviceWillPowerOff`/`kIOMessageDeviceHasPoweredOn` — the only mechanism that works from a system daemon with no GUI session). The `sleepimage` mtime check is used only once at startup to seed the state if launchd revives the daemon while the Mac is still asleep. `alwaysOff` is re-asserted on power-source changes (`IOPSNotificationCreateRunLoopSource`) and by a slow 3s re-assert timer; the optional **night schedule** (LED off sunset→sunrise) re-asserts the same way, with sun times fetched from `corebrightnessdiag sunschedule` (30-min timer, 20:00–07:00 fallback). The optional **Notification Blink** (LED blinks green on incoming notifications) is app-side: `NotificationBlink` reads the Notification Center's accessibility tree (Accessibility permission, same mechanism as notifier apps like Bark) and diffs it with the pure `NotificationNodeDetector` (MagSleepCore) to detect new notifications, then sends the daemon a `blink` socket command (5 green blinks, serialized via `blinkGeneration`, gated on enabled + not asleep). Detection is designed to work across the app's whole macOS 14–26 range (banner subroles + a generic text heuristic, relative-time texts filtered so keys stay stable) and is verified against Sonoma-era and Tahoe-era tree fixtures.

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
- **Releases are CI-only.** `make release VERSION=X.Y.Z` (`scripts/release.sh`) does only what GitHub needs to build + publish the next release: validates the CHANGELOG section, sed-updates the README `VERSION=1.0.x` examples + Makefile default, commits `Release vX.Y.Z`, creates the annotated tag `vX.Y.Z`, and pushes branch + tag. The actual build (from scratch on a GitHub runner), VirusTotal scan, Sparkle appcast signing, attestation, and publish all happen in `.github/workflows/release.yml` — so every published DMG is provably GitHub-built (never locally tampered). No local build, DMG, or `gh` ever happens in the release flow.
- **CI release path** (`.github/workflows/release.yml`): pushing a `vX.Y.Z` tag builds the DMG from scratch on a macOS runner, runs the VirusTotal scan with the `VIRUSTOTAL_API_KEY` **repo secret**, signs the Sparkle appcast with the `SPARKLE_EDDSA_KEY` **repo secret** (piped to `generate_appcast --ed-key-file -`, never written to a file), attests the DMG + ZIP with `actions/attest` (Sigstore SLSA provenance — verify any release DMG with `gh attestation verify MagSleep-X.Y.Z.dmg --owner realAbitbol`), publishes the GitHub Release (DMG + ZIP), then commits the signed appcast to `master` (the feed is served from GitHub raw — committed after the release so master never advertises a not-yet-live asset). It skips at the top of the job if the tag's release already exists. `build-app.sh` embeds `Contents/Resources/build-info.json` recording the builder (`github-actions` + workflow-run URL + commit, or `local`) so any DMG can be traced to its build run. The (now unused) local appcast-signing key lives in the login keychain under service `https://sparkle-project.org` (44-char base64): `security find-generic-password -s "https://sparkle-project.org" -w`.
- **Every release must have a changelog entry.** Keep the released version's `## [x.y.z]` section in `CHANGELOG.md` updated before releasing; the CI workflow extracts that section as the GitHub release body and the embedded release notes in the Sparkle appcast (shown in the in-app update window), and **fails the job** if the section is missing — so always write the changelog first (`make release` validates it before you even commit).
- Notarization requires a paid Apple Developer Program membership (Developer ID cert); the app is ad-hoc signed and `make notarize` skips gracefully without a cert.

## Tests

`make test` runs `Tests/MagSleepCoreTests` (XCTest): request → config transitions, config decode/fallback, LED target logic, SMC struct layout, constants/paths, and the socket JSON protocol round-trips.

The git **pre-commit hook** (`make install-hooks`) runs SwiftLint, the Periphery dead-code scan, `swift test`, and a warnings-as-errors build; a commit is blocked if any fails. It requires `swiftlint` and `periphery` installed (`brew install swiftlint periphery`). Keep the helper's entry point as `@main` (in `MagSleepHelperMain.swift`) — Periphery cannot trace top-level executable code and would otherwise report the whole daemon as dead. Known false positives are marked in-source with `// periphery:ignore` (SMC kernel-layout struct fields read via `IOConnectCallStructMethod`, and retained-for-lifetime properties).

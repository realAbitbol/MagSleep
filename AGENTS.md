# Agent guidance

## Project

macOS menu bar app (AppKit) that turns off the MagSafe LED on sleep, restores on wake. Apple Silicon (arm64) only, macOS 14+, Swift 5.10.

## Structure

- `Sources/MagSleep/` — AppKit menu bar app (`@main` in `MagSleepApp.swift`)
- `Sources/MagSleepHelper/` — privileged LaunchDaemon (`magsleep-helper`) that writes to the SMC as root
- `Sources/MagSleepCore/` — shared library: SMC I/O (`SMC.swift`) + constants
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
| `make clean` | Remove `.build` and `dist` |

`scripts/build-app.sh` does the real work: `swift build -c release --arch arm64`, copies binaries + helper scripts + plists into the `.app` bundle, and codesigns with an ad-hoc signature.

**The app must be run from the built `.app` bundle** (not directly via `swift run`) because helper scripts and resources are bundled at build time.

## Architecture

Two processes, no direct IPC:

```
MagSleep.app (user)
  ├─ AppleScript "do shell script … with administrator privileges" → runs a bundled .sh as root
  │    (install-helper.sh, uninstall-helper.sh only)
  └─ writes /tmp/magsleep/request (command string) — no admin needed
magsleep-helper (root LaunchDaemon)
  └─ event-driven: kqueue watch on /tmp/magsleep/ + IORegisterForSystemPower + IOPS power-source changes
```

- **Privileged operations**: install and uninstall run bundled shell scripts via AppleScript. Mode changes, enable, and disable are NOT privileged — the app writes `mode:sleep` / `mode:alwaysOff` / `enable` / `disable` to `/tmp/magsleep/request` and the daemon processes it immediately via a kqueue directory watch (no polling). `HelperManager.sendRequest` optimistically reports success after 0.3s.
- **Helper lifecycle**: install = `install-helper.sh` (bootout old job, copy binary + plist, write `helper-version.txt`, bootstrap); disable = request-file "disable" (sets `config.enabled = false`, LED back to macOS — does NOT unload the daemon); uninstall = `uninstall-helper.sh` (bootout, `--reset` LED, remove files + config dir + `/tmp/magsleep`).
- **Config**: `/Library/Preferences/MagSleep/config.plist` (root-owned, written by the daemon). Fields: `mode` (`.sleep` default / `.alwaysOff`), `enabled`. Missing/corrupt config falls back to `DaemonConfig.default` on startup.
- **Version tracking**: `install-helper.sh` writes the app version to `helper-version.txt` next to the config. On launch the app compares it to its own `CFBundleShortVersionString`; mismatch triggers an update prompt (reinstall, or quit).
- **SMC**: `ACLC` key via `IOConnectCallStructMethod`. `0` = macOS control (default), `1` = off, `3` = green, `4` = amber. Writes require root, hence the LaunchDaemon.
- **Sleep detection**: event-driven via `IORegisterForSystemPower` (also handles `kIOMessageCanSystemSleep` → `IOAllowPowerChange`). The `sleepimage` mtime check is used only once at startup to seed the state if launchd revives the daemon while the Mac is still asleep. `alwaysOff` is re-asserted on power-source changes (`IOPSNotificationCreateRunLoopSource`).

### Key files

- `Sources/MagSleep/MagSleepApp.swift` — entry point, arch/`ACLC` support checks; quitting is a no-op for helper state (daemon keeps running in the active mode)
- `Sources/MagSleep/HelperManager.swift` — install/uninstall via AppleScript, request-file mode/enable/disable, version check
- `Sources/MagSleepHelper/main.swift` — `PowerDaemon`: kqueue request watch, sleep/wake + power-source events, LED control
- `Sources/MagSleepCore/SMC.swift` — AppleSMC IOKit client, `MagSafeLED` API
- `Sources/MagSleepCore/Constants.swift` — paths, labels, `OperationMode`, `DaemonConfig`
- `Sources/MagSleep/StatusItemController.swift` — menu bar UI (icon per mode), 5s state refresh timer; menu: mode items with checkmarks (Sleep Mode / Always Off / Disabled), Launch at Login, Buy me a coffee, Uninstall, About

## Development notes

- `install-helper.sh`/`uninstall-helper.sh` are the only scripts invoked at runtime. `disable-helper.sh` and `set-mode.sh` were removed: Disable is a request-file command (daemon stays loaded, `enabled=false`), and `set-mode.sh` was never bundled (broken dead code).
- Config is re-read only at startup or when a request arrives. SIGINT/SIGTERM are handled via dispatch signal sources that restore the LED to macOS control and exit non-zero — launchd's `KeepAlive` (`SuccessfulExit: false`) then revives the daemon whenever it is killed, so the LED briefly returns to macOS control before the daemon re-applies the active mode. bootout during install/uninstall unloads the job and stops it permanently. The app checks daemon *process* liveness via `pgrep -x` (not `launchctl print`, which reports jobs that are registered but dead) with a 15s cache TTL, and re-enables the helper on launch only if it's installed **but not running** — a deliberately "Disabled" helper stays disabled.

## No tests

No test targets exist in this codebase.

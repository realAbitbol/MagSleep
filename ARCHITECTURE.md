# Architecture

## Pattern Overview

**Overall:** Two-process daemon architecture — an unprivileged AppKit menu bar app paired with a privileged root LaunchDaemon, communicating over a unix-domain socket using newline-delimited JSON, with a pure shared core library both sides link.

**Key Characteristics:**
- **Unprivileged app + privileged daemon split.** The app never touches the SMC or privileged paths directly. Privileged operations (install/uninstall) run bundled shell scripts via AppleScript `do shell script … with administrator privileges`; everything else is a socket request to the daemon.
- **Shared pure core (`MagSleepCore`).** Protocol types, config model, state transitions, and the LED decision live in one library so the app and daemon can never drift. The daemon performs side effects from pure outcomes.
- **Event-driven daemon.** Sleep/wake via `IORegisterForSystemPower`, display sleep via IODisplayWrangler interest notifications (the only mechanism that works from a system daemon with no GUI session), power-source changes via `IOPSNotificationCreateRunLoopSource`, plus a 3s re-assert watchdog and a 30-min sun-schedule timer.
- **One connection per request.** The socket carries a single request line and returns a single response line (request/ack, no polling, short timeouts on the client).
- **SMC writes require root.** The daemon keeps one persistent `SMC.Connection` (no open/close churn); when Disabled it does zero SMC traffic.
- **Fail closed.** Peer authorization via `getpeereid` against the console user; unknown/undeterminable peers are rejected.

## Layers

**MagSleepCore (shared library):**
- Purpose: Single source of truth for the wire protocol, config model, state transitions, the AppleSMC client, and the plumbing both processes use.
- Location: `Sources/MagSleepCore/`
- Contains: SMC client (`SMC.swift`), paths/constants/config types (`Constants.swift`), pure state transitions + LED decision (`DaemonState.swift`), user-facing mode mapping (`LEDMode.swift`), socket protocol types (`SocketProtocol.swift`), pure request dispatch (`SocketCommandHandler.swift`), the socket server + its pure framing/authorization rules (`SocketServer.swift`, `SocketFraming.swift`, `PeerAuthorization.swift`), fd-level socket helpers (`UnixSocket.swift`), bounded subprocess runner (`BoundedProcess.swift`), helper versioning (`HelperVersioning.swift`, `MachOContentHash.swift`), sun-schedule parsing (`SunSchedule.swift`).
- Depends on: Foundation, IOKit, CryptoKit, Darwin only. No AppKit, no Sparkle.
- Used by: the `MagSleep` app target, the `magsleep-helper` executable, and `MagSleepCoreTests`.

**MagSleep.app (user process):**
- Purpose: Menu bar UI; installs/updates the helper, applies modes, manages Launch at Login, checks for updates.
- Location: `Sources/MagSleep/`
- Contains: Entry point (`MagSleepApp.swift`), helper lifecycle + socket client (`HelperManager.swift`), low-level socket client (`HelperConnection.swift`), menu UI + config watch (`StatusItemController.swift`), first-run onboarding window (`OnboardingWindowController.swift`), Sparkle updater (`UpdateManager.swift`), kqueue directory watch (`DirectoryWatcher.swift`), AppleScript/Shortcuts bridge (`AppleScriptCommands.swift`).
- Depends on: `MagSleepCore`, Sparkle, AppKit, ServiceManagement.
- Used by: the user (menu bar), Shortcuts/AppleScript (via the sdef).

**magsleep-helper (root LaunchDaemon):**
- Purpose: Owns the MagSafe LED. Turns it off on sleep, restores on wake, serves app requests over the socket.
- Location: `Sources/MagSleepHelper/`
- Contains: `PowerDaemon` (sleep/wake + power-source events, config, LED control). The socket server it drives lives in `MagSleepCore` (`SocketServer.swift`) so it is reachable from the unit-test suite.
- Depends on: `MagSleepCore`, IOKit, SystemConfiguration, os.log. Runs as root via `packaging/com.magsleep.helper.plist` (`KeepAlive` with `SuccessfulExit: false`).
- Used by: the app (socket requests), launchd.

**Packaging & scripts (build/runtime):**
- Purpose: Assemble the `.app` bundle, install/uninstall the helper, drive releases.
- Location: `packaging/`, `scripts/`
- Contains: `Info.plist` template (version/build substituted at build time), LaunchDaemon plist, AppleScript sdef, `build-app.sh`/`build-dmg.sh`, `install-helper.sh`/`uninstall-helper.sh` (bundled at build time and invoked at runtime), release/signing/scanning scripts.
- Depends on: `swift build`, `codesign`, `launchctl`, `osascript`.

## Data Flow

**Mode / enable / disable / night-schedule request (app → daemon):**
1. Menu item, Shortcut, or AppleScript invokes `HelperManager.apply(_:)` or `setNightSchedule(_:)` — `Sources/MagSleep/HelperManager.swift`
2. `sendRequest` dispatches `HelperConnection.send(command)` off the main thread — `Sources/MagSleep/HelperConnection.swift`
3. Client encodes a `SocketRequest(id:cmd:)` as one JSON line and writes it to `/var/run/magsleep.sock` via `UnixSocket.writeAll` — `Sources/MagSleepCore/SocketProtocol.swift`, `Sources/MagSleepCore/UnixSocket.swift`
4. The daemon's `SocketServer` accepts the connection, reads the bytes, and frames the line (`SocketFraming`); it resolves the peer uid via `getpeereid` — `Sources/MagSleepCore/SocketServer.swift`, `Sources/MagSleepCore/SocketFraming.swift`
5. `PowerDaemon.handleSocketRequest` rejects non-console peers via the pure `PeerAuthorization` rule (fails closed), then calls the pure `SocketCommandHandler.handle` — `Sources/MagSleepHelper/MagSleepHelperMain.swift`, `Sources/MagSleepCore/PeerAuthorization.swift`, `Sources/MagSleepCore/SocketCommandHandler.swift`
6. On success the daemon persists the new config (atomic plist write), calls `applyMode()`, and replies with a `SocketResponse` echoing the new config; the client surfaces `response.ok`/`error` on the main queue — real results, no optimistic success.

**Sleep/wake (daemon):**
1. `IORegisterForSystemPower` delivers `systemWillSleep` / `systemHasPoweredOn` (and `canSystemSleep`, which is always acknowledged via `IOAllowPowerChange`) — `Sources/MagSleepHelper/MagSleepHelperMain.swift`
2. `handlePowerMessage` flips `isSleeping`/`isDisplayAsleep` and calls `applyMode()`
3. `applyMode()` computes `LEDTarget.color(for:isSystemSleeping:isDisplayAsleep:isNight:)` and writes the color over the persistent SMC connection — `Sources/MagSleepCore/DaemonState.swift`, `Sources/MagSleepCore/SMC.swift`
4. Writes are deduped: re-writing `.system` when the last write was `.system` is skipped (pure SMC churn), while `.off` is always re-asserted (macOS flips the wire value on plug/unplug).

**Display sleep (daemon):**
- IODisplayWrangler interest notifications (`kIOMessageDeviceWillPowerOff`/`kIOMessageDeviceHasPoweredOn`) update `isDisplayAsleep` → `applyMode()`. This is the mechanism that works from a bare system daemon (NSWorkspace/CGDisplay callbacks require a GUI session).

**Power-source re-assert (daemon):**
- `IOPSNotificationCreateRunLoopSource` fires on plug/unplug/charging-state changes → `onPowerSourceChange()` → `applyMode()` (covers `alwaysOff` winning over the charging indicator). Skipped while disabled.

**Re-assert watchdog (daemon):**
- A 3s timer re-applies the active mode and also retries a failed socket bind + checks the socket file exists (self-healing `/var/run` cleanup). The dedup rule keeps this near-zero SMC traffic.

**Night schedule (daemon):**
- A 30-min timer runs `corebrightnessdiag sunschedule` (probed at `/usr/libexec/` then `/usr/bin/`) through `BoundedProcess` (10s timeout), parses it with `SunSchedule`, and feeds `DayNight.isNight` — `Sources/MagSleepCore/SunSchedule.swift`. Unavailable/unparsable schedule falls back to a local 20:00–07:00 window; the 3s re-assert timer converges the LED across night boundaries.

**Helper install (app → admin script):**
1. Onboarding window or upgrade prompt calls `HelperManager.install`/`enable` — `Sources/MagSleep/OnboardingWindowController.swift`
2. `runPrivilegedScript` wraps `install-helper.sh <resources> <user> <revision>` in an osascript admin prompt, run via `BoundedProcess` (180s timeout) — `Sources/MagSleep/HelperManager.swift`
3. `install-helper.sh` verifies the app bundle signature and the bundled helper's cdhash against `helper-cdhash.txt` before touching anything, serializes installs with `lockf`, bootouts the old job, installs binary + plist, strips quarantine xattrs, re-signs ad-hoc at the final path, bootstraps with retries, and writes `helper-version.txt` only on success — `scripts/install-helper.sh`
4. `confirmConnection` polls the socket for up to 15s (1s interval) so the UI hourglass lasts until the daemon actually answers.

**Helper uninstall (app → admin script):**
- `HelperManager.uninstall` runs `uninstall-helper.sh`, which bootouts the job, runs `magsleep-helper --reset` (restores LED to macOS control), removes binary/plist/config/socket/`/tmp/magsleep`, then unregisters the login item — `scripts/uninstall-helper.sh`.

**Helper update detection (app):**
- `build-app.sh` embeds the helper revision (last commit touching `Sources/MagSleepHelper`, `Sources/MagSleepCore`, `packaging/com.magsleep.helper.plist`, `scripts/install-helper.sh`) as `helper-revision.txt` and the signed binary's cdhash as `helper-cdhash.txt`. On launch the app compares **content hashes** of the installed vs bundled helper binary first (`MachOContentHash`, signing-independent) and falls back to the recorded revision when binaries can't be read — `Sources/MagSleep/HelperManager.swift`, `Sources/MagSleepCore/HelperVersioning.swift`, `Sources/MagSleepCore/MachOContentHash.swift`. A mismatch triggers an update prompt.

## Key Abstractions

**`DaemonConfig`:**
- Purpose: The persisted configuration — `mode` (`OperationMode`: `.sleep`/`.alwaysOff`), `enabled`, `nightScheduleEnabled`.
- Location: `Sources/MagSleepCore/Constants.swift`
- Pattern: Codable plist. `mode`/`enabled` are required (decode failure → caller falls back to `.default`); `nightScheduleEnabled` decodes via `decodeIfPresent` defaulting to false so older configs keep decoding. `DaemonConfig.load` falls back to `.default` on any error.

**`RequestCommand`:**
- Purpose: The single source of the wire vocabulary (`mode:sleep`, `mode:alwaysOff`, `enable`, `disable`, `nightschedule:on`, `nightschedule:off`).
- Location: `Sources/MagSleepCore/DaemonState.swift`
- Pattern: String constants. `DaemonConfig.apply` switches on them, `LEDMode.socketCommand` produces them — both sides reference the same constants so they can't drift.

**`LEDMode`:**
- Purpose: The user-facing three-state concept (Sleep / Always Off / Disabled) shared by the menu, Shortcuts, and AppleScript.
- Location: `Sources/MagSleepCore/LEDMode.swift`
- Pattern: Raw-value enum mapping to `socketCommand` and `operationMode` (`.disabled` is the `enabled = false` flag, not a mode value). `LEDStatusDescription` keeps the human-readable status string identical across surfaces.

**`LEDTarget`:**
- Purpose: The pure LED-color decision — Disabled always wins (`.system`), night schedule beats mode, `.sleep` off when system OR display asleep, `.alwaysOff` always off.
- Location: `Sources/MagSleepCore/DaemonState.swift`
- Pattern: Static pure function over `DaemonConfig` + sleep flags; unit-testable without hardware.

**`SocketCommandHandler` / `SocketCommandOutcome`:**
- Purpose: The authorization boundary and command→response decision, extracted from the daemon so it is unit-testable.
- Location: `Sources/MagSleepCore/SocketCommandHandler.swift`
- Pattern: Pure dispatch returning the response plus the new config to persist/apply; the daemon performs the side effects from the outcome.

**`SocketRequest` / `SocketResponse`:**
- Purpose: The wire types — one connection per request, one newline-terminated JSON line each.
- Location: `Sources/MagSleepCore/SocketProtocol.swift`
- Pattern: Codable structs with `parseLine`/`encodeLine`. `encodeLine` falls back to a valid error response (never an unparseable `"{}"` that would hang the client until timeout).

**`SMC` / `SMC.Connection` / `MagSafeLED`:**
- Purpose: Minimal AppleSMC client. `MagSafeLED` is the ACLC key API (`0`=macOS, `1`=off, `3`=green, `4`=amber).
- Location: `Sources/MagSleepCore/SMC.swift`
- Pattern: Struct layout mirrors the kernel's 80-byte `SMCParamStruct` (pinned by tests). `Connection` opens the service once, caches key info, and reuses the connection for recurring re-asserts. Not thread-safe — the daemon only touches it from the main run loop.

**`UnixSocket`:**
- Purpose: Shared fd-level socket helpers (sockaddr construction, blocking `writeAll` with poll timeouts).
- Location: `Sources/MagSleepCore/UnixSocket.swift`
- Pattern: Static helpers so the client and server can't drift in the fd-level details.

**`SocketServer` / `SocketFraming` / `PeerAuthorization`:**
- Purpose: The daemon's unix-domain socket server, split so its rules are testable: `SocketFraming` decides "what did those bytes mean?" (line vs incomplete vs too large), `PeerAuthorization` decides who may connect (pure, fail-closed), and `SocketServer` owns the fd plumbing (accept, 32-client cap, 10s idle sweep, self-healing rebind).
- Location: `Sources/MagSleepCore/SocketServer.swift` (+ `SocketFraming.swift`, `PeerAuthorization.swift`)
- Pattern: One serial queue per server (the daemon passes `.main`), so the connection table needs no locking. Lives in the shared core so `MagSleepCoreTests` can drive a real server over a temp-path socket.

**`BoundedProcess`:**
- Purpose: Runs a subprocess with a bounded wait AND bounded output drain, so a hung or chatty child can never leak a thread or deadlock a pipe.
- Location: `Sources/MagSleepCore/BoundedProcess.swift`
- Pattern: SIGTERM → SIGKILL escalation; poll-bounded pipe drains that re-check the deadline (a grandchild inheriting a write end can't block past the deadline).

**`HelperVersioning` / `MachOContentHash`:**
- Purpose: Decide whether the installed helper matches the bundled one.
- Location: `Sources/MagSleepCore/HelperVersioning.swift`, `Sources/MagSleepCore/MachOContentHash.swift`
- Pattern: Content-hash comparison is primary (signing-independent — hashes everything up to the code signature with the signature-tracking load-command fields zeroed, so re-signed identical binaries hash equal); revision comparison is the fallback when hashes are unavailable.

**`SunSchedule` / `DayNight`:**
- Purpose: Parse `corebrightnessdiag sunschedule` output and decide night (between sunset and sunrise, or the 20:00–07:00 fallback window).
- Location: `Sources/MagSleepCore/SunSchedule.swift`
- Pattern: Best-effort parsing anchored to line starts; callers degrade gracefully when parsing fails.

## Entry Points

**MagSleep app:**
- Location: `Sources/MagSleep/MagSleepApp.swift` (`@main MagSleepMain`)
- Triggers: `open` / Launch at Login / user launch
- Responsibilities: `NSApplication` setup (accessory, minimal main menu so Cmd+Q works), arm64 + `MagSafeLED.isSupported()` checks, single-instance guard (activates the existing instance instead), constructs `HelperManager` + `StatusItemController`. Quitting never touches helper state — the daemon keeps running in the active mode.

**magsleep-helper:**
- Location: `Sources/MagSleepHelper/MagSleepHelperMain.swift` (`@main MagSleepHelperMain`)
- Triggers: launchd `RunAtLoad`/`KeepAlive`; also invoked with `--reset` by `uninstall-helper.sh`
- Responsibilities: `--reset` restores the LED to macOS control and exits 0; otherwise `PowerDaemon().run()` — config load (healing missing/corrupt config), sleep-state seeding from the `sleepimage` mtime + dynamic store, signal handlers (restore `.system`, exit 1 so KeepAlive revives), power/display/power-source notifications, socket server, sun-schedule timer, 3s re-assert timer.

**AppleScript/Shortcuts bridge:**
- Location: `Sources/MagSleep/AppleScriptCommands.swift` (instantiated by AppKit from `packaging/MagSleep.sdef`)
- Triggers: `set led mode <sleep|alwaysOff|disabled>`, `turn LED off`, `turn LED on`, `get led status`
- Responsibilities: Convert sdef commands to `LEDMode.socketCommand` and send synchronously (off-main send + semaphore wait to avoid a main-thread deadlock); `get led status` reuses a shared `HelperManager` and reads config from disk without a blocking socket probe.

## Error Handling

**Strategy:** Fail closed and degrade gracefully.

- **Authorization:** The daemon rejects any request whose `getpeereid` uid is neither root nor the current console user; an undeterminable console user rejects rather than authorizing an arbitrary local process on the 0666 socket.
- **Config:** Missing/corrupt config falls back to `DaemonConfig.default`; the daemon rewrites defaults to disk so a corrupt file is healed. `nightScheduleEnabled` defaults to false for pre-1.3 configs.
- **Socket server:** Oversized requests (> 4096 bytes) close the connection; at most 32 concurrent clients; idle clients are swept after 10s; a missing socket file is rebound from the re-assert timer. Both processes ignore SIGPIPE so a peer disconnect surfaces as a failed request instead of killing the process.
- **SMC:** Writes are retried on the next tick; a failed write drops the persistent connection so the next apply reopens it; failure logs are throttled to one per distinct message. `SMCParamStruct` size is validated (must be 80 bytes) before any call.
- **Subprocesses:** Bounded — 180s for privileged scripts (a left-open admin prompt must not block a worker forever), 10s for sun-schedule fetches, with SIGTERM→SIGKILL escalation.
- **Shutdown:** SIGINT/SIGTERM restore the LED to macOS control and exit non-zero; launchd's `KeepAlive` revives the daemon. `bootout` during install/uninstall stops it permanently. Quitting the app is a no-op for the helper.
- **Update detection:** Falls back to the recorded revision when binaries can't be read; "unknown" embedded revision (no git at build time) keeps the legacy always-reinstall behavior.

## Cross-Cutting Concerns

**Logging:** `os.log` `Logger` (subsystem `com.magsleep.helper`, categories `daemon` and `socket`). SMC failure logs are throttled to avoid 3s-tick spam; peer uids are logged with `privacy: .public`.
**Caching:** `SMC.Connection` caches key-info lookups; the sun schedule is refreshed on a 30-min timer; the app probes daemon liveness per refresh (cheap socket connect, no pgrep).
**Storage:** Root-owned `/Library/Preferences/MagSleep/config.plist` (atomic writes, 0644 so the app can read it), `helper-version.txt` next to it, socket at `/var/run/magsleep.sock` (0666). The bundle embeds `helper-revision.txt`, `helper-cdhash.txt`, and `build-info.json` (builder provenance).
**Signing/trust:** `install-helper.sh` verifies the enclosing bundle's signature and the bundled helper's cdhash pin before any privileged write; the installed binary is re-signed ad-hoc at its final path (launchd validates signatures at the path it reads). Helper binary comparison uses a signing-independent content hash, not cdhash (codesign versions differ across machines).

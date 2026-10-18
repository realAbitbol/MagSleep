# Codebase Structure

## Directory Layout

```
MagSleep/
├── Sources/
│   ├── MagSleep/          # AppKit menu bar app (user process)
│   ├── MagSleepCore/      # Shared library (protocol, SMC, pure state)
│   └── MagSleepHelper/    # Privileged root LaunchDaemon (magsleep-helper)
├── Tests/
│   └── MagSleepCoreTests/ # XCTest unit tests for the core library
├── packaging/             # Info.plist template, LaunchDaemon plist, AppleScript sdef
├── scripts/               # Build, release, and runtime helper scripts
├── appcast/               # Sparkle appcast feed (committed to master)
├── .github/workflows/     # CI: release.yml, codeql.yml
├── dist/                  # Build output (MagSleep.app, DMG, ZIP) — gitignored
├── .build/                # SwiftPM build products — gitignored
├── Package.swift          # SwiftPM manifest (4 targets)
├── Makefile               # Build/run/install/dmg/test/lint/release targets
├── AGENTS.md              # Agent guidance for this repo
├── CHANGELOG.md           # Release notes (CI extracts sections as release bodies)
├── README.md              # User-facing docs
└── SECURITY.md            # Security policy
```

## Directory Purposes

**Sources/MagSleep/:**
- Purpose: The AppKit menu bar app — UI, helper lifecycle, updates.
- Contains: `@main` entry point, `HelperManager`, `HelperConnection`, `StatusItemController`, `OnboardingWindowController` (+ `ModeCardView`), `UpdateManager`, `DirectoryWatcher`, `AppleScriptCommands`.
- Key files: `MagSleepApp.swift` (entry), `HelperManager.swift` (install/mode/enable/disable/uninstall), `StatusItemController.swift` (menu UI + config watch).

**Sources/MagSleepCore/:**
- Purpose: The shared library both processes link. Everything here is public and pure where possible.
- Contains: SMC client, config + protocol types, state transitions, socket plumbing (including the socket server), subprocess runner, versioning logic, sun-schedule parsing.
- Key files: `SMC.swift`, `Constants.swift`, `DaemonState.swift`, `SocketProtocol.swift`, `SocketCommandHandler.swift`, `SocketServer.swift`, `SocketFraming.swift`, `PeerAuthorization.swift`, `UnixSocket.swift`, `BoundedProcess.swift`, `HelperVersioning.swift`, `MachOContentHash.swift`, `LEDMode.swift`, `SunSchedule.swift`.
- Constraint: No AppKit/Sparkle imports — only Foundation, IOKit, CryptoKit, Darwin.

**Sources/MagSleepHelper/:**
- Purpose: The privileged daemon binary (`magsleep-helper`) that owns the LED and serves the socket.
- Contains: `PowerDaemon` (power events, config, LED control, timers). The socket server it drives lives in `MagSleepCore`.
- Key files: `MagSleepHelperMain.swift` (`@main` + `--reset` path).

**Tests/MagSleepCoreTests/:**
- Purpose: XCTest coverage of the core library (request→config transitions, config decode/fallback, LED target logic, SMC struct layout, constants/paths, socket protocol round-trips, socket framing, peer authorization, a live socket-server integration test, BoundedProcess, UnixSocket, MachOContentHash incl. fat containers, HelperVersioning, SunSchedule/DayNight).
- Key files: `MagSleepCoreTests.swift`, `MagSleepCoreArchitectureTests.swift`, `MagSleepCoreEdgeCaseTests.swift`, `SocketFramingTests.swift`, `PeerAuthorizationTests.swift`, `SocketServerTests.swift`.

**packaging/:**
- Purpose: Static resources and templates copied into the `.app` bundle by `scripts/build-app.sh`.
- Contains: `Info.plist` (version/build substituted at build time), `com.magsleep.helper.plist` (LaunchDaemon), `MagSleep.sdef` (AppleScript dictionary).
- Key files: `MagSleep.sdef` (declares the `cocoa class` names `AppleScriptCommands.swift` implements).

**scripts/:**
- Purpose: Everything that runs outside Swift — build, release, and the two runtime helper scripts.
- Contains: `build-app.sh`, `build-dmg.sh`, `install-helper.sh`, `uninstall-helper.sh` (bundled and invoked at runtime), `release.sh`, `notarize.sh`, `virustotal-scan.sh`, `sign-appcast.sh`, `apply-vt-proof.py`, `verify-sparkle-key.swift`, `make-icon.swift`, `git-hooks/`.
- Key files: `build-app.sh` (assembles the bundle, embeds helper revision + cdhash + build-info), `install-helper.sh`/`uninstall-helper.sh` (the only scripts invoked at runtime).

**appcast/:**
- Purpose: The Sparkle feed, committed to master and served from GitHub raw.
- Contains: `appcast.xml` (signed by CI with `SPARKLE_EDDSA_KEY`, committed after each release).

**.github/workflows/:**
- Purpose: CI. `release.yml` builds the DMG from scratch on a runner, VirusTotal-scans, signs the appcast, attests, publishes, and commits the appcast + VT proof; `codeql.yml` runs CodeQL analysis.
- Key files: `release.yml` (triggered by a `vX.Y.Z` tag push).

**dist/ and .build/:**
- Purpose: Build outputs. `dist/` holds `MagSleep.app`, DMGs, and the Sparkle ZIP; `.build/` is SwiftPM intermediates. Both gitignored.

## Key File Locations

**Entry Points:** `Sources/MagSleep/MagSleepApp.swift` (app `@main`); `Sources/MagSleepHelper/MagSleepHelperMain.swift` (daemon `@main`, plus the `--reset` one-shot); `packaging/MagSleep.sdef` + `Sources/MagSleep/AppleScriptCommands.swift` (AppleScript/Shortcuts surface).
**Configuration:** `Sources/MagSleepCore/Constants.swift` (paths, labels, `OperationMode`, `DaemonConfig`); `packaging/Info.plist` (bundle identity, Sparkle public key); `packaging/com.magsleep.helper.plist` (LaunchDaemon job); `Makefile` (VERSION default).
**Core Logic:** `Sources/MagSleepCore/DaemonState.swift` (`RequestCommand`, `DaemonConfig.apply`, `LEDTarget`), `Sources/MagSleepCore/SocketCommandHandler.swift` (request dispatch), `Sources/MagSleepCore/SMC.swift` (LED writes).
**Tests:** `Tests/MagSleepCoreTests/` — three files covering the shared core.
**Build:** `scripts/build-app.sh`, `scripts/build-dmg.sh`, `Makefile`.
**Release:** `scripts/release.sh` (local: validate + bump + commit + tag + push only), `.github/workflows/release.yml` (the actual build/publish), `scripts/sign-appcast.sh`, `scripts/virustotal-scan.sh`, `scripts/apply-vt-proof.py`, `scripts/verify-sparkle-key.swift`.

## Naming Conventions

**Files:** PascalCase matching the primary type: `HelperManager.swift`, `SocketServer.swift`, `StatusItemController.swift`. Core-library files are named after the domain concept: `DaemonState.swift`, `SocketProtocol.swift`, `LEDMode.swift`, `SunSchedule.swift`.
**Directories:** PascalCase targets under `Sources/` (`MagSleep`, `MagSleepCore`, `MagSleepHelper`); lowercase test directory (`MagSleepCoreTests`); lowercase `packaging/`, `scripts/`, `appcast/`.
**Types:** Public structs/enums in `MagSleepCore` (shared across processes); `final` classes for app/daemon objects; `@objc` names on sdef-backed AppleScript command classes (`SetLEDModeCommand`, `TurnLEDOffCommand`, `TurnLEDOnCommand`, `GetLEDStatusCommand`).
**Wire commands:** Lowercase `kebab`/`colon` strings defined once as `RequestCommand` constants (`mode:sleep`, `mode:alwaysOff`, `enable`, `disable`, `nightschedule:on`, `nightschedule:off`) — never string-literal commands at call sites.
**Tests:** `XCTestCase` classes named `<Area>Tests` (`DaemonConfigTests`, `LEDTargetTests`, `SocketProtocolTests`, `BoundedProcessTests`).

## Where to Add New Code

**New socket command:** Add the constant to `RequestCommand` (`Sources/MagSleepCore/DaemonState.swift`), the case to `DaemonConfig.apply`, a user-facing mapping in `LEDMode` if it is a mode, then cover the transition in `Tests/MagSleepCoreTests/`. The command string then flows unchanged through `SocketCommandHandler` → `PowerDaemon` → `HelperManager.sendRequest`.
**New core logic (shared):** `Sources/MagSleepCore/<Name>.swift` — keep it pure and free of AppKit/Sparkle, and add an `XCTestCase` in `Tests/MagSleepCoreTests/` (new file or an existing one by theme).
**New app UI or feature:** `Sources/MagSleep/<Name>.swift`, wired through `StatusItemController` (menu) or the app startup chain.
**New daemon behavior:** `Sources/MagSleepHelper/<Name>.swift`, registered in `PowerDaemon.run()` (a notification source, timer, or socket path). Keep the `MagSleepHelperMain` entry point untouched for Lethen (the socket server itself lives in `MagSleepCore`, where the test target can reach it).
**New AppleScript/Shortcuts command:** Add the sdef entry in `packaging/MagSleep.sdef` (`<cocoa class="…"/>`) and the `@objc` handler class in `Sources/MagSleep/AppleScriptCommands.swift` (mark it `// periphery:ignore - instantiated by AppKit from the sdef`).
**New runtime shell script:** `scripts/<name>.sh`, bundled in `scripts/build-app.sh` (copy into `Contents/Resources` + `chmod +x`) and invoked via `HelperManager.runPrivilegedScript` if it needs admin.
**New SwiftPM target:** Add to `Package.swift`; if the helper depends on it, include its path in the `helper-revision` computation in `scripts/build-app.sh` so helper-affecting changes still trigger reinstalls.
**Tests:** Co-located in `Tests/MagSleepCoreTests/` as `*.swift` — pure-core logic is unit-tested there; the app and daemon are deliberately thin shells around the tested core.

<div align="center">

<img width="300" height="300" alt="MagSleep" src="https://github.com/user-attachments/assets/be61ac1c-3fd5-48c2-9749-7b62d5d10916" />

# MagSleep

A tiny macOS menu bar app that turns off your MagSafe LED when the MacBook sleeps, and hands it back to macOS when it wakes.
Or to turn it off completely.

Perfect for a dark bedroom: no green/amber glow from the charger while you sleep.

![Platform](https://img.shields.io/badge/macOS-14%2B-blue)
![Arch](https://img.shields.io/badge/Apple%20Silicon-arm64-black)
![Language](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/personal%20use-welcome-lightgrey)

</div>

## Features

- **Sleep Mode** — turns the MagSafe LED off while the Mac sleeps, restores it to macOS on wake
- **Always Off** — keeps the LED off at all times (re-asserted even when you plug/unplug the charger)
- **Disabled** — hands the LED back to macOS entirely, whenever you want
- **Launch at Login** — starts MagSleep automatically when you log in
- **In-app updates** — checks for new versions automatically (twice a day) and installs them with Sparkle; no more manual DMG downloads
- Lives quietly in the menu bar; the helper keeps working even if you quit the app

## Requirements

- Apple Silicon MacBook with **MagSafe 3** (2021 or later MacBook Pro / Air)
- A MagSafe cable with an LED
- macOS 14 Sonoma or later
- Admin password once (to install the privileged helper)

Intel Macs are not supported.

## How to install

### From a DMG

1. Download the latest MagSleep DMG from the [Releases](https://github.com/realAbitbol/MagSleep/releases) page.
2. Open the DMG and drag **MagSleep** into **Applications**.
3. Launch MagSleep (it will appear as an icon in the menu bar).
4. Click the menu bar icon and choose **Sleep Mode** (or **Always Off**) — this installs the helper and asks for your admin password once.

> [!IMPORTANT]
> MagSleep is **ad-hoc signed, not notarized** (notarization requires a paid Apple Developer Program membership). macOS therefore quarantines the downloaded app, and Gatekeeper may block the first launch. This is expected — unblock it with one of the methods below.

#### If Gatekeeper blocks the app or the DMG

When you first try to open a downloaded MagSleep, macOS may show one of these dialogs:

- *"MagSleep cannot be opened because the developer cannot be verified."*
- *"MagSleep cannot be opened because it is not from an identified developer."*
- *"MagSleep-1.0.X.dmg cannot be opened because it was not downloaded from the App Store."*

Try these in order — stop as soon as one works:

**Method A — right-click → Open (easiest)**
1. Open **Finder** and go to **Applications**.
2. **Right-click** (or Control-click) **MagSleep**, then choose **Open**.
3. Click **Open** in the confirmation dialog.
4. MagSleep launches and is allowed to open from then on.

**Method B — System Settings → Open Anyway**
1. After a first blocked attempt, open **System Settings → Privacy & Security**.
2. Scroll down to the **Security** section.
3. Next to *"MagSleep was blocked from use…"* click **Open Anyway** and confirm with Touch ID or your password.

**Method C — the DMG itself won't open**
If the error happens while opening the DMG, unblock the DMG file first, then open it again:

```bash
xattr -d com.apple.quarantine ~/Downloads/MagSleep-1.2.4.dmg
```

**Method D — remove the quarantine flag (most reliable)**
If the app was already copied into Applications, remove the quarantine flag directly:

```bash
xattr -dr com.apple.quarantine /Applications/MagSleep.app
```

Then launch MagSleep normally. To confirm it's unblocked:

```bash
xattr -l /Applications/MagSleep.app | grep quarantine
```

No output means the flag is gone and Gatekeeper will no longer block it.

> [!NOTE]
> - Removing the quarantine flag is safe: MagSleep is open source and built locally from this repository.
> - Gatekeeper exceptions work best when the app lives in `/Applications`. If it still won't open, move it there and retry Method A or B.

## How to use

1. Click the menu bar icon and choose a mode:
   - **Sleep Mode** — LED off while the Mac sleeps, restored to macOS on wake (recommended)
   - **Always Off** — LED stays off at all times
   - **Disabled** — hand the LED back to macOS entirely
2. The first mode selection installs the small root helper and asks for your admin password once.
3. Optionally enable **Launch at Login** so MagSleep starts automatically.

That's it. Sleep and wake are handled automatically — the helper keeps running even if you quit the menu bar app, as long as it stays enabled.

### Menu reference

| Item | Action |
|------|--------|
| **Sleep Mode** | LED off while the Mac sleeps, restored to macOS on wake |
| **Always Off** | LED stays off at all times (re-asserted even after plug-in/unplug) |
| **Disabled** | Hand the LED back to macOS entirely |
| **Launch at Login** | Start MagSleep when you log in |
| **Check for Updates…** | Check for updates via Sparkle (also checked automatically twice a day) |
| **Report a Problem…** | Open the GitHub issue tracker with your app version + helper revision pre-filled |
| **Buy me a coffee** | [ko-fi.com/realabitbol](https://ko-fi.com/realabitbol) |
| **Uninstall MagSleep…** | Full cleanup, then quit |
| **About MagSleep…** | App version and helper status |
| **Quit MagSleep** | Quit the menu bar UI (the helper keeps running if enabled) |

## Automation

MagSleep is scriptable from **Shortcuts** and **AppleScript** — both go through the same socket requests as the menu items, so no helper reinstall is involved.

**Shortcuts** (macOS 13+): the app provides **Set LED Mode**, **Turn LED Off**, **Turn LED On**, and **Get LED Status** actions — open the Shortcuts app, add a MagSleep action, and use it in any shortcut or automation.

**AppleScript** (e.g. in Script Editor):

```applescript
tell application "MagSleep"
    set led mode "alwaysOff"   -- "sleep" | "alwaysOff" | "disabled"
    turn LED off
    turn LED on
    get led status
end tell
```

## How to update

- **Automatic**: MagSleep checks for new versions twice a day and offers the update when one is available.
- **Manual**: click **Check for Updates…** in the menu bar to check right now.
- Updates are downloaded and installed **in-place by Sparkle** (no DMG, no need to reinstall), then the app relaunches.
- If you ever reinstall from a fresh DMG instead, macOS may block it again — see the Gatekeeper guide in *How to install* above.

## How to uninstall

**From the app:** **Uninstall MagSleep…** → confirm → admin password.

That restores macOS LED control, unloads and deletes the helper and LaunchDaemon, turns off Launch at Login, and quits. Delete `MagSleep.app` afterwards if you want.

**From the terminal:**

```bash
sudo launchctl bootout system/com.magsleep.helper 2>/dev/null || true
sudo /Library/PrivilegedHelperTools/com.magsleep.helper --reset 2>/dev/null || true
sudo rm -f /Library/PrivilegedHelperTools/com.magsleep.helper
sudo rm -f /Library/LaunchDaemons/com.magsleep.helper.plist
sudo rm -rf /Library/Preferences/MagSleep
sudo rm -rf /Library/Logs/MagSleep
sudo rm -rf /tmp/magsleep
```

## Support ☕

If MagSleep keeps your nights a little darker, you can [buy me a coffee](https://ko-fi.com/realabitbol).

---

# For developers

## Building from source

```bash
git clone <repo-url>
cd MagSleep
make app VERSION=1.2.4    # build dist/MagSleep.app
make install VERSION=1.2.4  # copy to /Applications
# or
make dmg VERSION=1.2.4    # dist/MagSleep-1.2.4.dmg
```

## Build targets

| Command | Result |
|---------|--------|
| `make app VERSION=x.y.z` | Build `dist/MagSleep.app` with that version |
| `make dmg VERSION=x.y.z` | `dist/MagSleep-<version>.dmg` |
| `make install VERSION=x.y.z` | Copy the built app to `/Applications` (never silently rebuilds) |
| `make run` | Build and open |
| `make test` | Run the XCTest unit tests |
| `make lint` | Run SwiftLint + Periphery dead-code scan (also runs in the git pre-commit hook) |
| `make install-hooks` | Install the git pre-commit hook (SwiftLint, Periphery, tests, warnings-as-errors build); requires `swiftlint` and `periphery` (`brew install swiftlint periphery`) |
| `make notarize` | Sign + notarize with a Developer ID cert if present (skips gracefully without one) |
| `make release VERSION=x.y.z` | Full release: test, build DMG, update versions, commit, tag, push, publish GitHub Release + Sparkle appcast |
| `make clean` | Remove `.build` and `dist` |

The app version is written to the app's `Info.plist`; the **helper revision** (last commit touching helper-affecting code) is written to the helper version file on install. Launching an app whose helper revision differs from the installed helper's triggers an "Update Helper" prompt — so an unchanged helper is not reinstalled on a plain app update.

## Release process

`make release VERSION=x.y.z` automates a full release (`scripts/release.sh`):

- Refuses a dirty tree or an existing tag
- Runs tests, builds the DMG and the Sparkle update ZIP
- Updates the README/Makefile version references
- Uses the released version's `CHANGELOG.md` section as the GitHub release body
  and as the Sparkle update notes (write the changelog before releasing)
- Regenerates and signs `appcast/appcast.xml` (Sparkle EdDSA), committing it
- Commits, creates tag `vX.Y.Z`, pushes branch + tag
- Publishes the GitHub Release with the DMG + ZIP attached

Requirements: a clean tree, a `gh`-authenticated session, and the Sparkle EdDSA signing key (from `generate_keys`) in the login keychain.

## Notarization & distribution

MagSleep is **ad-hoc signed**, not notarized: notarization requires an Apple Developer Program membership (paid, \$99/yr) and a Developer ID certificate. Because of this, DMGs downloaded from the internet may be blocked by Gatekeeper — prefer building from source (`make app` + `make install`), which produces a locally-built app with no quarantine flag.

If you ever join the Apple Developer Program, `make notarize` signs with your Developer ID certificate, submits for notarization, and staples the ticket. Without a certificate it prints guidance and exits 0.

## How it works

```text
Mac goes to sleep  →  helper writes ACLC = 1  →  MagSafe LED off
Mac wakes up       →  helper writes ACLC = 0  →  macOS controls the LED again
```

MagSleep is a lightweight AppKit menu bar app plus a privileged LaunchDaemon. The daemon is fully event-driven: it serves app requests over a unix socket (`/var/run/magsleep.sock`, request/ack, no polling), listens for system power events (`IORegisterForSystemPower`), and reacts to power-source changes (`IOPS`) so **Always Off** stays off even when you plug in or unplug the charger. It writes the MagSafe LED SMC key `ACLC`; root is required for SMC writes, which is why the first mode selection asks for your password once.

| `ACLC` | Meaning |
|--------|---------|
| `0` | System control (amber / green as usual) |
| `1` | Off |
| `3` | Green |
| `4` | Amber |

MagSafe LED control is undocumented. A macOS or firmware update may change or break it.

## Tests

`make test` runs `Tests/MagSleepCoreTests` (XCTest): request → config transitions, config decode/fallback, LED target logic, SMC struct layout, constants/paths, socket protocol round-trips, and version comparison.

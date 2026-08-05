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

## Requirements

- Apple Silicon MacBook with **MagSafe 3** (2021 or later MacBook Pro / Air)
- A MagSafe cable with an LED
- macOS 14 Sonoma or later
- Admin password once (to install the privileged helper)

Intel Macs are not supported.

## Install

### From a DMG

1. Download the latest MagSleep DMG from the [Releases](https://github.com/realAbitbol/MagSleep/releases) page.
2. Open the DMG and drag **MagSleep** into **Applications**.
3. Launch MagSleep (it will appear as an icon in the menu bar).
4. Click the menu bar icon and choose **Sleep Mode** (or **Always Off**) — this installs the helper and asks for your admin password once.

> [!IMPORTANT]
> MagSleep is **ad-hoc signed, not notarized** (notarization requires a paid Apple Developer Program membership). macOS therefore quarantines the downloaded app, and Gatekeeper may block the first launch. This is expected — unblock it with one of the methods below. See [Notarization & distribution](#notarization--distribution).

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
xattr -d com.apple.quarantine ~/Downloads/MagSleep-1.0.9.dmg
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
> - Updating to a newer DMG re-quarantines the app, so you may need to repeat Method D after each update.
> - Removing the quarantine flag is safe: MagSleep is open source and built locally from this repository.
> - Gatekeeper exceptions work best when the app lives in `/Applications`. If it still won't open, move it there and retry Method A or B.

### From source

```bash
git clone <repo-url>
cd MagSleep
make app VERSION=1.0.5    # build dist/MagSleep.app
make install VERSION=1.0.5  # copy to /Applications
# or
make dmg VERSION=1.0.5    # dist/MagSleep-1.0.5.dmg
```

## Notarization & distribution

MagSleep is **ad-hoc signed**, not notarized: notarization requires an Apple Developer Program membership (paid, \$99/yr) and a Developer ID certificate. Because of this, DMGs downloaded from the internet may be blocked by Gatekeeper — prefer building from source (`make app` + `make install`), which produces a locally-built app with no quarantine flag.

If you ever join the Apple Developer Program, `make notarize` signs with your Developer ID certificate, submits for notarization, and staples the ticket. Without a certificate it prints guidance and exits 0.

## First-time setup

1. Open MagSleep from the menu bar.
2. Choose a mode (**Sleep Mode** or **Always Off**) — this installs the small root helper (one admin prompt).
3. Optionally turn on **Launch at Login**.

After that, sleep and wake are handled automatically even if you quit the menu bar app — as long as the helper stays enabled. Quitting the app does **not** disable the helper; it keeps running in the mode you chose.

## What the menu does

| Item | Action |
|------|--------|
| **Sleep Mode** | LED off while the Mac sleeps, restored to macOS on wake |
| **Always Off** | LED stays off at all times (re-asserted even after plug-in/unplug) |
| **Disabled** | Hand the LED back to macOS entirely |
| **Launch at Login** | Start MagSleep when you log in |
| **Check for Updates…** | Check GitHub Releases for a newer MagSleep |
| **Copy Diagnostics…** | Copy a support-ready status block to the clipboard |
| **Buy me a coffee** | [ko-fi.com/realabitbol](https://ko-fi.com/realabitbol) |
| **Uninstall MagSleep…** | Full cleanup, then quit |
| **About MagSleep…** | App and helper version info |
| **Quit MagSleep** | Quit the menu bar UI (the helper keeps running if enabled) |

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

## Uninstall

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

## Build targets

| Command | Result |
|---------|--------|
| `make app VERSION=x.y.z` | Build `dist/MagSleep.app` with that version |
| `make dmg VERSION=x.y.z` | `dist/MagSleep-<version>.dmg` |
| `make install VERSION=x.y.z` | Copy the built app to `/Applications` (never silently rebuilds) |
| `make run` | Build and open |
| `make clean` | Remove `.build` and `dist` |

The version is written to the app's `Info.plist` and to the helper version file on install; launching an app whose version differs from the installed helper triggers an "Update Helper" prompt.

## Support ☕

If MagSleep keeps your nights a little darker, you can [buy me a coffee](https://ko-fi.com/realabitbol).

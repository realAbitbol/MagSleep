<div align="center">

<img width="300" height="300" alt="MagSleep" src="https://github.com/user-attachments/assets/6f1c5c78-154f-41c2-a0f9-9059a4d3b13b" />


# MagSleep

A tiny macOS menu bar app that turns off your MagSafe LED when the MacBook sleeps, and hands it back to macOS when it wakes.

Perfect for a dark bedroom: no amber glow from the charger while you sleep.

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

1. Build a disk image (or grab a release if you publish one):

   ```bash
   make dmg
   ```

2. Open `dist/MagSleep-1.0.0.dmg` and drag **MagSleep** into **Applications**.
3. Launch MagSleep (moon icon in the menu bar).
4. Choose **Enable MagSleep…** and enter your admin password.

If Gatekeeper blocks the unsigned build: right-click the app → **Open**.

### From source

```bash
git clone <repo-url>
cd MagSleep
make run          # build + open
# or
make install      # copy to /Applications
make dmg          # dist/MagSleep-<version>.dmg
```

## First-time setup

1. Open MagSleep from the menu bar.
2. **Enable MagSleep…** — installs a small root helper (one admin prompt).
3. Optionally turn on **Launch at Login**.

After that, sleep and wake are handled automatically even if you quit the menu bar app — as long as the helper stays enabled.

## What the menu does

| Item | Action |
|------|--------|
| **Enable MagSleep** | Install / load the helper |
| **Disable MagSleep** | Stop the helper; restore the LED to macOS; keep files for a quick re-enable |
| **Uninstall MagSleep…** | Full cleanup, then quit |
| **Launch at Login** | Start MagSleep when you log in |
| **Buy me a coffee** | [ko-fi.com/realabitbol](https://ko-fi.com/realabitbol) |
| **Quit MagSleep** | Quit the menu bar UI (the helper keeps running if enabled) |

## How it works

```text
Mac goes to sleep  →  helper writes ACLC = 1  →  MagSafe LED off
Mac wakes up       →  helper writes ACLC = 0  →  macOS controls the LED again
```

MagSleep is a lightweight AppKit menu bar app plus a LaunchDaemon. The daemon listens for system power events (`IORegisterForSystemPower`) and writes the MagSafe LED SMC key `ACLC`. Root is required for SMC writes, which is why Enable asks for your password once.

| `ACLC` | Meaning |
|--------|---------|
| `0` | System control (amber / green as usual) |
| `1` | Off |

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
sudo rm -rf /Library/Logs/MagSleep
```

## Build targets

| Command | Result |
|---------|--------|
| `make app` | `dist/MagSleep.app` |
| `make dmg` | `dist/MagSleep-<version>.dmg` |
| `make install` | Copy app to `/Applications` |
| `make run` | Build and open |
| `make clean` | Remove `.build` and `dist` |

Override the version with `make dmg VERSION=1.0.1`.

## Support

If MagSleep keeps your nights a little darker, you can [buy me a coffee](https://ko-fi.com/realabitbol).

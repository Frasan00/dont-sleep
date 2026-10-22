# Dont Sleep

A small macOS menu bar app that keeps your Mac awake, even with the lid closed, with one switch.
It runs `pmset -a disablesleep 0|1` for you. Local only: no network access, no analytics.

Requires macOS 14 or later (Apple Silicon and Intel).

## Install

1. Open `DontSleep-<version>.dmg` and drag **DontSleep** to **Applications**.
2. The app is signed only with an ad-hoc signature (no paid Apple Developer ID), so macOS blocks the first launch.
   Either right-click the app and choose **Open**, or allow it in **System Settings → Privacy & Security → Open Anyway**,
   or run `xattr -dr com.apple.quarantine /Applications/DontSleep.app`.
3. Launch it. A cup or moon icon appears in the menu bar and Settings opens once.

## First use: the one-time password

Changing the sleep setting needs root. The first time you flip the switch, Dont Sleep asks for your password once and
installs `/etc/sudoers.d/dont-sleep`, a rule that lets your user run only these two commands without a password:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

If the password prompt does not work for you, choose **Open Terminal** (or **Copy Command**) in the same message.

## What it does

- Switch in the menu, or the global shortcut (default ⌃⌥⌘S).
- **Keep awake for** 1 or 2 hours, **Add time** 30 or 5 minutes (shortcut ⌃⌥⌘5 for +5 minutes). Both shortcuts are configurable.
- Auto-off timer with a countdown in the menu bar, with presets or a custom duration.
- Turns off when the Mac is unplugged or the battery gets low, and can notify you when it restores sleep.
- Restores normal sleep when the app quits or starts. If the app crashes or is force-quit while sleep is disabled,
  a small helper process restores it within seconds, so a laptop is not left awake in a bag.

## Uninstall

Use **Uninstall…** in the menu. It restores sleep, removes the sudoers rule (asks for your password), the login item and
the settings, and moves the app to the Trash.

If you deleted the app by hand instead, remove the rule with `sudo rm /etc/sudoers.d/dont-sleep` and run
`sudo pmset -a disablesleep 0`.

## Build

```
./build.sh                # DontSleep.app, universal binary
./build-dmg.sh v1.2.0     # dist/DontSleep-1.2.0.dmg and a .sha256
```

Needs Xcode command line tools only. The icon is drawn at build time by `make-icon.swift`.

## Release

Push a tag such as `v1.2.0`, or run the **Release** workflow manually from the Actions tab with a tag. The workflow builds the
DMG on a macOS runner and publishes it as a GitHub release.

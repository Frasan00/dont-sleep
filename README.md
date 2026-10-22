# Dont Sleep

A small macOS menu bar app that keeps your Mac awake, even with the lid closed, with one switch.
It runs `pmset -a disablesleep 0|1` for you. It also works from the terminal (see [Command line](#command-line)). Local only: no network access, no analytics.

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

## Command line

The same app is also a terminal tool. Link it into your PATH once:

```
/Applications/DontSleep.app/Contents/MacOS/DontSleep link
```

Then use `dont-sleep` from any terminal. `dont-sleep -h` shows the full help, `dont-sleep help <command>` the options of one command.

```
dont-sleep setup                    # one-time password, same as the menu bar app (needed once per Mac)
dont-sleep on --for 2h              # on for two hours, returns right away
dont-sleep on -u 17:30 --unplug-off # until 17:30, or when the charger is unplugged
dont-sleep on --wait                # stay in the foreground; Ctrl-C turns it off
dont-sleep run -- ./long-build.sh   # awake only while the command runs
dont-sleep status --json            # machine-readable state; exit status 0 = on, 1 = off
dont-sleep off
dont-sleep config list              # every setting, shared with the menu bar app
dont-sleep config set auto-off 90m
dont-sleep config set shortcut-toggle ctrl+opt+cmd+d
```

`on` starts a small background process that ends the session when the time is up, even if you close the terminal; the same
crash watchdog as the menu bar app restores normal sleep if that process is killed. Exit statuses: `0` success, `2` wrong usage,
`3` setup missing, `4` operation failed (`run` returns the exit status of your command).

## Uninstall

Use **Uninstall…** in the menu. It restores sleep, removes the sudoers rule (asks for your password), the login item and
the settings, and moves the app to the Trash.

If you deleted the app by hand instead, remove the rule with `sudo rm /etc/sudoers.d/dont-sleep` and run
`sudo pmset -a disablesleep 0`.

## Build

```
./build.sh                # DontSleep.app, universal binary (menu bar app and command line in one executable)
./build-dmg.sh v1.2.0     # dist/DontSleep-1.2.0.dmg and a .sha256
```

Needs Xcode command line tools only. The icon is drawn at build time by `make-icon.swift`.

## Release

Push a tag such as `v1.2.0`, or run the **Release** workflow manually from the Actions tab with a tag. The workflow builds the
DMG on a macOS runner and publishes it as a GitHub release.

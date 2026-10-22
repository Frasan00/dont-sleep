# Dont Sleep

A small macOS menu bar app that keeps your Mac awake, even with the lid closed, with one switch.
It runs `pmset -a disablesleep 0|1` for you. It also works from the terminal (see [Command line](#command-line)).
Everything runs on your Mac. The only network request is an optional once-a-day check of GitHub's public releases page for
a newer version (you can turn it off); nothing about you or your Mac is sent, and there is no analytics.

- Requires **macOS 14 or later**, on Apple Silicon and Intel.
- One executable is both the menu bar app and the `dont-sleep` command.

## Install

### Option 1: download the release (recommended)

1. Download `DontSleep-<version>.dmg` from the [Releases page](https://github.com/Frasan00/dont-sleep/releases).
   Optionally check it against the `.sha256` file next to it: `shasum -a 256 -c DontSleep-<version>.dmg.sha256`.
2. Open the DMG and drag **DontSleep** onto the **Applications** shortcut.
3. Open **DontSleep** from Applications.
   The app is signed only with an ad-hoc signature (no paid Apple Developer ID), so macOS blocks the first launch with
   **"DontSleep" Not Opened - Apple could not verify "DontSleep" is free of malware**. Do not click *Move to Trash*; click
   **Done**, then allow it once with one of these:
   - **System Settings → Privacy & Security**, scroll to the **Security** section, click **Open Anyway** next to
     "DontSleep was blocked", then confirm with your password or Touch ID. This works on every macOS version; or
   - run `xattr -dr com.apple.quarantine /Applications/DontSleep.app` in Terminal, then open the app normally; or
   - on macOS 14 only, right-click the app and choose **Open**. (macOS 15 and later no longer allow this shortcut.)

   Make sure the app is in **Applications** first: opening it straight from the DMG or the Downloads folder keeps it blocked.
4. A cup or moon icon appears in the menu bar, and the Settings window opens once to show you where the app lives.

### Option 2: build from source

You need macOS 14+ and the Xcode command line tools (`xcode-select --install`). No other dependencies.

```
git clone https://github.com/Frasan00/dont-sleep.git
cd dont-sleep
./build.sh                      # creates DontSleep.app (universal binary)
cp -R DontSleep.app /Applications/
open /Applications/DontSleep.app
```

Locally built apps are not quarantined, so there is no Gatekeeper prompt.

## One-time setup (the password)

Changing the sleep setting needs root. The first time you flip the switch, Dont Sleep shows **One-time setup needed**.
Press **Install** and enter your password once. This installs `/etc/sudoers.d/dont-sleep`, a rule that lets your user run
exactly these two commands without a password, and nothing else:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

After that the switch turns on by itself, and the password is never asked again on this Mac.
If the password prompt does not work for you, choose **Open Terminal** (or **Copy Command**) in the same message.
From the terminal you can also run `dont-sleep setup`.

## Start it automatically at login

Dont Sleep is a menu bar app, so "auto start" means launching at login:

- Open the menu bar icon, choose **Settings…**, and turn on **Launch at login**; or
- from a terminal: `dont-sleep config set launch-at-login on`.

If macOS says the item needs approval, open **System Settings → General → Login Items & Extensions** and allow
**Dont Sleep**. The app then starts at every login and restores normal sleep on start (setting
**Restore normal sleep when the app starts**, on by default), so a Mac never boots into a stuck "stay awake" state.

To stop it from starting at login, turn the same switch off.

## Using the app

- Click the menu bar icon and use the switch, or press the global shortcut (default **⌃⌥⌘S**).
- **Keep awake for** 1 or 2 hours, **Add time** 30 or 5 minutes (global shortcut **⌃⌥⌘5** adds 5 minutes). Both shortcuts
  can be changed or removed in Settings.
- Auto-off timer with the remaining time in the menu bar; pick a preset or a custom duration.
- Turn off when the charger is unplugged or the battery is low, with an optional notification.
- Restore normal sleep when the app quits. If the app crashes or is force-quit while sleep is disabled, a small helper
  process restores it within seconds, so a laptop is never left awake in a bag.

## Updates

Dont Sleep checks GitHub for a newer release once a day, a few seconds after it starts and then at most every 24 hours.
When there is one, the menu shows **Version X is available…** at the top of the group below the switch; click it to open the
release page. **Settings → Updates** shows the installed version and the status, with **Check Now** and a **Download** button,
and the switch **Check for updates automatically** turns the daily check off. **Check for Updates…** in the menu checks on demand.

The app never downloads or installs anything by itself. To update, download the new DMG and drag **DontSleep** over the old
app in **Applications** (quit it first). Your settings, the login item and the one-time password setup are kept.

From a terminal, `dont-sleep update` does the same check: it prints the result and exits with `0` when you are up to date,
`1` when a newer version exists and `4` when the check failed. The only request made is a read-only call to
`api.github.com`, sending the app name and version in the `User-Agent` header and nothing else.

## Command line

Link the command into your PATH once:

```
/Applications/DontSleep.app/Contents/MacOS/DontSleep link
```

Then use `dont-sleep` from any terminal. `dont-sleep -h` shows the full help, `dont-sleep help <command>` the options of one command.

```
dont-sleep setup                    # one-time password, same as in the app
dont-sleep on --for 2h              # on for two hours, returns right away
dont-sleep on -u 17:30 --unplug-off # until 17:30, or when the charger is unplugged
dont-sleep on --wait                # stay in the foreground; Ctrl-C turns it off
dont-sleep run -- ./long-build.sh   # awake only while the command runs
dont-sleep status --json            # machine-readable state; exit status 0 = on, 1 = off
dont-sleep off
dont-sleep config list              # every setting, shared with the menu bar app
dont-sleep config set auto-off 90m
dont-sleep config set shortcut-toggle ctrl+opt+cmd+d
dont-sleep update                   # is there a newer release? (exit status 1 = yes)
```

`on` starts a small background process that ends the session when the time is up, even if you close the terminal; the same
crash watchdog as the menu bar app restores normal sleep if that process is killed. Exit statuses: `0` success, `2` wrong usage,
`3` setup missing, `4` operation failed (`run` returns the exit status of your command).

## Uninstall

Use **Uninstall…** in the menu. It restores sleep, removes the sudoers rule (asks for your password), the login item and
the settings, and moves the app to the Trash.

If you deleted the app by hand instead, remove the rule with `sudo rm /etc/sudoers.d/dont-sleep` (or `dont-sleep remove-rule`
while the command still exists) and run `sudo pmset -a disablesleep 0`.

## Development

```
./build.sh                # DontSleep.app, universal binary (menu bar app and command line in one executable)
./build-dmg.sh v1.2.0     # dist/DontSleep-1.2.0.dmg and a .sha256
```

Sources: `main.swift` (menu bar app), `Core.swift` (shared code), `CLI.swift` and `CLIHelp.swift` (command line),
`make-icon.swift` (draws the app icon at build time).

## Making a release

Releases are built on GitHub Actions (`.github/workflows/release.yml`) on a macOS runner.

1. Pick a version and tag the commit you want to release:
   ```
   git tag v1.2.0
   git push origin v1.2.0
   ```
2. The **Release** workflow builds the universal DMG and publishes a GitHub release named `v1.2.0` with the DMG and its
   `.sha256` attached, and generated release notes.

You can also run the workflow by hand from the **Actions** tab (**Release → Run workflow**) with a tag name such as
`v1.2.0`; it creates the tag for you. Manual runs only work from the `main` branch. To build the DMG on your own Mac instead,
use `./build-dmg.sh v1.2.0` and attach `dist/*.dmg` to a release yourself.

## Notes

- The app is not notarized: that needs a paid Apple Developer account, so the first launch needs the one-time
  approval described in [Install](#option-1-download-the-release-recommended).
- The update check is the only thing that uses the network. Disable it with **Settings → Updates**, or
  `dont-sleep config set check-updates off`.
- Sleep prevention is a single system setting: the menu bar app and the `dont-sleep` command act on the same one.

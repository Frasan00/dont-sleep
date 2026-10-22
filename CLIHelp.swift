import Foundation

// All user-facing help text of the command line interface.
enum Help {
    static let order = ["on", "off", "toggle", "status", "run", "config", "update", "setup", "remove-rule", "link", "unlink", "help", "version"]

    static let main = """
    dont-sleep - keep your Mac awake, even with the lid closed

    USAGE
      dont-sleep <command> [options]
      dont-sleep -h | --help          Show this help
      dont-sleep -V | --version       Show the version

    COMMANDS
      on [options]          Turn sleep prevention on, optionally for a limited time
      off                   Turn it off and restore normal sleep
      toggle [options]      Turn it on if it is off, and off if it is on
      status [options]      Show whether it is on, and when it ends
      run [options] -- CMD [ARGS...]
                            Keep the Mac awake only while CMD runs
      config <action>       Show and change settings (shared with the menu bar app)
      update [options]      Check GitHub for a newer release
      setup                 One-time setup: allow changing sleep without a password
      remove-rule           Undo the setup
      link | unlink         Add or remove 'dont-sleep' in your PATH
      help [command]        Show help for one command
      version               Print the version

    Run 'dont-sleep help <command>' for the options of each command.

    COMMON OPTIONS
      -h, --help            Show help for the command
      -q, --quiet           Print nothing on success (on, off, toggle, status, run)

    DURATIONS
      A number followed by a unit, or several of them: 30s, 15m, 2h, 1d, 1h30m, "2h 15m".
      A single bare number means minutes (90 = 90m). Clock form also works: 1:30 = 1h30m.
      The longest duration is 100000 days.

    TIMES (for --until)
      17:30   5pm   5:30pm   2026-12-24T08:00   "2026-12-24 08:00"
      A time of day that already passed today means tomorrow.

    SETTINGS (dont-sleep config list)
      auto-off, restore-on-start, restore-on-quit, notify, show-countdown, check-updates,
      unplug-off, low-battery-off, low-battery-percent, launch-at-login, shortcut-toggle, shortcut-add5.
      Defaults of the options of 'on' come from these settings, and options override them.

    EXIT STATUS
      0   Success (for 'status': sleep prevention is on)
      1   'status': sleep prevention is off. Other commands: cancelled
      2   Wrong usage: unknown command or option, invalid value
      3   The one-time setup is missing: run 'dont-sleep setup'
      4   The operation failed (pmset, sudo, reading the state, or reaching GitHub)
      127 'run': the command could not be started. Otherwise 'run' returns the exit status of CMD.

    FILES
      ~/Library/Preferences/local.dontsleep.plist
                  Settings, shared with the menu bar app ('dont-sleep config path')
      ~/Library/Application Support/Dont Sleep/cli-state.json
                  State of the background timer started by 'dont-sleep on'
      /etc/sudoers.d/dont-sleep
                  The rule installed by 'dont-sleep setup'

    EXAMPLES
      dont-sleep setup                       One-time setup (asks for your password once)
      dont-sleep on                          On, using the configured auto-off (default: no limit)
      dont-sleep on --for 2h                 On for two hours; returns right away
      dont-sleep on -u 17:30                 On until 17:30
      dont-sleep on --forever                On with no limit, ignoring the auto-off setting
      dont-sleep on -f 3h --unplug-off --low-battery 25
                                             Also turn off if unplugged or below 25%
      dont-sleep on --wait                   Stay in the foreground; Ctrl-C turns it off
      dont-sleep run -- ./long-build.sh      Awake only while the script runs
      dont-sleep status --json               Machine-readable state
      dont-sleep off
      dont-sleep config set auto-off 90m
      dont-sleep config set shortcut-toggle ctrl+opt+cmd+d
      dont-sleep link                        Install the command in your PATH
      dont-sleep update                      Is there a newer release?

    NOTES
      'on' starts a small background process that turns sleep prevention off when the time is up,
      even if you close the terminal. If that process is killed, a watchdog restores normal sleep
      within seconds, so a laptop is not left awake in a bag.
      Sleep prevention is a single system setting: the menu bar app and this command act on the same one.
    """

    static let commands: [String: String] = [
        "on": """
        dont-sleep on - turn sleep prevention on

        USAGE
          dont-sleep on [options]

        OPTIONS
          -f, --for DURATION      Turn off after DURATION (30m, 2h, 1h30m, 1:30)
          -u, --until TIME        Turn off at a clock time (17:30, 5pm, 2026-12-24T08:00)
              --forever           No time limit, ignoring the auto-off setting
          -w, --wait              Stay in the foreground until the end; Ctrl-C turns it off
              --unplug-off        Also turn off when the charger is unplugged
              --no-unplug-off     Ignore the unplug-off setting
              --low-battery PCT   Also turn off when the battery drops to PCT percent (5-90)
              --no-low-battery    Ignore the low-battery settings
              --notify            Show a notification when it turns off by itself
              --no-notify         Do not
          -q, --quiet             Print nothing on success
          -h, --help              Show this help

        Without --for, --until or --forever the 'auto-off' setting applies (default: never).
        Starting it again replaces the running timer. Without --wait the command returns at once.

        EXAMPLES
          dont-sleep on --for 2h
          dont-sleep on -u 5pm --unplug-off
          dont-sleep on --wait --low-battery 15
        """,
        "off": """
        dont-sleep off - turn sleep prevention off and restore normal sleep

        USAGE
          dont-sleep off [-q]

        Stops the background timer started by 'dont-sleep on' and restores normal sleep.
        It also works when the menu bar app turned sleep prevention on.
        Exit status: 0 on success (also if it was already off).
        """,
        "toggle": """
        dont-sleep toggle - turn sleep prevention on if it is off, and off if it is on

        USAGE
          dont-sleep toggle [options]

        Takes the same options as 'dont-sleep on' (they apply when it turns on).
        """,
        "status": """
        dont-sleep status - show whether sleep prevention is on

        USAGE
          dont-sleep status [options]

        OPTIONS
          -j, --json    Machine-readable output
          -q, --quiet   Print nothing; use the exit status only
          -h, --help    Show this help

        EXIT STATUS
          0   Sleep prevention is on
          1   Sleep prevention is off
          4   The state could not be read

        EXAMPLE
          if dont-sleep status -q; then echo "already awake"; fi
        """,
        "run": """
        dont-sleep run - keep the Mac awake only while a command runs

        USAGE
          dont-sleep run [options] -- COMMAND [ARGS...]

        OPTIONS
              --unplug-off        Turn off when the charger is unplugged (the command keeps running)
              --no-unplug-off     Ignore the unplug-off setting
              --low-battery PCT   Turn off when the battery drops to PCT percent (5-90)
              --no-low-battery    Ignore the low-battery settings
              --notify            Show a notification if sleep is restored before the command ends
              --no-notify         Do not
          -q, --quiet             Do not print the start message
          -h, --help              Show this help

        Normal sleep comes back as soon as the command ends or you press Ctrl-C.
        The exit status is that of COMMAND (127 if it could not be started).

        EXAMPLES
          dont-sleep run -- make -j8
          dont-sleep run --low-battery 20 -- ./backup.sh --full
        """,
        "config": """
        dont-sleep config - show and change settings

        USAGE
          dont-sleep config list [--json]
          dont-sleep config get KEY [--json]
          dont-sleep config set KEY VALUE
          dont-sleep config reset [KEY]
          dont-sleep config path

        SETTINGS
          auto-off              Default time before sleep prevention ends: never, 90m, 2h, 1h30m
          restore-on-start      on|off  Menu bar app: restore normal sleep when it starts
          restore-on-quit       on|off  Menu bar app: restore normal sleep when it quits (arms the crash watchdog)
          notify                on|off  Notify when sleep is restored automatically
          show-countdown        on|off  Menu bar app: remaining time next to the icon
          check-updates         on|off  Menu bar app: look for new releases on GitHub once a day
          unplug-off            on|off  Turn off when the charger is unplugged
          low-battery-off       on|off  Turn off when the battery gets low
          low-battery-percent   5-90    Battery level for low-battery-off
          launch-at-login       on|off  Start the menu bar app at login
          shortcut-toggle       Global shortcut that toggles, e.g. ctrl+opt+cmd+s, or none, or default
          shortcut-add5         Global shortcut that adds 5 minutes

        SHORTCUTS
          Modifiers: ctrl, opt (alt), cmd, shift; at least one of ctrl, opt or cmd.
          Keys: a-z, 0-9, f1-f12, space, return, tab, left, right, up, down and - = [ ] ; ' , . / \\ `
          Example: ctrl+opt+cmd+d, cmd+shift+f5

        The menu bar app and the Settings window read the same values, so changes apply to both.

        EXAMPLES
          dont-sleep config set auto-off 2h
          dont-sleep config set low-battery-percent 25
          dont-sleep config get shortcut-toggle
          dont-sleep config reset
        """,
        "update": """
        dont-sleep update - check for a newer release

        USAGE
          dont-sleep update [options]

        OPTIONS
          -j, --json    Machine-readable output
          -q, --quiet   Print nothing; use the exit status only
          -h, --help    Show this help

        Asks the public GitHub API for the latest release of Dont Sleep and compares it with the installed version.
        It only reports: nothing is downloaded or installed, and the download page is yours to open.
        The menu bar app does the same check once a day unless 'check-updates' is off.

        EXIT STATUS
          0   You have the latest version
          1   A newer version is available
          4   The check failed (no connection, rate limit, unexpected answer)

        EXAMPLES
          dont-sleep update
          dont-sleep update --json
          dont-sleep update -q || echo "update available (or check failed)"
        """,
        "setup": """
        dont-sleep setup - one-time setup

        USAGE
          dont-sleep setup [options]

        OPTIONS
              --print     Only print the command that would be run, and do nothing
          -y, --yes       Do not ask for confirmation
          -h, --help      Show this help

        Changing sleep needs root. This installs /etc/sudoers.d/dont-sleep, a rule that lets your user run only
        '/usr/bin/pmset -a disablesleep 0' and '/usr/bin/pmset -a disablesleep 1' without a password.
        sudo asks for your password once. The rule is checked with visudo before it is installed.
        """,
        "remove-rule": """
        dont-sleep remove-rule - undo the setup

        USAGE
          dont-sleep remove-rule [-y]

        Restores normal sleep, then removes /etc/sudoers.d/dont-sleep (sudo asks for your password).
        """,
        "link": """
        dont-sleep link - add the 'dont-sleep' command to your PATH

        USAGE
          dont-sleep link [options]

        OPTIONS
          -d, --dir DIR   Folder for the link (default: /usr/local/bin or /opt/homebrew/bin if writable, else ~/.local/bin)
          -f, --force     Replace an existing link that points somewhere else
          -h, --help      Show this help

        Creates a symbolic link named 'dont-sleep' to the executable inside the app, so it works from any terminal.
        """,
        "unlink": """
        dont-sleep unlink - remove the 'dont-sleep' link

        USAGE
          dont-sleep unlink [--dir DIR]

        Removes the link created by 'dont-sleep link'. It only removes a link that points to this app.
        """,
        "help": """
        dont-sleep help - show help

        USAGE
          dont-sleep help [command]
        """,
        "version": """
        dont-sleep version - print the version

        USAGE
          dont-sleep version
          dont-sleep -V
        """,
    ]
}

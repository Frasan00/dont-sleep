import Carbon.HIToolbox
import Foundation
import IOKit.ps

// Code shared by the menu bar app and the command line interface. No top-level statements live here.

// Waits on a semaphore instead of waitUntilExit, which would spin the run loop and let other handlers run mid-toggle.
// Returns nil if the process cannot start or does not finish within the timeout.
func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 6) -> (status: Int32, output: String)? {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return nil }
    // Our own copy of the write end must be closed, or the read below never reaches EOF
    try? pipe.fileHandleForWriting.close()
    guard done.wait(timeout: .now() + timeout) == .success else {
        p.terminate()
        return nil
    }
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

// nil means the state could not be read, which must not be confused with "sleep is allowed"
func sleepDisabled() -> Bool? {
    guard let r = runProcess("/usr/bin/pmset", ["-g"]), r.status == 0 else { return nil }
    return r.output.split(separator: "\n").contains { $0.contains("SleepDisabled") && $0.split(whereSeparator: \.isWhitespace).last == "1" }
}

func run(_ path: String, _ args: [String]) -> Bool {
    runProcess(path, args)?.status == 0
}

// Relies on a sudoers rule: the osascript admin dialog does not accept keyboard input for an ad-hoc signed app
@discardableResult
func setSleepDisabled(_ on: Bool) -> Bool {
    run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
}

func sudoRuleWorks() -> Bool {
    run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"])
}

func asAppleScriptString(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

// Runs entirely as root inside the root-only drop-in directory, so no user-writable file can be swapped between the visudo check and the move
func sudoersInstallScript(dir: String = "/etc/sudoers.d") -> String {
    let name = NSUserName()
    let user = name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil ? name : "#\(getuid())"
    let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    // sudo ignores files with a dot in the name, so a half-written staging file is never active
    let t = "\(dir)/.dont-sleep.tmp"
    return "PATH=/usr/bin:/bin:/usr/sbin:/sbin; umask 077; t=\(t); printf \"%s\\n\" \"\(rule)\" > \"$t\" && /usr/sbin/visudo -cf \"$t\" && /usr/sbin/chown root:wheel \"$t\" && /bin/chmod 440 \"$t\" && /bin/mv -f \"$t\" \(dir)/dont-sleep || { /bin/rm -f \"$t\"; exit 1; }"
}

func powerInfo() -> (onBattery: Bool, percent: Int)? {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
    for ps in sources {
        guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
              d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
        return (d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue, d[kIOPSCurrentCapacityKey] as? Int ?? 100)
    }
    return nil
}

let maxAutoOffSeconds = 8_640_000_000
let appBundleID = "local.dontsleep"
// Posted by the command line after it changes a setting, because preference writes from another process do not notify the app
let settingsChangedNotification = Notification.Name("local.dontsleep.settingsChanged")
let sudoersRulePath = "/etc/sudoers.d/dont-sleep"
let hotkeyNames = ["toggle", "add5"]
let hotkeyDefaults: [String: (key: Int, label: String)] = ["toggle": (1, "⌃⌥⌘S"), "add5": (23, "⌃⌥⌘5")]
let hotkeyDefaultMods = controlKey | optionKey | cmdKey
let autoOffChoices: [(String, Int)] = [("Never", 0), ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14400), ("8 hours", 28800)]
let autoOffUnits: [(String, Int)] = [("Seconds", 1), ("Minutes", 60), ("Hours", 3600), ("Days", 86400)]


// Detached helper that restores normal sleep when the process `pid` dies (crash, kill -9) or `until` (epoch seconds) passes,
// so a laptop is never left awake in a bag. It compares the parent start time to survive pid reuse.
func startWatchdog(pid: Int32, until: Int?) -> Process? {
    let limit = until ?? 9_999_999_999
    let script = "PATH=/usr/bin:/bin:/usr/sbin:/sbin; s=$(ps -p \"$1\" -o lstart= 2>/dev/null); while [ -n \"$s\" ] && [ \"$(ps -p \"$1\" -o lstart= 2>/dev/null)\" = \"$s\" ] && [ \"$(date +%s)\" -lt \"$2\" ]; do sleep 10; done; sudo -n /usr/bin/pmset -a disablesleep 0"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script, "sh", String(pid), String(limit)]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    return (try? p.run()) != nil ? p : nil
}

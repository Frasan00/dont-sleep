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

// MARK: updates

// The only network request the app ever makes: the public GitHub API, read-only, no identifiers sent.
let updateAPIURL = "https://api.github.com/repos/Frasan00/dont-sleep/releases/latest"

struct ReleaseInfo: Equatable {
    let version: String
    let tag: String
    let url: URL
}

enum UpdateError: LocalizedError {
    case network(String)
    case http(Int)
    case invalid
    case noRelease

    var errorDescription: String? {
        switch self {
        case .network(let m): return "No connection to GitHub (\(m))"
        case .http(403), .http(429): return "GitHub is limiting requests right now, try again later"
        case .http(let c): return "GitHub answered with status \(c)"
        case .invalid: return "GitHub sent an unexpected answer"
        case .noRelease: return "No release has been published yet"
        }
    }
}

// The running version: from Bundle.main, or from the app that contains the executable when started through a symlink
func currentVersion() -> String? {
    if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { return v }
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    guard let r = exe.range(of: ".app/Contents/MacOS/"), let b = Bundle(path: String(exe[..<r.lowerBound]) + ".app") else { return nil }
    return b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
}

// "v1.2.3", "1.2" and "1.2.3-beta" all reduce to their numeric parts
func versionComponents(_ s: String) -> [Int] {
    var t = s.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
    return t.prefix { $0.isNumber || $0 == "." }.split(separator: ".").map { Int($0) ?? 0 }
}

func isNewerVersion(_ candidate: String, than current: String) -> Bool {
    let a = versionComponents(candidate), b = versionComponents(current)
    guard !a.isEmpty else { return false }
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

func parseLatestRelease(_ data: Data) throws -> ReleaseInfo {
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let tag = o["tag_name"] as? String, !versionComponents(tag).isEmpty else { throw UpdateError.invalid }
    // Whatever the response says, the only page this ever opens is a https page on github.com
    guard let page = o["html_url"] as? String, let url = URL(string: page), url.scheme == "https", url.host == "github.com" else { throw UpdateError.invalid }
    return ReleaseInfo(version: versionComponents(tag).map(String.init).joined(separator: "."), tag: tag, url: url)
}

func fetchLatestRelease(apiURL: String = updateAPIURL, timeout: TimeInterval = 10) async throws -> ReleaseInfo {
    guard let url = URL(string: apiURL) else { throw UpdateError.invalid }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    request.setValue("DontSleep/\(currentVersion() ?? "dev")", forHTTPHeaderField: "User-Agent")
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
    } catch {
        throw UpdateError.network(error.localizedDescription)
    }
    guard let http = response as? HTTPURLResponse, data.count < 1_000_000 else { throw UpdateError.invalid }
    switch http.statusCode {
    case 200: return try parseLatestRelease(data)
    case 404: throw UpdateError.noRelease
    default: throw UpdateError.http(http.statusCode)
    }
}

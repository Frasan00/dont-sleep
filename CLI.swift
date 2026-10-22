import Carbon.HIToolbox
import Foundation
import ServiceManagement

// Command line interface. The same executable acts as `dont-sleep` when it is called by that name
// (or with a known subcommand), and as the menu bar app otherwise. Settings live in the app's own preferences
// domain, so the menu bar app and the command line always agree.

struct UsageError: Error { let message: String }

// Set from signal handlers, which can only touch plain globals
private var cliStopSignal: Int32 = 0
private var cliHandover: Int32 = 0

enum CLI {
    static let subcommands: Set<String> = ["on", "off", "toggle", "status", "run", "config", "setup", "remove-rule", "link", "unlink", "update", "help", "version", "__guard", "__login"]

    static func shouldRun(_ args: [String]) -> Bool {
        if URL(fileURLWithPath: args.first ?? "").lastPathComponent == "dont-sleep" { return true }
        guard args.count > 1 else { return false }
        return subcommands.contains(args[1]) || ["-h", "--help", "-V", "--version"].contains(args[1])
    }

    static func main(_ args: [String]) -> Never {
        let code: Int32
        do { code = try dispatch(Array(args.dropFirst())) } catch let e as UsageError {
            printErr("dont-sleep: \(e.message)\nTry 'dont-sleep --help'.")
            code = 2
        } catch {
            printErr("dont-sleep: \(error.localizedDescription)")
            code = 4
        }
        exit(code)
    }

    static func dispatch(_ args: [String]) throws -> Int32 {
        guard let first = args.first else {
            print(Help.main)
            return 0
        }
        let rest = Array(args.dropFirst())
        switch first {
        case "-h", "--help": print(Help.main); return 0
        case "-V", "--version", "version": print("dont-sleep \(version)"); return 0
        case "help": return help(rest)
        case "on": return try cmdOn(rest, toggling: false)
        case "toggle": return try cmdOn(rest, toggling: true)
        case "off": return try cmdOff(rest)
        case "status": return try cmdStatus(rest)
        case "run": return try cmdRun(rest)
        case "config": return try cmdConfig(rest)
        case "setup": return try cmdSetup(rest)
        case "update": return try cmdUpdate(rest)
        case "remove-rule": return try cmdRemoveRule(rest)
        case "link": return try cmdLink(rest, remove: false)
        case "unlink": return try cmdLink(rest, remove: true)
        case "__guard": return try cmdGuard(rest)
        case "__login": return cmdLogin(rest)
        default: throw UsageError(message: "unknown command '\(first)'")
        }
    }

    // Called through a symlink, Bundle.main is the folder of the link, so the app bundle is found from the real executable path
    static var appBundle: Bundle? {
        guard let range = selfPath.range(of: ".app/Contents/MacOS/") else { return nil }
        return Bundle(path: String(selfPath[..<range.lowerBound]) + ".app")
    }

    static var version: String { currentVersion() ?? "dev" }

    // MARK: output helpers

    static func printErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    static func help(_ args: [String]) -> Int32 {
        guard var name = args.first else { print(Help.main); return 0 }
        if name == "--help" || name == "-h" { name = "help" }
        guard let text = Help.commands[name] else {
            printErr("dont-sleep: no help for '\(name)'. Commands: \(Help.order.joined(separator: ", "))")
            return 2
        }
        print(text)
        return 0
    }

    // MARK: argument parsing

    struct Spec {
        var valued: Set<String> = []
        var flags: Set<String> = []
        var short: [Character: String] = [:]
    }

    struct Args {
        var positional: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var rest: [String] = []
    }

    static func parse(_ argv: [String], _ spec: Spec, stopAtFirstPositional: Bool = false) throws -> Args {
        var out = Args()
        var i = 0
        func takeValue(_ name: String, inline: String?) throws -> String {
            if let inline { return inline }
            i += 1
            guard i < argv.count else { throw UsageError(message: "option --\(name) needs a value") }
            return argv[i]
        }
        while i < argv.count {
            let a = argv[i]
            if a == "--" {
                out.rest = Array(argv[(i + 1)...])
                break
            }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                let name = body.split(separator: "=", maxSplits: 1).first.map(String.init) ?? body
                let inline = body.contains("=") ? String(body[body.index(after: body.firstIndex(of: "=")!)...]) : nil
                if spec.valued.contains(name) {
                    out.values[name] = try takeValue(name, inline: inline)
                } else if spec.flags.contains(name) || name == "help" {
                    if inline != nil { throw UsageError(message: "option --\(name) does not take a value") }
                    out.flags.insert(name)
                } else {
                    throw UsageError(message: "unknown option --\(name)")
                }
            } else if a.hasPrefix("-") && a.count > 1 {
                var chars = Array(a.dropFirst())
                while !chars.isEmpty {
                    let c = chars.removeFirst()
                    if c == "h" { out.flags.insert("help"); continue }
                    guard let name = spec.short[c] else { throw UsageError(message: "unknown option -\(c)") }
                    if spec.valued.contains(name) {
                        let inline = chars.isEmpty ? nil : String(chars)
                        chars = []
                        out.values[name] = try takeValue(name, inline: inline)
                    } else {
                        out.flags.insert(name)
                    }
                }
            } else {
                out.positional.append(a)
                if stopAtFirstPositional {
                    out.rest = Array(argv[(i + 1)...])
                    break
                }
            }
            i += 1
        }
        return out
    }

    // MARK: durations and times

    static func groups(_ pattern: String, _ text: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        }
    }

    static func parseDuration(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
            guard parts.count == 2 || parts.count == 3, !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
            let n = parts.map { $0! }
            let secs = n[0] * 3600 + n[1] * 60 + (n.count == 3 ? n[2] : 0)
            return secs > 0 && secs <= maxAutoOffSeconds ? secs : nil
        }
        guard !groups(#"^(?:\s*\d+(?:\.\d+)?\s*[a-z]*\s*)+$"#, t).isEmpty else { return nil }
        let tokens = groups(#"(\d+(?:\.\d+)?)\s*([a-z]*)"#, t)
        var total = 0.0
        for m in tokens {
            guard let n = Double(m[1]) else { return nil }
            let unit = m[2]
            let mult: Double
            switch unit {
            case "s", "sec", "secs", "second", "seconds": mult = 1
            case "m", "min", "mins", "minute", "minutes": mult = 60
            case "h", "hr", "hrs", "hour", "hours": mult = 3600
            case "d", "day", "days": mult = 86400
            case "":
                // A bare number is minutes, but only when it stands alone: "1h 30" is ambiguous
                guard tokens.count == 1 else { return nil }
                mult = 60
            default: return nil
            }
            total += n * mult
        }
        let secs = Int(total.rounded())
        return secs > 0 && secs <= maxAutoOffSeconds ? secs : nil
    }

    static func parseUntil(_ text: String, now: Date = Date()) -> Date? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let cal = Calendar.current
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: t) { return d > now ? d : nil }
        }
        guard let m = groups(#"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#, t).first else { return nil }
        var hour = Int(m[1]) ?? -1
        let minute = Int(m[2]) ?? 0
        if !m[3].isEmpty {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (m[3] == "pm" ? 12 : 0)
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard var d = cal.date(from: comps) else { return nil }
        if d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }

    static func formatDuration(_ secs: Int) -> String {
        let s = max(0, secs)
        if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        if s >= 60 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
        return "\(s)s"
    }

    static func formatClock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE d MMM HH:mm"
        return f.string(from: d)
    }

    // MARK: persistent state of a running guard

    struct GuardState: Codable {
        var pid: Int32
        var lstart: String
        var started: Double
        var until: Double?
        var unplugOff: Bool
        var lowBattery: Int?
    }

    static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dont Sleep/cli-state.json")
    }

    static func processStart(_ pid: Int32) -> String? {
        guard let r = runProcess("/bin/ps", ["-p", String(pid), "-o", "lstart="], timeout: 3), r.status == 0 else { return nil }
        let s = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    // A state file only counts while the process that wrote it is still the same one (pids get reused)
    static func readState() -> GuardState? {
        guard let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(GuardState.self, from: data) else { return nil }
        guard processStart(s.pid) == s.lstart else {
            try? FileManager.default.removeItem(at: stateURL)
            return nil
        }
        return s
    }

    static func writeState(_ s: GuardState) {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }

    static func clearState(ifOwnedBy pid: Int32) {
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(GuardState.self, from: data), s.pid == pid {
            try? FileManager.default.removeItem(at: stateURL)
        }
    }

    // MARK: preferences shared with the menu bar app

    enum Prefs {
        static func raw(_ key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, appBundleID as CFString) }
        static func bool(_ key: String, _ def: Bool) -> Bool { (raw(key) as? NSNumber)?.boolValue ?? def }
        static func int(_ key: String, _ def: Int) -> Int { (raw(key) as? NSNumber)?.intValue ?? def }
        static func setBool(_ key: String, _ v: Bool) { write(key, v ? kCFBooleanTrue : kCFBooleanFalse) }
        static func setInt(_ key: String, _ v: Int) { write(key, NSNumber(value: v)) }
        static func setString(_ key: String, _ v: String) { write(key, v as CFString) }
        static func remove(_ key: String) { write(key, nil) }
        private static func write(_ key: String, _ value: CFPropertyList?) {
            CFPreferencesSetAppValue(key as CFString, value, appBundleID as CFString)
            CFPreferencesAppSynchronize(appBundleID as CFString)
        }
    }

    // MARK: notifications

    static func notify(_ body: String) {
        let script = "display notification \"\(asAppleScriptString(body))\" with title \"Dont Sleep\""
        _ = runProcess("/usr/bin/osascript", ["-e", script], timeout: 5)
    }

    // MARK: setup requirement

    static func requireRule() -> Int32? {
        guard !sudoRuleWorks() else { return nil }
        printErr("""
        dont-sleep: the one-time setup has not been done, so changing sleep needs a password.
        Run:  dont-sleep setup
        """)
        return 3
    }

    // MARK: on / toggle

    static let onSpec = Spec(
        valued: ["for", "until", "low-battery"],
        flags: ["forever", "wait", "unplug-off", "no-unplug-off", "no-low-battery", "notify", "no-notify", "quiet"],
        short: ["f": "for", "u": "until", "w": "wait", "q": "quiet"])

    struct Plan {
        var until: Date?
        var unplugOff: Bool
        var lowBattery: Int?
        var notify: Bool
        var quiet: Bool
        var wait: Bool
    }

    static func makePlan(_ a: Args) throws -> Plan {
        var until: Date?
        let given = [a.values["for"] != nil, a.values["until"] != nil, a.flags.contains("forever")].filter { $0 }.count
        if given > 1 { throw UsageError(message: "use only one of --for, --until and --forever") }
        if let f = a.values["for"] {
            guard let s = parseDuration(f) else { throw UsageError(message: "invalid duration '\(f)' (try 90m, 2h, 1h30m, 1:30)") }
            until = Date().addingTimeInterval(TimeInterval(s))
        } else if let u = a.values["until"] {
            guard let d = parseUntil(u) else { throw UsageError(message: "invalid time '\(u)' (try 17:30, 5pm, 2026-12-24 08:00)") }
            until = d
        } else if !a.flags.contains("forever") {
            let configured = min(max(Prefs.int("autoOffSeconds", 0), 0), maxAutoOffSeconds)
            if configured > 0 { until = Date().addingTimeInterval(TimeInterval(configured)) }
        }
        var low: Int? = Prefs.bool("lowBatteryOff", false) ? min(max(Prefs.int("lowBatteryPercent", 20), 5), 90) : nil
        if let v = a.values["low-battery"] {
            guard let n = Int(v.replacingOccurrences(of: "%", with: "")), (5...90).contains(n) else { throw UsageError(message: "--low-battery needs a percentage from 5 to 90") }
            low = n
        }
        if a.flags.contains("no-low-battery") { low = nil }
        var unplug = Prefs.bool("offWhenUnplugged", false)
        if a.flags.contains("unplug-off") { unplug = true }
        if a.flags.contains("no-unplug-off") { unplug = false }
        var notifyOn = Prefs.bool("notifyAutoOff", true)
        if a.flags.contains("notify") { notifyOn = true }
        if a.flags.contains("no-notify") { notifyOn = false }
        return Plan(until: until, unplugOff: unplug, lowBattery: low, notify: notifyOn, quiet: a.flags.contains("quiet"), wait: a.flags.contains("wait"))
    }

    static func cmdOn(_ argv: [String], toggling: Bool) throws -> Int32 {
        let a = try parse(argv, onSpec)
        if a.flags.contains("help") { print(Help.commands[toggling ? "toggle" : "on"]!); return 0 }
        if let extra = a.positional.first { throw UsageError(message: "unexpected argument '\(extra)'") }
        if toggling, sleepDisabled() == true { return try cmdOff(a.flags.contains("quiet") ? ["--quiet"] : []) }
        let plan = try makePlan(a)
        if let code = requireRule() { return code }

        // A running guard hands over instead of restoring, so there is no flicker of normal sleep
        if let old = readState() {
            kill(old.pid, SIGUSR1)
            for _ in 0..<20 where kill(old.pid, 0) == 0 { usleep(100_000) }
        }
        guard setSleepDisabled(true) else {
            printErr("dont-sleep: could not turn sleep prevention on")
            return 4
        }
        if plan.wait {
            if !plan.quiet { print(summary(plan) + " Press Ctrl-C to stop.") }
            return runGuard(plan, child: nil, announce: !plan.quiet)
        }
        return try startDetached(plan)
    }

    static func summary(_ p: Plan) -> String {
        var s = "Sleep prevention is on"
        if let u = p.until { s += " until \(formatClock(u)) (in \(formatDuration(Int(u.timeIntervalSinceNow.rounded()))))" } else { s += " with no time limit" }
        s += "."
        var rules: [String] = []
        if p.unplugOff { rules.append("unplugging the charger") }
        if let l = p.lowBattery { rules.append("battery below \(l)%") }
        if !rules.isEmpty { s += " It also turns off on " + rules.joined(separator: " or ") + "." }
        return s
    }

    static var selfPath: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }

    static func startDetached(_ plan: Plan) throws -> Int32 {
        var args = ["__guard", "--until", String(Int(plan.until?.timeIntervalSince1970 ?? 0))]
        if plan.unplugOff { args.append("--unplug-off") }
        if let l = plan.lowBattery { args += ["--low-battery", String(l)] }
        if plan.notify { args.append("--notify") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: selfPath)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            _ = setSleepDisabled(false)
            printErr("dont-sleep: could not start the background timer: \(error.localizedDescription)")
            return 4
        }
        for _ in 0..<40 {
            if let s = readState(), s.pid == p.processIdentifier {
                if !plan.quiet { print(summary(plan)) }
                return 0
            }
            if !p.isRunning { break }
            usleep(100_000)
        }
        _ = setSleepDisabled(false)
        printErr("dont-sleep: the background timer did not start; sleep prevention was turned off again")
        return 4
    }

    // MARK: guard (the process that owns a session)

    static func installSignalHandlers(detached: Bool) {
        signal(SIGINT) { cliStopSignal = $0 }
        signal(SIGTERM) { cliStopSignal = $0 }
        signal(SIGUSR1) { cliHandover = $0 }
        if detached { signal(SIGHUP, SIG_IGN) } else { signal(SIGHUP) { cliStopSignal = $0 } }
    }

    // Owns one session: keeps checking the time, the battery and the optional child command, and restores sleep at the end.
    static func runGuard(_ plan: Plan, child: Process?, announce: Bool) -> Int32 {
        cliStopSignal = 0
        cliHandover = 0
        installSignalHandlers(detached: false)
        return guardLoop(plan, child: child, announce: announce)
    }

    static func guardLoop(_ plan: Plan, child: Process?, announce: Bool) -> Int32 {
        let me = getpid()
        let start = processStart(me) ?? ""
        writeState(GuardState(pid: me, lstart: start, started: Date().timeIntervalSince1970, until: plan.until?.timeIntervalSince1970, unplugOff: plan.unplugOff, lowBattery: plan.lowBattery))
        // The watchdog covers the guard itself being killed without a chance to restore anything
        let watchdog = startWatchdog(pid: me, until: plan.until.map { Int($0.timeIntervalSince1970) + 20 })
        var wasOnBattery = powerInfo()?.onBattery
        var reason = ""
        var exitCode: Int32 = 0
        var restore = true
        var tick = 0

        loop: while true {
            if cliHandover != 0 { restore = false; reason = "handed over"; break }
            if cliStopSignal != 0 {
                reason = "stopped"
                if let c = child, c.isRunning {
                    c.terminate()
                    // The usual shell convention: 130 after Ctrl-C, 143 after SIGTERM
                    exitCode = 128 + cliStopSignal
                }
                break
            }
            if let c = child, !c.isRunning {
                reason = "the command finished"
                exitCode = c.terminationReason == .uncaughtSignal ? 128 + c.terminationStatus : c.terminationStatus
                break
            }
            if let u = plan.until, Date() >= u { reason = "the time is up"; break }
            if let p = powerInfo() {
                if p.onBattery, plan.unplugOff, wasOnBattery == false { reason = "the power adapter was unplugged"; break }
                if p.onBattery, let l = plan.lowBattery, p.percent <= l { reason = "the battery is at \(p.percent)%"; break }
                wasOnBattery = p.onBattery
            }
            // Spawning pmset every second would be wasteful, so the outside check runs every few seconds
            tick += 1
            if tick % 5 == 0, sleepDisabled() == false { restore = false; reason = "sleep was turned off elsewhere"; break loop }
            usleep(1_000_000)
        }
        watchdog?.terminate()
        if restore { _ = setSleepDisabled(false) }
        clearState(ifOwnedBy: me)
        if announce && reason != "handed over" { print("Sleep restored: \(reason).") }
        if plan.notify && restore && !["stopped", "the command finished"].contains(reason) { notify("Sleep restored: \(reason)") }
        return exitCode
    }

    static func cmdGuard(_ argv: [String]) throws -> Int32 {
        let a = try parse(argv, Spec(valued: ["until", "low-battery"], flags: ["unplug-off", "notify"]))
        let epoch = Double(a.values["until"] ?? "0") ?? 0
        let plan = Plan(until: epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil, unplugOff: a.flags.contains("unplug-off"),
                        lowBattery: a.values["low-battery"].flatMap { Int($0) }, notify: a.flags.contains("notify"), quiet: true, wait: false)
        _ = setsid()
        cliStopSignal = 0
        cliHandover = 0
        installSignalHandlers(detached: true)
        return guardLoop(plan, child: nil, announce: false)
    }

    // MARK: off

    static func cmdOff(_ argv: [String]) throws -> Int32 {
        let a = try parse(argv, Spec(flags: ["quiet"], short: ["q": "quiet"]))
        if a.flags.contains("help") { print(Help.commands["off"]!); return 0 }
        if let extra = a.positional.first { throw UsageError(message: "unexpected argument '\(extra)'") }
        let quiet = a.flags.contains("quiet")
        if let s = readState() {
            kill(s.pid, SIGTERM)
            for _ in 0..<60 where kill(s.pid, 0) == 0 { usleep(100_000) }
            if kill(s.pid, 0) == 0 { kill(s.pid, SIGKILL) }
        }
        let current = sleepDisabled()
        if current == false {
            if !quiet { print("Sleep prevention is off.") }
            return 0
        }
        if let code = requireRule() { return code }
        guard setSleepDisabled(false) else {
            printErr("dont-sleep: could not restore normal sleep")
            return 4
        }
        if !quiet { print("Sleep prevention is off. Normal sleep is restored.") }
        return 0
    }

    // MARK: status

    static func cmdStatus(_ argv: [String]) throws -> Int32 {
        let a = try parse(argv, Spec(flags: ["json", "quiet"], short: ["q": "quiet", "j": "json"]))
        if a.flags.contains("help") { print(Help.commands["status"]!); return 0 }
        if let extra = a.positional.first { throw UsageError(message: "unexpected argument '\(extra)'") }
        let on = sleepDisabled()
        let state = on == true ? readState() : nil
        let ruleOK = sudoRuleWorks()
        let code: Int32 = on == true ? 0 : (on == false ? 1 : 4)
        if a.flags.contains("quiet") { return code }
        if a.flags.contains("json") {
            var o: [String: Any] = ["enabled": on.map { $0 as Any } ?? NSNull(), "setupDone": ruleOK, "version": version]
            if let s = state {
                o["pid"] = Int(s.pid)
                if let u = s.until {
                    o["until"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: u))
                    o["remainingSeconds"] = max(0, Int((u - Date().timeIntervalSince1970).rounded()))
                }
                o["unplugOff"] = s.unplugOff
                if let l = s.lowBattery { o["lowBatteryPercent"] = l }
            }
            let data = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted])) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "{}")
            return code
        }
        switch on {
        case true?:
            print("Sleep prevention: ON")
            if let s = state, let u = s.until {
                let left = Int((u - Date().timeIntervalSince1970).rounded())
                print("  Ends:     \(formatClock(Date(timeIntervalSince1970: u))) (in \(formatDuration(left)))")
            } else if state != nil {
                print("  Ends:     no time limit")
            } else {
                print("  Ends:     unknown (not started by the command line; the menu bar app may own the timer)")
            }
            if let s = state {
                var rules: [String] = []
                if s.unplugOff { rules.append("unplugging the charger") }
                if let l = s.lowBattery { rules.append("battery below \(l)%") }
                if !rules.isEmpty { print("  Also off: " + rules.joined(separator: ", ")) }
            }
        case false?:
            print("Sleep prevention: off")
        case nil:
            print("Sleep prevention: unknown (could not read the power settings)")
        }
        print("  Setup:    " + (ruleOK ? "done (no password needed)" : "not done, run 'dont-sleep setup'"))
        return code
    }

    // MARK: run

    static func cmdRun(_ argv: [String]) throws -> Int32 {
        let a = try parse(argv, Spec(valued: ["low-battery"], flags: ["unplug-off", "no-unplug-off", "no-low-battery", "notify", "no-notify", "quiet"], short: ["q": "quiet"]), stopAtFirstPositional: true)
        if a.flags.contains("help") { print(Help.commands["run"]!); return 0 }
        // Everything after "--" or after the first word is the command to run
        let command = a.positional + a.rest
        guard let program = command.first else { throw UsageError(message: "run needs a command, e.g. dont-sleep run -- make build") }
        var plan = try makePlan(a)
        plan.until = nil
        plan.wait = true
        if let code = requireRule() { return code }

        let p = Process()
        if program.contains("/") {
            p.executableURL = URL(fileURLWithPath: program)
            p.arguments = Array(command.dropFirst())
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = command
        }
        guard setSleepDisabled(true) else {
            printErr("dont-sleep: could not turn sleep prevention on")
            return 4
        }
        cliStopSignal = 0
        cliHandover = 0
        installSignalHandlers(detached: false)
        do { try p.run() } catch {
            _ = setSleepDisabled(false)
            printErr("dont-sleep: cannot run '\(program)': \(error.localizedDescription)")
            return 127
        }
        if !plan.quiet { printErr("dont-sleep: sleep prevention is on while '\(program)' runs.") }
        let code = guardLoop(plan, child: p, announce: false)
        if p.isRunning { p.waitUntilExit() }
        return code != 0 ? code : (p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus)
    }

    // MARK: config

    enum Kind { case bool, duration, percent, shortcut, loginItem }

    struct Setting {
        let key: String
        let pref: String
        let kind: Kind
        let def: String
        let help: String
    }

    static let settings: [Setting] = [
        Setting(key: "auto-off", pref: "autoOffSeconds", kind: .duration, def: "never", help: "Default time before sleep prevention ends by itself (never, 90m, 2h, 1h30m)"),
        Setting(key: "restore-on-start", pref: "resetOnLaunch", kind: .bool, def: "on", help: "Menu bar app: restore normal sleep when it starts"),
        Setting(key: "restore-on-quit", pref: "restoreOnQuit", kind: .bool, def: "on", help: "Menu bar app: restore normal sleep when it quits (also arms the crash watchdog)"),
        Setting(key: "notify", pref: "notifyAutoOff", kind: .bool, def: "on", help: "Notify when sleep is restored automatically"),
        Setting(key: "check-updates", pref: "checkUpdates", kind: .bool, def: "on", help: "Menu bar app: look for new releases on GitHub once a day"),
        Setting(key: "show-countdown", pref: "showCountdown", kind: .bool, def: "on", help: "Menu bar app: show the remaining time next to the icon"),
        Setting(key: "unplug-off", pref: "offWhenUnplugged", kind: .bool, def: "off", help: "Turn off when the charger is unplugged"),
        Setting(key: "low-battery-off", pref: "lowBatteryOff", kind: .bool, def: "off", help: "Turn off when the battery gets low"),
        Setting(key: "low-battery-percent", pref: "lowBatteryPercent", kind: .percent, def: "20", help: "Battery level (5-90) for low-battery-off"),
        Setting(key: "launch-at-login", pref: "", kind: .loginItem, def: "off", help: "Start the menu bar app when you log in"),
        Setting(key: "shortcut-toggle", pref: "hk.toggle", kind: .shortcut, def: "⌃⌥⌘S", help: "Global shortcut that toggles sleep prevention (or 'none')"),
        Setting(key: "shortcut-add5", pref: "hk.add5", kind: .shortcut, def: "⌃⌥⌘5", help: "Global shortcut that adds 5 minutes (or 'none')"),
    ]

    static func onOff(_ b: Bool) -> String { b ? "on" : "off" }

    static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "on", "true", "yes", "y", "1", "enable", "enabled": return true
        case "off", "false", "no", "n", "0", "disable", "disabled": return false
        default: return nil
        }
    }

    // Key codes of an ANSI keyboard, the same ones the shortcut recorder in the app stores
    static let keyCodes: [String: Int] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "return": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48,
        "space": 49, "`": 50, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
        "f12": 111, "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    static func parseShortcut(_ text: String) -> (key: Int, mods: Int, label: String)? {
        var mods = 0
        var key: String?
        for part in text.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "ctrl", "control": mods |= controlKey
            case "opt", "option", "alt": mods |= optionKey
            case "cmd", "command": mods |= cmdKey
            case "shift": mods |= shiftKey
            default:
                if key != nil { return nil }
                key = part
            }
        }
        guard let k = key, let code = keyCodes[k], mods & (cmdKey | optionKey | controlKey) != 0 else { return nil }
        let symbols = (mods & controlKey != 0 ? "⌃" : "") + (mods & optionKey != 0 ? "⌥" : "") + (mods & shiftKey != 0 ? "⇧" : "") + (mods & cmdKey != 0 ? "⌘" : "")
        let names: [String: String] = ["space": "Space", "return": "↩", "tab": "⇥", "left": "←", "right": "→", "up": "↑", "down": "↓"]
        return (code, mods, symbols + (names[k] ?? k.uppercased()))
    }

    static func shortcutText(_ s: Setting) -> String {
        let key = Prefs.int(s.pref + ".key", s.key == "shortcut-toggle" ? 1 : 23)
        if key < 0 { return "none" }
        return (Prefs.raw(s.pref + ".label") as? String) ?? s.def
    }

    // SMAppService only works for the running bundle, and through a symlink that is not the app, so the real executable is asked
    static func loginStatus() -> String {
        if Bundle.main.bundleURL.pathExtension == "app" { return rawLoginStatus() }
        guard appBundle != nil, let r = runProcess(selfPath, ["__login", "status"], timeout: 10), r.status == 0 else { return "unavailable" }
        return r.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cmdLogin(_ argv: [String]) -> Int32 {
        guard Bundle.main.bundleURL.pathExtension == "app" else { print("unavailable"); return 0 }
        do {
            switch argv.first {
            case "on": try SMAppService.mainApp.register()
            case "off": try SMAppService.mainApp.unregister()
            default: break
            }
        } catch {
            print("error: \(error.localizedDescription)")
            return 4
        }
        print(rawLoginStatus())
        return 0
    }

    static func rawLoginStatus() -> String {
        switch SMAppService.mainApp.status {
        case .enabled: return "on"
        case .notRegistered: return "off"
        case .requiresApproval: return "approval needed"
        case .notFound: return "unavailable"
        @unknown default: return "unknown"
        }
    }

    static func value(of s: Setting) -> String {
        switch s.kind {
        case .bool: return onOff(Prefs.bool(s.pref, s.def == "on"))
        case .duration:
            let v = Prefs.int(s.pref, 0)
            return v > 0 ? formatDuration(v) : "never"
        case .percent: return String(Prefs.int(s.pref, 20))
        case .shortcut: return shortcutText(s)
        case .loginItem: return loginStatus()
        }
    }

    static func jsonValue(of s: Setting) -> Any {
        switch s.kind {
        case .bool: return Prefs.bool(s.pref, s.def == "on")
        case .duration: return Prefs.int(s.pref, 0)
        case .percent: return Prefs.int(s.pref, 20)
        case .shortcut: return shortcutText(s)
        case .loginItem: return loginStatus()
        }
    }

    static func setting(named name: String) throws -> Setting {
        guard let s = settings.first(where: { $0.key == name }) else {
            throw UsageError(message: "unknown setting '\(name)'. Settings: \(settings.map(\.key).joined(separator: ", "))")
        }
        return s
    }

    // Lets a running menu bar app re-read shortcuts and display options at once
    static func announceSettingsChange() {
        DistributedNotificationCenter.default().postNotificationName(settingsChangedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    static func cmdConfig(_ argv: [String]) throws -> Int32 {
        let a = try parse(argv, Spec(flags: ["json"], short: ["j": "json"]))
        if a.flags.contains("help") || a.positional.first == nil && argv.isEmpty { print(Help.commands["config"]!); return 0 }
        let action = a.positional.first ?? "list"
        let args = Array(a.positional.dropFirst())
        switch action {
        case "list":
            if a.flags.contains("json") {
                var o: [String: Any] = [:]
                for s in settings { o[s.key] = jsonValue(of: s) }
                print(String(data: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted])) ?? Data(), encoding: .utf8) ?? "{}")
                return 0
            }
            let w = (settings.map(\.key.count).max() ?? 10) + 2
            print("KEY".padding(toLength: w, withPad: " ", startingAt: 0) + "VALUE".padding(toLength: 16, withPad: " ", startingAt: 0) + "DEFAULT".padding(toLength: 18, withPad: " ", startingAt: 0) + "DESCRIPTION")
            for s in settings {
                print(s.key.padding(toLength: w, withPad: " ", startingAt: 0) + String(value(of: s).prefix(14)).padding(toLength: 16, withPad: " ", startingAt: 0) + s.def.padding(toLength: 18, withPad: " ", startingAt: 0) + s.help)
            }
            return 0
        case "get":
            guard args.count == 1 else { throw UsageError(message: "usage: dont-sleep config get KEY") }
            let s = try setting(named: args[0])
            if a.flags.contains("json") { print(String(data: (try? JSONSerialization.data(withJSONObject: [s.key: jsonValue(of: s)], options: [.fragmentsAllowed])) ?? Data(), encoding: .utf8) ?? "") } else { print(value(of: s)) }
            if s.kind == .loginItem {
                switch loginStatus() {
                case "approval needed": printErr("Approve Dont Sleep in System Settings > General > Login Items.")
                case "unavailable": printErr("This command is not running from inside the app bundle, so it cannot manage the login item.")
                default: break
                }
            }
            return 0
        case "set":
            guard args.count == 2 else { throw UsageError(message: "usage: dont-sleep config set KEY VALUE") }
            let code = try set(try setting(named: args[0]), args[1])
            announceSettingsChange()
            return code
        case "reset":
            if let name = args.first {
                try reset(try setting(named: name))
                print("\(name) reset to its default (\(try setting(named: name).def)).")
            } else {
                for s in settings { try reset(s) }
                print("All settings reset to their defaults.")
            }
            announceSettingsChange()
            return 0
        case "path":
            print(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(appBundleID).plist").path)
            return 0
        default:
            throw UsageError(message: "unknown config action '\(action)' (list, get, set, reset, path)")
        }
    }

    static func reset(_ s: Setting) throws {
        switch s.kind {
        case .loginItem: try? SMAppService.mainApp.unregister()
        case .shortcut:
            Prefs.remove(s.pref + ".key")
            Prefs.remove(s.pref + ".mods")
            Prefs.remove(s.pref + ".label")
        case .duration:
            Prefs.remove(s.pref)
            Prefs.remove("autoOffUnit")
        default: Prefs.remove(s.pref)
        }
    }

    static func set(_ s: Setting, _ text: String) throws -> Int32 {
        switch s.kind {
        case .bool:
            guard let b = parseBool(text) else { throw UsageError(message: "'\(text)' is not on/off") }
            Prefs.setBool(s.pref, b)
            print("\(s.key) = \(onOff(b))")
        case .percent:
            guard let n = Int(text.replacingOccurrences(of: "%", with: "")), (5...90).contains(n) else { throw UsageError(message: "\(s.key) needs a number from 5 to 90") }
            Prefs.setInt(s.pref, n)
            print("\(s.key) = \(n)")
        case .duration:
            if ["never", "off", "none", "forever", "0"].contains(text.lowercased()) {
                Prefs.setInt(s.pref, 0)
                print("\(s.key) = never")
            } else {
                guard let secs = parseDuration(text) else { throw UsageError(message: "invalid duration '\(text)' (try 90m, 2h, 1h30m, 1:30, never)") }
                Prefs.setInt(s.pref, secs)
                // Choose the unit the Settings window shows, so 2 hours reads "2 Hours" there
                let unit = [86400, 3600, 60, 1].first { secs % $0 == 0 && secs / $0 <= 100_000 } ?? 1
                Prefs.setInt("autoOffUnit", unit)
                print("\(s.key) = \(formatDuration(secs))")
            }
        case .shortcut:
            let other = settings.first { $0.kind == .shortcut && $0.key != s.key }!
            switch text.lowercased() {
            case "none", "off":
                Prefs.setInt(s.pref + ".key", -1)
                print("\(s.key) = none")
            case "default":
                try reset(s)
                print("\(s.key) = \(s.def)")
            default:
                guard let sc = parseShortcut(text) else {
                    throw UsageError(message: "invalid shortcut '\(text)'. Use modifiers and a key, e.g. ctrl+opt+cmd+s (at least one of cmd, opt, ctrl)")
                }
                if Prefs.int(other.pref + ".key", other.key == "shortcut-toggle" ? 1 : 23) == sc.key, Prefs.int(other.pref + ".mods", hotkeyDefaultMods) == sc.mods {
                    throw UsageError(message: "that combination is already used by \(other.key)")
                }
                // Mods first so the app never sees a new key with an old modifier set
                Prefs.setInt(s.pref + ".mods", sc.mods)
                Prefs.setString(s.pref + ".label", sc.label)
                Prefs.setInt(s.pref + ".key", sc.key)
                print("\(s.key) = \(sc.label)")
            }
        case .loginItem:
            guard let b = parseBool(text) else { throw UsageError(message: "'\(text)' is not on/off") }
            if Bundle.main.bundleURL.pathExtension == "app" {
                if cmdLogin([b ? "on" : "off"]) != 0 { return 4 }
            } else {
                guard appBundle != nil, let r = runProcess(selfPath, ["__login", b ? "on" : "off"], timeout: 10) else {
                    printErr("dont-sleep: the login item can only be managed by the installed app")
                    return 4
                }
                if r.status != 0 {
                    printErr("dont-sleep: could not change the login item: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                    return 4
                }
            }
            print("\(s.key) = \(loginStatus())")
            if loginStatus() == "approval needed" { print("Approve Dont Sleep in System Settings > General > Login Items to finish.") }
        }
        return 0
    }

    // MARK: setup / remove-rule

    static func runInteractive(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { return 127 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    // A destructive action never proceeds silently when nobody can answer: scripts must pass --yes explicitly
    static func confirm(_ question: String, yes: Bool, requireYes: Bool = false) -> Bool {
        if yes { return true }
        if isatty(STDIN_FILENO) == 0 {
            if requireYes { printErr("dont-sleep: refusing to continue without a terminal; pass --yes to confirm") }
            return !requireYes
        }
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        return ["y", "yes"].contains((readLine() ?? "").lowercased())
    }

    static func cmdSetup(_ argv: [String]) throws -> Int32 {
        let a = try parse(argv, Spec(flags: ["print", "yes"], short: ["y": "yes"]))
        if a.flags.contains("help") { print(Help.commands["setup"]!); return 0 }
        let script = sudoersInstallScript()
        let command = "/usr/bin/sudo /bin/sh -c '\(script)'"
        if a.flags.contains("print") { print(command); return 0 }
        if sudoRuleWorks() {
            print("Setup is already done: sleep can be changed without a password.")
            return 0
        }
        print("""
        One-time setup. This installs /etc/sudoers.d/dont-sleep so your user can run exactly:
          /usr/bin/pmset -a disablesleep 0
          /usr/bin/pmset -a disablesleep 1
        without a password. sudo will ask for your password once.
        """)
        guard confirm("Continue?", yes: a.flags.contains("yes")) else { print("Cancelled."); return 1 }
        let status = runInteractive("/usr/bin/sudo", ["/bin/sh", "-c", script])
        guard status == 0, sudoRuleWorks() else {
            printErr("dont-sleep: setup did not complete")
            return 4
        }
        print("Done. You can now use 'dont-sleep on' without a password.")
        return 0
    }

    static func cmdRemoveRule(_ argv: [String]) throws -> Int32 {
        let a = try parse(argv, Spec(flags: ["yes"], short: ["y": "yes"]))
        if a.flags.contains("help") { print(Help.commands["remove-rule"]!); return 0 }
        guard FileManager.default.fileExists(atPath: sudoersRulePath) else {
            print("There is no rule to remove.")
            return 0
        }
        guard confirm("Remove \(sudoersRulePath)? Changing sleep will ask for a password again.", yes: a.flags.contains("yes"), requireYes: true) else { print("Cancelled."); return 1 }
        // Restore sleep first: afterwards this tool could no longer do it without a password
        if sleepDisabled() != false {
            let code = try cmdOff(["--quiet"])
            if code != 0 { printErr("dont-sleep: could not restore normal sleep, so the rule was not removed"); return code }
        }
        let status = runInteractive("/usr/bin/sudo", ["/bin/rm", "-f", sudoersRulePath])
        guard status == 0 else { printErr("dont-sleep: could not remove the rule"); return 4 }
        print("Rule removed.")
        return 0
    }

    // MARK: update

    final class FetchBox { var result: Result<ReleaseInfo, Error>? }

    static func cmdUpdate(_ argv: [String]) throws -> Int32 {
        let a = try parse(argv, Spec(flags: ["json", "quiet"], short: ["q": "quiet", "j": "json"]))
        if a.flags.contains("help") { print(Help.commands["update"]!); return 0 }
        if let extra = a.positional.first { throw UsageError(message: "unexpected argument '\(extra)'") }
        let box = FetchBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await fetchLatestRelease()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        let current = currentVersion()
        switch box.result! {
        case .failure(let error):
            if a.flags.contains("json") {
                print(String(data: (try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription], options: [.sortedKeys, .prettyPrinted])) ?? Data(), encoding: .utf8) ?? "{}")
            } else {
                printErr("dont-sleep: could not check for updates: \(error.localizedDescription)")
            }
            return 4
        case .success(let r):
            let newer = current.map { isNewerVersion(r.version, than: $0) } ?? false
            if a.flags.contains("json") {
                let o: [String: Any] = ["current": current.map { $0 as Any } ?? NSNull(), "latest": r.version, "tag": r.tag, "updateAvailable": newer, "url": r.url.absoluteString]
                print(String(data: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .prettyPrinted])) ?? Data(), encoding: .utf8) ?? "{}")
            } else if !a.flags.contains("quiet") {
                if newer {
                    print("Update available: \(r.version) (you have \(current ?? "unknown")).\nDownload: \(r.url.absoluteString)")
                } else if let current {
                    print("dont-sleep \(current) is up to date (latest release: \(r.tag)).")
                } else {
                    print("Latest release: \(r.tag) (this build has no version number).\nDownload: \(r.url.absoluteString)")
                }
            }
            return newer ? 1 : 0
        }
    }

    // MARK: link / unlink

    static func cmdLink(_ argv: [String], remove: Bool) throws -> Int32 {
        let a = try parse(argv, Spec(valued: ["dir"], flags: ["force"], short: ["f": "force", "d": "dir"]))
        if a.flags.contains("help") { print(Help.commands[remove ? "unlink" : "link"]!); return 0 }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = a.values["dir"].map { [$0] } ?? ["/usr/local/bin", "/opt/homebrew/bin", "\(home)/.local/bin"]
        let target = selfPath
        if remove {
            for dir in candidates {
                let link = dir + "/dont-sleep"
                if let dest = try? fm.destinationOfSymbolicLink(atPath: link), URL(fileURLWithPath: dest, relativeTo: URL(fileURLWithPath: dir)).resolvingSymlinksInPath().path == target {
                    try fm.removeItem(atPath: link)
                    print("Removed \(link)")
                    return 0
                }
            }
            print("No dont-sleep link to this app was found.")
            return 1
        }
        let dir: String
        if let given = a.values["dir"] { dir = given } else if let writable = candidates.first(where: { fm.isWritableFile(atPath: $0) }) {
            dir = writable
        } else {
            dir = "\(home)/.local/bin"
        }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let link = dir + "/dont-sleep"
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
            if URL(fileURLWithPath: existing, relativeTo: URL(fileURLWithPath: dir)).resolvingSymlinksInPath().path == target {
                print("\(link) already points to this app.")
                return 0
            } else if a.flags.contains("force") {
                try fm.removeItem(atPath: link)
            } else {
                throw UsageError(message: "\(link) already exists and points elsewhere (use --force to replace it)")
            }
        } else if fm.fileExists(atPath: link) {
            throw UsageError(message: "\(link) exists and is not a link; remove it first")
        }
        if !fm.fileExists(atPath: link) { try fm.createSymbolicLink(atPath: link, withDestinationPath: target) }
        print("Linked \(link) -> \(target)")
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if !path.contains(dir) { print("Note: \(dir) is not in your PATH. Add it, for example:\n  echo 'export PATH=\"\(dir):$PATH\"' >> ~/.zshrc") }
        return 0
    }
}

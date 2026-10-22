import Carbon.HIToolbox
import Cocoa
import ServiceManagement
import IOKit.ps
import SwiftUI
import UserNotifications

func sleepDisabled() -> Bool {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
    p.standardOutput = pipe
    try? p.run()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return out.split(separator: "\n").contains { $0.contains("SleepDisabled") && $0.split(whereSeparator: \.isWhitespace).last == "1" }
}

func run(_ path: String, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
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

let sudoersRulePath = "/etc/sudoers.d/dont-sleep"
let hotkeyNames = ["toggle", "add5"]
let hotkeyDefaults: [String: (key: Int, label: String)] = ["toggle": (1, "⌃⌥⌘S"), "add5": (23, "⌃⌥⌘5")]
let hotkeyDefaultMods = controlKey | optionKey | cmdKey
var hotkeyActions: [UInt32: () -> Void] = [:]
var hotkeyRefs: [EventHotKeyRef] = []
// Set while a shortcut is being recorded so the current binding does not fire
var recordingShortcut = false

func installHotkeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        DispatchQueue.main.async { if !recordingShortcut { hotkeyActions[id.id]?() } }
        return noErr
    }, 1, &spec, nil, nil)
}

func registerHotkeys() {
    hotkeyRefs.forEach { UnregisterEventHotKey($0) }
    hotkeyRefs = []
    for (i, name) in hotkeyNames.enumerated() {
        let key = UserDefaults.standard.integer(forKey: "hk.\(name).key")
        guard key >= 0 else { continue }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x44534C50), id: UInt32(i + 1))
        if RegisterEventHotKey(UInt32(key), UInt32(UserDefaults.standard.integer(forKey: "hk.\(name).mods")), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            hotkeyRefs.append(ref)
        }
    }
}

func shortcutLabel(_ e: NSEvent) -> String {
    let f = e.modifierFlags
    let mods = (f.contains(.control) ? "⌃" : "") + (f.contains(.option) ? "⌥" : "") + (f.contains(.shift) ? "⇧" : "") + (f.contains(.command) ? "⌘" : "")
    let special: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
    return mods + (special[e.keyCode] ?? e.charactersIgnoringModifiers?.uppercased() ?? "?")
}

func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    a.blended(withFraction: t, of: b) ?? a
}

// NSSwitch loses its accent color inside menus of an inactive app, so draw our own.
final class Pill: NSView {
    var onClick: (() -> Void)?
    private var progress: CGFloat = 0
    private var timer: Timer?
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            // .common mode keeps the animation running while the menu is tracking events
            timer?.invalidate()
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                guard let self else { return t.invalidate() }
                let target: CGFloat = self.isOn ? 1 : 0
                let step: CGFloat = 1.0 / 14
                self.progress = abs(target - self.progress) <= step ? target : self.progress + (target > self.progress ? step : -step)
                self.needsDisplay = true
                if self.progress == target { t.invalidate() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    override func draw(_ r: NSRect) {
        let w = bounds.width, h = bounds.height
        let e = progress * progress * (3 - 2 * progress)
        NSBezierPath(roundedRect: bounds, xRadius: h / 2, yRadius: h / 2).addClip()

        NSGradient(colors: [
            mix(NSColor(red: 0.06, green: 0.07, blue: 0.22, alpha: 1), NSColor(red: 0.33, green: 0.68, blue: 0.95, alpha: 1), e),
            mix(NSColor(red: 0.20, green: 0.15, blue: 0.42, alpha: 1), NSColor(red: 0.62, green: 0.85, blue: 0.98, alpha: 1), e),
        ])?.draw(in: bounds, angle: 0)

        for (fx, fy, sz) in [(0.55, 0.72, 2.0), (0.72, 0.30, 1.6), (0.85, 0.68, 2.2), (0.66, 0.50, 1.2), (0.92, 0.35, 1.4)] as [(CGFloat, CGFloat, CGFloat)] {
            NSColor.white.withAlphaComponent((1 - e) * 0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: fx * w, y: fy * h, width: sz, height: sz)).fill()
        }

        NSColor.white.withAlphaComponent(e * 0.85).setFill()
        for (fx, fy, cw, ch) in [(0.14, 0.18, 12.0, 6.0), (0.30, 0.45, 10.0, 5.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            NSBezierPath(roundedRect: NSRect(x: fx * w, y: fy * h, width: cw, height: ch), xRadius: ch / 2, yRadius: ch / 2).fill()
        }

        let d = h - 6
        let knob = NSRect(x: 3 + (w - d - 6) * e, y: 3, width: d, height: d)
        NSColor(red: 1, green: 0.85, blue: 0.2, alpha: 0.35 * e).setFill()
        NSBezierPath(ovalIn: knob.insetBy(dx: -3 * e, dy: -3 * e)).fill()
        mix(NSColor(red: 0.93, green: 0.93, blue: 0.86, alpha: 1), NSColor(red: 1, green: 0.8, blue: 0.15, alpha: 1), e).setFill()
        NSBezierPath(ovalIn: knob).fill()

        NSColor(red: 0.72, green: 0.72, blue: 0.66, alpha: 1 - e).setFill()
        for (fx, fy, f) in [(0.3, 0.55, 0.28), (0.6, 0.3, 0.2), (0.62, 0.65, 0.15)] as [(CGFloat, CGFloat, CGFloat)] {
            NSBezierPath(ovalIn: NSRect(x: knob.minX + fx * d, y: knob.minY + fy * d, width: f * d, height: f * d)).fill()
        }
    }

    override func mouseDown(with e: NSEvent) { onClick?() }
}

let autoOffChoices: [(String, Int)] = [("Never", 0), ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14400), ("8 hours", 28800)]
let autoOffUnits: [(String, Int)] = [("Seconds", 1), ("Minutes", 60), ("Hours", 3600), ("Days", 86400)]

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let toggle = Pill(frame: NSRect(x: 0, y: 0, width: 54, height: 28))
    let defaults = UserDefaults.standard
    var autoOffTimer: Timer?
    var tickTimer: Timer?
    var deadline: Date?
    var termSource: DispatchSourceSignal?
    var settingsWindow: NSWindow?
    var wasOnBattery: Bool?

    func applicationDidFinishLaunching(_ n: Notification) {
        defaults.register(defaults: ["resetOnLaunch": true, "restoreOnQuit": true, "autoOffSeconds": 0,
                                     "notifyAutoOff": true, "showCountdown": true, "offWhenUnplugged": false, "lowBatteryOff": false, "lowBatteryPercent": 20])
        for n in hotkeyNames {
            defaults.register(defaults: ["hk.\(n).key": hotkeyDefaults[n]!.key, "hk.\(n).mods": hotkeyDefaultMods, "hk.\(n).label": hotkeyDefaults[n]!.label])
        }
        defaults.removeObject(forKey: "autoOffMinutes")
        UNUserNotificationCenter.current().delegate = self

        let label = NSTextField(labelWithString: "Prevent Sleep")
        toggle.onClick = { [unowned self] in toggled() }
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        label.frame = NSRect(x: 14, y: 7, width: 120, height: 18)
        toggle.frame.origin = NSPoint(x: 240 - toggle.frame.width - 14, y: (32 - toggle.frame.height) / 2)
        toggle.autoresizingMask = .minXMargin
        row.autoresizingMask = .width
        row.addSubview(label)
        row.addSubview(toggle)

        let menu = NSMenu()
        menu.delegate = self
        let rowItem = NSMenuItem()
        rowItem.view = row
        menu.addItem(rowItem)
        menu.addItem(.separator())
        func add(_ title: String, _ key: String, _ action: Selector) {
            let m = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            m.target = self
            m.indentationLevel = 1
        }
        menu.addItem(NSMenuItem.sectionHeader(title: "Keep awake for"))
        add("1 hour", "1", #selector(keepOneHour))
        add("2 hours", "2", #selector(keepTwoHours))
        menu.addItem(NSMenuItem.sectionHeader(title: "Add time"))
        add("30 minutes", "3", #selector(addThirty))
        add("5 minutes", "5", #selector(addFive))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Uninstall…", action: #selector(uninstall), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        // pkill and similar send SIGTERM, which would otherwise skip applicationWillTerminate
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term

        // disablesleep survives reboots, so the safe default is restoring it
        if defaults.bool(forKey: "resetOnLaunch") && sleepDisabled() { setSleepDisabled(false) }
        refresh()
        startPowerMonitor()

        hotkeyActions = [1: { [unowned self] in refresh(); toggled() }, 2: { [unowned self] in keepAwake(seconds: 300, extend: true) }]
        installHotkeyHandler()
        registerHotkeys()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in registerHotkeys() }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func applicationWillTerminate(_ n: Notification) {
        if defaults.bool(forKey: "restoreOnQuit") && sleepDisabled() { setSleepDisabled(false) }
    }

    // Relaunching the app (Launchpad, Spotlight) opens Settings, handy when the icon is hidden by the notch
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func refresh() {
        let on = sleepDisabled()
        toggle.isOn = on
        if !on { disarm() }
        item.button?.image = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "moon.zzz", accessibilityDescription: nil)
    }

    func toggled() {
        let on = !toggle.isOn
        guard setSleepDisabled(on) else {
            item.menu?.cancelTracking()
            DispatchQueue.main.async { self.showSetupAlert { self.refresh(); self.toggled() } }
            return
        }
        refresh()
        if on { armAutoOff() }
    }

    // Runs a command as root through the standard macOS admin prompt; completion gets nil when the user dismissed the prompt
    func runAsAdmin(_ rootCommand: String, completion: @escaping (Bool?) -> Void) {
        let escaped = asAppleScriptString(rootCommand)
        let p = Process()
        let err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        DispatchQueue.global().async {
            guard (try? p.run()) != nil else { return DispatchQueue.main.async { completion(false) } }
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async { completion(ok ? true : (msg.contains("-128") ? nil : false)) }
        }
    }

    // retry runs automatically once the sudoers rule is in place, so the user's original action is not lost
    func showSetupAlert(retry: @escaping () -> Void, nativeFailed: Bool = false) {
        let install = sudoersInstallScript()
        let cmd = "/usr/bin/sudo /bin/sh -c '\(install)'"

        let alert = NSAlert()
        alert.messageText = "One-time setup needed"
        var actions: [() -> Void] = []
        func button(_ title: String, _ action: @escaping () -> Void) {
            alert.addButton(withTitle: title)
            actions.append(action)
        }
        let openTerminal = { [self] in
            // A fresh private directory with an unpredictable name: nothing can be planted at the path beforehand
            let script = """
            #!/bin/bash
            export PATH=/usr/bin:/bin:/usr/sbin:/sbin
            clear
            echo 'Dont Sleep one-time setup: macOS will ask for your password.'
            if \(cmd); then
              echo; echo 'Done.'
              /bin/rm -- "$0"; /bin/rmdir "$(/usr/bin/dirname "$0")" 2>/dev/null
              TTY=$(/usr/bin/tty)
              # Detached so the window can be closed without a "terminate processes" prompt; Terminal quits if nothing else is open
              ( /bin/sleep 1; /usr/bin/osascript -e 'tell application "Terminal"' -e "close (every window whose tty is \\"$TTY\\")" -e 'delay 0.5' -e 'if (count of windows) is 0 then quit' -e 'end tell' ) >/dev/null 2>&1 </dev/null &
              disown
              exit 0
            else
              echo 'Setup failed.'
              /bin/rm -- "$0"; /bin/rmdir "$(/usr/bin/dirname "$0")" 2>/dev/null
            fi
            """
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let url = dir.appendingPathComponent("Dont Sleep Setup.command")
                try script.write(to: url, atomically: false, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
                NSWorkspace.shared.open(url)
                waitForSudoRule(retry)
            } catch {
                let a = NSAlert()
                a.messageText = "Could not prepare the setup script"
                a.informativeText = "\(error.localizedDescription)\n\nUse Copy Command instead and paste it in Terminal."
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            }
        }

        if nativeFailed {
            alert.informativeText = "The password prompt did not complete. Open Terminal to run this command instead (it asks for your password once)."
            let field = NSTextField(wrappingLabelWithString: cmd)
            field.isSelectable = true
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.frame = NSRect(x: 0, y: 0, width: 440, height: 88)
            alert.accessoryView = field
        } else {
            alert.informativeText = "Dont Sleep needs your password once to change the sleep setting without asking again. It only allows turning sleep prevention on and off."
            button("Install") { [self] in
                runAsAdmin(install) { result in
                    switch result {
                    case true?:
                        // A silent mismatch (rule installed but not effective) must not look like success
                        if sudoRuleWorks() { retry() } else { self.showSetupAlert(retry: retry, nativeFailed: true) }
                    case false?: self.showSetupAlert(retry: retry, nativeFailed: true)
                    case nil: break
                    }
                }
            }
        }
        button("Open Terminal", openTerminal)
        button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
        button("Cancel") {}

        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if actions.indices.contains(index) { actions[index]() }
    }

    @objc func uninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Dont Sleep?"
        alert.informativeText = "This will restore normal sleep, remove the sudoers rule (asks for your password), remove the login item and all saved settings, and move the app to the Trash."
        alert.addButton(withTitle: "Uninstall").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Must happen while the sudoers rule still exists
        setSleepDisabled(false)
        guard FileManager.default.fileExists(atPath: sudoersRulePath) else { return finishUninstall() }
        runAsAdmin("/bin/rm -f \(sudoersRulePath)") { [self] result in
            switch result {
            case true?:
                finishUninstall()
            case false?:
                let a = NSAlert()
                a.messageText = "Could not remove the sudoers rule"
                a.informativeText = "Nothing else was removed. To remove it by hand, run in Terminal:\nsudo rm \(sudoersRulePath)"
                a.runModal()
            case nil:
                break
            }
        }
    }

    func finishUninstall() {
        disarm()
        hotkeyRefs.forEach { UnregisterEventHotKey($0) }
        hotkeyRefs = []
        try? SMAppService.mainApp.unregister()
        let fm = FileManager.default
        if let id = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: id)
            let lib = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
            for path in ["Preferences/\(id).plist", "Caches/\(id)", "HTTPStorages/\(id)", "Saved Application State/\(id).savedState"] {
                try? fm.removeItem(at: lib.appendingPathComponent(path))
            }
        }
        let plist = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(Bundle.main.bundleIdentifier ?? "local.dontsleep").plist").path
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
            // The completion handler is not on the main thread
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let a = NSAlert()
                a.messageText = "Dont Sleep was uninstalled"
                a.runModal()
                // cfprefsd writes an empty plist back a few seconds after removal, so delete it repeatedly from a detached process once we are gone
                let sh = Process()
                sh.executableURL = URL(fileURLWithPath: "/bin/sh")
                sh.arguments = ["-c", "for i in 1 2 3 4 5 6; do sleep 1.5; /bin/rm -f \"$1\"; done", "sh", plist]
                try? sh.run()
                // exit() instead of terminate so no handler rewrites the settings just removed
                exit(0)
            }
        }
    }

    func waitForSudoRule(_ then: @escaping () -> Void) {
        var tries = 0
        let t = Timer(timeInterval: 1, repeats: true) { t in
            tries += 1
            if run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"]) {
                t.invalidate()
                then()
            } else if tries >= 600 {
                t.invalidate()
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func autoTurnOff(_ reason: String) {
        setSleepDisabled(false)
        refresh()
        guard defaults.bool(forKey: "notifyAutoOff") else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "Dont Sleep"
            content.body = "Sleep restored: \(reason)"
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func startPowerMonitor() {
        wasOnBattery = powerInfo()?.onBattery
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            Unmanaged<App>.fromOpaque(ctx!).takeUnretainedValue().powerChanged()
        }, ctx)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    }

    func powerChanged() {
        guard let (onBattery, percent) = powerInfo() else { return }
        let justUnplugged = onBattery && wasOnBattery == false
        wasOnBattery = onBattery
        guard onBattery, sleepDisabled() else { return }
        if justUnplugged && defaults.bool(forKey: "offWhenUnplugged") {
            autoTurnOff("power adapter unplugged")
        } else if defaults.bool(forKey: "lowBatteryOff") && percent <= defaults.integer(forKey: "lowBatteryPercent") {
            autoTurnOff("battery at \(percent)%")
        }
    }

    func disarm() {
        autoOffTimer?.invalidate()
        deadline = nil
        updateCountdown()
    }

    func updateCountdown() {
        tickTimer?.invalidate()
        guard let deadline, defaults.bool(forKey: "showCountdown") else {
            item.button?.title = ""
            return
        }
        // Seconds only matter in the last hour; before that a per-minute refresh keeps the menu bar redraw cost near zero
        func tick() {
            let t = max(0, deadline.timeIntervalSinceNow)
            let r = Int(t.rounded(.up))
            let text = r > 3600 ? (r >= 86400 ? "\(r / 86400)d \(r % 86400 / 3600)h" : String(format: "%dh %02dm", r / 3600, r % 3600 / 60))
                : String(format: "%d:%02d", r / 60, r % 60)
            item.button?.title = " " + text
            let delay = r > 3600 ? max(0.5, t.truncatingRemainder(dividingBy: 60) + 0.05) : 1
            // .common mode so the countdown keeps moving while the menu is open
            let timer = Timer(timeInterval: delay, repeats: false) { _ in tick() }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        }
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        item.button?.imagePosition = .imageLeft
        tick()
    }

    func schedule(until date: Date) {
        autoOffTimer?.invalidate()
        deadline = date
        updateCountdown()
        // .common mode so it still fires while a menu is being tracked
        let t = Timer(timeInterval: max(0, date.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            self?.autoTurnOff("auto-off timer elapsed")
        }
        RunLoop.main.add(t, forMode: .common)
        autoOffTimer = t
    }

    func armAutoOff() {
        disarm()
        let seconds = defaults.integer(forKey: "autoOffSeconds")
        guard seconds > 0, toggle.isOn else { return }
        schedule(until: Date().addingTimeInterval(TimeInterval(seconds)))
    }

    // Turns sleep prevention on if needed; extending adds to the running countdown instead of restarting it
    func keepAwake(seconds: Int, extend: Bool) {
        refresh()
        if !toggle.isOn {
            guard setSleepDisabled(true) else {
                DispatchQueue.main.async { self.showSetupAlert { self.keepAwake(seconds: seconds, extend: extend) } }
                return
            }
            refresh()
        }
        schedule(until: (extend ? deadline ?? Date() : Date()).addingTimeInterval(TimeInterval(seconds)))
    }

    @objc func keepOneHour() { keepAwake(seconds: 3600, extend: false) }
    @objc func keepTwoHours() { keepAwake(seconds: 7200, extend: false) }
    @objc func addThirty() { keepAwake(seconds: 1800, extend: true) }
    @objc func addFive() { keepAwake(seconds: 300, extend: true) }

    @objc func openSettings() {
        let view = SettingsView(onAutoOffChange: { [weak self] in self?.armAutoOff() }, onDisplayChange: { [weak self] in self?.updateCountdown() })
        if settingsWindow == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Dont Sleep Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            // Drop the SwiftUI view tree when closed; it is rebuilt on every open anyway
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak w] _ in w?.contentViewController = nil }
            settingsWindow = w
        }
        // Fresh view each time so the login item state is re-read
        settingsWindow?.contentViewController = NSHostingController(rootView: view)
        // center() uses NSScreen.main, which can be a different display than the one the user is looking at
        if let w = settingsWindow, let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: f.midY - w.frame.height / 2))
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @AppStorage("resetOnLaunch") private var resetOnLaunch = true
    @AppStorage("restoreOnQuit") private var restoreOnQuit = true
    @AppStorage("autoOffSeconds") private var seconds = 0
    @AppStorage("autoOffUnit") private var unit = 60
    @AppStorage("notifyAutoOff") private var notifyAutoOff = true
    @AppStorage("showCountdown") private var showCountdown = true
    @AppStorage("offWhenUnplugged") private var offWhenUnplugged = false
    @AppStorage("lowBatteryOff") private var lowBatteryOff = false
    @AppStorage("lowBatteryPercent") private var lowBatteryPercent = 20
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var custom = !autoOffChoices.contains { $0.1 == UserDefaults.standard.integer(forKey: "autoOffSeconds") }
    let onAutoOffChange: () -> Void
    let onDisplayChange: () -> Void

    private var loginBinding: Binding<Bool> {
        Binding(get: { login }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {}
            login = SMAppService.mainApp.status == .enabled
        })
    }

    private var pickerBinding: Binding<Int> {
        Binding(get: { custom ? -1 : seconds }, set: { v in
            if v == -1 {
                custom = true
                if seconds == 0 { unit = 60; seconds = 45 * 60 }
            } else {
                custom = false
                seconds = v
            }
        })
    }

    private var amountBinding: Binding<Int> {
        Binding(get: { seconds / unit }, set: { seconds = max(1, $0) * unit })
    }

    private var unitBinding: Binding<Int> {
        Binding(get: { unit }, set: { u in
            let amount = max(1, seconds / unit)
            unit = u
            seconds = amount * u
        })
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: loginBinding)
                Toggle("Restore normal sleep when the app starts", isOn: $resetOnLaunch)
                Toggle("Restore normal sleep when the app quits", isOn: $restoreOnQuit)
                Toggle("Notify when sleep is restored automatically", isOn: $notifyAutoOff)
                Toggle("Show remaining time in the menu bar", isOn: $showCountdown)
            }
            Section("Auto-off") {
                Picker("Turn off after", selection: pickerBinding) {
                    ForEach(autoOffChoices, id: \.1) { Text($0.0).tag($0.1) }
                    Text("Custom…").tag(-1)
                }
                if custom {
                    LabeledContent("Duration") {
                        HStack(spacing: 8) {
                            TextField("", value: amountBinding, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Stepper("", value: amountBinding, in: 1...100_000).labelsHidden()
                        }
                    }
                    Picker("Unit", selection: unitBinding) {
                        ForEach(autoOffUnits, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section("Shortcuts") {
                ShortcutRow(title: "Toggle sleep prevention", name: "toggle")
                ShortcutRow(title: "Add 5 minutes", name: "add5")
            }
            Section("Battery") {
                Toggle("Turn off when unplugged", isOn: $offWhenUnplugged)
                Toggle("Turn off when battery is low", isOn: $lowBatteryOff)
                if lowBatteryOff {
                    Stepper("Below \(lowBatteryPercent)%", value: $lowBatteryPercent, in: 5...90, step: 5)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 400, height: (custom ? 110 : 0) + (lowBatteryOff ? 44 : 0) + 630)
        .onChange(of: seconds) { onAutoOffChange() }
        .onChange(of: showCountdown) { onDisplayChange() }
    }
}

struct ShortcutRow: View {
    let title: String
    let name: String
    @AppStorage private var key: Int
    @AppStorage private var mods: Int
    @AppStorage private var label: String
    @State private var recording = false
    @State private var monitor: Any?

    init(title: String, name: String) {
        self.title = title
        self.name = name
        _key = AppStorage(wrappedValue: hotkeyDefaults[name]!.key, "hk.\(name).key")
        _mods = AppStorage(wrappedValue: hotkeyDefaultMods, "hk.\(name).mods")
        _label = AppStorage(wrappedValue: hotkeyDefaults[name]!.label, "hk.\(name).label")
    }

    private var isDefault: Bool { key == hotkeyDefaults[name]!.key && mods == hotkeyDefaultMods }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Button(recording ? "Press shortcut…" : (key < 0 ? "None" : label)) { recording ? stop() : start() }
                    .frame(minWidth: 100)
                if !isDefault {
                    Button { reset() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless).help("Restore default")
                }
                if key >= 0 {
                    Button { key = -1 } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Remove shortcut")
                }
            }
        }
        .onDisappear { stop() }
    }

    private func reset() {
        key = hotkeyDefaults[name]!.key
        mods = hotkeyDefaultMods
        label = hotkeyDefaults[name]!.label
    }

    private func start() {
        recording = true
        recordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if e.keyCode == 53 { stop(); return nil }
            // A global shortcut without ⌘, ⌥ or ⌃ would hijack normal typing
            guard !f.isDisjoint(with: [.command, .option, .control]) else { NSSound.beep(); return nil }
            key = Int(e.keyCode)
            mods = (f.contains(.command) ? cmdKey : 0) | (f.contains(.option) ? optionKey : 0) | (f.contains(.control) ? controlKey : 0) | (f.contains(.shift) ? shiftKey : 0)
            label = shortcutLabel(e)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        recordingShortcut = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

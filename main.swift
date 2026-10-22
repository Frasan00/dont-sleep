import Carbon.HIToolbox
import Cocoa
import ServiceManagement
import IOKit.ps
import SwiftUI
import UserNotifications

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
        // Values come from user defaults, so anything outside the valid ranges is ignored instead of trapping
        let key = UserDefaults.standard.integer(forKey: "hk.\(name).key")
        let mods = UserDefaults.standard.integer(forKey: "hk.\(name).mods") & (cmdKey | optionKey | controlKey | shiftKey)
        guard (0...127).contains(key), mods & (cmdKey | optionKey | controlKey) != 0 else { continue }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x44534C50), id: UInt32(i + 1))
        if RegisterEventHotKey(UInt32(key), UInt32(mods), id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
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
    private var progress: CGFloat = 0
    private var timer: Timer?
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                progress = isOn ? 1 : 0
                needsDisplay = true
                return
            }
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

}

// The whole menu row is the control: clickable anywhere, and exposed to VoiceOver as one checkbox
final class ToggleRow: NSView {
    let pill: Pill
    var onClick: (() -> Void)?

    init(pill: Pill, label: String) {
        self.pill = pill
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        autoresizingMask = .width
        let text = NSTextField(labelWithString: label)
        text.frame = NSRect(x: 14, y: 7, width: 120, height: 18)
        pill.frame.origin = NSPoint(x: frame.width - pill.frame.width - 14, y: (frame.height - pill.frame.height) / 2)
        pill.autoresizingMask = .minXMargin
        addSubview(text)
        addSubview(pill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with e: NSEvent) { onClick?() }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { "Prevent Sleep" }
    override func accessibilityValue() -> Any? { pill.isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

// Accessory apps have no menu bar, but key equivalents such as Cmd+C or Cmd+W are still routed through the main menu
func installMainMenu() {
    let main = NSMenu()
    func add(_ title: String, _ items: [NSMenuItem]) {
        let top = NSMenuItem()
        let sub = NSMenu(title: title)
        items.forEach(sub.addItem)
        top.submenu = sub
        main.addItem(top)
    }
    func item(_ title: String, _ action: Selector, _ key: String, shift: Bool = false) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if shift { i.keyEquivalentModifierMask = [.command, .shift] }
        return i
    }
    add("Dont Sleep", [item("Quit Dont Sleep", #selector(NSApplication.terminate(_:)), "q")])
    add("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", shift: true), .separator(),
                 item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                 item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")])
    add("Window", [item("Close", #selector(NSWindow.performClose(_:)), "w")])
    NSApp.mainMenu = main
}

let autoOffChoices: [(String, Int)] = [("Never", 0), ("15 minutes", 900), ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("4 hours", 14400), ("8 hours", 28800)]
let autoOffUnits: [(String, Int)] = [("Seconds", 1), ("Minutes", 60), ("Hours", 3600), ("Days", 86400)]

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let toggle = Pill(frame: NSRect(x: 0, y: 0, width: 54, height: 28))
    lazy var row = ToggleRow(pill: toggle, label: "Prevent Sleep")
    let defaults = UserDefaults.standard
    var autoOffTimer: Timer?
    var tickTimer: Timer?
    var deadline: Date?
    // A deadline picked from the menu must survive later edits of the auto-off preference
    var manualDeadline = false
    var watchdog: Process?
    var sudoWaitTimer: Timer?
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

        installMainMenu()
        row.onClick = { [unowned self] in toggled() }

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
        menu.addItem(withTitle: "Quit Dont Sleep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        // pkill and similar send SIGTERM, which would otherwise skip applicationWillTerminate
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term

        // disablesleep survives reboots, so the safe default is restoring it
        if defaults.bool(forKey: "resetOnLaunch") && sleepDisabled() == true { setSleepDisabled(false) }
        refresh()
        startPowerMonitor()

        hotkeyActions = [1: { [unowned self] in refresh(); toggled() }, 2: { [unowned self] in keepAwake(seconds: 300, extend: true) }]
        installHotkeyHandler()
        registerHotkeys()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in registerHotkeys() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in checkDeadline() }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [unowned self] _ in checkDeadline() }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func applicationWillTerminate(_ n: Notification) {
        // Restore also when the state is unknown: setting 0 is harmless if sleep was already allowed
        if defaults.bool(forKey: "restoreOnQuit") && sleepDisabled() != false { setSleepDisabled(false) }
        stopWatchdog()
    }

    // Relaunching the app (Launchpad, Spotlight) opens Settings, handy when the icon is hidden by the notch
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func refresh() {
        // An unreadable state keeps what is shown (and the timers) instead of pretending sleep is allowed
        guard let on = sleepDisabled() else { return }
        toggle.isOn = on
        if on { if watchdog?.isRunning != true { armWatchdog() } } else { disarm() }
        let state = on ? "Sleep prevention is on" : "Sleep prevention is off"
        item.button?.image = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "moon.zzz", accessibilityDescription: state)
        item.button?.toolTip = "Dont Sleep: " + state.lowercased()
        item.button?.setAccessibilityLabel("Dont Sleep")
        item.button?.setAccessibilityValue(state)
        NSAccessibility.post(element: row, notification: .valueChanged)
    }

    func toggled() {
        let on = !toggle.isOn
        guard setSleepDisabled(on) else { return reportChangeFailure { self.setPower(on) } }
        refresh()
        if on { armAutoOff() }
    }

    // Idempotent on purpose: a delayed setup retry must never flip a state the user has changed meanwhile
    func setPower(_ on: Bool) {
        refresh()
        if toggle.isOn != on { toggled() }
    }

    // The setup alert is for a missing rule only; any other failure just says so
    func reportChangeFailure(retry: @escaping () -> Void) {
        item.menu?.cancelTracking()
        DispatchQueue.main.async {
            if sudoRuleWorks() {
                let a = NSAlert()
                a.messageText = "Could not change the sleep setting"
                a.informativeText = "macOS did not accept the change. Try again in a moment."
                NSApp.activate(ignoringOtherApps: true)
                a.runModal()
            } else {
                self.showSetupAlert(retry: retry)
            }
        }
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
                        if sudoRuleWorks() { self.sudoWaitTimer?.invalidate(); self.sudoWaitTimer = nil; retry() } else { self.showSetupAlert(retry: retry, nativeFailed: true) }
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

        // Must happen while the sudoers rule still exists, and must not be skipped silently
        if !setSleepDisabled(false) && sleepDisabled() != false {
            let a = NSAlert()
            a.messageText = "Could not restore normal sleep"
            a.informativeText = "Uninstall was cancelled so the Mac is not left unable to sleep. Turn sleep prevention off first, then try again."
            a.runModal()
            return
        }
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
        stopWatchdog()
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

    // One poller at a time, capped at two minutes: stale ones must not fire a late retry
    func waitForSudoRule(_ then: @escaping () -> Void) {
        sudoWaitTimer?.invalidate()
        var tries = 0
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] t in
            tries += 1
            if sudoRuleWorks() {
                t.invalidate()
                self?.sudoWaitTimer = nil
                then()
            } else if tries >= 60 {
                t.invalidate()
                self?.sudoWaitTimer = nil
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        sudoWaitTimer = t
    }

    func autoTurnOff(_ reason: String) {
        let ok = setSleepDisabled(false)
        refresh()
        if !ok && sleepDisabled() != false {
            // Never claim success: the laptop is still awake. Stop the countdown, which would sit at 0:00 forever.
            disarm()
            notify("Could not restore normal sleep. Open Dont Sleep and turn it off.", force: true)
            return
        }
        notify("Sleep restored: \(reason)")
    }

    func notify(_ body: String, force: Bool = false) {
        guard force || defaults.bool(forKey: "notifyAutoOff") else { return }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "Dont Sleep"
            content.body = body
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
        guard onBattery, sleepDisabled() == true else { return }
        if justUnplugged && defaults.bool(forKey: "offWhenUnplugged") {
            autoTurnOff("power adapter unplugged")
        } else if defaults.bool(forKey: "lowBatteryOff") && percent <= min(max(defaults.integer(forKey: "lowBatteryPercent"), 5), 90) {
            autoTurnOff("battery at \(percent)%")
        }
    }

    func disarm() {
        autoOffTimer?.invalidate()
        deadline = nil
        manualDeadline = false
        updateCountdown()
        stopWatchdog()
    }

    func stopWatchdog() {
        watchdog?.terminate()
        watchdog = nil
    }

    // Detached helper that restores normal sleep if this process dies (crash, kill -9) or hangs past the deadline,
    // so a laptop is never left awake in a bag. It compares the parent start time to survive pid reuse.
    func armWatchdog() {
        stopWatchdog()
        guard defaults.bool(forKey: "restoreOnQuit"), toggle.isOn else { return }
        let until = deadline.map { Int($0.timeIntervalSince1970) + 20 } ?? 9_999_999_999
        let script = "PATH=/usr/bin:/bin:/usr/sbin:/sbin; s=$(ps -p \"$1\" -o lstart= 2>/dev/null); while [ -n \"$s\" ] && [ \"$(ps -p \"$1\" -o lstart= 2>/dev/null)\" = \"$s\" ] && [ \"$(date +%s)\" -lt \"$2\" ]; do sleep 10; done; sudo -n /usr/bin/pmset -a disablesleep 0"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(getpid()), String(until)]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil { watchdog = p }
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
            timer.tolerance = r > 3600 ? 1 : 0.1
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
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        autoOffTimer = t
        armWatchdog()
    }

    // The timer follows a clock that stops while the Mac sleeps, and the user can change the wall clock
    func checkDeadline() {
        refresh()
        guard let d = deadline else { return }
        if d <= Date() { autoTurnOff("auto-off timer elapsed") } else { schedule(until: d) }
    }

    func armAutoOff() {
        disarm()
        let seconds = min(max(defaults.integer(forKey: "autoOffSeconds"), 0), maxAutoOffSeconds)
        guard seconds > 0, toggle.isOn else { return }
        schedule(until: Date().addingTimeInterval(TimeInterval(seconds)))
    }

    // Turns sleep prevention on if needed; extending adds to the running countdown instead of restarting it
    func keepAwake(seconds: Int, extend: Bool) {
        refresh()
        if !toggle.isOn {
            guard setSleepDisabled(true) else { return reportChangeFailure { self.keepAwake(seconds: seconds, extend: extend) } }
            refresh()
        }
        // A deadline already in the past (Mac slept through it) must not be extended from the past
        let base = extend ? max(deadline ?? Date(), Date()) : Date()
        manualDeadline = true
        schedule(until: base.addingTimeInterval(TimeInterval(seconds)))
    }

    @objc func keepOneHour() { keepAwake(seconds: 3600, extend: false) }
    @objc func keepTwoHours() { keepAwake(seconds: 7200, extend: false) }
    @objc func addThirty() { keepAwake(seconds: 1800, extend: true) }
    @objc func addFive() { keepAwake(seconds: 300, extend: true) }

    @objc func openSettings() {
        // center() uses NSScreen.main, which can be a different display than the one the user is looking at
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        // Leave room for the title bar so the window always fits and the form scrolls instead of clipping
        let view = SettingsView(maxHeight: visible.height - 56,
                                onAutoOffChange: { [weak self] in if self?.manualDeadline != true { self?.armAutoOff() } },
                                onDisplayChange: { [weak self] in self?.updateCountdown() })
        if settingsWindow == nil {
            let w = SettingsWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Dont Sleep Settings"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            // Drop the SwiftUI view tree when closed; it is rebuilt on every open anyway
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak w] _ in w?.contentViewController = nil }
            settingsWindow = w
        }
        // Fresh view each time so the login item state is re-read
        settingsWindow?.contentViewController = NSHostingController(rootView: view)
        if let w = settingsWindow {
            let x = min(max(visible.midX - w.frame.width / 2, visible.minX), visible.maxX - w.frame.width)
            let y = min(max(visible.midY - w.frame.height / 2, visible.minY), visible.maxY - w.frame.height)
            w.setFrameOrigin(NSPoint(x: x, y: y))
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
    let maxHeight: CGFloat
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

    // The preference can hold anything, and a typed value can be huge: keep every product far from Int overflow
    private var safeUnit: Int { autoOffUnits.contains { $0.1 == unit } ? unit : 60 }

    private var amountBinding: Binding<Int> {
        Binding(get: { seconds / safeUnit }, set: { seconds = min(max(1, $0), 100_000) * safeUnit })
    }

    private var unitBinding: Binding<Int> {
        Binding(get: { safeUnit }, set: { u in
            let amount = min(max(1, seconds / safeUnit), 100_000)
            unit = u
            seconds = amount * u
        })
    }

    private var desiredHeight: CGFloat { (custom ? 110 : 0) + (lowBatteryOff ? 44 : 0) + 630 }

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
        .scrollDisabled(desiredHeight <= maxHeight)
        .frame(width: 400, height: min(desiredHeight, maxHeight))
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

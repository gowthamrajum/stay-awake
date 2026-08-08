// Stay Awake — a menu bar switch for macOS sleep.
//
// The whole app is a thin, well-behaved front end for /usr/bin/caffeinate.
// caffeinate holds a real IOKit power assertion for as long as it is alive, so
// "keep the Mac awake for 2 hours" is just `caffeinate -i -s -d -t 7200` and
// "let it sleep again" is killing that process. No private API, no kext, no
// daemon — quit the app and the assertion dies with it.
//
// The one piece of state that is *not* ours is an external caffeinate: a
// `caffeinate` someone started in a terminal, or one left behind by another
// utility. We detect those with pgrep so the menu tells the truth ("something
// is holding this Mac awake") instead of claiming sleep is allowed.

import AppKit
import ServiceManagement

// MARK: - Constants

private enum K {
    /// Presets offered in the menu, and (abbreviated) on the window's button row.
    static let presets: [(title: String, short: String, minutes: Int)] = [
        ("15 minutes", "15m", 15),
        ("30 minutes", "30m", 30),
        ("1 hour", "1h", 60),
        ("2 hours", "2h", 120),
        ("4 hours", "4h", 240),
        ("8 hours", "8h", 480),
    ]

    static let caffeinate = "/usr/bin/caffeinate"
    static let pgrep = "/usr/bin/pgrep"
    static let pkill = "/usr/bin/pkill"

    /// Formats accepted by the "Until a time…" prompt, tried in order.
    static let timeFormats = ["h:mm a", "h:mma", "ha", "h a", "H:mm"]
    static let timeHint = "5:30 PM or 17:30"
}

// MARK: - Controller

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {

    // Status bar
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusItemLabel: NSMenuItem!
    private var displaySleepCheck: NSMenuItem!
    private var loginCheck: NSMenuItem!

    // Optional window (⌘-free quick panel, opened from the menu)
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var hoursField: NSTextField?
    private var turnOffButton: NSButton?

    // State
    private var task: Process?
    private var endDate: Date?
    private var indefinite = false
    private var externalActive = false
    private var allowDisplaySleep = false
    private var ticker: Timer?

    /// True when *we* are holding the Mac awake.
    private var ours: Bool { indefinite || endDate != nil }

    /// True when anything at all is holding the Mac awake.
    private var awake: Bool { ours || externalActive }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement already keeps us out of the Dock; .accessory lets the
        // optional window come forward without ever adding a Dock tile.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        buildMenu()
        menu.delegate = self

        // One second is plenty: the only thing the tick does is recompute a
        // countdown string and notice when caffeinate has gone away.
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Only our own assertion — an external caffeinate is not ours to kill.
        task?.terminate()
    }

    // MARK: Menu

    private func buildMenu() {
        menu.removeAllItems()

        statusItemLabel = NSMenuItem(title: "Sleep allowed", action: nil, keyEquivalent: "")
        statusItemLabel.isEnabled = false
        menu.addItem(statusItemLabel)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Keep awake for:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for preset in K.presets {
            let item = NSMenuItem(title: preset.title, action: #selector(presetAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = preset.minutes
            menu.addItem(item)
        }

        let until = NSMenuItem(title: "Until a time…", action: #selector(untilTime), keyEquivalent: "")
        until.target = self
        menu.addItem(until)

        let forever = NSMenuItem(title: "Indefinitely", action: #selector(startIndefinite), keyEquivalent: "")
        forever.target = self
        menu.addItem(forever)

        menu.addItem(.separator())

        let add15Item = NSMenuItem(title: "Add 15 minutes", action: #selector(add15), keyEquivalent: "")
        add15Item.target = self
        menu.addItem(add15Item)

        let add60Item = NSMenuItem(title: "Add 1 hour", action: #selector(add60), keyEquivalent: "")
        add60Item.target = self
        menu.addItem(add60Item)

        let off = NSMenuItem(title: "Turn Off (allow sleep)", action: #selector(turnOff), keyEquivalent: "")
        off.target = self
        menu.addItem(off)

        menu.addItem(.separator())

        displaySleepCheck = NSMenuItem(title: "Allow display to sleep",
                                       action: #selector(toggleDisplaySleep),
                                       keyEquivalent: "")
        displaySleepCheck.target = self
        menu.addItem(displaySleepCheck)

        loginCheck = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginCheck.target = self
        menu.addItem(loginCheck)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Window", action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: "Quit Stay Awake", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Left click drops the menu; right- or control-click is a fast on/off so
    /// the common case never needs a second click.
    @objc private func handleClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
        let isControl = event?.modifierFlags.contains(.control) ?? false

        if isRight || isControl {
            if awake { turnOff() } else { startIndefinite() }
            return
        }

        // The menu is attached only for the duration of the click, otherwise
        // AppKit swallows the button action entirely and handleClick never runs.
        refreshMenuState()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenuState()
    }

    private func refreshMenuState() {
        statusItemLabel.title = statusText()
        displaySleepCheck.state = allowDisplaySleep ? .on : .off
        loginCheck.state = loginEnabled ? .on : .off
    }

    // MARK: Actions

    @objc private func presetAction(_ sender: NSMenuItem) {
        start(seconds: TimeInterval(sender.tag * 60))
    }

    @objc private func startIndefinite() {
        start(seconds: nil)
    }

    @objc private func add15() {
        extend(by: 15 * 60)
    }

    @objc private func add60() {
        extend(by: 60 * 60)
    }

    @objc private func turnOff() {
        stop(killExternal: true)
        refresh()
    }

    @objc private func toggleDisplaySleep() {
        allowDisplaySleep.toggle()
        // The flag is baked into caffeinate's arguments, so an active assertion
        // has to be relaunched for the change to mean anything.
        if ours {
            let remaining = endDate.map { max(0, $0.timeIntervalSinceNow) }
            start(seconds: indefinite ? nil : remaining)
        }
        refresh()
    }

    @objc private func openWindow() {
        if window == nil { buildWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Timed prompts

    @objc private func untilTime() {
        let alert = NSAlert()
        alert.messageText = "Keep awake until what time?"
        alert.informativeText = "e.g. \(K.timeHint)"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. \(K.timeHint)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let date = parseTime(field.stringValue) else {
            warn("Couldn't read that time.", "Try formats like \(K.timeHint).")
            return
        }
        start(seconds: date.timeIntervalSinceNow)
    }

    /// Parses a bare time-of-day against today, rolling to tomorrow when the
    /// time has already passed — "keep awake until 6 AM" at midnight means the
    /// coming 6 AM, not one eighteen hours in the past.
    private func parseTime(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        for format in K.timeFormats {
            formatter.dateFormat = format
            guard let parsed = formatter.date(from: text) else { continue }

            let calendar = Calendar.current
            let time = calendar.dateComponents([.hour, .minute], from: parsed)
            let now = Date()
            guard var candidate = calendar.date(bySettingHour: time.hour ?? 0,
                                                minute: time.minute ?? 0,
                                                second: 0,
                                                of: now) else { continue }
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            return candidate
        }
        return nil
    }

    // MARK: caffeinate

    /// Starts (or restarts) the assertion. `seconds == nil` means indefinite.
    private func start(seconds: TimeInterval?) {
        // Replaces our own assertion only. A caffeinate someone else started is
        // left alone here — picking a duration is not a request to cancel other
        // people's work, and "Turn Off" is where that decision belongs.
        stop(killExternal: false)

        // -d display, -i idle, -s system-on-AC. Dropping -d is exactly what
        // "Allow display to sleep" does: the Mac stays up, the screen may dim.
        var args: [String] = []
        if !allowDisplaySleep { args.append("-d") }
        args += ["-i", "-s"]

        var deadline: Date?
        if let seconds {
            let whole = max(1, Int(seconds.rounded()))
            args += ["-t", String(whole)]
            deadline = Date().addingTimeInterval(TimeInterval(whole))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: K.caffeinate)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // caffeinate exits on its own when -t elapses. That termination is the
        // authoritative "time is up" signal, so clearing state here is what
        // flips the icon back rather than leaving a stale countdown on screen.
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.task === finished else { return }
                self.clearState()
                self.refresh()
            }
        }

        do {
            try process.run()
        } catch {
            warn("Couldn't start caffeinate.", error.localizedDescription)
            return
        }

        task = process
        endDate = deadline
        indefinite = (seconds == nil)
        refresh()
    }

    /// Adds time to a running assertion, or starts one if nothing is running.
    private func extend(by seconds: TimeInterval) {
        if indefinite { return }                     // already unbounded
        let base = endDate.map { max(0, $0.timeIntervalSinceNow) } ?? 0
        start(seconds: base + seconds)
    }

    private func stop(killExternal: Bool) {
        if let task, task.isRunning {
            // Drop the handler first: this termination is deliberate, and the
            // handler would otherwise race the fresh state we are about to set.
            task.terminationHandler = nil
            task.terminate()
        }
        task = nil

        // "Turn Off" promises sleep is allowed, which is a lie while anyone
        // else's caffeinate is still up — so that path clears those too.
        if killExternal && externalActive { run(K.pkill, ["-x", "caffeinate"]) }

        clearState()
    }

    private func clearState() {
        task = nil
        endDate = nil
        indefinite = false
    }

    // MARK: Refresh

    private func refresh() {
        // Belt and braces for the termination handler. If caffeinate is killed
        // from outside, or the handler is ever missed, the elapsed deadline
        // still resolves here — the countdown can never stick at "<1m".
        if let deadline = endDate, Date() >= deadline {
            clearState()
        }
        if ours && !indefinite && task?.isRunning != true {
            clearState()
        }

        externalActive = !ours && caffeinateRunning()

        // Filled bulb = lit = something is holding this Mac awake. The outline
        // is the same shape unlit, so the state reads at a glance without
        // needing the countdown text beside it.
        let symbol = awake ? "lightbulb.fill" : "lightbulb"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Stay Awake")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = titleText()

        let text = statusText()
        statusItemLabel?.title = text
        statusLabel?.stringValue = text
        turnOffButton?.isEnabled = awake
    }

    private func caffeinateRunning() -> Bool {
        !run(K.pgrep, ["-x", "caffeinate"]).isEmpty
    }

    private func statusText() -> String {
        if indefinite { return "Awake — no time limit" }
        if let deadline = endDate {
            return "Awake — \(remainingText(until: deadline)) left (until \(clockText(deadline)))"
        }
        if externalActive { return "Awake — external timer (time unknown)" }
        return "Sleep allowed"
    }

    /// "<1m", "45m", "4:46" — minutes on their own below an hour, h:mm above.
    private func remainingText(until deadline: Date) -> String {
        let seconds = Int(max(0, deadline.timeIntervalSinceNow))
        if seconds < 60 { return "<1m" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours == 0 { return "\(minutes)m" }
        return "\(hours):" + String(format: "%02d", minutes)
    }

    /// The countdown drawn beside the menu bar icon. Empty unless a timed
    /// assertion is running — an indefinite hold is just the filled cup.
    private func titleText() -> String {
        guard !indefinite, let deadline = endDate else { return "" }
        return " " + remainingText(until: deadline)
    }

    private func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    // MARK: Window

    private func buildWindow() {
        let label = NSTextField(labelWithString: statusText())
        label.font = NSFont.boldSystemFont(ofSize: 13)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        statusLabel = label

        let row = NSStackView(views: K.presets.map { preset in
            let button = NSButton(title: preset.short, target: self, action: #selector(presetButton(_:)))
            button.bezelStyle = .rounded
            button.tag = preset.minutes
            return button
        })
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 6

        let field = NSTextField(frame: .zero)
        field.placeholderString = "hours"
        field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        hoursField = field

        let start = NSButton(title: "Start", target: self, action: #selector(startFromField))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"           // Return commits the hours field

        let custom = NSStackView(views: [field, start])
        custom.orientation = .horizontal
        custom.spacing = 6

        let off = NSButton(title: "Turn Off (allow sleep)", target: self, action: #selector(turnOff))
        off.bezelStyle = .rounded
        turnOffButton = off

        let stack = NSStackView(views: [label, row, custom, off])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let rowWidth = max(row.fittingSize.width, 300)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: rowWidth + 32, height: 160))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])

        let win = NSWindow(contentRect: content.frame,
                           styleMask: [.titled, .closable],
                           backing: .buffered,
                           defer: false)
        win.title = "Stay Awake"
        win.contentView = content
        win.isReleasedWhenClosed = false      // reopened from the menu, not rebuilt
        win.center()
        window = win
    }

    @objc private func presetButton(_ sender: NSButton) {
        start(seconds: TimeInterval(sender.tag * 60))
    }

    @objc private func startFromField() {
        let raw = (hoursField?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        guard let hours = Double(raw), hours > 0 else {
            warn("Please enter a number of hours, e.g. 2 or 1.5.", "")
            return
        }
        start(seconds: hours * 3600)
    }

    // MARK: Launch at Login

    private var loginEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else {
            warn("Launch at Login needs macOS 13 or later.", "")
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            warn("Couldn't change the Login Item setting:", error.localizedDescription)
        }
        refreshMenuState()
    }

    // MARK: Helpers

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func warn(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()

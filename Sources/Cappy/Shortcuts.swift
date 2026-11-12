import AppKit
import Carbon.HIToolbox

/// A global key combination.
struct Shortcut: Codable, Equatable {
    var keyCode: Int
    /// Carbon modifier flags (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: Int
    /// The key as shown to the user, e.g. "A" or "F5".
    var key: String

    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// ⌃⌥⇧⌘ in the standard macOS order, then the key.
    var display: String {
        var out = ""
        if modifiers & controlKey != 0 { out += "⌃" }
        if modifiers & optionKey != 0 { out += "⌥" }
        if modifiers & shiftKey != 0 { out += "⇧" }
        if modifiers & cmdKey != 0 { out += "⌘" }
        return out + key
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & controlKey != 0 { flags.insert(.control) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        return flags
    }

    /// Key equivalent for showing the shortcut in a menu; nil for keys a menu cannot show.
    var menuKeyEquivalent: String? {
        key.count == 1 ? key.lowercased() : nil
    }

    /// Builds a shortcut from a key press. Needs ⌘, ⌃ or ⌥ so that plain
    /// typing can never trigger a capture.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var carbon = 0
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.command) { carbon |= cmdKey }
        guard carbon & (controlKey | optionKey | cmdKey) != 0 else { return nil }
        let code = Int(event.keyCode)
        let name: String
        if let special = Shortcut.special[code] {
            name = special
        } else if let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0xF700 }) {
            name = characters.uppercased()
        } else {
            return nil
        }
        self.init(keyCode: code, modifiers: carbon, key: name)
    }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// Per-mode shortcuts, stored in the user defaults.
enum ShortcutStore {
    /// ⌃⌥ with the left hand's home row: reachable with one hand, and clear
    /// of the system's ⌘⇧3/4/5 and of WeChat's ⌃⌘A.
    static func defaultShortcut(for mode: CaptureMode) -> Shortcut {
        let keys: [(Int, String)] = [(kVK_ANSI_A, "A"), (kVK_ANSI_S, "S"), (kVK_ANSI_D, "D"), (kVK_ANSI_F, "F")]
        let (code, key) = keys[mode.rawValue]
        return Shortcut(keyCode: code, modifiers: controlKey | optionKey, key: key)
    }

    private static func defaultsKey(_ mode: CaptureMode) -> String { "shortcut.v2.\(mode.rawValue)" }

    /// nil = the user removed the shortcut for this mode.
    static func shortcut(for mode: CaptureMode, in defaults: UserDefaults = .standard) -> Shortcut? {
        guard let data = defaults.data(forKey: defaultsKey(mode)) else { return defaultShortcut(for: mode) }
        return try? JSONDecoder().decode(Shortcut?.self, from: data)
    }

    static func set(_ shortcut: Shortcut?, for mode: CaptureMode, in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: defaultsKey(mode))
    }

    static func resetAll(in defaults: UserDefaults = .standard) {
        for mode in CaptureMode.allCases { defaults.removeObject(forKey: defaultsKey(mode)) }
    }
}

/// A button that shows a shortcut and records a new one when clicked.
final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut? { didSet { refreshTitle() } }
    var onChange: (Shortcut?) -> Void = { _ in }
    /// Called when recording starts / ends, so global hot keys can be paused.
    var onRecording: (Bool) -> Void = { _ in }
    private var monitor: Any?

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var recording: Bool { monitor != nil }

    private func refreshTitle() {
        title = recording ? "请按下快捷键…" : (shortcut?.display ?? "未设置")
    }

    @objc private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil
        }
        refreshTitle()
    }

    func stopRecording() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
        refreshTitle()
        onRecording(false)
    }

    /// Esc cancels, Delete removes the shortcut, anything with ⌘/⌃/⌥ sets it.
    func handle(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if plain, event.keyCode == kVK_Escape {
            stopRecording()
        } else if plain, event.keyCode == kVK_Delete || event.keyCode == kVK_ForwardDelete {
            shortcut = nil
            stopRecording()
            onChange(nil)
        } else if let new = Shortcut(event: event) {
            shortcut = new
            stopRecording()
            onChange(new)
        } else {
            NSSound.beep()
        }
    }
}

final class ShortcutSettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Called after any change so hot keys and menus can be refreshed.
    var onChange: () -> Void = {}
    /// Pauses / resumes global hot keys while a shortcut is being recorded.
    var onRecording: (Bool) -> Void = { _ in }
    private var buttons: [CaptureMode: ShortcutRecorderButton] = [:]

    init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 360, height: 250),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Cappy 快捷键"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        var rows: [[NSView]] = []
        for mode in CaptureMode.allCases {
            let label = NSTextField(labelWithString: mode.title)
            let button = ShortcutRecorderButton()
            button.shortcut = ShortcutStore.shortcut(for: mode)
            button.onRecording = { [weak self] recording in self?.onRecording(recording) }
            button.onChange = { [weak self] shortcut in self?.changed(mode, to: shortcut) }
            button.widthAnchor.constraint(equalToConstant: 150).isActive = true
            buttons[mode] = button
            rows.append([label, button])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing

        let hint = NSTextField(wrappingLabelWithString: "点击按钮后按下新的组合键（需包含 ⌘、⌃ 或 ⌥）。Esc 取消，Delete 清除。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let reset = NSButton(title: "恢复默认", target: self, action: #selector(resetDefaults))

        let stack = NSStackView(views: [grid, hint, reset])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        hint.widthAnchor.constraint(equalToConstant: 300).isActive = true
        window.contentView = stack
        window.setContentSize(stack.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func changed(_ mode: CaptureMode, to shortcut: Shortcut?) {
        // A combination can belong to one mode only: taking it clears the other.
        if let shortcut {
            for other in CaptureMode.allCases where other != mode && ShortcutStore.shortcut(for: other) == shortcut {
                ShortcutStore.set(nil, for: other)
                buttons[other]?.shortcut = nil
            }
        }
        ShortcutStore.set(shortcut, for: mode)
        onChange()
    }

    @objc private func resetDefaults() {
        ShortcutStore.resetAll()
        for (mode, button) in buttons { button.shortcut = ShortcutStore.shortcut(for: mode) }
        onChange()
    }

    func windowWillClose(_ notification: Notification) {
        buttons.values.forEach { $0.stopRecording() }
    }
}

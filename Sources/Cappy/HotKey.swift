import AppKit
import Carbon.HIToolbox

/// System-wide hot keys via Carbon (needs no accessibility permission).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false
    private var nextID: UInt32 = 0

    /// Returns false when the combination is already taken by another app.
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        install()
        nextID += 1
        let id = nextID
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4341_5059), id: id) // "CAPY"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }
        handlers[id] = handler
        refs.append(ref)
        return true
    }

    /// Drops every registered hot key (before re-registering changed shortcuts).
    func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        handlers.removeAll()
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if status == noErr { HotKeyCenter.shared.fire(hotKeyID.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        handlers[id]?()
    }
}

/// A small transient message near the top of the screen.
enum Toast {
    private static var panel: NSPanel?
    private static var token = 0

    static func show(_ message: String) {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 36, height: 36)
        let screen = NSScreen.underMouse
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        let background = NSView(frame: CGRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
        background.layer?.cornerRadius = size.height / 2
        label.frame.origin = CGPoint(x: 18, y: (size.height - label.frame.height) / 2)
        background.addSubview(label)
        p.contentView = background
        p.orderFrontRegardless()
        panel = p
        token += 1
        let current = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if token == current {
                panel?.orderOut(nil)
                panel = nil
            }
        }
    }
}

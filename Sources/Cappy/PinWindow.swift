import AppKit

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A screenshot floating above every window. Click it to focus (an accent
/// outline shows it has the keyboard), drag it to move, Esc to dismiss,
/// double-click to go back to the editor, scroll to resize while focused.
final class PinView: NSView {
    let image: CGImage
    let scale: CGFloat
    var onClose: () -> Void = {}
    /// Reopens the editor for this image; nil when there is nothing to edit.
    var onEdit: (() -> Void)?

    init(image: CGImage, scale: CGFloat, frame: CGRect) {
        self.image = image
        self.scale = scale
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: name, object: window)
        }
    }

    @objc private func focusChanged() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.drawFlipped(image, in: bounds)
        if window?.isKeyWindow == true {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(bounds.insetBy(dx: 1, dy: 1))
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount == 2, let onEdit {
            onClose()
            onEdit()
        } else {
            window?.performDrag(with: event)
        }
    }

    /// Wheel / trackpad scrolling resizes the focused pin around the pointer.
    override func scrollWheel(with event: NSEvent) {
        guard let window, window.isKeyWindow, event.scrollingDeltaY != 0 else { return }
        let factor = event.hasPreciseScrollingDeltas
            ? exp(event.scrollingDeltaY * 0.01)
            : pow(1.1, max(-4, min(4, event.scrollingDeltaY)))
        zoom(by: factor, around: NSEvent.mouseLocation)
    }

    /// Resizes the window, keeping the image point under `anchor` (global
    /// coordinates) in place. The size stays between 20% and 800% of the image.
    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        guard let window else { return }
        let old = window.frame
        let natural = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let lower = max(natural.width * 0.2, min(48, natural.width)), upper = natural.width * 8
        let width = max(lower, min(upper, old.width * factor)).rounded()
        let height = (width * natural.height / natural.width).rounded()
        let fx = old.width > 0 ? (anchor.x - old.minX) / old.width : 0.5
        let fy = old.height > 0 ? (anchor.y - old.minY) / old.height : 0.5
        window.setFrame(CGRect(x: anchor.x - fx * width, y: anchor.y - fy * height, width: width, height: height),
                        display: true)
        window.invalidateShadow()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose() } else { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if onEdit != nil {
            menu.addItem(withTitle: "回到编辑", action: #selector(editImage), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "复制", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "取消悬浮", action: #selector(closePin), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        guard let png = Bitmap.pngData(image, scale: scale) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    @objc private func closePin() { onClose() }

    @objc private func editImage() {
        onClose()
        onEdit?()
    }
}

enum PinManager {
    private(set) static var panels: [NSPanel] = []

    /// Floats `image` on screen, centered on `anchor` (global AppKit coordinates).
    @discardableResult
    static func pin(_ image: CGImage, scale: CGFloat, centeredOn anchor: CGPoint? = nil,
                    onEdit: (() -> Void)? = nil) -> NSPanel {
        let screen = anchor.flatMap { p in NSScreen.screens.first { $0.frame.contains(p) } } ?? NSScreen.underMouse
        let visible = screen.visibleFrame
        var size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        // Keep very large captures on screen.
        let fit = min(1, visible.width * 0.9 / size.width, visible.height * 0.9 / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())

        let center = anchor ?? CGPoint(x: visible.midX, y: visible.midY)
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        origin.x = max(visible.minX, min(visible.maxX - size.width, origin.x))
        origin.y = max(visible.minY, min(visible.maxY - size.height, origin.y))

        let panel = PinPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating // after isFloatingPanel, which resets the level
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let view = PinView(image: image, scale: scale, frame: CGRect(origin: .zero, size: size))
        view.onClose = { [weak panel] in
            guard let panel else { return }
            panel.orderOut(nil)
            panels.removeAll { $0 === panel }
        }
        view.onEdit = onEdit
        panel.contentView = view
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)
        panels.append(panel)
        return panel
    }
}

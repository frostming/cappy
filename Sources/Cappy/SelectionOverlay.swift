import AppKit

enum OverlayMode {
    case region, window
}

enum OverlayResult {
    /// `rect` is in points relative to the screen's top-left corner.
    case region(screen: NSScreen, rect: CGRect, shot: Shot)
    /// `fallback` is the window's area cropped from the frozen screen.
    case window(WindowInfo, fallback: Shot)
    case cancelled
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Freezes every display behind a full-screen panel and lets the user drag
/// out a region or pick a window.
final class SelectionOverlayController {
    private(set) var mode: OverlayMode
    let allowsWindowToggle: Bool
    let regionHint: String
    private var panels: [NSPanel] = []
    private var views: [OverlayView] = []
    private let completion: (OverlayResult) -> Void
    private var finished = false

    init(shots: [(screen: NSScreen, shot: Shot)], windows: [WindowInfo], mode: OverlayMode,
         allowsWindowToggle: Bool, regionHint: String, completion: @escaping (OverlayResult) -> Void) {
        self.mode = mode
        self.allowsWindowToggle = allowsWindowToggle
        self.regionHint = regionHint
        self.completion = completion

        for (screen, shot) in shots {
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = false
            panel.acceptsMouseMovedEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false

            let origin = CGDisplayBounds(screen.displayID).origin
            let local = windows.map {
                WindowInfo(id: $0.id, frame: $0.frame.offsetBy(dx: -origin.x, dy: -origin.y))
            }
            let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size),
                                   screen: screen, shot: shot, windows: local, controller: self)
            panel.contentView = view
            panel.setFrame(screen.frame, display: false)
            panels.append(panel)
            views.append(view)
        }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        for panel in panels { panel.orderFrontRegardless() }
        let key = panels.first { $0.frame.contains(mouse) } ?? panels.first
        key?.makeKeyAndOrderFront(nil)
        if let view = key?.contentView { key?.makeFirstResponder(view) }
    }

    func toggleMode() {
        guard allowsWindowToggle else { return }
        mode = mode == .region ? .window : .region
        views.forEach { $0.modeChanged() }
    }

    func finish(_ result: OverlayResult) {
        guard !finished else { return }
        finished = true
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        completion(result)
    }
}

private final class OverlayView: NSView {
    private let screen: NSScreen
    private let shot: Shot
    private let windows: [WindowInfo]
    private weak var controller: SelectionOverlayController?

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hover: WindowInfo?

    init(frame: CGRect, screen: NSScreen, shot: Shot, windows: [WindowInfo], controller: SelectionOverlayController) {
        self.screen = screen
        self.shot = shot
        self.windows = windows
        self.controller = controller
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var mode: OverlayMode { controller?.mode ?? .region }

    func modeChanged() {
        dragStart = nil
        selection = nil
        hover = nil
        if mode == .window, let window {
            updateHover(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.interpolationQuality = .high
        ctx.drawFlipped(shot.image, in: bounds)

        let hole: CGRect? = mode == .window ? hover?.frame.intersection(bounds) : selection
        ctx.saveGState()
        ctx.addRect(bounds)
        if let hole, !hole.isEmpty { ctx.addRect(hole) }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.42))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        if let hole, !hole.isEmpty {
            if mode == .window {
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(2)
                ctx.stroke(hole.insetBy(dx: 1, dy: 1))
            } else {
                ctx.setStrokeColor(.white)
                ctx.setLineWidth(1)
                ctx.stroke(hole.insetBy(dx: -0.5, dy: -0.5))
                drawSizeLabel(for: hole)
            }
        }

        if dragStart == nil { drawHint() }
    }

    private func drawBadge(_ text: String, fontSize: CGFloat, position: (CGSize) -> CGPoint) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let textSize = attributed.size()
        let size = CGSize(width: textSize.width + 16, height: textSize.height + 8)
        let rect = CGRect(origin: position(size), size: size)
        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        attributed.draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 4))
    }

    private func drawSizeLabel(for rect: CGRect) {
        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        drawBadge(text, fontSize: 11) { size in
            var y = rect.maxY + 6
            if y + size.height > self.bounds.maxY - 4 { y = rect.maxY - size.height - 6 }
            return CGPoint(x: max(4, rect.maxX - size.width), y: y)
        }
    }

    private func drawHint() {
        guard let controller else { return }
        var text: String
        if mode == .window {
            text = "点击选择窗口"
            if controller.allowsWindowToggle { text += " · 空格 切换到区域" }
        } else {
            text = controller.regionHint
            if controller.allowsWindowToggle { text += " · 空格 切换到窗口" }
        }
        text += " · Esc 取消"
        drawBadge(text, fontSize: 13) { size in
            CGPoint(x: self.bounds.midX - size.width / 2, y: 64)
        }
    }

    // MARK: Events

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseExited(with event: NSEvent) {
        if hover != nil {
            hover = nil
            needsDisplay = true
        }
    }

    private func updateHover(_ p: CGPoint) {
        let hit = bounds.contains(p) ? windows.first { $0.frame.contains(p) } : nil
        if hit?.id != hover?.id {
            hover = hit
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        if mode == .window { updateHover(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if mode == .window {
            updateHover(p)
        } else {
            dragStart = p
            selection = nil
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, let start = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        p.x = max(0, min(bounds.width, p.x))
        p.y = max(0, min(bounds.height, p.y))
        selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                           width: abs(p.x - start.x), height: abs(p.y - start.y)).integral
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if mode == .window {
            guard let info = hover else { return }
            let rect = info.frame.intersection(bounds).integral
            guard let image = crop(rect) else { return }
            controller?.finish(.window(info, fallback: Shot(image: image, scale: shot.scale)))
            return
        }
        defer {
            dragStart = nil
            needsDisplay = true
        }
        guard let rect = selection, rect.width >= 4, rect.height >= 4, let image = crop(rect) else {
            selection = nil
            return
        }
        controller?.finish(.region(screen: screen, rect: rect, shot: Shot(image: image, scale: shot.scale)))
    }

    private func crop(_ rect: CGRect) -> CGImage? {
        let sx = CGFloat(shot.image.width) / bounds.width, sy = CGFloat(shot.image.height) / bounds.height
        let pixels = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).integral
        return shot.image.cropping(to: pixels)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: controller?.finish(.cancelled) // esc
        case 49: controller?.toggleMode() // space
        default: break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.finish(.cancelled)
    }
}

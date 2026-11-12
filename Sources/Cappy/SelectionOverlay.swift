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
    /// The app that was frontmost before the overlay took over.
    private(set) var previousApp: NSRunningApplication?

    init(shots: [(screen: NSScreen, shot: Shot)], windows: [WindowInfo], mode: OverlayMode,
         allowsWindowToggle: Bool, regionHint: String, completion: @escaping (OverlayResult) -> Void) {
        self.mode = mode
        self.allowsWindowToggle = allowsWindowToggle
        self.regionHint = regionHint
        self.completion = completion

        for (screen, shot) in shots {
            let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.isOpaque = true
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.level = .screenSaver // after isFloatingPanel, which resets the level
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

    var panelLevels: [NSWindow.Level] { panels.map(\.level) }

    func show() {
        // macOS only lets the frontmost app change the pointer, so become
        // active for the duration of the selection to show the crosshair.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != getpid() { previousApp = front }
        NSApp.activate(ignoringOtherApps: true)

        let mouse = NSEvent.mouseLocation
        for panel in panels { panel.orderFrontRegardless() }
        let key = panels.first { $0.frame.contains(mouse) } ?? panels.first
        key?.makeKeyAndOrderFront(nil)
        if let view = key?.contentView { key?.makeFirstResponder(view) }
        NSCursor.crosshair.push()
    }

    /// Hands focus back to the app the user was in (after a cancel, or when
    /// the capture continues in that app, as a scrolling capture does).
    func restorePreviousApp() {
        guard let previousApp, !previousApp.isTerminated else { return }
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        } else {
            previousApp.activate(options: [])
        }
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
        NSCursor.pop()
        NSCursor.arrow.set()
        completion(result)
    }
}

final class OverlayView: NSView {
    private let screen: NSScreen
    private let shot: Shot
    private let windows: [WindowInfo]
    private weak var controller: SelectionOverlayController?

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hover: WindowInfo?
    /// Where the pointer is during a drag (screen points, unsnapped).
    private var dragPoint: CGPoint?

    /// Magnification of the frozen screen (1 = actual size) for precise
    /// selection, and the screen point shown at the view's top-left corner.
    /// The selection, window frames and the crop stay in screen points, so
    /// the captured image is always at native resolution.
    private(set) var zoom: CGFloat = 1
    private(set) var offset: CGPoint = .zero
    static let maxZoom: CGFloat = 12

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

    // MARK: Zoom

    private var pixelsPerPoint: CGFloat { CGFloat(shot.image.width) / max(bounds.width, 1) }

    /// View point → screen point.
    func screenPoint(_ v: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + v.x / zoom, y: offset.y + v.y / zoom)
    }

    /// Screen rect → view rect.
    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - offset.x) * zoom, y: (r.minY - offset.y) * zoom, width: r.width * zoom, height: r.height * zoom)
    }

    private func clampOffset() {
        offset.x = max(0, min(bounds.width - bounds.width / zoom, offset.x))
        offset.y = max(0, min(bounds.height - bounds.height / zoom, offset.y))
    }

    /// Zooms keeping the screen point under `v` (view coordinates) in place.
    func zoom(by factor: CGFloat, at v: CGPoint) {
        let anchor = screenPoint(v)
        let target = max(1, min(Self.maxZoom, zoom * factor))
        zoom = abs(target - 1) < 0.02 ? 1 : target
        offset = CGPoint(x: anchor.x - v.x / zoom, y: anchor.y - v.y / zoom)
        clampOffset()
        refreshAfterViewChange(v)
    }

    private func pan(by delta: CGPoint, at v: CGPoint) {
        guard zoom > 1 else { return }
        offset.x -= delta.x / zoom
        offset.y -= delta.y / zoom
        clampOffset()
        refreshAfterViewChange(v)
    }

    private func refreshAfterViewChange(_ v: CGPoint) {
        if mode == .window { updateHover(screenPoint(v)) }
        needsDisplay = true
    }

    /// A mouse wheel (or ⌘ + scroll) zooms around the pointer; trackpad
    /// scrolling pans the magnified view.
    override func scrollWheel(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if event.hasPreciseScrollingDeltas {
            if event.modifierFlags.contains(.command) {
                zoom(by: exp(event.scrollingDeltaY * 0.01), at: v)
            } else {
                pan(by: CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY), at: v)
            }
        } else if event.scrollingDeltaY != 0 {
            zoom(by: pow(1.25, max(-4, min(4, event.scrollingDeltaY))), at: v)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    func modeChanged() {
        dragStart = nil
        selection = nil
        hover = nil
        if mode == .window, let window {
            updateHover(screenPoint(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Magnified, individual pixels should stay crisp.
        ctx.interpolationQuality = zoom >= 2 ? .none : .high
        ctx.drawFlipped(shot.image, in: viewRect(bounds))

        let hole: CGRect? = (mode == .window ? hover?.frame.intersection(bounds) : selection).map(viewRect)
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
                if let selection { drawSizeLabel(for: hole, size: selection.size) }
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

    private func drawSizeLabel(for rect: CGRect, size: CGSize) {
        let text = "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
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
        if mode == .region { text += " · 按住 ⌘ 吸附边缘" }
        text += zoom > 1 ? " · \(Int((zoom * 100).rounded()))%" : " · 滚轮 放大"
        text += " · Esc 取消"
        drawBadge(text, fontSize: 13) { size in
            CGPoint(x: self.bounds.midX - size.width / 2, y: 64)
        }
    }

    // MARK: Events

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

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
        if mode == .window { updateHover(screenPoint(convert(event.locationInWindow, from: nil))) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let p = screenPoint(convert(event.locationInWindow, from: nil))
        if mode == .window {
            updateHover(p)
        } else {
            dragStart = p
            selection = nil
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, dragStart != nil else { return }
        var p = screenPoint(convert(event.locationInWindow, from: nil))
        p.x = max(0, min(bounds.width, p.x))
        p.y = max(0, min(bounds.height, p.y))
        dragPoint = p
        updateSelection(snapToEdges: event.modifierFlags.contains(.command))
    }

    /// Pressing or releasing ⌘ mid-drag takes effect without moving the mouse.
    override func flagsChanged(with event: NSEvent) {
        if dragStart != nil, dragPoint != nil {
            updateSelection(snapToEdges: event.modifierFlags.contains(.command))
        }
    }

    private func updateSelection(snapToEdges: Bool) {
        guard var a = dragStart, var b = dragPoint else { return }
        if snapToEdges {
            // Each side of the selection moves to the nearest visible edge
            // (a line where the picture changes) that runs along that side.
            let xs = (a.x, b.x), ys = (a.y, b.y)
            a.x = snapToEdge(a.x, vertical: true, along: ys)
            b.x = snapToEdge(b.x, vertical: true, along: ys)
            a.y = snapToEdge(a.y, vertical: false, along: xs)
            b.y = snapToEdge(b.y, vertical: false, along: xs)
        }
        // Whole device pixels, which is finer than points when magnified.
        let grid = pixelsPerPoint
        func snap(_ value: CGFloat) -> CGFloat { (value * grid).rounded() / grid }
        let x0 = snap(min(a.x, b.x)), y0 = snap(min(a.y, b.y))
        selection = CGRect(x: x0, y: y0, width: snap(max(a.x, b.x)) - x0, height: snap(max(a.y, b.y)) - y0)
        needsDisplay = true
    }

    // MARK: Edge snapping

    /// Grayscale copy of the frozen screen, built the first time ⌘ is used.
    private lazy var luminance: (bytes: [UInt8], width: Int, height: Int)? = {
        let width = shot.image.width, height = shot.image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(shot.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }()

    /// Moves a coordinate (points) to the nearest strong edge within reach.
    /// `vertical` snaps an x coordinate to a vertical edge, judged along the
    /// y range `along`; otherwise a y coordinate to a horizontal edge.
    private func snapToEdge(_ value: CGFloat, vertical: Bool, along: (CGFloat, CGFloat)) -> CGFloat {
        guard let lum = luminance else { return value }
        let grid = pixelsPerPoint
        let limit = vertical ? lum.width : lum.height, cross = vertical ? lum.height : lum.width
        let center = Int((value * grid).rounded())
        // About 10 on-screen points of reach, so it tightens as you zoom in.
        let reach = max(2, Int((10 / zoom * grid).rounded()))
        let from = max(0, min(cross - 1, Int((min(along.0, along.1) * grid).rounded())))
        let to = max(0, min(cross - 1, Int((max(along.0, along.1) * grid).rounded())))
        guard to - from >= 6, limit > 2 else { return value }
        let step = max(1, (to - from) / 96)

        var best: [(position: Int, strength: Double)] = []
        var strongest = 0.0
        lum.bytes.withUnsafeBufferPointer { p in
            for position in max(1, center - reach)...max(1, min(limit - 1, center + reach)) {
                var sum = 0, count = 0
                var k = from
                while k <= to {
                    let here = vertical ? k * lum.width + position : position * lum.width + k
                    let before = vertical ? here - 1 : here - lum.width
                    sum += abs(Int(p[here]) - Int(p[before]))
                    count += 1
                    k += step
                }
                let strength = Double(sum) / Double(max(count, 1))
                best.append((position, strength))
                strongest = max(strongest, strength)
            }
        }
        // A clear edge: an average step of 10+ gray levels along the side,
        // and not dwarfed by a much stronger edge nearby.
        let threshold = max(10, strongest * 0.5)
        let candidates = best.filter { $0.strength >= threshold }
        guard let nearest = candidates.min(by: { abs($0.position - center) < abs($1.position - center) }) else { return value }
        return CGFloat(nearest.position) / grid
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
            dragPoint = nil
            needsDisplay = true
        }
        guard let rect = selection, rect.width >= 2, rect.height >= 2, let image = crop(rect) else {
            selection = nil
            return
        }
        controller?.finish(.region(screen: screen, rect: rect, shot: Shot(image: image, scale: shot.scale)))
    }

    private func crop(_ rect: CGRect) -> CGImage? {
        let sx = CGFloat(shot.image.width) / bounds.width, sy = CGFloat(shot.image.height) / bounds.height
        let pixels = CGRect(x: (rect.minX * sx).rounded(), y: (rect.minY * sy).rounded(),
                            width: (rect.width * sx).rounded(), height: (rect.height * sy).rounded())
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

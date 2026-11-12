import AppKit
import Combine

/// Keeps the document centered when it is smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if doc.frame.height < rect.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Mouse-wheel zooming: a wheel (or ⌘ + any scroll) zooms around the pointer,
/// while trackpad two-finger scrolling keeps panning.
final class CanvasScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let canvas = documentView as? CanvasView else { return super.scrollWheel(with: event) }
        let command = event.modifierFlags.contains(.command)
        if event.hasPreciseScrollingDeltas {
            guard command else { return super.scrollWheel(with: event) }
            canvas.zoom(by: exp(event.scrollingDeltaY * 0.01), at: event.locationInWindow)
        } else {
            guard event.scrollingDeltaY != 0 else { return }
            let steps = max(-4, min(4, event.scrollingDeltaY))
            canvas.zoom(by: pow(1.12, steps), at: event.locationInWindow)
        }
    }
}

final class CanvasView: NSView, NSTextFieldDelegate {
    let state: EditorState
    /// While true the zoom follows the viewport size.
    var autoFit = true

    private enum Drag {
        case none
        case creating(UUID)
        case moving(UUID, last: CGPoint, moved: Bool)
        case resizing(UUID, startX: Bool, startY: Bool, moved: Bool)
        /// Hand-tool drag: where the mouse went down and the scroll origin then.
        case panning(from: CGPoint, origin: CGPoint)
    }

    /// True while the space bar is held: dragging pans instead of drawing.
    private var spaceDown = false

    private var drag: Drag = .none
    private var cancellable: AnyCancellable?
    private var field: NSTextField?
    private var editingOrigin: CGPoint = .zero
    private var finishingEdit = false
    private var lastTool: Tool

    init(state: EditorState) {
        self.state = state
        lastTool = state.tool
        super.init(frame: CGRect(origin: .zero, size: state.canvasSize))
        cancellable = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.stateChanged() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Layout & zoom

    private var zoom: CGFloat { state.zoom }
    private var imageOrigin: CGPoint { Renderer.imageOrigin(state.decoration) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                                               name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.frameDidChangeNotification, object: clip)
        DispatchQueue.main.async { [weak self] in
            self?.fitIfNeeded()
            self?.window?.makeFirstResponder(self)
        }
    }

    @objc private func viewportChanged() { fitIfNeeded() }

    private func stateChanged() {
        if state.tool != lastTool {
            lastTool = state.tool
            commitTextEditing()
            window?.invalidateCursorRects(for: self)
        }
        fitIfNeeded()
        syncSize()
        needsDisplay = true
    }

    private func syncSize() {
        let size = state.canvasSize
        let target = CGSize(width: (size.width * zoom).rounded(), height: (size.height * zoom).rounded())
        if frame.size != target {
            setFrameSize(target)
            layoutField()
        }
    }

    func fitZoom() -> CGFloat {
        guard let viewport = enclosingScrollView?.contentSize, viewport.width > 80, viewport.height > 80 else { return 1 }
        let size = state.canvasSize
        let availW = viewport.width - 48, availH = viewport.height - 48
        var z = min(1, availW / size.width)
        // Long scrolling captures fit to width and scroll vertically.
        if size.height / size.width < 2.2 { z = min(z, availH / size.height) }
        return max(0.05, z)
    }

    private func fitIfNeeded() {
        guard autoFit else { return }
        let z = fitZoom()
        if abs(z - state.zoom) > 0.0005 { state.zoom = z }
        syncSize()
    }

    func zoomToFit() {
        autoFit = true
        fitIfNeeded()
    }

    func setZoom(_ z: CGFloat) {
        autoFit = false
        state.zoom = max(0.05, min(8, z))
        syncSize()
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, at: event.locationInWindow)
    }

    /// Zooms keeping the canvas point under `windowPoint` fixed on screen.
    func zoom(by factor: CGFloat, at windowPoint: CGPoint) {
        guard let clip = enclosingScrollView?.contentView else { return setZoom(state.zoom * factor) }
        let old = state.zoom
        let anchor = convert(windowPoint, from: nil)
        let inClip = clip.convert(windowPoint, from: nil)
        let offset = CGPoint(x: inClip.x - clip.bounds.minX, y: inClip.y - clip.bounds.minY)
        setZoom(old * factor)
        let ratio = state.zoom / old
        scrollClip(to: CGPoint(x: anchor.x * ratio - offset.x, y: anchor.y * ratio - offset.y))
    }

    private func scrollClip(to origin: CGPoint) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let target = clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: target.origin)
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Panning

    @objc private func windowResignedKey() { setSpaceDown(false) }

    private func setSpaceDown(_ down: Bool) {
        guard spaceDown != down else { return }
        spaceDown = down
        window?.invalidateCursorRects(for: self)
        if down { NSCursor.openHand.set() }
    }

    private func beginPan(_ event: NSEvent) {
        guard let clip = enclosingScrollView?.contentView else { return }
        drag = .panning(from: event.locationInWindow, origin: clip.bounds.origin)
        NSCursor.closedHand.set()
    }

    private func continuePan(_ event: NSEvent) -> Bool {
        guard case .panning(let from, let origin) = drag else { return false }
        let p = event.locationInWindow
        // Window y points up, the flipped canvas y points down.
        scrollClip(to: CGPoint(x: origin.x - (p.x - from.x), y: origin.y + (p.y - from.y)))
        return true
    }

    private func endPan() {
        drag = .none
        window?.invalidateCursorRects(for: self)
        if spaceDown { NSCursor.openHand.set() }
    }

    override func otherMouseDown(with event: NSEvent) { beginPan(event) }
    override func otherMouseDragged(with event: NSEvent) { _ = continuePan(event) }
    override func otherMouseUp(with event: NSEvent) { endPan() }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { setSpaceDown(false) } else { super.keyUp(with: event) }
    }

    /// Lets the window forward a space release when focus sits elsewhere.
    func handleKeyUp(_ event: NSEvent) {
        if event.keyCode == 49 { setSpaceDown(false) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.scaleBy(x: zoom, y: zoom)
        Renderer.draw(in: ctx, image: state.image, imageSize: state.imageSize, annotations: state.annotations,
                      decoration: state.decoration, mosaic: state.mosaic, hidden: state.editingID)
        if let a = state.selected, a.id != state.editingID {
            ctx.translateBy(x: imageOrigin.x, y: imageOrigin.y)
            drawSelection(a, in: ctx)
        }
        ctx.restoreGState()
    }

    private func handles(for a: Annotation) -> [(point: CGPoint, startX: Bool, startY: Bool)] {
        switch a.kind {
        case .arrow, .line:
            return [(a.start, true, true), (a.end, false, false)]
        case .rect, .ellipse, .mosaic:
            return [
                (CGPoint(x: a.start.x, y: a.start.y), true, true),
                (CGPoint(x: a.end.x, y: a.start.y), false, true),
                (CGPoint(x: a.start.x, y: a.end.y), true, false),
                (CGPoint(x: a.end.x, y: a.end.y), false, false),
            ]
        case .pen, .text:
            return []
        }
    }

    private func drawSelection(_ a: Annotation, in ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        let unit = 1 / zoom
        if a.kind != .arrow && a.kind != .line {
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(unit)
            ctx.setLineDash(phase: 0, lengths: [4 * unit, 3 * unit])
            ctx.stroke(a.bounds.insetBy(dx: -3 * unit, dy: -3 * unit))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        let radius = 4.5 * unit
        for handle in handles(for: a) {
            let rect = CGRect(x: handle.point.x - radius, y: handle.point.y - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5 * unit)
            ctx.strokeEllipse(in: rect)
        }
    }

    // MARK: Cursor

    override func resetCursorRects() {
        if spaceDown {
            addCursorRect(bounds, cursor: .openHand)
            return
        }
        let cursor: NSCursor
        switch state.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    private func docPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x / zoom - imageOrigin.x, y: p.y / zoom - imageOrigin.y)
    }

    private func topmost(at p: CGPoint, where predicate: (Annotation) -> Bool = { _ in true }) -> Annotation? {
        state.annotations.last { predicate($0) && $0.hitTest(p, tolerance: 5 / zoom) }
    }

    override func mouseDown(with event: NSEvent) {
        if field != nil {
            commitTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        if spaceDown {
            beginPan(event)
            return
        }
        let p = docPoint(event)
        drag = .none

        if let a = state.selected {
            let reach = 7 / zoom
            if let h = handles(for: a).first(where: { hypot($0.point.x - p.x, $0.point.y - p.y) <= reach }) {
                drag = .resizing(a.id, startX: h.startX, startY: h.startY, moved: false)
                return
            }
        }

        switch state.tool {
        case .select:
            if let hit = topmost(at: p) {
                state.select(hit.id)
                if event.clickCount == 2, hit.kind == .text {
                    beginTextEditing(existing: hit)
                } else {
                    drag = .moving(hit.id, last: p, moved: false)
                }
            } else {
                state.select(nil)
            }
        case .text:
            if let hit = topmost(at: p, where: { $0.kind == .text }) {
                state.select(hit.id)
                beginTextEditing(existing: hit)
            } else {
                state.select(nil)
                beginTextEditing(at: p)
            }
        default:
            guard let kind = state.tool.annotationKind else { return }
            var a = Annotation(kind: kind, start: p, end: p, color: state.color, lineWidth: state.lineWidth)
            a.filled = state.filled && (kind == .rect || kind == .ellipse)
            if kind == .pen { a.points = [p] }
            state.checkpoint()
            state.annotations.append(a)
            state.selectedID = nil
            drag = .creating(a.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if continuePan(event) { return }
        let p = docPoint(event)
        switch drag {
        case .none, .panning:
            break
        case .creating(let id):
            guard let i = state.index(of: id) else { return }
            var a = state.annotations[i]
            if a.kind == .pen {
                if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) < 1 / zoom { return }
                a.points.append(p)
                a.end = p
            } else {
                a.end = event.modifierFlags.contains(.shift) ? constrain(p, from: a.start, kind: a.kind) : p
            }
            state.annotations[i] = a
        case .moving(let id, let last, let moved):
            guard let i = state.index(of: id) else { return }
            if !moved { state.checkpoint() }
            state.annotations[i].translate(by: CGPoint(x: p.x - last.x, y: p.y - last.y))
            drag = .moving(id, last: p, moved: true)
        case .resizing(let id, let startX, let startY, let moved):
            guard let i = state.index(of: id) else { return }
            if !moved { state.checkpoint() }
            var a = state.annotations[i]
            if startX { a.start.x = p.x } else { a.end.x = p.x }
            if startY { a.start.y = p.y } else { a.end.y = p.y }
            state.annotations[i] = a
            drag = .resizing(id, startX: startX, startY: startY, moved: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .panning = drag {
            endPan()
            return
        }
        defer { drag = .none }
        guard case .creating(let id) = drag, let i = state.index(of: id) else { return }
        let a = state.annotations[i]
        let tooSmall = a.kind == .pen ? a.points.count < 2 : hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 3
        if tooSmall {
            state.annotations.remove(at: i)
            state.discardCheckpoint()
        } else {
            state.selectedID = id
        }
    }

    /// Shift-drag: squares / circles, and lines snapped to 45° steps.
    private func constrain(_ p: CGPoint, from start: CGPoint, kind: Annotation.Kind) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        switch kind {
        case .arrow, .line:
            let step = CGFloat.pi / 4
            let angle = (atan2(dy, dx) / step).rounded() * step
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
    }

    // MARK: Keyboard

    /// Returns true when the key was consumed.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard field == nil else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49: // space: hold to pan
            setSpaceDown(true)
            return true
        case 51, 117: // delete, forward delete
            state.deleteSelected()
            return true
        case 53: // escape
            if state.selectedID != nil {
                state.select(nil)
                return true
            }
            return false
        default:
            break
        }
        if let ch = event.charactersIgnoringModifiers?.lowercased(),
           let tool = Tool.allCases.first(where: { $0.key == ch }) {
            state.tool = tool
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    // MARK: Text editing

    private func beginTextEditing(existing: Annotation) {
        state.editingID = existing.id
        startField(at: existing.start, text: existing.text, color: existing.color, lineWidth: existing.lineWidth)
    }

    private func beginTextEditing(at p: CGPoint) {
        state.editingID = nil
        startField(at: p, text: "", color: state.color, lineWidth: state.lineWidth)
    }

    private func startField(at origin: CGPoint, text: String, color: RGBA, lineWidth: CGFloat) {
        editingOrigin = origin
        let f = NSTextField(string: text)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.textColor = color.nsColor
        f.font = Annotation.font(size: Annotation.fontSize(forLineWidth: lineWidth) * zoom)
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        f.delegate = self
        f.wantsLayer = true
        f.layer?.borderWidth = 1
        f.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        f.layer?.cornerRadius = 2
        addSubview(f)
        field = f
        layoutField()
        window?.makeFirstResponder(f)
        needsDisplay = true
    }

    private func layoutField() {
        guard let f = field else { return }
        let size = f.cell?.cellSize ?? f.fittingSize
        let x = (editingOrigin.x + imageOrigin.x) * zoom - 2
        let y = (editingOrigin.y + imageOrigin.y) * zoom
        f.frame = CGRect(x: x, y: y, width: max(size.width + 12, 60), height: size.height)
    }

    func controlTextDidChange(_ obj: Notification) { layoutField() }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditing() }

    func commitTextEditing() { finishTextEditing(commit: true) }

    func cancelTextEditing() { finishTextEditing(commit: false) }

    private func finishTextEditing(commit: Bool) {
        guard let f = field, !finishingEdit else { return }
        finishingEdit = true
        defer { finishingEdit = false }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let editedID = state.editingID
        field = nil
        state.editingID = nil
        f.delegate = nil
        if window?.firstResponder === f.currentEditor() || window?.firstResponder === f {
            window?.makeFirstResponder(self)
        }
        f.removeFromSuperview()

        if commit {
            if let i = state.index(of: editedID) {
                if text.isEmpty {
                    state.checkpoint()
                    state.annotations.remove(at: i)
                    state.selectedID = nil
                } else if text != state.annotations[i].text {
                    state.checkpoint()
                    state.annotations[i].text = text
                }
            } else if !text.isEmpty {
                var a = Annotation(kind: .text, start: editingOrigin, end: editingOrigin,
                                   color: state.color, lineWidth: state.lineWidth)
                a.text = text
                state.checkpoint()
                state.annotations.append(a)
                state.selectedID = a.id
            }
        }
        needsDisplay = true
    }
}

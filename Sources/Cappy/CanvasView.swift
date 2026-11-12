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

    private enum Handle {
        /// Moves one end of the start/end pair (shapes, lines, mosaic).
        case corner(startX: Bool, startY: Bool)
        /// Text box: which edges move (-1 = left/top, 1 = right/bottom, 0 = none).
        /// Resizing changes the box only, never the font size.
        case textBox(dx: Int, dy: Int)
    }

    private enum Drag {
        case none
        case creating(UUID)
        /// Moving every selected annotation together.
        case moving(last: CGPoint, moved: Bool)
        /// Rubber-band selection from this point.
        case marquee(from: CGPoint)
        /// Dragging a handle; `original` is the annotation as it was at mouse-down.
        case resizing(UUID, handle: Handle, original: Annotation, moved: Bool)
        /// Hand-tool drag: where the mouse went down and the scroll origin then.
        case panning(from: CGPoint, origin: CGPoint)
        /// Dragging out a text selection from this caret.
        case selectingText(anchor: TextPosition)
    }

    /// True while the space bar is held: dragging pans instead of drawing.
    private var spaceDown = false

    private var drag: Drag = .none
    /// The rubber band being dragged out, in image points.
    private var marqueeRect: CGRect?
    private var cancellable: AnyCancellable?
    private var field: NSTextField?
    private var editingOrigin: CGPoint = .zero
    private var editingFontSize: CGFloat = Annotation.defaultFontSize
    private var editingFontName: String?
    private var editingBoxWidth: CGFloat?
    private var finishingEdit = false
    private var lastTool: Tool

    init(state: EditorState) {
        self.state = state
        lastTool = state.tool
        super.init(frame: CGRect(origin: .zero, size: state.canvasSize))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
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
            if state.tool != .select, state.textSelection != nil { state.textSelection = nil }
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
        ctx.translateBy(x: imageOrigin.x, y: imageOrigin.y)
        if let range = state.textSelection, let layout = state.textLayout {
            ctx.setFillColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45).cgColor)
            for rect in layout.rects(for: range) {
                ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerWidth: 2, cornerHeight: 2, transform: nil))
            }
            ctx.fillPath()
        }
        let selection = state.selectedAnnotations
        if selection.count == 1 {
            if selection[0].id != state.editingID { drawSelection(selection[0], in: ctx) }
        } else {
            for a in selection { drawOutline(a.bounds, in: ctx) }
        }
        if let marquee = marqueeRect {
            let accent = NSColor.controlAccentColor
            ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
            ctx.fill(marquee)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1 / zoom)
            ctx.stroke(marquee)
        }
        ctx.restoreGState()
    }

    private func handles(for a: Annotation) -> [(point: CGPoint, handle: Handle)] {
        switch a.kind {
        case .arrow, .line:
            return [(a.start, .corner(startX: true, startY: true)), (a.end, .corner(startX: false, startY: false))]
        case .rect, .ellipse, .mosaic:
            return [
                (CGPoint(x: a.start.x, y: a.start.y), .corner(startX: true, startY: true)),
                (CGPoint(x: a.end.x, y: a.start.y), .corner(startX: false, startY: true)),
                (CGPoint(x: a.start.x, y: a.end.y), .corner(startX: true, startY: false)),
                (CGPoint(x: a.end.x, y: a.end.y), .corner(startX: false, startY: false)),
            ]
        case .text:
            let b = a.bounds.insetBy(dx: -3 / zoom, dy: -3 / zoom) // on the dashed outline
            var out: [(point: CGPoint, handle: Handle)] = []
            for dy in [-1, 0, 1] {
                for dx in [-1, 0, 1] where dx != 0 || dy != 0 {
                    let x = dx < 0 ? b.minX : dx > 0 ? b.maxX : b.midX
                    let y = dy < 0 ? b.minY : dy > 0 ? b.maxY : b.midY
                    out.append((CGPoint(x: x, y: y), .textBox(dx: dx, dy: dy)))
                }
            }
            return out
        case .pen:
            return []
        }
    }

    private func drawOutline(_ rect: CGRect, in ctx: CGContext) {
        let unit = 1 / zoom
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(unit)
        ctx.setLineDash(phase: 0, lengths: [4 * unit, 3 * unit])
        ctx.stroke(rect.insetBy(dx: -3 * unit, dy: -3 * unit))
        ctx.setLineDash(phase: 0, lengths: [])
    }

    private func drawSelection(_ a: Annotation, in ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        let unit = 1 / zoom
        if a.kind != .arrow && a.kind != .line { drawOutline(a.bounds, in: ctx) }
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

    /// With the select tool, recognized text shows an I-beam so it reads as selectable.
    override func mouseMoved(with event: NSEvent) {
        guard state.tool == .select, !spaceDown, field == nil else { return }
        let p = docPoint(event)
        let overText = topmost(at: p) == nil && state.textLayout?.line(at: p, slop: 3 / zoom) != nil
        (overText ? NSCursor.iBeam : NSCursor.arrow).set()
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
        if state.textSelection != nil { state.textSelection = nil }

        if let a = state.selected {
            let reach = 7 / zoom
            if let h = handles(for: a).first(where: { hypot($0.point.x - p.x, $0.point.y - p.y) <= reach }) {
                drag = .resizing(a.id, handle: h.handle, original: a, moved: false)
                return
            }
        }

        switch state.tool {
        case .select:
            let extend = event.modifierFlags.contains(.shift)
            if let hit = topmost(at: p) {
                if extend {
                    // Shift-click adds to / removes from the selection.
                    if state.selectedIDs.contains(hit.id) { state.selectedIDs.remove(hit.id) } else { state.selectedIDs.insert(hit.id) }
                } else if event.clickCount == 2, hit.kind == .text {
                    state.select(hit.id)
                    beginTextEditing(existing: hit)
                    return
                } else if !state.selectedIDs.contains(hit.id) {
                    state.select(hit.id)
                }
                // Dragging any member moves the whole selection.
                if state.selectedIDs.contains(hit.id) { drag = .moving(last: p, moved: false) }
            } else if !extend, let layout = state.textLayout,
                      let position = layout.position(at: p, strict: true, slop: 3 / zoom) {
                // On recognized text: select text instead.
                state.select(nil)
                if event.clickCount == 2 {
                    state.textSelection = layout.wholeLine(position.line)
                } else {
                    drag = .selectingText(anchor: position)
                }
            } else {
                // Empty space: rubber-band select.
                if !extend { state.select(nil) }
                drag = .marquee(from: p)
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
        case .selectingText(let anchor):
            guard let head = state.textLayout?.position(at: p, strict: false) else { return }
            let range = TextRange(anchor: anchor, head: head)
            state.textSelection = range.isEmpty ? nil : range
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
        case .moving(let last, let moved):
            let delta = CGPoint(x: p.x - last.x, y: p.y - last.y)
            guard delta != .zero, !state.selectedIDs.isEmpty else { return }
            if !moved { state.checkpoint() }
            var updated = state.annotations
            for i in updated.indices where state.selectedIDs.contains(updated[i].id) { updated[i].translate(by: delta) }
            state.annotations = updated
            drag = .moving(last: p, moved: true)
        case .marquee(let from):
            let rect = CGRect(x: min(from.x, p.x), y: min(from.y, p.y), width: abs(p.x - from.x), height: abs(p.y - from.y))
            marqueeRect = rect
            let hits = state.annotations.filter { a in
                let pad = max(a.lineWidth / 2, 1)
                return a.bounds.insetBy(dx: -pad, dy: -pad).intersects(rect)
            }
            let ids = Set(hits.map(\.id))
            if ids != state.selectedIDs { state.selectedIDs = ids }
            needsDisplay = true
        case .resizing(let id, let handle, let original, let moved):
            guard let i = state.index(of: id) else { return }
            if !moved { state.checkpoint() }
            var a = state.annotations[i]
            switch handle {
            case .corner(let startX, let startY):
                if startX { a.start.x = p.x } else { a.end.x = p.x }
                if startY { a.start.y = p.y } else { a.end.y = p.y }
            case .textBox(let dx, let dy):
                // The opposite edges stay put; the text re-wraps to the new width.
                let box = original.bounds
                if dx > 0 {
                    a.boxWidth = max(24, p.x - box.minX)
                } else if dx < 0 {
                    let width = max(24, box.maxX - p.x)
                    a.boxWidth = width
                    a.start.x = box.maxX - width
                }
                if dy != 0 {
                    // Never shorter than the text needs at the current width.
                    let needed = max(Annotation.textSize(a.attributedText, wrapWidth: a.boxWidth).height, a.fontSize)
                    if dy > 0 {
                        a.boxHeight = max(needed, p.y - box.minY)
                    } else {
                        let height = max(needed, box.maxY - p.y)
                        a.boxHeight = height
                        a.start.y = box.maxY - height
                    }
                }
            }
            state.annotations[i] = a
            drag = .resizing(id, handle: handle, original: original, moved: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if case .panning = drag {
            endPan()
            return
        }
        defer { drag = .none }
        if case .marquee = drag {
            marqueeRect = nil
            if state.selectedIDs.count == 1 { state.select(state.selectedIDs.first) }
            needsDisplay = true
            return
        }
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
            if state.textSelection != nil {
                state.textSelection = nil
                return true
            }
            if !state.selectedIDs.isEmpty {
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
        startField(at: existing.start, text: existing.text, color: existing.color, fontSize: existing.fontSize,
                   fontName: existing.fontName, boxWidth: existing.boxWidth)
    }

    private func beginTextEditing(at p: CGPoint) {
        state.editingID = nil
        startField(at: p, text: "", color: state.color, fontSize: state.fontSize, fontName: state.fontName)
    }

    private func startField(at origin: CGPoint, text: String, color: RGBA, fontSize: CGFloat, fontName: String?,
                            boxWidth: CGFloat? = nil) {
        editingOrigin = origin
        editingFontSize = fontSize
        editingFontName = fontName
        editingBoxWidth = boxWidth
        let f = NSTextField(string: text)
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.textColor = color.nsColor
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.cell?.usesSingleLineMode = false
        f.maximumNumberOfLines = 0
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

    /// Sizes the editing field to its text: as wide as the longest line, or
    /// wrapped at the annotation's box width, growing downwards line by line.
    private func layoutField() {
        guard let f = field else { return }
        let font = Annotation.font(name: editingFontName, size: editingFontSize * zoom)
        f.font = font
        var sample = f.stringValue
        if sample.isEmpty || sample.hasSuffix("\n") { sample += " " } // keep the caret's line
        let wrap = editingBoxWidth.map { $0 * zoom }
        let size = Annotation.textSize(NSAttributedString(string: sample, attributes: [.font: font]), wrapWidth: wrap)
        // The cell insets its text by 2pt on each side.
        let width = (wrap ?? max(size.width + 14, 60)) + 4
        let x = (editingOrigin.x + imageOrigin.x) * zoom - 2
        let y = (editingOrigin.y + imageOrigin.y) * zoom
        f.frame = CGRect(x: x, y: y, width: width, height: size.height + 2)
    }

    func controlTextDidChange(_ obj: Notification) { layoutField() }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditing() }

    /// Return starts a new line; Esc leaves text editing, keeping what was typed.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            commitTextEditing()
            return true
        default:
            return false
        }
    }

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
                a.fontPointSize = editingFontSize
                a.fontName = editingFontName
                state.checkpoint()
                state.annotations.append(a)
                state.selectedID = a.id
            }
        }
        needsDisplay = true
    }
}

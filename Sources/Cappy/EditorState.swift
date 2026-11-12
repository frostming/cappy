import AppKit
import Combine
import UniformTypeIdentifiers

enum SmartMosaicMode {
    case auto, sensitiveText, faces, allText

    var wantsText: Bool { self != .faces }
    var wantsFaces: Bool { self == .auto || self == .faces }
}

final class EditorState: ObservableObject {
    let image: CGImage
    let scale: CGFloat
    let imageSize: CGSize
    let mosaic: MosaicCache

    @Published var annotations: [Annotation] = []
    /// Selected annotations. One selection shows resize handles; several
    /// (from a marquee or shift-click) move, restyle and delete together.
    @Published var selectedIDs: Set<UUID> = []
    @Published var tool: Tool = .select
    @Published var color: RGBA = RGBA.palette[0]
    @Published var lineWidth: CGFloat = 4
    @Published var filled = false
    @Published var decoration: Decoration { didSet { if decoration != oldValue { decoration.save() } } }
    @Published var showInspector: Bool
    @Published var widthPickerOpen = false
    /// Font for new text, and for the selected text annotations.
    @Published var fontSize: CGFloat = Annotation.defaultFontSize
    @Published var fontName: String?
    @Published var fontPickerOpen = false
    @Published var fontSizePickerOpen = false
    /// Text selected with the mouse (select tool), Live Text style.
    @Published var textSelection: TextRange?
    /// Recognized text with per-character boxes; filled in shortly after the editor opens.
    private(set) var textLayout: TextLayout?
    @Published var zoom: CGFloat = 1
    @Published var toast: String?
    @Published var busy = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Annotation currently being edited in a text field (hidden from rendering).
    var editingID: UUID?
    weak var canvas: CanvasView?

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var coalesceKey: String?
    private var toastToken = 0

    /// Identifier in `RecentStore` when this image came from a capture.
    let recentID: UUID?

    init(shot: Shot, recentID: UUID? = nil, annotations: [Annotation] = []) {
        self.recentID = recentID
        self.annotations = annotations
        image = shot.image
        scale = shot.scale
        imageSize = shot.pointSize
        mosaic = MosaicCache(image: shot.image, scale: shot.scale)
        let saved = Decoration.load()
        decoration = saved
        showInspector = saved.enabled
        recognizeTextLayout()
    }

    private func recognizeTextLayout() {
        let image = self.image, scale = self.scale
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let lines = (try? VisionService.recognize(image)) ?? []
            let layout = VisionService.layout(lines, scale: scale)
            DispatchQueue.main.async {
                self?.textLayout = layout
                self?.canvas?.needsDisplay = true
            }
        }
    }

    var selectedText: String? {
        guard let range = textSelection, !range.isEmpty, let layout = textLayout else { return nil }
        let text = layout.string(for: range)
        return text.isEmpty ? nil : text
    }

    /// Copies the mouse-selected text; false when there is no selection.
    func copySelectedText() -> Bool {
        guard let text = selectedText else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    func selectAllText() {
        guard let all = textLayout?.everything else {
            showToast("未识别到文字")
            return
        }
        tool = .select
        select(nil)
        textSelection = all
    }

    /// Saves the current annotations so the capture can be reopened later.
    func persist() {
        guard let recentID else { return }
        canvas?.commitTextEditing()
        RecentStore.shared.update(recentID, annotations: annotations)
    }

    var canvasSize: CGSize { Renderer.canvasSize(imageSize: imageSize, decoration: decoration) }

    // MARK: Undo

    /// Snapshots the annotations before a mutation. Consecutive checkpoints
    /// with the same key (e.g. dragging a slider) collapse into one undo step.
    func checkpoint(_ key: String? = nil) {
        if let key, key == coalesceKey { return }
        coalesceKey = key
        undoStack.append(annotations)
        redoStack.removeAll()
        refreshUndoFlags()
    }

    /// Drops the latest checkpoint (the mutation it guarded was abandoned).
    func discardCheckpoint() {
        _ = undoStack.popLast()
        coalesceKey = nil
        refreshUndoFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        restore(next)
    }

    private func restore(_ snapshot: [Annotation]) {
        canvas?.cancelTextEditing()
        annotations = snapshot
        selectedIDs.formIntersection(snapshot.map(\.id))
        coalesceKey = nil
        refreshUndoFlags()
    }

    private func refreshUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Selection & properties

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return annotations.firstIndex { $0.id == id }
    }

    /// The selection when exactly one annotation is selected.
    var selectedID: UUID? {
        get { selectedIDs.count == 1 ? selectedIDs.first : nil }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }

    var selected: Annotation? { index(of: selectedID).map { annotations[$0] } }

    /// Selected annotations in drawing order.
    var selectedAnnotations: [Annotation] { annotations.filter { selectedIDs.contains($0.id) } }

    func select(_ id: UUID?) {
        selectedID = id
        coalesceKey = nil
        guard let a = selected, a.kind != .mosaic else { return }
        color = a.color
        if a.kind == .text {
            fontSize = a.fontSize
            fontName = a.fontName
        } else {
            lineWidth = a.lineWidth
            filled = a.filled
        }
    }

    /// True when the toolbar should offer font controls instead of the line width.
    var editsText: Bool {
        let kinds = Set(selectedAnnotations.map(\.kind))
        return kinds.isEmpty ? tool == .text : kinds == [.text]
    }

    func deleteSelected() {
        guard !selectedAnnotations.isEmpty else { return }
        checkpoint()
        annotations.removeAll { selectedIDs.contains($0.id) }
        selectedIDs = []
    }

    private func mutateSelected(_ key: String, _ change: (inout Annotation) -> Void) {
        var updated = annotations
        for i in updated.indices where selectedIDs.contains(updated[i].id) { change(&updated[i]) }
        guard updated != annotations else { return }
        checkpoint("\(key)-\(selectedIDs.map(\.uuidString).sorted().joined())")
        annotations = updated
    }

    func applyColor(_ c: RGBA) {
        color = c
        mutateSelected("color") { $0.color = c }
    }

    func applyFontSize(_ size: CGFloat) {
        fontSize = size
        mutateSelected("fontSize") { if $0.kind == .text { $0.fontPointSize = size } }
    }

    func applyFontName(_ name: String?) {
        fontName = name
        mutateSelected("fontName") { if $0.kind == .text { $0.fontName = name } }
    }

    func applyLineWidth(_ w: CGFloat) {
        lineWidth = w
        mutateSelected("width") { $0.lineWidth = w }
    }

    func applyFilled(_ f: Bool) {
        filled = f
        mutateSelected("fill") { $0.filled = f }
    }

    func toggleInspector() {
        showInspector.toggle()
        if showInspector, !decoration.enabled { decoration.enabled = true }
    }

    // MARK: Feedback

    func showToast(_ message: String) {
        toast = message
        toastToken += 1
        let token = toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            if self?.toastToken == token { self?.toast = nil }
        }
    }

    // MARK: Output

    func renderFinal() -> CGImage? {
        canvas?.commitTextEditing()
        return Renderer.render(image: image, scale: scale, annotations: annotations, decoration: decoration, mosaic: mosaic)
    }

    /// Floats the finished image above all windows and closes the editor.
    /// Double-clicking the pinned image reopens the editor on the original
    /// capture with its annotations still editable.
    func pinToScreen() {
        guard let output = renderFinal() else {
            showToast("悬浮失败")
            return
        }
        let window = canvas?.window
        let anchor = window.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        let shot = Shot(image: image, scale: scale), annotations = self.annotations, recentID = self.recentID
        PinManager.pin(output, scale: scale, centeredOn: anchor) {
            (NSApp.delegate as? AppDelegate)?.reopenEditor(shot, recentID: recentID, annotations: annotations)
        }
        window?.close()
    }

    func copyToClipboard() {
        guard let output = renderFinal(), let png = Bitmap.pngData(output, scale: scale) else {
            showToast("复制失败")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if output.width * output.height < 24_000_000,
           let tiff = NSBitmapImageRep(cgImage: output).tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        showToast("已复制到剪贴板")
    }

    func save(from window: NSWindow?) {
        guard let output = renderFinal(), let png = Bitmap.pngData(output, scale: scale) else {
            showToast("导出失败")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "Cappy \(formatter.string(from: Date())).png"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try png.write(to: url)
                self?.showToast("已保存")
            } catch {
                self?.showToast("保存失败：\(error.localizedDescription)")
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    // MARK: Vision

    func smartMosaic(_ mode: SmartMosaicMode) {
        guard !busy else { return }
        busy = true
        let image = self.image, scale = self.scale
        DispatchQueue.global(qos: .userInitiated).async {
            var rects: [CGRect] = []
            if mode.wantsText {
                let lines = (try? VisionService.recognize(image)) ?? []
                rects += mode == .allText ? lines.map(\.rect) : VisionService.sensitiveRects(lines)
            }
            if mode.wantsFaces { rects += VisionService.faceRects(image) }
            DispatchQueue.main.async {
                self.busy = false
                self.addMosaics(pixelRects: rects, scale: scale)
            }
        }
    }

    private func addMosaics(pixelRects: [CGRect], scale: CGFloat) {
        guard !pixelRects.isEmpty else {
            showToast("未发现需要打码的内容")
            return
        }
        checkpoint()
        for r in pixelRects {
            let p = CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
                .insetBy(dx: -2, dy: -2)
            annotations.append(Annotation(kind: .mosaic, start: p.origin, end: CGPoint(x: p.maxX, y: p.maxY),
                                          color: color, lineWidth: lineWidth))
        }
        selectedID = nil
        showToast("已自动打码 \(pixelRects.count) 处")
    }
}

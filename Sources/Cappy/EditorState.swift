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
    @Published var selectedID: UUID?
    @Published var tool: Tool = .arrow
    @Published var color: RGBA = RGBA.palette[0]
    @Published var lineWidth: CGFloat = 4
    @Published var filled = false
    @Published var decoration: Decoration { didSet { if decoration != oldValue { decoration.save() } } }
    @Published var showInspector: Bool
    @Published var zoom: CGFloat = 1
    @Published var toast: String?
    @Published var ocrText: String?
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
        if let id = selectedID, !snapshot.contains(where: { $0.id == id }) { selectedID = nil }
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

    var selected: Annotation? { index(of: selectedID).map { annotations[$0] } }

    func select(_ id: UUID?) {
        selectedID = id
        coalesceKey = nil
        guard let a = selected, a.kind != .mosaic else { return }
        color = a.color
        lineWidth = a.lineWidth
        filled = a.filled
    }

    func deleteSelected() {
        guard let i = index(of: selectedID) else { return }
        checkpoint()
        annotations.remove(at: i)
        selectedID = nil
    }

    private func mutateSelected(_ key: String, _ change: (inout Annotation) -> Void) {
        guard let i = index(of: selectedID) else { return }
        var a = annotations[i]
        change(&a)
        guard a != annotations[i] else { return }
        checkpoint("\(key)-\(a.id)")
        annotations[i] = a
    }

    func applyColor(_ c: RGBA) {
        color = c
        mutateSelected("color") { $0.color = c }
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

    func runOCR() {
        guard !busy else { return }
        busy = true
        let image = self.image
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = (try? VisionService.recognize(image)) ?? []
            let text = VisionService.plainText(lines)
            DispatchQueue.main.async {
                self.busy = false
                if text.isEmpty { self.showToast("未识别到文字") } else { self.ocrText = text }
            }
        }
    }

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

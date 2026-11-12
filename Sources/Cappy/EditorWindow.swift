import AppKit
import SwiftUI

final class EditorWindow: NSWindow {
    weak var editorState: EditorState?
    /// The most recent mouse-down, which `performDrag(with:)` needs to start a window drag.
    private(set) var lastMouseDown: NSEvent?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { lastMouseDown = event }
        super.sendEvent(event)
    }

    /// Keys nobody in the responder chain consumed (e.g. focus sits on a
    /// toolbar control) still reach the canvas shortcuts.
    override func keyDown(with event: NSEvent) {
        if editorState?.canvas?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        editorState?.canvas?.handleKeyUp(event)
        super.keyUp(with: event)
    }
}

/// The toolbar is drawn inside the title bar area, where AppKit treats a
/// plain `NSHostingView` as title bar: dragging a slider moved the window and
/// double-clicking a button zoomed it. The editor window is therefore not
/// system-movable (`isMovable = false`) and the hosting view does not report
/// `mouseDownCanMoveWindow`; `ToolbarDragArea` (in the toolbar's background,
/// behind its controls) starts window drags and handles the title bar
/// double-click itself.
final class EditorHostingView<Content: View>: NSHostingView<Content> {
    /// Height of the toolbar row at the top of the window.
    static var toolbarHeight: CGFloat { 52 }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Like a real title bar, the toolbar works on the click that activates
    /// the window, so an inactive editor window can still be dragged by it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, let window, event.locationInWindow.y >= window.frame.height - Self.toolbarHeight {
            return true
        }
        return super.acceptsFirstMouse(for: event)
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let state: EditorState
    var onClose: ((EditorWindowController) -> Void)?

    init(shot: Shot, recentID: UUID? = nil, annotations: [Annotation] = []) {
        state = EditorState(shot: shot, recentID: recentID, annotations: annotations)

        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let canvas = state.canvasSize
        let inspector: CGFloat = state.showInspector ? 249 : 0
        let width = min(visible.width * 0.9, max(1160, canvas.width + 96 + inspector))
        let height = min(visible.height * 0.9, max(600, canvas.height + 96 + 53))

        let window = EditorWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.editorState = state
        window.title = "Cappy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.minSize = CGSize(width: 1160, height: 480)
        window.contentView = EditorHostingView(rootView: EditorView(state: state))
        window.setContentSize(CGSize(width: width, height: height))
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        state.persist()
        onClose?(self)
    }

    // MARK: Menu actions (reached through the responder chain)

    /// ⌘C copies the mouse-selected text when there is one, otherwise the image.
    ///
    /// Selection helpers such as PopClip press ⌘C on the user's behalf after
    /// every mouse drag to find out what was selected. Answering that with the
    /// whole image would replace the clipboard and flash "copied" after a
    /// marquee or a drawn shape, so a ⌘C that another process synthesized only
    /// ever copies selected text.
    @objc func copy(_ sender: Any?) {
        if state.copySelectedText() { return }
        if Self.isSynthesizedByAnotherProcess(NSApp.currentEvent) { return }
        state.copyToClipboard()
    }

    /// True for a key event posted by another process rather than typed on a keyboard.
    static func isSynthesizedByAnotherProcess(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown || event.type == .keyUp, let cgEvent = event.cgEvent else { return false }
        let pid = cgEvent.getIntegerValueField(.eventSourceUnixProcessID)
        return pid != 0 && pid != Int64(getpid())
    }

    @objc override func selectAll(_ sender: Any?) { state.selectAllText() }
    // Not named `undo:` / `redo:`: NSWindow answers those itself (for its own,
    // empty, undo manager), so the actions would never get past the window.
    @objc func undoEdit(_ sender: Any?) {
        if !forwardToFieldEditor(Selector(("undo:"))) { state.undo() }
    }

    @objc func redoEdit(_ sender: Any?) {
        if !forwardToFieldEditor(Selector(("redo:"))) { state.redo() }
    }

    /// While a text annotation is being typed, ⌘Z undoes typing rather than annotations.
    private func forwardToFieldEditor(_ action: Selector) -> Bool {
        guard let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        editor.undoManager.map { action == Selector(("undo:")) ? $0.undo() : $0.redo() }
        return true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let typing = (window?.firstResponder as? NSTextView)?.isFieldEditor == true
        switch item.action {
        case #selector(undoEdit(_:)): return typing || state.canUndo
        case #selector(redoEdit(_:)): return typing || state.canRedo
        default: return true
        }
    }
    @objc func delete(_ sender: Any?) { state.deleteSelected() }
    @objc func saveDocument(_ sender: Any?) { state.save(from: window) }
    @objc func pinImage(_ sender: Any?) { state.pinToScreen() }
    @objc func zoomImageIn(_ sender: Any?) { state.canvas?.setZoom(state.zoom * 1.25) }
    @objc func zoomImageOut(_ sender: Any?) { state.canvas?.setZoom(state.zoom / 1.25) }
    @objc func zoomImageToFit(_ sender: Any?) { state.canvas?.zoomToFit() }
    @objc func zoomImageToActualSize(_ sender: Any?) { state.canvas?.setZoom(1) }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "关于 Cappy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 Cappy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "退出 Cappy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, title: "Cappy", to: main)

        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "保存…", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "悬浮到屏幕", action: #selector(EditorWindowController.pinImage(_:)), keyEquivalent: "f")
        file.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: "文件", to: main)

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: #selector(EditorWindowController.undoEdit(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: #selector(EditorWindowController.redoEdit(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, title: "编辑", to: main)

        let view = NSMenu(title: "显示")
        view.addItem(withTitle: "放大", action: #selector(EditorWindowController.zoomImageIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "缩小", action: #selector(EditorWindowController.zoomImageOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "适应窗口", action: #selector(EditorWindowController.zoomImageToFit(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "实际大小", action: #selector(EditorWindowController.zoomImageToActualSize(_:)), keyEquivalent: "1")
        add(view, title: "显示", to: main)

        return main
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}

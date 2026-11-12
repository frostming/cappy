import AppKit
import SwiftUI

final class EditorWindow: NSWindow {
    weak var editorState: EditorState?

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

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let state: EditorState
    var onClose: ((EditorWindowController) -> Void)?

    init(shot: Shot, recentID: UUID? = nil, annotations: [Annotation] = []) {
        state = EditorState(shot: shot, recentID: recentID, annotations: annotations)

        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let canvas = state.canvasSize
        let inspector: CGFloat = state.showInspector ? 249 : 0
        let width = min(visible.width * 0.9, max(1000, canvas.width + 96 + inspector))
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
        window.minSize = CGSize(width: 1000, height: 480)
        window.contentView = NSHostingView(rootView: EditorView(state: state))
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

    @objc func copy(_ sender: Any?) { state.copyToClipboard() }
    @objc func undo(_ sender: Any?) { state.undo() }
    @objc func redo(_ sender: Any?) { state.redo() }
    @objc func delete(_ sender: Any?) { state.deleteSelected() }
    @objc func saveDocument(_ sender: Any?) { state.save(from: window) }
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
        file.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, title: "文件", to: main)

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
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

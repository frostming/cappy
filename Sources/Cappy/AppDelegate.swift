import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

enum CaptureMode: Int, CaseIterable {
    case region, window, fullscreen, scroll, ocr

    var title: String {
        switch self {
        case .region: return "区域截图"
        case .window: return "窗口截图"
        case .fullscreen: return "全屏截图"
        case .scroll: return "滚动长截图"
        case .ocr: return "截取文字 (OCR)"
        }
    }

    var symbol: String {
        switch self {
        case .region: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullscreen: return "display"
        case .scroll: return "arrow.up.and.down.text.horizontal"
        case .ocr: return "text.viewfinder"
        }
    }

    /// ⌃⌥1 … ⌃⌥5
    var keyCode: Int {
        [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5][rawValue]
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: SelectionOverlayController?
    private var scrollSession: ScrollCaptureController?
    private var editors: [EditorWindowController] = []
    private var preparing = false
    private let recentMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        setUpStatusItem()
        for mode in CaptureMode.allCases {
            HotKeyCenter.shared.register(keyCode: mode.keyCode, modifiers: controlKey | optionKey) { [weak self] in
                self?.begin(mode)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        editors.forEach { $0.state.persist() }
        RecentStore.shared.flush()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Cappy")

        let menu = NSMenu()
        for mode in CaptureMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(captureItemClicked(_:)),
                                  keyEquivalent: "\(mode.rawValue + 1)")
            item.keyEquivalentModifierMask = [.control, .option]
            item.tag = mode.rawValue
            item.target = self
            item.image = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)
            menu.addItem(item)
            if mode == .scroll { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        let recent = NSMenuItem(title: "最近截图", action: nil, keyEquivalent: "")
        recent.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        recent.submenu = recentMenu
        recentMenu.delegate = self
        menu.addItem(recent)
        menu.addItem(withTitle: "打开图片…", action: #selector(openImageFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "编辑剪贴板中的图片", action: #selector(openClipboardImage), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Cappy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    // MARK: Recent captures

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let entries = RecentStore.shared.entries().prefix(RecentStore.limit)
        guard !entries.isEmpty else {
            menu.addItem(withTitle: "暂无截图", action: nil, keyEquivalent: "")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(entries.last!.date) ? "HH:mm:ss" : "M月d日 HH:mm"
        for entry in entries {
            let size = "\(Int(CGFloat(entry.width) / entry.scale)) × \(Int(CGFloat(entry.height) / entry.scale))"
            var title = "\(formatter.string(from: entry.date))   \(size)"
            if !entry.annotations.isEmpty { title += "   · \(entry.annotations.count) 处标注" }
            let item = NSMenuItem(title: title, action: #selector(recentItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            if let thumb = RecentStore.shared.thumbnail(entry.id) {
                let height: CGFloat = 40
                thumb.size = CGSize(width: max(24, thumb.size.width * height / max(1, thumb.size.height)), height: height)
                item.image = thumb
            }
            menu.addItem(item)
        }
    }

    @objc private func recentItemClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        if let open = editors.first(where: { $0.state.recentID == id }) {
            NSApp.activate(ignoringOtherApps: true)
            open.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let loaded = RecentStore.shared.load(id) else {
            Toast.show("这张截图已不存在")
            return
        }
        openEditor(loaded.shot, recentID: id, annotations: loaded.annotations)
    }

    /// Opens a fresh capture in the editor and remembers it in the recent list.
    private func openCapture(_ shot: Shot) {
        openEditor(shot, recentID: RecentStore.shared.add(shot))
    }

    @objc private func captureItemClicked(_ sender: NSMenuItem) {
        guard let mode = CaptureMode(rawValue: sender.tag) else { return }
        // Give the menu a moment to close so it is not part of the capture.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.begin(mode) }
    }

    // MARK: Capture flows

    func begin(_ mode: CaptureMode) {
        if let session = scrollSession {
            // Any capture shortcut ends a running scroll capture.
            session.finish()
            return
        }
        guard overlay == nil, !preparing, ensurePermission() else { return }
        preparing = true
        Task { @MainActor in
            defer { self.preparing = false }
            do {
                if mode == .fullscreen {
                    self.openCapture(try await ScreenCapture.captureDisplay(NSScreen.underMouse))
                    return
                }
                let content = try await ScreenCapture.shareableContent()
                var shots: [(screen: NSScreen, shot: Shot)] = []
                for screen in NSScreen.screens {
                    shots.append((screen, try await ScreenCapture.captureDisplay(screen, content: content)))
                }
                let hint: String
                switch mode {
                case .scroll: hint = "拖拽框选要滚动截取的区域"
                case .ocr: hint = "拖拽框选要识别文字的区域"
                default: hint = "拖拽选择截图区域"
                }
                let controller = SelectionOverlayController(
                    shots: shots, windows: ScreenCapture.onScreenWindows(),
                    mode: mode == .window ? .window : .region,
                    allowsWindowToggle: mode == .region || mode == .window,
                    regionHint: hint
                ) { [weak self] result in
                    self?.overlay = nil
                    self?.handle(result, mode: mode)
                }
                self.overlay = controller
                controller.show()
            } catch {
                self.report(error)
            }
        }
    }

    private func handle(_ result: OverlayResult, mode: CaptureMode) {
        switch result {
        case .cancelled:
            break
        case .window(let info, let fallback):
            Task { @MainActor in
                let shot = (try? await ScreenCapture.captureWindow(info.id)) ?? fallback
                self.openCapture(shot)
            }
        case .region(let screen, let rect, let shot):
            switch mode {
            case .scroll:
                let session = ScrollCaptureController(screen: screen, rect: rect) { [weak self] shot in
                    self?.scrollSession = nil
                    if let shot { self?.openCapture(shot) }
                }
                scrollSession = session
                session.start()
            case .ocr:
                recognizeText(in: shot)
            default:
                openCapture(shot)
            }
        }
    }

    private func recognizeText(in shot: Shot) {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = VisionService.plainText((try? VisionService.recognize(shot.image)) ?? [])
            DispatchQueue.main.async {
                guard !text.isEmpty else {
                    Toast.show("未识别到文字")
                    return
                }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Toast.show("已复制 \(text.count) 个字符")
            }
        }
    }

    // MARK: Editor

    func openEditor(_ shot: Shot, recentID: UUID? = nil, annotations: [Annotation] = []) {
        let controller = EditorWindowController(shot: shot, recentID: recentID, annotations: annotations)
        controller.onClose = { [weak self] closed in
            guard let self else { return }
            self.editors.removeAll { $0 === closed }
            if self.editors.isEmpty { NSApp.setActivationPolicy(.accessory) }
        }
        editors.append(controller)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openImageFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        open(image)
    }

    @objc private func openClipboardImage() {
        guard let image = NSImage(pasteboard: .general) else {
            Toast.show("剪贴板中没有图片")
            return
        }
        open(image)
    }

    private func open(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let scale = image.size.width > 0 ? max(1, (CGFloat(cgImage.width) / image.size.width).rounded()) : 1
        openEditor(Shot(image: cgImage, scale: scale))
    }

    // MARK: Permission & errors

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let askedKey = "askedScreenCapture"
        let askedBefore = UserDefaults.standard.bool(forKey: askedKey)
        UserDefaults.standard.set(true, forKey: askedKey)
        // The first request shows the system prompt by itself.
        if CGRequestScreenCaptureAccess() { return true }
        if askedBefore { showPermissionAlert() }
        return false
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = "请在 系统设置 › 隐私与安全性 › 屏幕与系统音频录制 中允许 Cappy，然后重新启动 Cappy。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func report(_ error: Error) {
        if !CGPreflightScreenCaptureAccess() {
            showPermissionAlert()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "截图失败"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

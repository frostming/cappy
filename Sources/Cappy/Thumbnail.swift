import AppKit

enum Clipboard {
    /// Puts an image on the general pasteboard as PNG (plus TIFF for apps
    /// that only read that, unless the image is very large).
    static func setImage(_ image: CGImage, png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if image.width * image.height < 24_000_000, let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }
}

private final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// The small preview shown in the corner of the screen after a capture, like
/// the system screenshot thumbnail: click it to edit, or let it slide away.
final class ThumbnailView: NSView {
    var onClick: () -> Void = {}
    var onClose: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    private let closeButton = NSButton()

    init(image: CGImage, frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.55).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(.init(paletteColors: [.white, NSColor(white: 0, alpha: 0.55)]))
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.frame = CGRect(x: 4, y: bounds.height - 24, width: 20, height: 20)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.isHidden = true
        addSubview(closeButton)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        toolTip = "点击编辑"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        onHover(false)
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }

    @objc private func closeClicked() { onClose() }
}

final class ThumbnailController {
    /// At most one thumbnail is on screen; a new capture replaces it.
    private(set) static var current: ThumbnailController?
    static var lifetime: TimeInterval = 4

    let panel: NSPanel
    private let restingFrame: CGRect
    private let screenEdge: CGFloat
    private var timer: Timer?
    private var dismissed = false
    /// Keeps App Nap from postponing the dismissal timer: Cappy usually sits
    /// in the background, where timers of idle apps may be delayed.
    private var activity: NSObjectProtocol?

    /// Thumbnail size for an image of the given point size: fits 200×130,
    /// never upscaled, and never thinner than 56 (long captures are cropped).
    static func thumbnailSize(for size: CGSize) -> CGSize {
        let factor = min(1, 200 / max(size.width, 1), 130 / max(size.height, 1))
        return CGSize(width: max(56, (size.width * factor).rounded()), height: max(56, (size.height * factor).rounded()))
    }

    @discardableResult
    static func show(image: CGImage, scale: CGFloat, on screen: NSScreen, animated: Bool = true,
                     onOpen: @escaping () -> Void) -> ThumbnailController {
        current?.dismiss(animated: false)
        let controller = ThumbnailController(image: image, scale: scale, screen: screen, onOpen: onOpen)
        current = controller
        controller.present(animated: animated)
        return controller
    }

    static func dismissCurrent(animated: Bool) {
        current?.dismiss(animated: animated)
    }

    private init(image: CGImage, scale: CGFloat, screen: NSScreen, onOpen: @escaping () -> Void) {
        let size = Self.thumbnailSize(for: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        let visible = screen.visibleFrame
        restingFrame = CGRect(x: visible.maxX - size.width - 16, y: visible.minY + 16, width: size.width, height: size.height)
        screenEdge = screen.frame.maxX

        panel = ThumbnailPanel(contentRect: restingFrame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar // after isFloatingPanel, which resets the level
        panel.sharingType = .none // keep it out of the next capture
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        let view = ThumbnailView(image: image, frame: CGRect(origin: .zero, size: size))
        view.onClick = { [weak self] in
            self?.dismiss(animated: false)
            onOpen()
        }
        view.onClose = { [weak self] in self?.dismiss(animated: true) }
        // Hovering keeps it around; leaving restarts the countdown.
        view.onHover = { [weak self] inside in inside ? self?.timer?.invalidate() : self?.startTimer() }
        panel.contentView = view
    }

    private var offscreenFrame: CGRect {
        CGRect(x: screenEdge + 8, y: restingFrame.minY, width: restingFrame.width, height: restingFrame.height)
    }

    private func present(animated: Bool) {
        if animated {
            panel.setFrame(offscreenFrame, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(restingFrame, display: true)
            }
        } else {
            panel.setFrame(restingFrame, display: true)
            panel.orderFrontRegardless()
        }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Showing the capture thumbnail")
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.lifetime, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
        // Common modes: keeps counting while a menu is open or something is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func dismiss(animated: Bool) {
        guard !dismissed else { return }
        dismissed = true
        timer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if ThumbnailController.current === self { ThumbnailController.current = nil }
        guard animated else {
            panel.orderOut(nil)
            return
        }
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(offscreenFrame, display: true)
        }, completionHandler: { panel.orderOut(nil) })
    }
}

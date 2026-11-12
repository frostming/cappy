import AppKit
import ApplicationServices
import SwiftUI

final class ScrollHUDModel: ObservableObject {
    @Published var status = "请缓慢向下滚动页面"
    @Published var warning = false
    @Published var height = 0
    @Published var auto = false
    var onToggleAuto: () -> Void = {}
    var onDone: () -> Void = {}
    var onCancel: () -> Void = {}
}

private struct ScrollHUDView: View {
    @ObservedObject var model: ScrollHUDModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.warning ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(model.warning ? Color.orange : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.status).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("已拼接 \(model.height) px").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle("自动滚动", isOn: Binding(get: { model.auto }, set: { _ in model.onToggleAuto() }))
                .toggleStyle(.button)
                .controlSize(.small)
            Button("取消") { model.onCancel() }.controlSize(.small)
            Button("完成") { model.onDone() }.controlSize(.small).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .frame(width: 440, height: 52)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private final class RegionFrameView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}

/// Drives a scrolling capture: repeatedly grabs the selected region while the
/// page scrolls (manually or automatically) and feeds frames to the stitcher.
final class ScrollCaptureController {
    private let screen: NSScreen
    /// Region in points, relative to the screen's top-left corner.
    private let rect: CGRect
    private let completion: (Shot?) -> Void
    private let stitcher = ScrollStitcher()
    private let model = ScrollHUDModel()
    private var frameWindow: NSWindow?
    private var hud: NSPanel?
    private var loop: Task<Void, Never>?
    private var running = false
    private var scale: CGFloat = 2

    init(screen: NSScreen, rect: CGRect, completion: @escaping (Shot?) -> Void) {
        self.screen = screen
        self.rect = rect.integral
        self.completion = completion
    }

    /// Region in AppKit global coordinates.
    private var appKitRect: CGRect {
        CGRect(x: screen.frame.minX + rect.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    func start() {
        running = true
        showChrome()
        model.onDone = { [weak self] in self?.finish() }
        model.onCancel = { [weak self] in self?.cancel() }
        model.onToggleAuto = { [weak self] in self?.toggleAuto() }
        loop = Task { @MainActor [weak self] in await self?.run() }
    }

    func finish() { stop(deliver: true) }

    func cancel() { stop(deliver: false) }

    private func stop(deliver: Bool) {
        guard running else { return }
        running = false
        loop?.cancel()
        frameWindow?.orderOut(nil)
        hud?.orderOut(nil)
        frameWindow = nil
        hud = nil
        if deliver, let image = stitcher.makeImage() {
            completion(Shot(image: image, scale: scale))
        } else {
            completion(nil)
        }
    }

    // MARK: Capture loop

    @MainActor
    private func run() async {
        let capture: () async throws -> Shot
        do {
            capture = try await ScreenCapture.displayCapturer(screen, rect: rect, excludingSelf: true)
        } catch {
            model.status = "截图失败：\(error.localizedDescription)"
            model.warning = true
            return
        }
        // Let the selection overlay disappear before the first frame.
        try? await Task.sleep(nanoseconds: 200_000_000)

        var idle = 0
        while running, !Task.isCancelled {
            guard let shot = try? await capture() else {
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            scale = shot.scale
            let stitcher = self.stitcher
            let outcome = await Task.detached(priority: .userInitiated) { stitcher.add(shot.image) }.value
            guard running else { return }
            model.height = stitcher.rows

            switch outcome {
            case .first:
                idle = 0
            case .appended:
                idle = 0
                model.warning = false
                model.status = model.auto ? "正在自动滚动…" : "正在拼接，继续向下滚动"
            case .unchanged:
                idle += 1
                if model.auto, idle >= 4 {
                    finish()
                    return
                }
            case .noMatch:
                idle += 1
                model.warning = true
                model.status = "未能对齐：滚动太快，请往回滚一点"
                if model.auto, idle >= 8 {
                    finish()
                    return
                }
            case .full:
                finish()
                return
            }

            if model.auto {
                postScroll()
                try? await Task.sleep(nanoseconds: 380_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 110_000_000)
            }
        }
    }

    // MARK: Auto scroll

    private func toggleAuto() {
        if model.auto {
            model.auto = false
            model.status = "请缓慢向下滚动页面"
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            model.warning = true
            model.status = "自动滚动需要「辅助功能」权限"
            return
        }
        // Scroll events go to whatever is under the pointer.
        let origin = CGDisplayBounds(screen.displayID).origin
        CGWarpMouseCursorPosition(CGPoint(x: origin.x + rect.midX, y: origin.y + rect.midY))
        model.warning = false
        model.auto = true
        model.status = "正在自动滚动…"
    }

    private func postScroll() {
        let distance = Int32(max(40, rect.height * 0.35))
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: -distance, wheel2: 0, wheel3: 0) else { return }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Chrome

    private func showChrome() {
        let region = appKitRect
        let frame = NSWindow(contentRect: region.insetBy(dx: -3, dy: -3), styleMask: .borderless,
                             backing: .buffered, defer: false)
        frame.isOpaque = false
        frame.backgroundColor = .clear
        frame.hasShadow = false
        frame.ignoresMouseEvents = true
        frame.level = .statusBar
        frame.sharingType = .none
        frame.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        frame.isReleasedWhenClosed = false
        frame.contentView = RegionFrameView()
        frame.orderFrontRegardless()
        frameWindow = frame

        let size = CGSize(width: 440, height: 52)
        let visible = screen.visibleFrame
        var origin = CGPoint(x: region.midX - size.width / 2, y: region.minY - size.height - 12)
        if origin.y < visible.minY + 4 { origin.y = region.maxY + 12 }
        if origin.y + size.height > visible.maxY - 4 { origin.y = region.minY + 12 }
        origin.x = max(visible.minX + 8, min(visible.maxX - size.width - 8, origin.x))

        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.sharingType = .none
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ScrollHUDView(model: model))
        panel.orderFrontRegardless()
        hud = panel
    }
}

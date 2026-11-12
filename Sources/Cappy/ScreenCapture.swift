import AppKit
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Screen under the mouse pointer.
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(p) } ?? main ?? screens[0]
    }
}

struct WindowInfo {
    let id: CGWindowID
    /// Frame in global display coordinates (origin at the primary display's top-left).
    let frame: CGRect
}

enum CaptureError: LocalizedError {
    case displayNotFound
    case windowNotFound

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "找不到要截取的显示器"
        case .windowNotFound: return "找不到要截取的窗口"
        }
    }
}

enum ScreenCapture {
    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Builds a reusable capture closure for a display (or a sub-rectangle of
    /// it, in points relative to the display's top-left corner).
    static func displayCapturer(_ screen: NSScreen, rect: CGRect? = nil, excludingSelf: Bool = false,
                                content: SCShareableContent? = nil) async throws -> () async throws -> Shot {
        let content = try await (content == nil ? shareableContent() : content!)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw CaptureError.displayNotFound
        }
        let filter: SCContentFilter
        if excludingSelf, let me = content.applications.first(where: { $0.processID == getpid() }) {
            filter = SCContentFilter(display: display, excludingApplications: [me], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let scale = screen.backingScaleFactor
        let area = (rect ?? CGRect(origin: .zero, size: screen.frame.size)).integral
        let config = SCStreamConfiguration()
        if rect != nil { config.sourceRect = area }
        config.width = Int((area.width * scale).rounded())
        config.height = Int((area.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return Shot(image: image, scale: scale)
        }
    }

    static func captureDisplay(_ screen: NSScreen, content: SCShareableContent? = nil) async throws -> Shot {
        try await displayCapturer(screen, content: content)()
    }

    /// Captures a single window on its own: transparent corners, no shadow,
    /// nothing overlapping it.
    static func captureWindow(_ id: CGWindowID) async throws -> Shot {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Shot(image: image, scale: scale)
    }

    /// Normal application windows, front to back, excluding our own.
    static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != me,
                  ((info[kCGWindowAlpha as String] as? Double) ?? 1) > 0.01,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= 40, frame.height >= 40 else { return nil }
            return WindowInfo(id: id, frame: frame)
        }
    }
}

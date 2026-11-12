import AppKit
import SwiftUI

/// Offline checks that need no screen-recording permission:
/// `Cappy --selftest <output directory>`
enum SelfTest {
    private static var failures = 0

    private static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL")  \(label)")
        if !condition { failures += 1 }
    }

    static func run(outputDirectory: String) -> Bool {
        let dir = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let shot = makeDocumentShot()
        write(shot.image, scale: shot.scale, to: dir.appendingPathComponent("1-source.png"))

        testVision(shot)
        testTextSelection(shot)
        testRender(shot, dir: dir)
        testStitcher(dir: dir)
        testEditorWindow(shot, dir: dir)
        testRecentStore(shot, dir: dir)
        testPin(shot)
        testOverlayZoom(shot)
        testEdgeSnapping()
        testShortcuts(dir: dir)

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0
    }

    // MARK: Fixtures

    private static let lines = [
        "Cappy 自测文档",
        "联系邮箱: alice.wang@example.com",
        "手机号码: 138-0013-8000",
        "API Key: sk-abc123def456ghi789jkl012",
        "发布日期 2026-11-12",
        "普通的一行文字 Hello World",
    ]

    private static func makeDocumentShot() -> Shot {
        let scale: CGFloat = 2
        let size = CGSize(width: 720, height: 420)
        let ctx = Bitmap.context(width: Int(size.width * scale), height: Int(size.height * scale))!
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [
                .font: NSFont.systemFont(ofSize: i == 0 ? 30 : 22, weight: i == 0 ? .bold : .regular),
                .foregroundColor: NSColor.black,
            ]).draw(at: CGPoint(x: 40, y: 36 + CGFloat(i) * 58))
        }
        NSGraphicsContext.restoreGraphicsState()
        return Shot(image: ctx.makeImage()!, scale: scale)
    }

    private static func write(_ image: CGImage, scale: CGFloat, to url: URL) {
        try? Bitmap.pngData(image, scale: scale)?.write(to: url)
    }

    // MARK: Vision

    private static func testVision(_ shot: Shot) {
        let recognized = (try? VisionService.recognize(shot.image)) ?? []
        for line in recognized { print("  OCR: \(line.text)") }
        let text = VisionService.plainText(recognized)
        check(recognized.count >= 5, "OCR finds the text lines (\(recognized.count))")
        check(text.contains("example.com"), "OCR reads the e-mail address")
        check(text.contains("自测"), "OCR reads Chinese")

        check(VisionService.sensitiveRanges(in: lines[1]).count == 1, "e-mail is sensitive")
        check(VisionService.sensitiveRanges(in: lines[2]).count == 1, "phone number is sensitive")
        check(VisionService.sensitiveRanges(in: lines[3]).count == 1, "API key is sensitive")
        check(VisionService.sensitiveRanges(in: lines[4]).isEmpty, "a date is not sensitive")
        check(VisionService.sensitiveRanges(in: lines[5]).isEmpty, "plain text is not sensitive")

        let rects = VisionService.sensitiveRects(recognized)
        check(rects.count == 3, "smart mosaic targets 3 regions (\(rects.count))")
        let full = CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height)
        check(rects.allSatisfy { full.contains($0) && $0.width < full.width * 0.7 },
              "sensitive rects cover substrings inside the image")
    }

    // MARK: Text selection

    private static func testTextSelection(_ shot: Shot) {
        let recognized = (try? VisionService.recognize(shot.image)) ?? []
        let started = Date()
        let layout = VisionService.layout(recognized, scale: shot.scale)
        let characters = layout.lines.reduce(0) { $0 + $1.chars.count }
        print(String(format: "  layout: %d lines, %d characters in %.0f ms", layout.lines.count, characters,
                     Date().timeIntervalSince(started) * 1000))
        check(layout.lines.allSatisfy { $0.chars.count == $0.text.count }, "every character has a box")
        check(layout.lines.allSatisfy { line in line.chars.allSatisfy { line.rect.insetBy(dx: -4, dy: -4).intersects($0) } },
              "character boxes lie on their line")
        check(layout.lines.allSatisfy { line in
            zip(line.chars, line.chars.dropFirst()).allSatisfy { $0.midX <= $1.midX + 0.5 }
        }, "characters run left to right, spaces included")

        guard let index = layout.lines.firstIndex(where: { $0.text.contains("alice.wang@example.com") }),
              let range = layout.lines[index].text.range(of: "alice.wang@example.com") else {
            check(false, "the e-mail line is recognized")
            return
        }
        let line = layout.lines[index]
        let from = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
        let to = line.text.distance(from: line.text.startIndex, to: range.upperBound)
        let y = line.rect.midY
        // Press just inside the first character, drag to just inside the last.
        let start = layout.position(at: CGPoint(x: line.chars[from].minX + 0.2, y: y), strict: true)
        let end = layout.position(at: CGPoint(x: line.chars[to - 1].maxX - 0.2, y: y), strict: false)
        check(start == TextPosition(line: index, caret: from) && end == TextPosition(line: index, caret: to),
              "mouse positions map to carets")
        if let start, let end {
            let selection = TextRange(anchor: end, head: start) // dragged right-to-left
            check(layout.string(for: selection) == "alice.wang@example.com", "dragging over a word selects exactly it")
            let rects = layout.rects(for: selection)
            check(rects.count == 1 && rects[0].width < line.rect.width * 0.85 && line.rect.insetBy(dx: -2, dy: -2).contains(rects[0]),
                  "the highlight covers only the selected characters")
        }
        check(layout.position(at: CGPoint(x: 5, y: 5), strict: true) == nil, "clicking empty space starts no selection")
        if index + 1 < layout.lines.count {
            let multi = TextRange(anchor: TextPosition(line: index, caret: from),
                                  head: TextPosition(line: index + 1, caret: 4))
            let text = layout.string(for: multi)
            check(text.hasPrefix("alice.wang@example.com\n") && text.count == 22 + 1 + 4, "a selection can span lines")
            check(layout.rects(for: multi).count == 2, "a multi-line selection highlights each line")
        }
        check(layout.everything.map { layout.string(for: $0) } == VisionService.plainText(recognized),
              "select-all yields the full text")
    }

    // MARK: Rendering

    private static func testRender(_ shot: Shot, dir: URL) {
        let red = RGBA.palette[0], blue = RGBA.palette[4]
        var text = Annotation(kind: .text, start: CGPoint(x: 420, y: 300), end: .zero, color: blue, lineWidth: 5)
        text.text = "标注文字 Text"
        var pen = Annotation(kind: .pen, start: .zero, end: .zero, color: RGBA.palette[3], lineWidth: 4)
        pen.points = (0...40).map { CGPoint(x: 60 + CGFloat($0) * 6, y: 380 + sin(CGFloat($0) / 4) * 14) }
        var filled = Annotation(kind: .ellipse, start: CGPoint(x: 560, y: 30), end: CGPoint(x: 680, y: 100),
                                color: RGBA.palette[1], lineWidth: 3)
        filled.filled = true
        let annotations = [
            Annotation(kind: .rect, start: CGPoint(x: 30, y: 84), end: CGPoint(x: 470, y: 132), color: red, lineWidth: 3),
            Annotation(kind: .arrow, start: CGPoint(x: 640, y: 250), end: CGPoint(x: 480, y: 120), color: red, lineWidth: 5),
            Annotation(kind: .line, start: CGPoint(x: 40, y: 250), end: CGPoint(x: 300, y: 250), color: blue, lineWidth: 4),
            Annotation(kind: .mosaic, start: CGPoint(x: 150, y: 150), end: CGPoint(x: 330, y: 186), color: red, lineWidth: 3),
            filled, text, pen,
        ]
        let mosaic = MosaicCache(image: shot.image, scale: shot.scale)

        let plain = Renderer.render(image: shot.image, scale: shot.scale, annotations: annotations,
                                    decoration: Decoration(), mosaic: mosaic)
        check(plain?.width == shot.image.width && plain?.height == shot.image.height, "undecorated export keeps the pixel size")

        var decoration = Decoration()
        decoration.enabled = true
        decoration.borderWidth = 2
        let decorated = Renderer.render(image: shot.image, scale: shot.scale, annotations: annotations,
                                        decoration: decoration, mosaic: mosaic)
        let expectedWidth = shot.image.width + Int(decoration.padding * 2 * shot.scale)
        check(decorated?.width == expectedWidth, "decorated export adds padding")
        if let decorated { write(decorated, scale: shot.scale, to: dir.appendingPathComponent("2-decorated.png")) }

        decoration.background = .none
        let transparent = Renderer.render(image: shot.image, scale: shot.scale, annotations: [],
                                          decoration: decoration, mosaic: mosaic)
        check(transparent.map { pixel($0, x: 2, y: 2).a == 0 } ?? false, "transparent background stays transparent")
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: Bitmap.sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -CGFloat(x), y: CGFloat(y) - CGFloat(image.height) + 1,
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (p[0], p[1], p[2], p[3])
    }

    // MARK: Scroll stitching

    private static func testStitcher(dir: URL) {
        let width = 800, contentHeight = 4200, header = 64, footer = 40, viewport = 600
        // A tall "page": paragraphs of text on white with a few colored blocks.
        let page = Bitmap.context(width: width, height: contentHeight)!
        page.translateBy(x: 0, y: CGFloat(contentHeight))
        page.scaleBy(x: 1, y: -1)
        page.setFillColor(.white)
        page.fill(CGRect(x: 0, y: 0, width: width, height: contentHeight))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: page, flipped: true)
        var generator = SystemRandomNumberGenerator()
        var y = 20
        var index = 0
        while y < contentHeight - 40 {
            index += 1
            if index % 9 == 0 {
                NSColor(hue: CGFloat.random(in: 0...1, using: &generator), saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: 40, y: y, width: 520, height: 120), xRadius: 12, yRadius: 12).fill()
                y += 150
            } else {
                let words = (0..<Int.random(in: 4...11, using: &generator)).map { _ in
                    String((0..<Int.random(in: 2...9, using: &generator)).map { _ in
                        "abcdefghijklmnopqrstuvwxyz".randomElement(using: &generator)!
                    })
                }
                NSAttributedString(string: "\(index). " + words.joined(separator: " "), attributes: [
                    .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black,
                ]).draw(at: CGPoint(x: 40, y: y))
                y += 38
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        let pageImage = page.makeImage()!

        // Viewport frame = sticky header + scrolled content + sticky footer.
        func frame(at offset: Int) -> CGImage {
            let h = header + viewport + footer
            let ctx = Bitmap.context(width: width, height: h)!
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.drawFlipped(pageImage.cropping(to: CGRect(x: 0, y: offset, width: width, height: viewport))!,
                            in: CGRect(x: 0, y: header, width: width, height: viewport))
            ctx.setFillColor(CGColor(srgbRed: 0.15, green: 0.2, blue: 0.45, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: header))
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.88, alpha: 1))
            ctx.fill(CGRect(x: 0, y: header + viewport, width: width, height: footer))
            return ctx.makeImage()!
        }

        let stitcher = ScrollStitcher()
        var offset = 0
        var outcomes: [ScrollStitcher.Outcome] = [stitcher.add(frame(at: 0))]
        let steps = [137, 211, 0, 96, 333, 250, 401, 180, 77, 290, 310, 222, 365, 144, 199, 280]
        var expectedOffsets: [ScrollStitcher.Outcome] = [.first]
        for step in steps {
            let next = min(offset + step, contentHeight - viewport)
            let delta = next - offset
            offset = next
            expectedOffsets.append(delta == 0 ? .unchanged : .appended(delta))
            outcomes.append(stitcher.add(frame(at: offset)))
        }
        check(outcomes == expectedOffsets, "stitcher recovers every scroll offset")
        if outcomes != expectedOffsets { print("  got \(outcomes)\n  expected \(expectedOffsets)") }

        let expectedRows = header + offset + viewport + footer
        check(stitcher.rows == expectedRows, "stitched height \(stitcher.rows) == \(expectedRows)")

        // A jump larger than the viewport cannot be aligned and must be rejected.
        let probe = ScrollStitcher()
        _ = probe.add(frame(at: 0))
        check(probe.add(frame(at: 1900)) == .noMatch, "unalignable frame is rejected")

        guard let result = stitcher.makeImage() else {
            check(false, "stitcher produces an image")
            return
        }
        write(result, scale: 1, to: dir.appendingPathComponent("3-stitched.png"))
        // Content rows must equal the original page.
        let expected = pageImage.cropping(to: CGRect(x: 0, y: 0, width: width, height: offset + viewport))!
        let actual = result.cropping(to: CGRect(x: 0, y: header, width: width, height: offset + viewport))!
        check(maxDifference(expected, actual) <= 2, "stitched content matches the page pixel for pixel")
    }

    private static func maxDifference(_ a: CGImage, _ b: CGImage) -> Int {
        guard a.width == b.width, a.height == b.height else { return 255 }
        func bytes(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            data.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: Bitmap.sRGB,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        let x = bytes(a), y = bytes(b)
        var worst = 0
        for i in 0..<x.count { worst = max(worst, abs(Int(x[i]) - Int(y[i]))) }
        return worst
    }

    // MARK: Capture overlay

    private static func testOverlayZoom(_ shot: Shot) {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { return }
        // Stand-in "screen": the fixture image shown at its point size.
        let size = shot.pointSize
        var result: OverlayResult?
        let controller = SelectionOverlayController(shots: [(screen, shot)], windows: [], mode: .region,
                                                    allowsWindowToggle: true, regionHint: "") { result = $0 }
        let view = OverlayView(frame: CGRect(origin: .zero, size: size), screen: screen, shot: shot, windows: [],
                               controller: controller)
        let host = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        host.contentView = view

        let pointer = CGPoint(x: 200, y: 120)
        let before = view.screenPoint(pointer)
        view.zoom(by: 4, at: pointer)
        let after = view.screenPoint(pointer)
        check(view.zoom == 4, "the wheel magnifies the frozen screen")
        check(abs(after.x - before.x) < 0.01 && abs(after.y - before.y) < 0.01, "zooming keeps the point under the pointer")
        view.zoom(by: 100, at: pointer)
        check(view.zoom == OverlayView.maxZoom, "magnification is capped")
        view.zoom(by: 0.001, at: pointer)
        check(view.zoom == 1 && view.offset == .zero, "zooming out returns to the full screen")

        // Select while magnified: the capture is the right screen area at native resolution.
        view.zoom(by: 4, at: pointer)
        func event(_ type: NSEvent.EventType, screenPoint p: CGPoint) -> NSEvent? {
            // screen point → view point (flipped) → window coordinates (y up)
            let v = CGPoint(x: (p.x - view.offset.x) * view.zoom, y: (p.y - view.offset.y) * view.zoom)
            return NSEvent.mouseEvent(with: type, location: CGPoint(x: v.x, y: size.height - v.y), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let a = CGPoint(x: 180.5, y: 100.5), b = CGPoint(x: 230, y: 140)
        if let down = event(.leftMouseDown, screenPoint: a), let drag = event(.leftMouseDragged, screenPoint: b),
           let up = event(.leftMouseUp, screenPoint: b) {
            view.mouseDown(with: down)
            view.mouseDragged(with: drag)
            view.mouseUp(with: up)
        }
        if case .region(_, let rect, let cropped)? = result {
            check(rect == CGRect(x: 180.5, y: 100.5, width: 49.5, height: 39.5), "a magnified selection maps back to screen points, to the half point")
            check(cropped.image.width == 99 && cropped.image.height == 79 && cropped.scale == shot.scale,
                  "the capture stays at native resolution")
            let expected = shot.image.cropping(to: CGRect(x: 361, y: 201, width: 99, height: 79))
            check(expected.map { maxDifference($0, cropped.image) == 0 } ?? false, "the captured pixels are the selected ones")
        } else {
            check(false, "selecting while magnified produces a capture")
        }
    }

    /// Holding ⌘ while dragging snaps the selection to visible edges.
    private static func testEdgeSnapping() {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { return }
        // A light "screen" with one dark panel at pixels x 203..<601, y 141..<447 (2x).
        let scale: CGFloat = 2
        let size = CGSize(width: 500, height: 320)
        let panel = CGRect(x: 203, y: 141, width: 398, height: 306)
        let ctx = Bitmap.context(width: Int(size.width * scale), height: Int(size.height * scale))!
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fill(panel)
        let shot = Shot(image: ctx.makeImage()!, scale: scale)

        func select(command: Bool, from a: CGPoint, to b: CGPoint) -> CGRect? {
            var result: OverlayResult?
            let controller = SelectionOverlayController(shots: [(screen, shot)], windows: [], mode: .region,
                                                        allowsWindowToggle: true, regionHint: "") { result = $0 }
            let view = OverlayView(frame: CGRect(origin: .zero, size: size), screen: screen, shot: shot, windows: [],
                                   controller: controller)
            let host = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
            host.contentView = view
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: size.height - p.y),
                                   modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = event(.leftMouseDown, a), let drag = event(.leftMouseDragged, b), let up = event(.leftMouseUp, b) {
                view.mouseDown(with: down)
                view.mouseDragged(with: drag)
                view.mouseUp(with: up)
            }
            if case .region(_, let rect, _)? = result { return rect }
            return nil
        }

        // Drag sloppily around the panel: a few points outside on one corner, inside on the other.
        let a = CGPoint(x: 96, y: 66), b = CGPoint(x: 296, y: 228)
        let exact = CGRect(x: panel.minX / scale, y: panel.minY / scale, width: panel.width / scale, height: panel.height / scale)
        check(select(command: true, from: a, to: b) == exact, "holding ⌘ snaps the selection to the panel's edges")
        check(select(command: false, from: a, to: b) == CGRect(x: 96, y: 66, width: 200, height: 162),
              "without ⌘ the selection follows the pointer")
        // Too far from any edge: nothing to snap to, so the pointer wins.
        let far = select(command: true, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 70, y: 50))
        check(far == CGRect(x: 20, y: 20, width: 50, height: 30), "⌘ leaves the selection alone when no edge is near")
    }

    // MARK: Shortcuts

    private static func testShortcuts(dir: URL) {
        let defaults = CaptureMode.allCases.map { ShortcutStore.defaultShortcut(for: $0) }
        check(defaults.map(\.display) == ["⌃⌥A", "⌃⌥S", "⌃⌥D", "⌃⌥F"], "default shortcuts are ⌃⌥ + A S D F")
        check(Set(defaults.map(\.display)).count == CaptureMode.allCases.count, "every mode has its own shortcut")

        func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: keyCode)
        }
        let recorded = press("x", keyCode: 7, [.command, .shift]).flatMap(Shortcut.init(event:))
        check(recorded?.display == "⇧⌘X" && recorded?.menuKeyEquivalent == "x" && recorded?.modifierFlags == [.command, .shift],
              "a key press becomes a shortcut")
        check(press("x", keyCode: 7, []).flatMap(Shortcut.init(event:)) == nil
              && press("X", keyCode: 7, .shift).flatMap(Shortcut.init(event:)) == nil,
              "a shortcut needs ⌘, ⌃ or ⌥")
        check(press("\u{F708}", keyCode: 96, .control).flatMap(Shortcut.init(event:))?.display == "⌃F5", "function keys are named")

        // Stored per mode; removing one is remembered; reset restores the defaults.
        let suite = "cappy.selftest.\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite), let custom = recorded else { return }
        defer { store.removePersistentDomain(forName: suite) }
        check(ShortcutStore.shortcut(for: .region, in: store) == defaults[0], "unset shortcuts fall back to the default")
        ShortcutStore.set(custom, for: .region, in: store)
        ShortcutStore.set(nil, for: .scroll, in: store)
        check(ShortcutStore.shortcut(for: .region, in: store) == custom, "a custom shortcut is saved")
        check(ShortcutStore.shortcut(for: .scroll, in: store) == nil, "a removed shortcut stays removed")
        check(ShortcutStore.shortcut(for: .window, in: store) == defaults[1], "other modes keep theirs")
        ShortcutStore.resetAll(in: store)
        check(CaptureMode.allCases.map { ShortcutStore.shortcut(for: $0, in: store) } == defaults, "reset restores the defaults")

        // The recorder button: Esc cancels, a combination sets, Delete clears.
        let button = ShortcutRecorderButton()
        button.shortcut = defaults[0]
        var changes: [Shortcut?] = []
        button.onChange = { changes.append($0) }
        button.performClick(nil)
        check(button.title == "请按下快捷键…", "clicking the recorder starts listening")
        if let escape = press("\u{1B}", keyCode: 53, []) { button.handle(escape) }
        check(button.title == "⌃⌥A" && changes.isEmpty, "Esc cancels recording")
        button.performClick(nil)
        if let combo = press("x", keyCode: 7, [.command, .shift]) { button.handle(combo) }
        check(button.title == "⇧⌘X" && changes == [custom], "a combination is recorded")
        button.performClick(nil)
        if let delete = press("\u{7F}", keyCode: 51, []) { button.handle(delete) }
        check(button.title == "未设置" && changes.count == 2 && changes[1] == nil, "Delete removes the shortcut")

        // Snapshot of the settings window for a visual check.
        _ = NSApplication.shared
        let settings = ShortcutSettingsWindowController()
        if let content = settings.window?.contentView {
            settings.window?.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                if let image = rep.cgImage { write(image, scale: 2, to: dir.appendingPathComponent("5-shortcuts.png")) }
            }
            settings.window?.orderOut(nil)
        }
    }

    // MARK: Pinning

    private static func testPin(_ shot: Shot) {
        _ = NSApplication.shared
        let before = PinManager.panels.count
        let panel = PinManager.pin(shot.image, scale: shot.scale)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check(PinManager.panels.count == before + 1 && panel.isVisible, "pinning shows a floating panel")
        check(panel.level == .floating, "the pinned image floats above normal windows")
        check(panel.frame.size == shot.pointSize, "the pinned image keeps its point size")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                      context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                      isARepeat: false, keyCode: 53)
        // Scroll-wheel resizing keeps the point under the pointer and is clamped.
        if let pinView = panel.contentView as? PinView {
            let start = panel.frame
            let anchor = CGPoint(x: start.minX + start.width * 0.25, y: start.minY + start.height * 0.75)
            pinView.zoom(by: 2, around: anchor)
            let grown = panel.frame
            check(abs(grown.width - start.width * 2) <= 1 && abs(grown.height - start.height * 2) <= 1,
                  "scrolling resizes the pinned image")
            check(abs((anchor.x - grown.minX) / grown.width - 0.25) < 0.01
                  && abs((anchor.y - grown.minY) / grown.height - 0.75) < 0.01,
                  "resizing keeps the point under the pointer")
            pinView.zoom(by: 1000, around: anchor)
            check(abs(panel.frame.width - shot.pointSize.width * 8) <= 1, "pinned image size is capped")
            pinView.zoom(by: 0.0001, around: anchor)
            check(abs(panel.frame.width - shot.pointSize.width * 0.2) <= 1, "pinned image cannot shrink to nothing")
        }
        if let escape { panel.contentView?.keyDown(with: escape) }
        check(PinManager.panels.count == before && !panel.isVisible, "Esc dismisses the pinned image")

        // Double-click goes back to the editor and takes the pin down.
        var edits = 0
        let editable = PinManager.pin(shot.image, scale: shot.scale) { edits += 1 }
        func click(_ count: Int) {
            if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 20), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: editable.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: count, pressure: 1) {
                editable.contentView?.mouseDown(with: event)
            }
        }
        click(2)
        check(edits == 1, "double-clicking a pinned image reopens the editor")
        check(PinManager.panels.count == before && !editable.isVisible, "the pin is removed when editing resumes")
    }

    // MARK: Recent captures

    private static func testRecentStore(_ shot: Shot, dir: URL) {
        let folder = dir.appendingPathComponent("recent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = RecentStore(directory: folder)
        var ids: [UUID] = []
        for _ in 0..<7 {
            ids.append(store.add(shot))
            Thread.sleep(forTimeInterval: 0.01)
        }
        let entries = store.entries()
        check(entries.count == RecentStore.limit, "recent list keeps only \(RecentStore.limit) captures (\(entries.count))")
        check(entries.map(\.id) == Array(ids.suffix(RecentStore.limit).reversed()), "recent list is newest first")
        check(store.load(ids[0]) == nil, "oldest captures are pruned")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check(files.count == RecentStore.limit * 3, "pruned files are deleted (\(files.count) files)")

        let note = Annotation(kind: .arrow, start: CGPoint(x: 10, y: 20), end: CGPoint(x: 200, y: 120),
                              color: RGBA.palette[0], lineWidth: 5)
        store.update(ids[6], annotations: [note])
        store.flush()
        // A second store instance stands in for the app after a relaunch.
        let reopened = RecentStore(directory: folder).load(ids[6])
        check(reopened?.annotations == [note], "annotations survive a relaunch")
        check(reopened?.shot.image.width == shot.image.width && reopened?.shot.scale == shot.scale,
              "reopened image keeps its size and scale")
        check(reopened.map { maxDifference($0.shot.image, shot.image) == 0 } ?? false, "reopened image is lossless")
        check(store.thumbnail(ids[6]) != nil, "thumbnail is available")
    }

    // MARK: Editor window

    private static func testEditorWindow(_ shot: Shot, dir: URL) {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "decoration.v1")
        let controller = EditorWindowController(shot: shot)
        let state = controller.state
        guard let window = controller.window, let content = window.contentView else {
            check(false, "editor window exists")
            return
        }
        window.orderFrontRegardless()
        func pump(_ seconds: TimeInterval = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        pump()

        state.annotations = [
            Annotation(kind: .arrow, start: CGPoint(x: 620, y: 240), end: CGPoint(x: 470, y: 120),
                       color: RGBA.palette[0], lineWidth: 5),
            Annotation(kind: .rect, start: CGPoint(x: 30, y: 84), end: CGPoint(x: 470, y: 132),
                       color: RGBA.palette[0], lineWidth: 3),
        ]
        state.selectedID = state.annotations[1].id
        state.toggleInspector()
        pump()

        check(state.canvas != nil, "canvas is mounted")
        check(state.decoration.enabled, "opening the inspector enables decoration")
        if let canvas = state.canvas {
            let expected = CGSize(width: (state.canvasSize.width * state.zoom).rounded(),
                                  height: (state.canvasSize.height * state.zoom).rounded())
            check(canvas.frame.size == expected, "canvas frame follows zoom (\(Int(state.zoom * 100))%)")
        }

        // Toolbar controls live under the transparent title bar; make sure
        // clicks there reach the SwiftUI content rather than the title bar.
        if let frameView = content.superview {
            let inWindow = CGPoint(x: 95, y: window.frame.height - 26)
            let hit = frameView.hitTest(frameView.convert(inWindow, from: nil))
            let inContent = hit.map { $0 === content || $0.isDescendant(of: content) } ?? false
            print("  toolbar hit view: \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
            check(inContent, "toolbar buttons receive clicks")

            // The toolbar sits in the title bar area. Its controls must not
            // act as title bar (drag / double-click zoom); only the dedicated
            // drag area in the empty space behind them does.
            func click(at point: CGPoint, count: Int) {
                for n in 1...count {
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil,
                                                          eventNumber: 0, clickCount: n, pressure: 1) {
                            window.sendEvent(event)
                        }
                    }
                }
                pump(0.8)
            }
            func hitView(at point: CGPoint) -> NSView? {
                frameView.hitTest(frameView.convert(point, from: nil))
            }
            let barY = window.frame.height - 26
            let probes = stride(from: 80, to: Int(window.frame.width) - 4, by: 4).map { CGPoint(x: CGFloat($0), y: barY) }
            check(!window.isMovable, "the system cannot drag the editor window by its toolbar")
            check(probes.allSatisfy { hitView(at: $0)?.mouseDownCanMoveWindow == false },
                  "nothing in the toolbar is a system window-drag handle")

            let button = CGPoint(x: 127, y: barY) // the arrow tool, second in the row
                        let frameBefore = window.frame
            state.tool = .select
            click(at: button, count: 2)
            check(state.tool == .arrow, "the toolbar button still responds to clicks")
            check(window.frame == frameBefore, "double-clicking a toolbar button does not zoom the window")
            window.setFrame(frameBefore, display: true)
            pump(0.3)

            // Double-clicking empty space follows the system title bar setting.
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            // The gap between the tool buttons and the first separator.
            let empty = CGPoint(x: 339, y: barY)
            if action != "None", action != "Minimize" {
                click(at: empty, count: 2)
                check(window.frame != frameBefore, "double-clicking empty toolbar space zooms the window")
                window.setFrame(frameBefore, display: true)
                pump(0.5)
            }
            state.tool = .arrow
        }

        if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let image = rep.cgImage { write(image, scale: 2, to: dir.appendingPathComponent("4-editor.png")) }
        }

        // Zooming must keep the canvas point under the pointer in place.
        if let canvas = state.canvas, let clip = canvas.enclosingScrollView?.contentView {
            let pointer = clip.convert(CGPoint(x: clip.bounds.minX + 300, y: clip.bounds.minY + 200), to: nil)
            let zoomBefore = state.zoom
            let before = canvas.convert(pointer, from: nil)
            canvas.zoom(by: 3, at: pointer)
            pump(0.1)
            let after = canvas.convert(pointer, from: nil)
            let ratio = state.zoom / zoomBefore
            check(abs(ratio - 3) < 0.01, "wheel zoom changes the zoom level")
            check(abs(after.x - before.x * ratio) < 1.5 && abs(after.y - before.y * ratio) < 1.5,
                  "zoom keeps the point under the pointer fixed")
            canvas.zoomToFit()
            pump(0.1)
        }

        // Selecting recognized text with the mouse (select tool).
        if let canvas = state.canvas {
            let deadline = Date().addingTimeInterval(8)
            while state.textLayout == nil, Date() < deadline { pump(0.1) }
            if let layout = state.textLayout,
               let line = layout.lines.first(where: { $0.text.contains("example.com") }) {
                func event(_ type: NSEvent.EventType, _ doc: CGPoint) -> NSEvent? {
                    let origin = Renderer.imageOrigin(state.decoration)
                    let inView = CGPoint(x: (doc.x + origin.x) * state.zoom, y: (doc.y + origin.y) * state.zoom)
                    return NSEvent.mouseEvent(with: type, location: canvas.convert(inView, to: nil), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                              clickCount: 1, pressure: 1)
                }
                let savedAnnotations = state.annotations, savedSelection = state.selectedID
                defer {
                    state.annotations = savedAnnotations
                    state.selectedID = savedSelection
                }
                state.annotations = []
                state.tool = .select
                pump(0.1)
                let a = CGPoint(x: line.rect.minX + 1, y: line.rect.midY)
                let b = CGPoint(x: line.rect.maxX - 1, y: line.rect.midY)
                if let down = event(.leftMouseDown, a), let dragged = event(.leftMouseDragged, b), let up = event(.leftMouseUp, b) {
                    canvas.mouseDown(with: down)
                    canvas.mouseDragged(with: dragged)
                    canvas.mouseUp(with: up)
                }
                check(state.selectedText == line.text, "dragging across a line in the editor selects its text")
                state.tool = .arrow
                pump(0.1)
                check(state.textSelection == nil, "switching to a drawing tool clears the text selection")
                state.selectAllText()
                check(state.tool == .select && state.selectedText?.contains("example.com") == true, "select-all selects every line")
                state.textSelection = nil
            } else {
                check(false, "the editor recognizes text in the background")
            }
        }

        // Marquee selection, moving a group, and Esc while typing text.
        if let canvas = state.canvas {
            func mouse(_ type: NSEvent.EventType, _ doc: CGPoint, clicks: Int = 1) {
                let origin = Renderer.imageOrigin(state.decoration)
                let inView = CGPoint(x: (doc.x + origin.x) * state.zoom, y: (doc.y + origin.y) * state.zoom)
                guard let event = NSEvent.mouseEvent(with: type, location: canvas.convert(inView, to: nil), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: clicks, pressure: 1) else { return }
                switch type {
                case .leftMouseDown: canvas.mouseDown(with: event)
                case .leftMouseDragged: canvas.mouseDragged(with: event)
                default: canvas.mouseUp(with: event)
                }
            }
            let saved = state.annotations, savedSelection = state.selectedIDs
            // Three shapes in the blank lower-right area, away from any recognized text.
            let a = Annotation(kind: .rect, start: CGPoint(x: 500, y: 300), end: CGPoint(x: 540, y: 330), color: RGBA.palette[0], lineWidth: 3)
            let b = Annotation(kind: .arrow, start: CGPoint(x: 560, y: 300), end: CGPoint(x: 600, y: 330), color: RGBA.palette[0], lineWidth: 3)
            let c = Annotation(kind: .ellipse, start: CGPoint(x: 640, y: 380), end: CGPoint(x: 680, y: 410), color: RGBA.palette[0], lineWidth: 3)
            state.annotations = [a, b, c]
            state.tool = .select
            state.select(nil)
            pump(0.1)

            mouse(.leftMouseDown, CGPoint(x: 490, y: 290))
            mouse(.leftMouseDragged, CGPoint(x: 610, y: 340))
            mouse(.leftMouseUp, CGPoint(x: 610, y: 340))
            check(state.selectedIDs == [a.id, b.id], "dragging a marquee selects the annotations it touches")

            // Drag one member: the whole group moves, the unselected one stays.
            mouse(.leftMouseDown, CGPoint(x: 500, y: 315))
            mouse(.leftMouseDragged, CGPoint(x: 520, y: 345))
            mouse(.leftMouseUp, CGPoint(x: 520, y: 345))
            let moved = state.annotations
            check(moved[0].start == CGPoint(x: 520, y: 330) && moved[1].start == CGPoint(x: 580, y: 330) && moved[2] == c,
                  "dragging one selected annotation moves the whole group")
            check(state.selectedIDs == [a.id, b.id], "the group stays selected after moving")
            state.undo()
            check(state.annotations == [a, b, c], "one undo puts the whole group back")

            // Shift-click adds a third; delete removes them all.
            if let shift = NSEvent.mouseEvent(with: .leftMouseDown,
                                              location: canvas.convert(CGPoint(x: (640 + Renderer.imageOrigin(state.decoration).x) * state.zoom,
                                                                               y: (395 + Renderer.imageOrigin(state.decoration).y) * state.zoom), to: nil),
                                              modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                canvas.mouseDown(with: shift)
                mouse(.leftMouseUp, CGPoint(x: 640, y: 395))
            }
            check(state.selectedIDs.count == 3, "shift-click adds to the selection")
            state.deleteSelected()
            check(state.annotations.isEmpty, "delete removes every selected annotation")

            // A click on empty space clears the selection.
            state.annotations = [a, b, c]
            state.selectedIDs = [a.id, b.id]
            mouse(.leftMouseDown, CGPoint(x: 620, y: 60))
            mouse(.leftMouseUp, CGPoint(x: 620, y: 60))
            check(state.selectedIDs.isEmpty, "clicking empty space clears the selection")

            // Text tool: type, then Esc leaves editing and keeps the text.
            state.annotations = []
            state.tool = .text
            pump(0.1)
            mouse(.leftMouseDown, CGPoint(x: 520, y: 360))
            mouse(.leftMouseUp, CGPoint(x: 520, y: 360))
            if let field = canvas.subviews.compactMap({ $0 as? NSTextField }).first {
                field.stringValue = "Esc 测试"
                let handled = canvas.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
                check(handled, "Esc is handled while typing")
                check(canvas.subviews.compactMap { $0 as? NSTextField }.isEmpty, "Esc leaves text editing")
                check(state.annotations.count == 1 && state.annotations[0].text == "Esc 测试", "Esc keeps the typed text")
            } else {
                check(false, "the text tool opens an editing field")
            }

            // Return adds a line break instead of ending the edit.
            state.annotations = []
            mouse(.leftMouseDown, CGPoint(x: 480, y: 330))
            mouse(.leftMouseUp, CGPoint(x: 480, y: 330))
            if let field = canvas.subviews.compactMap({ $0 as? NSTextField }).first,
               let editor = field.currentEditor() as? NSTextView {
                editor.insertText("第一行", replacementRange: editor.selectedRange())
                let oneLine = field.frame.height
                let handled = canvas.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
                editor.insertText("第二行", replacementRange: editor.selectedRange())
                canvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
                check(handled && field.stringValue == "第一行\n第二行", "Return inserts a line break while typing")
                check(field.frame.height > oneLine * 1.6, "the editing field grows with each line")
                canvas.commitTextEditing()
                check(state.annotations.first?.text == "第一行\n第二行", "multi-line text is kept")
            } else {
                check(false, "the text field has an editor")
                canvas.commitTextEditing()
            }

            // Multi-line layout, wrapping and resizing by the handles.
            var note = Annotation(kind: .text, start: CGPoint(x: 440, y: 300), end: .zero, color: RGBA.palette[0], lineWidth: 3)
            note.text = "one two three four five six"
            let single = note.bounds
            var twoLines = note
            twoLines.text = "one two three\nfour five six"
            check(twoLines.bounds.height > single.height * 1.6 && twoLines.bounds.width < single.width,
                  "a line break makes the text taller and narrower")
            state.annotations = [note]
            state.tool = .select
            state.select(note.id)
            pump(0.1)
            // Drag the right-side handle inwards: the box narrows and the text wraps.
            mouse(.leftMouseDown, CGPoint(x: single.maxX, y: single.midY))
            mouse(.leftMouseDragged, CGPoint(x: single.minX + 120, y: single.midY))
            mouse(.leftMouseUp, CGPoint(x: single.minX + 120, y: single.midY))
            let wrapped = state.annotations[0]
            check(wrapped.boxWidth == 120 && wrapped.bounds.width == 120 && wrapped.start == note.start,
                  "dragging a side handle sets the text box width")
            check(wrapped.bounds.height > single.height * 1.6, "text wraps inside a narrower box")
            // Drag the bottom-right corner: the box grows, the font size does not.
            let box = wrapped.bounds
            mouse(.leftMouseDown, CGPoint(x: box.maxX, y: box.maxY))
            mouse(.leftMouseDragged, CGPoint(x: box.minX + 200, y: box.minY + box.height + 60))
            mouse(.leftMouseUp, CGPoint(x: box.minX + 200, y: box.minY + box.height + 60))
            let resized = state.annotations[0]
            check(resized.fontSize == wrapped.fontSize, "resizing a text box keeps the font size")
            check(resized.bounds.width == 200 && resized.start == wrapped.start, "a corner handle changes the box width")
            check(abs(resized.bounds.height - (box.height + 60)) < 0.01, "a corner handle changes the box height")
            // A box cannot be made shorter than its text.
            let tall = resized.bounds
            mouse(.leftMouseDown, CGPoint(x: tall.midX, y: tall.maxY))
            mouse(.leftMouseDragged, CGPoint(x: tall.midX, y: tall.minY + 2))
            mouse(.leftMouseUp, CGPoint(x: tall.midX, y: tall.minY + 2))
            let needed = Annotation.textSize(state.annotations[0].attributedText, wrapWidth: 200).height
            check(abs(state.annotations[0].bounds.height - needed) < 0.01, "a text box never clips its text")
            state.undo()
            state.undo()
            state.undo()
            check(state.annotations == [note], "each resize is one undo step")

            // Font size and family apply to the selected text and to new text.
            state.select(note.id)
            check(state.editsText, "selecting text switches the toolbar to font controls")
            state.applyFontSize(40)
            state.applyFontName("Menlo")
            let styled = state.annotations[0]
            check(styled.fontSize == 40 && styled.fontName == "Menlo", "font size and family apply to the selected text")
            check(styled.attributedText.attribute(.font, at: 0, effectiveRange: nil).flatMap { ($0 as? NSFont)?.familyName } == "Menlo",
                  "the chosen family is used for drawing")
            check(styled.bounds.height > note.bounds.height * 1.5, "a larger font makes the text bigger")
            check(styled.lineWidth == note.lineWidth, "font size is independent of the line width")
            state.select(nil)
            state.tool = .arrow
            check(!state.editsText, "drawing tools show the line width instead")
            state.tool = .text
            check(state.editsText && state.fontSize == 40, "the text tool keeps the last font settings")
            state.tool = .select
            let wrappedForSave = wrapped

            // Saved captures keep the box width.
            let roundTrip = try? JSONDecoder().decode([Annotation].self, from: JSONEncoder().encode([wrappedForSave, styled]))
            check(roundTrip == [wrappedForSave, styled], "text box and font survive saving")
            let legacy = #"[{"id":"00000000-0000-0000-0000-000000000001","kind":"text","start":[1,2],"end":[1,2],"points":[],"text":"旧","color":{"r":1,"g":0,"b":0,"a":1},"lineWidth":4,"filled":false}]"#
            let old = (try? JSONDecoder().decode([Annotation].self, from: Data(legacy.utf8)))?.first
            check(old != nil && old?.boxWidth == nil && old?.fontSize == 24, "captures saved before text boxes load with their old size")

            state.annotations = saved
            state.selectedIDs = savedSelection
            state.tool = .arrow
            pump(0.1)
        }

        // A ⌘C synthesized by another app (PopClip-style) is told apart from a typed one.
        do {
            func keyEvent(fromPID pid: Int64?) -> NSEvent? {
                guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: 8, keyDown: true) else { return nil }
                cg.flags = .maskCommand
                if let pid { cg.setIntegerValueField(.eventSourceUnixProcessID, value: pid) }
                return NSEvent(cgEvent: cg)
            }
            check(!EditorWindowController.isSynthesizedByAnotherProcess(keyEvent(fromPID: 0)), "a typed ⌘C is accepted")
            check(EditorWindowController.isSynthesizedByAnotherProcess(keyEvent(fromPID: 4242)),
                  "a ⌘C posted by another app is recognized")
            check(!EditorWindowController.isSynthesizedByAnotherProcess(keyEvent(fromPID: Int64(getpid()))),
                  "our own events are not treated as foreign")
            check(!EditorWindowController.isSynthesizedByAnotherProcess(nil), "menu clicks are not treated as foreign")
        }

        // ⌘Z / ⇧⌘Z: the Edit menu items must reach the editor through the
        // responder chain, starting at the canvas like a real key press does.
        do {
            let menu = MainMenu.build()
            func item(key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
                menu.items.compactMap(\.submenu).flatMap(\.items)
                    .first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }
            }
            func perform(_ menuItem: NSMenuItem?) -> Bool {
                guard let action = menuItem?.action else { return false }
                var responder: NSResponder? = state.canvas
                while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
                guard let target = responder else { return false }
                if let validator = target as? NSMenuItemValidation, let menuItem, !validator.validateMenuItem(menuItem) { return false }
                _ = target.perform(action, with: menuItem)
                return target === controller
            }
            let undoItem = item(key: "z", modifiers: .command), redoItem = item(key: "z", modifiers: [.command, .shift])
            check(undoItem != nil && redoItem != nil, "⌘Z and ⇧⌘Z are bound in the Edit menu")
            let original = state.annotations
            state.deleteSelected()
            check(state.annotations.count == original.count - 1, "an annotation was deleted")
            check(perform(undoItem) && state.annotations == original, "⌘Z undoes through the menu")
            check(perform(redoItem) && state.annotations.count == original.count - 1, "⇧⌘Z redoes through the menu")
            check(perform(undoItem) && state.annotations == original, "⌘Z undoes again")
            state.selectedID = state.annotations.last?.id

            // The other editor shortcuts take the same route.
            func target(of menuItem: NSMenuItem?) -> NSResponder? {
                guard let action = menuItem?.action else { return nil }
                var responder: NSResponder? = state.canvas
                while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
                return responder
            }
            for (key, modifiers, name) in [("c", NSEvent.ModifierFlags.command, "⌘C"), ("a", .command, "⌘A"),
                                           ("s", .command, "⌘S"), ("f", .command, "⌘F"), ("0", .command, "⌘0")] {
                let found = target(of: item(key: key, modifiers: modifiers))
                check(found === controller, "\(name) reaches the editor (\(found.map { String(describing: type(of: $0)) } ?? "nobody"))")
            }
        }

        // Undo / redo round trip.
        let before = state.annotations
        state.deleteSelected()
        check(state.annotations.count == 1 && state.canUndo, "delete removes the selection")
        state.undo()
        check(state.annotations == before, "undo restores it")
        state.redo()
        check(state.annotations.count == 1, "redo removes it again")

        window.orderOut(nil)
        UserDefaults.standard.removeObject(forKey: "decoration.v1")
    }
}

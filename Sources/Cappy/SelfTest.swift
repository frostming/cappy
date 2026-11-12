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
        testRender(shot, dir: dir)
        testStitcher(dir: dir)
        testEditorWindow(shot, dir: dir)
        testRecentStore(shot, dir: dir)

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

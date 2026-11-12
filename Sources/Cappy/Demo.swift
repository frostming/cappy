import AppKit

/// `Cappy --demo`: opens the editor on a sample document with annotations,
/// smart mosaic and decoration applied. Used to produce the README screenshot.
enum Demo {
    static func open(in delegate: AppDelegate) {
        let shot = makeShot()
        let scale = shot.scale
        let previous = UserDefaults.standard.data(forKey: "decoration.v1")

        // Real smart mosaic: mask whatever Vision flags as sensitive.
        let lines = (try? VisionService.recognize(shot.image)) ?? []
        var annotations = VisionService.sensitiveRects(lines).map { r -> Annotation in
            let p = CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
                .insetBy(dx: -3, dy: -3)
            return Annotation(kind: .mosaic, start: p.origin, end: CGPoint(x: p.maxX, y: p.maxY),
                              color: RGBA.palette[0], lineWidth: 4)
        }
        let red = RGBA.palette[0], blue = RGBA.palette[4]
        var label = Annotation(kind: .text, start: CGPoint(x: 452, y: 262), end: .zero, color: red, lineWidth: 3)
        label.text = "敏感信息已自动打码"
        var note = Annotation(kind: .text, start: CGPoint(x: 470, y: 98), end: .zero, color: blue, lineWidth: 3)
        note.text = "重点看这里"
        annotations += [
            Annotation(kind: .rect, start: CGPoint(x: 34, y: 92), end: CGPoint(x: 440, y: 136), color: blue, lineWidth: 3),
            note,
            Annotation(kind: .arrow, start: CGPoint(x: 520, y: 256), end: CGPoint(x: 400, y: 196), color: red, lineWidth: 5),
            label,
        ]

        delegate.openEditor(shot, annotations: annotations)
        guard let state = delegate.frontEditorState else { return }
        var decoration = Decoration()
        decoration.enabled = true
        state.decoration = decoration
        state.showInspector = true
        state.tool = .arrow
        // Leave the user's saved decoration untouched.
        UserDefaults.standard.set(previous, forKey: "decoration.v1")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let number = state.canvas?.window?.windowNumber { print("WINDOW \(number)") }
            fflush(stdout)
        }
    }

    private static func makeShot() -> Shot {
        let scale: CGFloat = 2
        let size = CGSize(width: 680, height: 360)
        let ctx = Bitmap.context(width: Int(size.width * scale), height: Int(size.height * scale))!
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let rows: [(String, CGFloat, NSFont.Weight, NSColor)] = [
            ("账户信息", 28, .bold, .black),
            ("用户名：Cappy 截图助手", 20, .regular, .black),
            ("联系邮箱：alice.wang@example.com", 20, .regular, .black),
            ("手机号码：138-0013-8000", 20, .regular, .black),
            ("API Key：sk-abc123def456ghi789jkl012", 20, .regular, .black),
            ("注册日期：2026-11-12", 20, .regular, NSColor(white: 0.4, alpha: 1)),
        ]
        var y: CGFloat = 34
        for (text, fontSize, weight, color) in rows {
            NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: weight), .foregroundColor: color,
            ]).draw(at: CGPoint(x: 44, y: y))
            y += fontSize == 28 ? 66 : 50
        }
        NSGraphicsContext.restoreGraphicsState()
        return Shot(image: ctx.makeImage()!, scale: scale)
    }
}

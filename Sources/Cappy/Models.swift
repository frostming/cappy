import AppKit

// MARK: - Color

struct RGBA: Codable, Equatable, Hashable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        self.init(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    static let palette: [RGBA] = [
        RGBA(hex: 0xFF3B30), RGBA(hex: 0xFF9500), RGBA(hex: 0xFFCC00), RGBA(hex: 0x34C759),
        RGBA(hex: 0x0A84FF), RGBA(hex: 0xAF52DE), RGBA(hex: 0x1C1C1E), RGBA(hex: 0xFFFFFF),
    ]
}

// MARK: - Tools

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, ellipse, pen, text, mosaic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "选择"
        case .arrow: return "箭头"
        case .line: return "直线"
        case .rect: return "矩形"
        case .ellipse: return "椭圆"
        case .pen: return "画笔"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .text: return "character.cursor.ibeam"
        case .mosaic: return "checkerboard.rectangle"
        }
    }

    /// Single-key shortcut while the canvas has focus.
    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .text: return "t"
        case .mosaic: return "m"
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .select: return nil
        case .arrow: return .arrow
        case .line: return .line
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .pen: return .pen
        case .text: return .text
        case .mosaic: return .mosaic
        }
    }
}

// MARK: - Annotation

/// All coordinates are in image points, origin at the image's top-left corner.
struct Annotation: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case arrow, line, rect, ellipse, pen, text, mosaic }

    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var text = ""
    var color: RGBA
    var lineWidth: CGFloat
    var filled = false

    var fontSize: CGFloat { Annotation.fontSize(forLineWidth: lineWidth) }

    static func fontSize(forLineWidth w: CGFloat) -> CGFloat { 8 + w * 4 }

    static func font(size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: Annotation.font(size: fontSize),
            .foregroundColor: color.nsColor,
        ])
    }

    /// Normalized rectangle spanned by start/end.
    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var bounds: CGRect {
        switch kind {
        case .pen:
            guard let first = points.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .text:
            let size = attributedText.size()
            return CGRect(origin: start, size: CGSize(width: max(size.width, 8), height: max(size.height, fontSize)))
        default:
            return rect
        }
    }

    mutating func translate(by d: CGPoint) {
        start.x += d.x; start.y += d.y
        end.x += d.x; end.y += d.y
        for i in points.indices { points[i].x += d.x; points[i].y += d.y }
    }

    func hitTest(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        let reach = lineWidth / 2 + t
        switch kind {
        case .arrow:
            return Geometry.distance(p, toSegment: start, end) <= max(reach, lineWidth * 1.8)
        case .line:
            return Geometry.distance(p, toSegment: start, end) <= reach
        case .rect:
            let outer = rect.insetBy(dx: -reach, dy: -reach)
            guard outer.contains(p) else { return false }
            if filled { return true }
            let inner = rect.insetBy(dx: reach, dy: reach)
            return inner.isEmpty || !inner.contains(p)
        case .ellipse:
            let r = rect
            guard r.width > 0.5, r.height > 0.5 else { return false }
            let rx = r.width / 2, ry = r.height / 2
            let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
            let v = sqrt(nx * nx + ny * ny)
            let slack = reach / min(rx, ry)
            return filled ? v <= 1 + slack : abs(v - 1) <= slack
        case .pen:
            guard points.count > 1 else { return false }
            for i in 1..<points.count where Geometry.distance(p, toSegment: points[i - 1], points[i]) <= reach {
                return true
            }
            return false
        case .text, .mosaic:
            return bounds.insetBy(dx: -t, dy: -t).contains(p)
        }
    }
}

enum Geometry {
    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

// MARK: - Decoration

struct GradientPreset {
    let colors: [RGBA]

    static let all: [GradientPreset] = [
        GradientPreset(colors: [RGBA(hex: 0x667EEA), RGBA(hex: 0x764BA2)]),
        GradientPreset(colors: [RGBA(hex: 0x4FACFE), RGBA(hex: 0x00F2FE)]),
        GradientPreset(colors: [RGBA(hex: 0xFF9A8B), RGBA(hex: 0xFF6A88), RGBA(hex: 0xFF99AC)]),
        GradientPreset(colors: [RGBA(hex: 0x43E97B), RGBA(hex: 0x38F9D7)]),
        GradientPreset(colors: [RGBA(hex: 0xF83600), RGBA(hex: 0xF9D423)]),
        GradientPreset(colors: [RGBA(hex: 0xFF6FD8), RGBA(hex: 0x3813C2)]),
        GradientPreset(colors: [RGBA(hex: 0xA1C4FD), RGBA(hex: 0xC2E9FB)]),
        GradientPreset(colors: [RGBA(hex: 0xFAD0C4), RGBA(hex: 0xFFD1FF)]),
        GradientPreset(colors: [RGBA(hex: 0x0F2027), RGBA(hex: 0x203A43), RGBA(hex: 0x2C5364)]),
        GradientPreset(colors: [RGBA(hex: 0x232526), RGBA(hex: 0x414345)]),
    ]
}

struct Decoration: Codable, Equatable {
    enum Background: Codable, Equatable {
        case none
        case gradient(Int)
        case solid(RGBA)
    }

    var enabled = false
    var background: Background = .gradient(0)
    var padding: CGFloat = 56
    var cornerRadius: CGFloat = 12
    var shadow: CGFloat = 28
    var borderWidth: CGFloat = 0
    var borderColor = RGBA(1, 1, 1, 0.7)
    /// Film-grain strength on the background, 0…1.
    var noise: CGFloat = 0.35

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        background = try c.decode(Background.self, forKey: .background)
        padding = try c.decode(CGFloat.self, forKey: .padding)
        cornerRadius = try c.decode(CGFloat.self, forKey: .cornerRadius)
        shadow = try c.decode(CGFloat.self, forKey: .shadow)
        borderWidth = try c.decode(CGFloat.self, forKey: .borderWidth)
        borderColor = try c.decode(RGBA.self, forKey: .borderColor)
        noise = try c.decodeIfPresent(CGFloat.self, forKey: .noise) ?? 0.35
    }

    static let solidPresets: [RGBA] = [
        RGBA(hex: 0xFFFFFF), RGBA(hex: 0xF2F2F7), RGBA(hex: 0x8E8E93), RGBA(hex: 0x1C1C1E),
    ]

    private static let defaultsKey = "decoration.v1"

    static func load() -> Decoration {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Decoration.self, from: data) else { return Decoration() }
        return value
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Decoration.defaultsKey)
        }
    }
}

/// A captured image plus the point→pixel scale it was captured at.
struct Shot {
    let image: CGImage
    let scale: CGFloat

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

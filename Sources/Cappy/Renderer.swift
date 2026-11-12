import AppKit
import ImageIO
import UniformTypeIdentifiers

extension CGContext {
    /// Draws an image upright in a context whose y axis points down.
    func drawFlipped(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}

enum Bitmap {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func usableColorSpace(_ space: CGColorSpace?) -> CGColorSpace {
        if let space, space.model == .rgb, space.supportsOutput { return space }
        return sRGB
    }

    static func context(width: Int, height: Int, colorSpace: CGColorSpace? = nil) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: usableColorSpace(colorSpace), bitmapInfo: info) {
            return ctx
        }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: sRGB, bitmapInfo: info)
    }

    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// Lazily builds a low-resolution copy of the image; drawing it back with
/// nearest-neighbour sampling gives the mosaic effect for any rectangle.
final class MosaicCache {
    let image: CGImage
    let scale: CGFloat
    /// Mosaic cell size in points.
    let block: CGFloat = 10

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
    }

    private(set) lazy var small: CGImage? = {
        let cell = max(2, (block * scale).rounded())
        let w = max(1, Int((CGFloat(image.width) / cell).rounded(.up)))
        let h = max(1, Int((CGFloat(image.height) / cell).rounded(.up)))
        guard let ctx = Bitmap.context(width: w, height: h, colorSpace: image.colorSpace) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }()
}

enum Renderer {
    // MARK: Layout

    static func imageOrigin(_ d: Decoration) -> CGPoint {
        d.enabled ? CGPoint(x: d.padding, y: d.padding) : .zero
    }

    static func canvasSize(imageSize: CGSize, decoration d: Decoration) -> CGSize {
        d.enabled ? CGSize(width: imageSize.width + d.padding * 2, height: imageSize.height + d.padding * 2) : imageSize
    }

    // MARK: Composition

    /// Draws the whole composition into a context with a top-left origin, in points.
    static func draw(in ctx: CGContext, image: CGImage, imageSize: CGSize, annotations: [Annotation],
                     decoration d: Decoration, mosaic: MosaicCache, hidden: UUID? = nil) {
        let canvas = CGRect(origin: .zero, size: canvasSize(imageSize: imageSize, decoration: d))
        let imageRect = CGRect(origin: imageOrigin(d), size: imageSize)
        let radius = d.enabled ? min(d.cornerRadius, min(imageSize.width, imageSize.height) / 2) : 0
        let clipPath = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if d.enabled {
            drawBackground(ctx, d.background, in: canvas)
            if d.noise > 0, d.background != .none, let tile = NoiseTexture.tile {
                // Film grain: neutral-gray noise blended in overlay mode, one
                // noise texel per pixel on a 2x export.
                ctx.saveGState()
                ctx.clip(to: canvas)
                ctx.setBlendMode(.overlay)
                ctx.setAlpha(min(1, d.noise))
                ctx.interpolationQuality = .none
                let side = CGFloat(tile.width) / 2
                ctx.draw(tile, in: CGRect(x: 0, y: 0, width: side, height: side), byTiling: true)
                ctx.restoreGState()
            }
            if d.shadow > 0, let shadow = ShadowCache.image(size: imageSize, radius: radius, blur: d.shadow) {
                let m = ShadowCache.margin(blur: d.shadow)
                let rect = imageRect.insetBy(dx: -m, dy: -m).offsetBy(dx: 0, dy: d.shadow * 0.35)
                ctx.saveGState()
                ctx.clip(to: canvas)
                ctx.drawFlipped(shadow, in: rect)
                ctx.restoreGState()
            }
        }

        ctx.saveGState()
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.drawFlipped(image, in: imageRect)
        ctx.translateBy(x: imageRect.minX, y: imageRect.minY)
        for a in annotations where a.id != hidden {
            draw(a, in: ctx, imageSize: imageSize, mosaic: mosaic)
        }
        ctx.restoreGState()

        if d.enabled, d.borderWidth > 0 {
            let inset = d.borderWidth / 2
            let r = max(0, radius - inset)
            let path = CGPath(roundedRect: imageRect.insetBy(dx: inset, dy: inset), cornerWidth: r, cornerHeight: r, transform: nil)
            ctx.addPath(path)
            ctx.setStrokeColor(d.borderColor.cgColor)
            ctx.setLineWidth(d.borderWidth)
            ctx.strokePath()
        }
    }

    static func drawBackground(_ ctx: CGContext, _ background: Decoration.Background, in rect: CGRect) {
        switch background {
        case .none:
            break
        case .solid(let color):
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
        case .gradient(let index):
            let preset = GradientPreset.all[max(0, min(index, GradientPreset.all.count - 1))]
            let colors = preset.colors.map(\.cgColor) as CFArray
            guard let gradient = CGGradient(colorsSpace: Bitmap.sRGB, colors: colors, locations: nil) else { return }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY),
                                   end: CGPoint(x: rect.maxX, y: rect.maxY),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
    }

    // MARK: Annotations

    static func draw(_ a: Annotation, in ctx: CGContext, imageSize: CGSize, mosaic: MosaicCache) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.kind {
        case .arrow:
            ctx.addPath(arrowPath(from: a.start, to: a.end, width: a.lineWidth))
            ctx.fillPath()
        case .line:
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .rect:
            let r = a.rect
            let corner = min(a.lineWidth, min(r.width, r.height) / 2)
            ctx.setLineJoin(.miter)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
            ctx.drawPath(using: a.filled ? .fillStroke : .stroke)
        case .ellipse:
            ctx.addEllipse(in: a.rect)
            ctx.drawPath(using: a.filled ? .fillStroke : .stroke)
        case .pen:
            guard let first = a.points.first else { return }
            ctx.move(to: first)
            if a.points.count == 2 {
                ctx.addLine(to: a.points[1])
            } else if a.points.count > 2 {
                for i in 1..<a.points.count - 1 {
                    let p = a.points[i], next = a.points[i + 1]
                    ctx.addQuadCurve(to: CGPoint(x: (p.x + next.x) / 2, y: (p.y + next.y) / 2), control: p)
                }
                ctx.addLine(to: a.points[a.points.count - 1])
            }
            ctx.strokePath()
        case .text:
            guard !a.text.isEmpty else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            a.attributedText.draw(with: CGRect(origin: a.start, size: CGSize(width: a.boxWidth ?? 100_000, height: 100_000)),
                                  options: Annotation.textDrawingOptions)
            NSGraphicsContext.restoreGraphicsState()
        case .mosaic:
            guard let small = mosaic.small else { return }
            ctx.clip(to: a.rect)
            ctx.interpolationQuality = .none
            ctx.drawFlipped(small, in: CGRect(origin: .zero, size: imageSize))
        }
    }

    /// A tapered arrow: thin at the tail, widening toward a barbed head.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return path }
        let ux = dx / length, uy = dy / length
        let nx = -uy, ny = ux
        let headLength = min(length * 0.6, max(14, width * 4.5))
        let headHalf = headLength * 0.52
        let neckHalf = max(1, width * 0.55)
        let tailHalf = max(0.6, width * 0.22)
        let base = length - headLength
        let neck = length - headLength * 0.82

        func point(_ along: CGFloat, _ side: CGFloat) -> CGPoint {
            CGPoint(x: start.x + ux * along + nx * side, y: start.y + uy * along + ny * side)
        }
        path.move(to: point(0, tailHalf))
        path.addLine(to: point(neck, neckHalf))
        path.addLine(to: point(base, headHalf))
        path.addLine(to: end)
        path.addLine(to: point(base, -headHalf))
        path.addLine(to: point(neck, -neckHalf))
        path.addLine(to: point(0, -tailHalf))
        path.closeSubpath()
        return path
    }

    // MARK: Export

    static func render(image: CGImage, scale: CGFloat, annotations: [Annotation], decoration: Decoration,
                       mosaic: MosaicCache) -> CGImage? {
        let imageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let canvas = canvasSize(imageSize: imageSize, decoration: decoration)
        let w = Int((canvas.width * scale).rounded()), h = Int((canvas.height * scale).rounded())
        guard let ctx = Bitmap.context(width: w, height: h, colorSpace: image.colorSpace) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(in: ctx, image: image, imageSize: imageSize, annotations: annotations, decoration: decoration, mosaic: mosaic)
        return ctx.makeImage()
    }
}

/// Pre-blurred rounded-rect shadows, rendered once per geometry at reduced
/// resolution so they look identical on screen and in the exported file.
enum ShadowCache {
    private static var key = ""
    private static var cached: CGImage?

    static func margin(blur: CGFloat) -> CGFloat { blur * 2 + 2 }

    static func image(size: CGSize, radius: CGFloat, blur: CGFloat) -> CGImage? {
        let k = "\(size.width)x\(size.height)-\(radius)-\(blur)"
        if k == key, let cached { return cached }
        let m = margin(blur: blur)
        let full = CGSize(width: size.width + m * 2, height: size.height + m * 2)
        let q = min(1, 1024 / max(full.width, full.height))
        let w = max(1, Int((full.width * q).rounded(.up))), h = max(1, Int((full.height * q).rounded(.up)))
        guard let ctx = Bitmap.context(width: w, height: h) else { return nil }
        // Draw the shape off-canvas and let only its shadow land inside the bitmap.
        let shift = CGFloat(w) + 64
        ctx.setShadow(offset: CGSize(width: shift, height: 0), blur: max(1, blur * q),
                      color: CGColor(gray: 0, alpha: 0.5))
        ctx.scaleBy(x: q, y: q)
        ctx.translateBy(x: -shift / q, y: 0)
        ctx.addPath(CGPath(roundedRect: CGRect(x: m, y: m, width: size.width, height: size.height),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        cached = ctx.makeImage()
        key = k
        return cached
    }
}

/// A tileable grayscale noise texture, generated once with a fixed seed so
/// the editor preview and the exported file show the same grain.
enum NoiseTexture {
    static let tile: CGImage? = {
        let side = 512
        var bytes = [UInt8](repeating: 0, count: side * side)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 40) / Double(1 << 24)
        }
        for i in bytes.indices {
            // Sum of uniforms: roughly gaussian around mid-gray.
            let v = (next() + next() + next() + next()) / 4
            bytes[i] = UInt8(max(0, min(255, 127.5 + (v - 0.5) * 520)))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

import CoreGraphics
import Foundation

/// Stitches successive captures of a scrolling region into one tall image.
///
/// Each frame is reduced to a per-row signature. A new frame is aligned
/// against the previous one by first ignoring bands that did not move
/// (sticky headers / footers) and then searching for the vertical offset
/// that makes the remaining rows line up.
final class ScrollStitcher {
    enum Outcome: Equatable {
        case first
        case appended(Int)
        case unchanged
        case noMatch
        case full
    }

    private(set) var width = 0
    private(set) var frameHeight = 0
    private(set) var rows = 0
    let maxRows: Int

    private var buffer = Data()
    private var lastSignature: [Float] = []
    private var colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let buckets = 24
    private let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(maxRows: Int = 60_000) {
        self.maxRows = maxRows
    }

    func add(_ image: CGImage) -> Outcome {
        if width == 0 {
            width = image.width
            frameHeight = image.height
            if let space = image.colorSpace, space.model == .rgb, space.supportsOutput { colorSpace = space }
        }
        guard let pixels = pixelData(image) else { return .noMatch }
        let signature = makeSignature(pixels)

        if lastSignature.isEmpty {
            buffer = pixels
            rows = frameHeight
            lastSignature = signature
            return .first
        }
        guard rows < maxRows else { return .full }

        let h = frameHeight, k = buckets
        let (top, bottom, offset) = lastSignature.withUnsafeBufferPointer { a in
            signature.withUnsafeBufferPointer { b -> (Int, Int, Int?) in
                func distance(_ rowA: Int, _ rowB: Int) -> Float {
                    var sum: Float = 0
                    let ia = rowA * k, ib = rowB * k
                    for i in 0..<k { sum += abs(a[ia + i] - b[ib + i]) }
                    return sum
                }
                let same = Float(k) * 0.6
                var top = 0
                while top < h, distance(top, top) < same { top += 1 }
                if top == h { return (h, 0, nil) }
                var bottom = 0
                while bottom < h - top - 1, distance(h - 1 - bottom, h - 1 - bottom) < same { bottom += 1 }

                let moving = h - top - bottom
                guard moving >= 48 else { return (top, bottom, nil) }
                let minOverlap = max(24, moving / 6)
                // `slack` only breaks ties between equally good offsets (repeating
                // content), in favour of the smallest scroll distance.
                let accept: Float = 2.0, slack: Float = 0.02
                var best = Float.infinity
                var errors = [Float](repeating: .infinity, count: moving)
                for d in 1...(moving - minOverlap) {
                    let n = moving - d
                    let limit = (min(best, accept) + slack) * Float(n * k)
                    var sum: Float = 0
                    var y = top
                    let end = top + n
                    while y < end {
                        sum += distance(y + d, y)
                        if sum > limit { break }
                        y += 1
                    }
                    if y == end {
                        let e = sum / Float(n * k)
                        errors[d] = e
                        if e < best { best = e }
                    }
                }
                guard best <= accept else { return (top, bottom, nil) }
                let d = errors.firstIndex { $0 <= best + slack }
                return (top, bottom, d)
            }
        }

        if top == h { return .unchanged }
        guard let d = offset else { return .noMatch }

        let rowBytes = width * 4
        let trim = min(bottom * rowBytes, buffer.count)
        buffer.removeLast(trim)
        buffer.append(pixels.subdata(in: (h - bottom - d) * rowBytes..<h * rowBytes))
        rows += d
        lastSignature = signature
        return .appended(d)
    }

    func makeImage() -> CGImage? {
        guard rows > 0, let provider = CGDataProvider(data: buffer as CFData) else { return nil }
        return CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Pixels

    private func pixelData(_ image: CGImage) -> Data? {
        let rowBytes = width * 4
        guard let ctx = CGContext(data: nil, width: width, height: frameHeight, bitsPerComponent: 8,
                                  bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: bitmapInfo),
              ctx.bytesPerRow == rowBytes else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: frameHeight))
        guard let base = ctx.data else { return nil }
        return Data(bytes: base, count: rowBytes * frameHeight)
    }

    /// `buckets` average-luminance values per row. The right edge is skipped
    /// so a moving scroll indicator does not disturb the match.
    private func makeSignature(_ pixels: Data) -> [Float] {
        let k = buckets
        let usable = max(k, width - min(width / 10, 48))
        let bucketWidth = usable / k
        var out = [Float](repeating: 0, count: frameHeight * k)
        pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<frameHeight {
                let row = y * width * 4
                for bucket in 0..<k {
                    var sum = 0, count = 0
                    var x = bucket * bucketWidth
                    let end = x + bucketWidth
                    while x < end {
                        let i = row + x * 4
                        sum += Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2])
                        count += 3
                        x += 2
                    }
                    out[y * k + bucket] = count > 0 ? Float(sum) / Float(count) : 0
                }
            }
        }
        return out
    }
}

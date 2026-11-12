import AppKit
import Vision

struct RecognizedLine {
    let text: String
    /// Bounding box in image pixels, top-left origin.
    let rect: CGRect
    let candidate: VNRecognizedText
    /// The tile (in image pixels, top-left origin) the line was recognized in.
    let tile: CGRect
}

enum VisionService {
    // MARK: OCR

    /// Recognizes text. Tall images (scrolling captures) are processed in
    /// overlapping tiles so small text keeps enough resolution.
    static func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let width = image.width, height = image.height
        let tileHeight = max(2400, width * 2), overlap = 160
        var tiles: [(rect: CGRect, own: Range<CGFloat>)] = []
        if height <= tileHeight + overlap {
            tiles.append((CGRect(x: 0, y: 0, width: width, height: height), 0..<CGFloat(height) + 1))
        } else {
            var y = 0
            while true {
                let h = min(tileHeight, height - y)
                let isLast = y + h >= height
                let lower = y == 0 ? 0 : CGFloat(y + overlap / 2)
                let upper = isLast ? CGFloat(height) + 1 : CGFloat(y + h - overlap / 2)
                tiles.append((CGRect(x: 0, y: y, width: width, height: h), lower..<upper))
                if isLast { break }
                y += tileHeight - overlap
            }
        }

        var lines: [RecognizedLine] = []
        for tile in tiles {
            guard let crop = tiles.count == 1 ? image : image.cropping(to: tile.rect) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let rect = pixelRect(observation.boundingBox, in: tile.rect)
                guard tile.own.contains(rect.midY) else { continue }
                lines.append(RecognizedLine(text: candidate.string, rect: rect, candidate: candidate, tile: tile.rect))
            }
        }
        return lines
    }

    /// Per-character boxes in image points, for selecting text with the mouse.
    static func layout(_ lines: [RecognizedLine], scale: CGFloat) -> TextLayout {
        func points(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX / scale, y: r.minY / scale, width: r.width / scale, height: r.height / scale)
        }
        return TextLayout(lines: lines.map { line in
            let text = line.text
            let count = text.count
            let lineRect = points(line.rect)
            // Vision has no box for some characters (spaces come back empty).
            var boxes: [CGRect?] = []
            boxes.reserveCapacity(count)
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(after: index)
                if let box = try? line.candidate.boundingBox(for: index..<next),
                   box.boundingBox.width > 0, box.boundingBox.height > 0 {
                    boxes.append(points(pixelRect(box.boundingBox, in: line.tile)))
                } else {
                    boxes.append(nil)
                }
                index = next
            }
            // Fill each run of missing boxes by splitting the gap between its neighbours.
            var chars: [CGRect] = []
            chars.reserveCapacity(count)
            var i = 0
            while i < boxes.count {
                if let box = boxes[i] {
                    chars.append(box)
                    i += 1
                    continue
                }
                var end = i
                while end < boxes.count, boxes[end] == nil { end += 1 }
                let left = chars.last?.maxX ?? lineRect.minX
                let right = max(left, end < boxes.count ? boxes[end]!.minX : lineRect.maxX)
                let width = (right - left) / CGFloat(end - i)
                for k in 0..<(end - i) {
                    chars.append(CGRect(x: left + width * CGFloat(k), y: lineRect.minY, width: width, height: lineRect.height))
                }
                i = end
            }
            return TextLine(text: text, rect: lineRect, chars: chars)
        })
    }

    static func plainText(_ lines: [RecognizedLine]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// Vision boxes are normalized with a bottom-left origin.
    private static func pixelRect(_ box: CGRect, in tile: CGRect) -> CGRect {
        CGRect(x: tile.minX + box.minX * tile.width,
               y: tile.minY + (1 - box.maxY) * tile.height,
               width: box.width * tile.width,
               height: box.height * tile.height)
    }

    // MARK: Sensitive content

    /// (pattern, capture group to mask)
    private static let patterns: [(NSRegularExpression, Int)] = {
        let sources: [(String, Int)] = [
            // e-mail
            (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, 0),
            // long digit runs: phone / card / ID numbers
            (#"(?<![\d.])\+?\d[\d \-]{7,}\d(?![\d.])"#, 0),
            // Chinese resident ID
            (#"\d{17}[\dXx]"#, 0),
            // IPv4
            (#"(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])"#, 0),
            // well-known token prefixes
            (#"(?:sk|pk|rk|ghp|gho|ghs|github_pat|xox[abprs]|AKIA|AIza|glpat|nvapi)[-_A-Za-z0-9]{8,}"#, 0),
            // long mixed alphanumeric secrets
            (#"(?<![A-Za-z0-9_\-])(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}(?![A-Za-z0-9_\-])"#, 0),
            // key: value credentials
            (#"(?i)(?:password|passwd|pwd|secret|token|api[_\- ]?key|密码|口令|密钥)\s*[:=：]\s*(\S+)"#, 1),
        ]
        return sources.compactMap { source, group in
            (try? NSRegularExpression(pattern: source)).map { ($0, group) }
        }
    }()

    private static let dateLike = try! NSRegularExpression(pattern: #"^\d{4}[\-/ ]\d{1,2}[\-/ ]\d{1,2}"#)
    private static let phoneDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    static func sensitiveRanges(in string: String) -> [NSRange] {
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var ranges: [NSRange] = []
        for (index, (regex, group)) in patterns.enumerated() {
            regex.enumerateMatches(in: string, range: full) { match, _, _ in
                guard let match else { return }
                let range = match.range(at: group)
                guard range.location != NSNotFound, range.length > 0 else { return }
                if index == 1 {
                    // Digit runs: need enough digits, and skip things that are just dates.
                    let piece = ns.substring(with: range)
                    let digits = piece.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
                    let pieceRange = NSRange(location: 0, length: (piece as NSString).length)
                    if digits < 9 || dateLike.firstMatch(in: piece, range: pieceRange) != nil { return }
                }
                ranges.append(range)
            }
        }
        phoneDetector?.enumerateMatches(in: string, range: full) { match, _, _ in
            if let match { ranges.append(match.range) }
        }
        // Merge overlaps.
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, NSMaxRange(last) >= range.location {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Pixel rects (top-left origin) covering sensitive substrings.
    static func sensitiveRects(_ lines: [RecognizedLine]) -> [CGRect] {
        var rects: [CGRect] = []
        for line in lines {
            for range in sensitiveRanges(in: line.text) {
                guard let stringRange = Range(range, in: line.text) else { continue }
                if let box = try? line.candidate.boundingBox(for: stringRange) {
                    rects.append(pixelRect(box.boundingBox, in: line.tile))
                } else {
                    rects.append(line.rect)
                }
            }
        }
        return rects
    }

    static func faceRects(_ image: CGImage) -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return (request.results ?? []).map { face in
            let r = pixelRect(face.boundingBox, in: full)
            return r.insetBy(dx: -r.width * 0.08, dy: -r.height * 0.12)
        }
    }
}

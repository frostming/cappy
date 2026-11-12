import CoreGraphics

/// One recognized line with a box per character, in image points (top-left origin).
struct TextLine {
    let text: String
    let rect: CGRect
    /// One rect per `Character` of `text`.
    let chars: [CGRect]
}

/// A caret position: `caret` characters into line `line`.
struct TextPosition: Comparable, Equatable {
    var line: Int
    var caret: Int

    static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.line != b.line ? a.line < b.line : a.caret < b.caret
    }
}

struct TextRange: Equatable {
    var anchor: TextPosition
    var head: TextPosition

    var lower: TextPosition { min(anchor, head) }
    var upper: TextPosition { max(anchor, head) }
    var isEmpty: Bool { anchor == head }
}

/// The recognized text of an image, laid out for mouse selection.
struct TextLayout {
    let lines: [TextLine]

    var isEmpty: Bool { lines.isEmpty }

    var everything: TextRange? {
        guard let last = lines.indices.last else { return nil }
        return TextRange(anchor: TextPosition(line: 0, caret: 0),
                         head: TextPosition(line: last, caret: lines[last].chars.count))
    }

    func wholeLine(_ index: Int) -> TextRange {
        TextRange(anchor: TextPosition(line: index, caret: 0),
                  head: TextPosition(line: index, caret: lines[index].chars.count))
    }

    /// Line whose box (grown by `slop`) contains the point.
    func line(at p: CGPoint, slop: CGFloat) -> Int? {
        lines.firstIndex { $0.rect.insetBy(dx: -slop, dy: -slop).contains(p) }
    }

    private func nearestLine(to p: CGPoint) -> Int? {
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            // Vertical distance dominates so a drag picks the row first.
            return dy * 4 + dx
        }
        return lines.indices.min { distance(lines[$0].rect) < distance(lines[$1].rect) }
    }

    /// Caret closest to `p`. With `strict`, the point has to be on a line;
    /// otherwise the nearest line is used (while extending a selection).
    func position(at p: CGPoint, strict: Bool, slop: CGFloat = 3) -> TextPosition? {
        guard let index = strict ? line(at: p, slop: slop) : nearestLine(to: p) else { return nil }
        let caret = lines[index].chars.filter { $0.midX < p.x }.count
        return TextPosition(line: index, caret: caret)
    }

    /// Highlight rects, one per touched line.
    func rects(for range: TextRange) -> [CGRect] {
        let a = range.lower, b = range.upper
        guard lines.indices.contains(a.line), lines.indices.contains(b.line) else { return [] }
        var out: [CGRect] = []
        for index in a.line...b.line {
            let line = lines[index]
            let from = index == a.line ? a.caret : 0
            let to = min(index == b.line ? b.caret : line.chars.count, line.chars.count)
            guard from < to else { continue }
            let span = line.chars[from..<to].reduce(CGRect.null) { $0.union($1) }
            out.append(CGRect(x: span.minX, y: line.rect.minY, width: span.width, height: line.rect.height))
        }
        return out
    }

    func string(for range: TextRange) -> String {
        let a = range.lower, b = range.upper
        guard lines.indices.contains(a.line), lines.indices.contains(b.line) else { return "" }
        var parts: [String] = []
        for index in a.line...b.line {
            let characters = Array(lines[index].text)
            let from = index == a.line ? a.caret : 0
            let to = min(index == b.line ? b.caret : characters.count, characters.count)
            guard from <= to else { continue }
            parts.append(String(characters[from..<to]))
        }
        return parts.joined(separator: "\n")
    }
}

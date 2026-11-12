import AppKit
import ImageIO

/// Keeps the most recent captures on disk (original image + annotations) so
/// they can be reopened in the editor later, including after a relaunch.
final class RecentStore {
    static let shared = RecentStore()
    static let limit = 5

    struct Entry: Codable {
        let id: UUID
        let date: Date
        let scale: CGFloat
        let width: Int
        let height: Int
        var annotations: [Annotation]
    }

    private let directory: URL
    /// Serializes all disk access; PNG encoding happens off the main thread.
    private let queue = DispatchQueue(label: "cappy.recent", qos: .utility)

    init(directory: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? base.appendingPathComponent("Cappy/Recent", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    private func metaURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }
    private func imageURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }
    private func thumbURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).thumb.png") }

    // MARK: Writing

    /// Records a new capture and returns its identifier.
    @discardableResult
    func add(_ shot: Shot) -> UUID {
        let entry = Entry(id: UUID(), date: Date(), scale: shot.scale, width: shot.image.width,
                          height: shot.image.height, annotations: [])
        queue.async {
            guard let png = Bitmap.pngData(shot.image, scale: shot.scale) else { return }
            try? png.write(to: self.imageURL(entry.id))
            if let thumb = Self.thumbnail(shot.image), let data = Bitmap.pngData(thumb, scale: 2) {
                try? data.write(to: self.thumbURL(entry.id))
            }
            self.write(entry)
            self.prune()
        }
        return entry.id
    }

    func update(_ id: UUID, annotations: [Annotation]) {
        queue.async {
            guard var entry = self.read(id), entry.annotations != annotations else { return }
            entry.annotations = annotations
            self.write(entry)
        }
    }

    /// Blocks until pending writes are on disk (used at quit).
    func flush() {
        queue.sync {}
    }

    // MARK: Reading

    /// Newest first.
    func entries() -> [Entry] {
        queue.sync { allEntries() }
    }

    func load(_ id: UUID) -> (shot: Shot, annotations: [Annotation])? {
        queue.sync {
            guard let entry = read(id),
                  let source = CGImageSourceCreateWithURL(imageURL(id) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return (Shot(image: image, scale: entry.scale), entry.annotations)
        }
    }

    func thumbnail(_ id: UUID) -> NSImage? {
        guard let image = NSImage(contentsOf: thumbURL(id)) else { return nil }
        return image
    }

    // MARK: Internals (call on `queue`)

    private func read(_ id: UUID) -> Entry? {
        guard let data = try? Data(contentsOf: metaURL(id)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func write(_ entry: Entry) {
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: metaURL(entry.id), options: .atomic)
        }
    }

    private func allEntries() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) } }
            .sorted { $0.date > $1.date }
    }

    private func prune() {
        for entry in allEntries().dropFirst(Self.limit) {
            for url in [metaURL(entry.id), imageURL(entry.id), thumbURL(entry.id)] {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// A small preview that fits a menu row; tall captures show their top part.
    private static func thumbnail(_ image: CGImage) -> CGImage? {
        let maxWidth: CGFloat = 192, maxHeight: CGFloat = 112
        let factor = min(maxWidth / CGFloat(image.width), 1)
        let width = max(1, Int(CGFloat(image.width) * factor))
        let fullHeight = CGFloat(image.height) * factor
        let height = max(1, Int(min(fullHeight, maxHeight)))
        guard let ctx = Bitmap.context(width: width, height: height) else { return nil }
        ctx.interpolationQuality = .high
        // Align the image's top edge with the top of the thumbnail.
        ctx.draw(image, in: CGRect(x: 0, y: CGFloat(height) - fullHeight, width: CGFloat(width), height: fullHeight))
        return ctx.makeImage()
    }
}

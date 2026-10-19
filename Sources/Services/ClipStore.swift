import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Recognition status of a stored image.
enum OCRState: String, Codable {
    case pending, done, tooLarge, dropped
}

/// One captured image in the history, as persisted in the JSON index.
struct ClipEntry: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var pinned: Bool
    var pixelWidth: Int
    var pixelHeight: Int
    var sourceApp: String?
    var text: String
    var ocr: OCRState
    var fileExtension: String
    var hash: String

    /// First non-empty line of recognized text, used as the card caption.
    var firstLine: String? {
        text.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    var isNotIndexed: Bool { ocr == .tooLarge || ocr == .dropped }
}

/// Owns the on-disk image folder, thumbnails and JSON index; all mutations happen on the main actor.
@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var entries: [ClipEntry] = []
    /// Set when a disk operation fails; the UI shows a banner and capturing stops.
    @Published var diskError: String?

    static let maxRecognitionPixels = 40_000_000

    private let root: URL
    private var imagesDir: URL { root.appendingPathComponent("Images", isDirectory: true) }
    private var thumbsDir: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private let thumbCache = NSCache<NSUUID, NSImage>()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        root = base.appendingPathComponent("ShotClipSearch", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        } catch {
            diskError = "Could not create storage folder: \(error.localizedDescription)"
        }
        load()
    }

    func imageURL(for entry: ClipEntry) -> URL {
        imagesDir.appendingPathComponent("\(entry.id.uuidString).\(entry.fileExtension)")
    }

    func thumbURL(for entry: ClipEntry) -> URL {
        thumbsDir.appendingPathComponent("\(entry.id.uuidString).png")
    }

    func thumbnail(for entry: ClipEntry) -> NSImage? {
        if let cached = thumbCache.object(forKey: entry.id as NSUUID) { return cached }
        guard let image = NSImage(contentsOf: thumbURL(for: entry)) else { return nil }
        thumbCache.setObject(image, forKey: entry.id as NSUUID)
        return image
    }

    /// Stores new image data. Returns the entry if it is new and needs recognition, nil otherwise.
    func add(data rawData: Data, fileExtension rawExt: String, sourceApp: String?) -> ClipEntry? {
        let hash = SHA256.hash(data: rawData).map { String(format: "%02x", $0) }.joined()
        if let idx = entries.firstIndex(where: { $0.hash == hash }) {
            // Duplicate: bump it to the top instead of storing a second copy.
            entries[idx].date = Date()
            entries.sort { $0.date > $1.date }
            save()
            return nil
        }
        // TIFF is uncompressed; re-encode as PNG to keep the folder small.
        var data = rawData, ext = rawExt
        if ext == "tiff", let png = NSBitmapImageRep(data: rawData)?.representation(using: .png, properties: [:]) {
            data = png; ext = "png"
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0

        var entry = ClipEntry(id: UUID(), date: Date(), pinned: false, pixelWidth: width, pixelHeight: height,
                              sourceApp: sourceApp, text: "", ocr: .pending, fileExtension: ext, hash: hash)
        if width * height > Self.maxRecognitionPixels { entry.ocr = .tooLarge }

        do {
            try data.write(to: imageURL(for: entry), options: .atomic)
            try writeThumbnail(from: source, to: thumbURL(for: entry))
        } catch {
            try? FileManager.default.removeItem(at: imageURL(for: entry))
            diskError = "Could not save image: \(error.localizedDescription)"
            return nil
        }
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    /// Scales the image to a 256 pt (512 px) thumbnail with ImageIO/CoreGraphics and writes it as PNG.
    private func writeThumbnail(from source: CGImageSource, to url: URL) throws {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    func setRecognition(id: UUID, text: String, state: OCRState) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].text = text
        entries[idx].ocr = state
        save()
    }

    func togglePin(_ entry: ClipEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx].pinned.toggle()
        save()
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        // Files go first so an interrupted delete never leaves orphaned files behind.
        for entry in entries where ids.contains(entry.id) {
            try? FileManager.default.removeItem(at: imageURL(for: entry))
            try? FileManager.default.removeItem(at: thumbURL(for: entry))
            thumbCache.removeObject(forKey: entry.id as NSUUID)
        }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func clearUnpinned() {
        delete(Set(entries.filter { !$0.pinned }.map(\.id)))
    }

    /// Removes unpinned entries older than `days` (0 = forever) and trims unpinned entries beyond `maxCount`.
    func enforceRetention(days: Int, maxCount: Int) {
        var doomed = Set<UUID>()
        if days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) {
            doomed.formUnion(entries.filter { !$0.pinned && $0.date < cutoff }.map(\.id))
        }
        let survivors = entries.filter { !doomed.contains($0.id) }
        if survivors.count > maxCount {
            let overflow = survivors.count - maxCount
            doomed.formUnion(survivors.filter { !$0.pinned }.suffix(overflow).map(\.id))
        }
        delete(doomed)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([ClipEntry].self, from: data).sorted { $0.date > $1.date }
        } catch {
            diskError = "The index file is unreadable: \(error.localizedDescription)"
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do {
            try encoder.encode(entries).write(to: indexURL, options: .atomic)
        } catch {
            diskError = "Could not write the index: \(error.localizedDescription)"
        }
    }
}

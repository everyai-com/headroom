import Foundation
import Vision
import PDFKit
import ImageIO

/// The words inside your screenshots and photos, read on this Mac with Apple's Vision framework —
/// nothing is uploaded. Results are cached by path and modification date, so each image is read once.
public final class TextIndex: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var modified: Date
        public var text: String
    }

    private var entries: [String: Entry]
    private let lock = NSLock()
    private let url: URL
    /// iCloud-only files are never read (tests stand in for the file flag, which only the system sets).
    var isDataless: @Sendable (URL) -> Bool = { LibraryScanner.isDataless($0) }

    public static var defaultURL: URL { HeadroomPaths.support.appendingPathComponent("text.plist") }

    public init(url: URL = TextIndex.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? PropertyListDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {
            entries = [:]
        }
    }

    public var count: Int { lock.withLock { entries.count } }

    /// Every recognised text by path, for search.
    public var all: [String: String] {
        lock.withLock { entries.compactMapValues { $0.text.isEmpty ? nil : $0.text } }
    }

    /// The cached text, when it's still current for this file.
    public func cached(_ item: LibraryItem) -> String? {
        lock.withLock {
            guard let e = entries[item.path], abs(e.modified.timeIntervalSince(item.modified)) < 1 else { return nil }
            return e.text
        }
    }

    /// The text in this file — read now if it isn't cached yet. Never an iCloud-only file: reading it
    /// would download it (and nothing is cached, so it's read once it's back on this Mac).
    public func text(for item: LibraryItem) -> String {
        if let t = cached(item) { return t }
        if isDataless(item.url) { return "" }
        let t = Self.recognize(item.url) ?? ""
        lock.withLock { entries[item.path] = Entry(modified: item.modified, text: t) }
        return t
    }

    public func save() {
        let snapshot = lock.withLock { entries }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }

    /// Forget everything (Settings → Headroom's own data).
    public func clear() {
        lock.withLock { entries = [:] }
        try? FileManager.default.removeItem(at: url)
    }

    /// Read the images that aren't indexed yet, newest first, at most `limit` per run. Drops entries for
    /// files that are gone. Saves as it goes so a quit loses little.
    public func index(_ items: [LibraryItem], limit: Int = 1500, isCancelled: @Sendable () -> Bool = { false },
                      progress: @Sendable (Int, Int) -> Void = { _, _ in }) {
        let live = Set(items.map(\.path))
        lock.withLock { entries = entries.filter { live.contains($0.key) || FileManager.default.fileExists(atPath: $0.key) } }
        let todo = items.filter { cached($0) == nil }.prefix(limit)
        var done = 0
        for item in todo {
            if isCancelled() { break }
            _ = text(for: item)
            done += 1
            progress(done, todo.count)
            if done % 25 == 0 { save() }
        }
        save()
    }

    /// What's worth reading: every screenshot, then recent photos and images (newest first).
    public static func candidates(_ index: LibraryIndex, now: Date = .now, days: Int = 365) -> [LibraryItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let readable: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"]
        let images = index.items.filter { $0.kind == .image && readable.contains($0.ext) && $0.bytes < 40_000_000 }
        let shots = images.filter(\.isScreenshot).sorted { $0.arrived > $1.arrived }
        let recent = images.filter { !$0.isScreenshot && $0.arrived > cutoff }.sorted { $0.arrived > $1.arrived }
        return shots + recent
    }

    // MARK: Reading

    /// The text in an image (Vision) or a PDF (its own text; scanned pages are read with Vision).
    public static func recognize(_ url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" { return pdfText(url) }
        guard let image = loadImage(url, maxPixels: 2600) else { return nil }
        return recognize(image)
    }

    public static func recognize(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    static func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var parts: [String] = []
        for i in 0..<min(doc.pageCount, 60) {
            guard let page = doc.page(at: i) else { continue }
            if let s = page.string, s.trimmingCharacters(in: .whitespacesAndNewlines).count > 8 {
                parts.append(s)
            } else if i < 10 {
                // A scanned page: no text layer, so read the picture of it.
                let thumb = page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
                if let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil), let s = recognize(cg) { parts.append(s) }
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// A downscaled decode: Vision doesn't need 48 megapixels to read a sign.
    static func loadImage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

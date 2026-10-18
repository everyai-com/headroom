import Foundation
import CoreServices

/// What Spotlight already knows about your files: when you last opened them, the text inside
/// documents, and the camera a photo came from. Read-only; when Spotlight is off or its index is
/// read-only, every answer is simply empty and callers fall back to what the file system says.
public enum Spotlight {
    /// When each file was last opened, where Spotlight knows.
    public static func lastUsed(_ paths: [String]) -> [String: Date] {
        var out: [String: Date] = [:]
        for path in paths {
            guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else { continue }
            out[path] = date
        }
        return out
    }

    /// Camera or phone, pixel size and duration for one file — the inspector's details.
    public struct Details: Sendable, Hashable {
        public var device: String?
        public var pixelWidth: Int?
        public var pixelHeight: Int?
        public var duration: Double?
        public var lastUsed: Date?
        public var pages: Int?
        public var authors: [String]?
        public var title: String?
        public var album: String?
        public var artist: String?

        public init() {}
    }

    public static func details(_ path: String) -> Details {
        var d = Details()
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return d }
        func value(_ key: CFString) -> Any? { MDItemCopyAttribute(item, key) }
        let make = value(kMDItemAcquisitionMake) as? String
        let model = value(kMDItemAcquisitionModel) as? String
        if let model { d.device = make.map { model.hasPrefix($0) ? model : "\($0) \(model)" } ?? model } else { d.device = make }
        d.pixelWidth = (value(kMDItemPixelWidth) as? NSNumber)?.intValue
        d.pixelHeight = (value(kMDItemPixelHeight) as? NSNumber)?.intValue
        d.duration = (value(kMDItemDurationSeconds) as? NSNumber)?.doubleValue
        d.lastUsed = value(kMDItemLastUsedDate) as? Date
        d.pages = (value(kMDItemNumberOfPages) as? NSNumber)?.intValue
        d.authors = value(kMDItemAuthors) as? [String]
        d.title = value(kMDItemTitle) as? String
        d.album = value(kMDItemAlbum) as? String
        d.artist = (value(kMDItemAuthors) as? [String])?.first ?? (value(kMDItemComposer) as? String)
        return d
    }

    /// Files under `root` whose text contains every term (documents, PDFs, notes), via `mdfind`.
    public static func paths(containing terms: [String], in root: String, limit: Int = 3000, timeout: TimeInterval = 6) -> Set<String> {
        let clean = terms.map(sanitize).filter { $0.count >= 2 }
        guard !clean.isEmpty else { return [] }
        let query = clean.map { "kMDItemTextContent == \"\($0)*\"cdw" }.joined(separator: " && ")
        return run(query, in: root, limit: limit, timeout: timeout)
    }

    /// Photos and videos made with a device whose make or model contains `device` ("iPhone", "Canon").
    public static func paths(fromDevice device: String, in root: String, limit: Int = 50_000, timeout: TimeInterval = 8) -> Set<String> {
        let d = sanitize(device)
        guard !d.isEmpty else { return [] }
        let query = "kMDItemAcquisitionModel == \"*\(d)*\"cd || kMDItemAcquisitionMake == \"*\(d)*\"cd"
        return run(query, in: root, limit: limit, timeout: timeout)
    }

    /// Only letters, digits, spaces and a few safe marks reach the query: nothing can break out of the quotes.
    static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" || $0 == "." }
            .map(Character.init)).trimmingCharacters(in: .whitespaces)
    }

    static func run(_ query: String, in root: String, limit: Int, timeout: TimeInterval) -> Set<String> {
        guard let out = Shell.run("/usr/bin/mdfind", ["-onlyin", root, query], timeout: timeout) else { return [] }
        var result = Set<String>()
        for line in out.split(separator: "\n") {
            result.insert(String(line))
            if result.count >= limit { break }
        }
        return result
    }
}

import Foundation

/// Headroom's notepad: a new text file in the folder you're looking at, and edits to the text files you
/// open in it. Besides Tidy these are the only writes to your files: a new file never replaces one, and a
/// save rewrites only the file open in the editor — never one that changed on disk since it was read.
public enum Notes {
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case markdown = "md", text = "txt"
        public var id: String { rawValue }
        public var title: String { self == .markdown ? "Markdown" : "Plain Text" }
    }

    public enum Problem: Error, Equatable, LocalizedError {
        case notHere, notText, tooBig, inICloudOnly, changedElsewhere
        public var errorDescription: String? {
            switch self {
            case .notHere: "Headroom doesn't make files in this folder."
            case .notText: "This isn't a plain text file."
            case .tooBig: "This file is too big to edit here."
            case .inICloudOnly: "This file is only in iCloud. Open it in Finder to download it first."
            case .changedElsewhere: "This file changed in another app since you opened it."
            }
        }
    }

    /// What the editor opens: plain text it can show whole, never a dataless iCloud file (reading downloads it).
    public static let editable: Set<String> = ["md", "markdown", "txt", "text"]
    public static let maxBytes = 5_000_000

    public static func canEdit(_ url: URL) -> Bool { (try? check(url)) != nil }

    static func check(_ url: URL) throws {
        guard editable.contains(url.pathExtension.lowercased()) else { throw Problem.notText }
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard v.isRegularFile == true else { throw Problem.notText }
        if LibraryScanner.isDataless(url) { throw Problem.inICloudOnly }
        if (v.fileSize ?? 0) > maxBytes { throw Problem.tooBig }
    }

    /// New files go only in your own folders: not Library, not inside an app or another bundle.
    public static func canCreate(in folder: String, home: String = HeadroomPaths.home) -> Bool {
        let f = (folder as NSString).standardizingPath
        let h = (home as NSString).standardizingPath
        let inHome = f == h || f.hasPrefix(h + "/")
        guard inHome || f.hasPrefix("/Volumes/") else { return false }
        let inside = inHome ? f.dropFirst(h.count).lowercased() : ""
        if inside == "/library" || inside.hasPrefix("/library/") { return false }
        if f.split(separator: "/").contains(where: { $0.hasSuffix(".app") || $0.hasSuffix(".photoslibrary") }) { return false }
        return FileManager.default.isWritableFile(atPath: f)
    }

    /// The name a new file gets in a folder, given which names are already there.
    public static func name(base: String = "Untitled", ext: String, taken: (String) -> Bool) -> String {
        // Finder's way: Untitled, Untitled 2, Untitled 3…; bounded, so an odd folder can't spin forever.
        for n in 1...1_000 {
            let candidate = n == 1 ? "\(base).\(ext)" : "\(base) \(n).\(ext)"
            if !taken(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(8)).\(ext)"
    }

    /// Make an empty file and return where it is. Never replaces anything: the write fails if the name's taken.
    public static func create(_ kind: Kind, in folder: URL, home: String = HeadroomPaths.home) throws -> URL {
        guard canCreate(in: folder.path, home: home) else { throw Problem.notHere }
        let fm = FileManager.default
        let file = name(ext: kind.rawValue) { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let url = folder.appendingPathComponent(file)
        try Data().write(to: url, options: .withoutOverwriting)
        return url
    }

    /// The text and the file's date on disk, which `save` checks before writing.
    public static func read(_ url: URL) throws -> (text: String, modified: Date?) {
        try check(url)
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return (text, modified(url))
    }

    /// Write the editor's text back. Refuses when the file changed on disk since `expected` — another app's
    /// edit is never lost — unless `force` (the user chose to keep their version). Returns the new date.
    @discardableResult
    public static func save(_ text: String, to url: URL, expected: Date?, force: Bool = false) throws -> Date? {
        guard editable.contains(url.pathExtension.lowercased()) else { throw Problem.notText }
        if !force, let now = modified(url), now != expected { throw Problem.changedElsewhere }
        try Data(text.utf8).write(to: url, options: .atomic)
        return modified(url)
    }

    /// Read fresh each time: a URL caches its resource values, which would hide another app's edit.
    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Copy files you picked or dropped into a folder (Add Files on a drive). Copies only: the originals stay,
    /// and a name already in the folder is skipped, never replaced. Returns what was skipped or failed.
    public static func add(_ files: [URL], into folder: URL) -> (copied: Int, skipped: [String]) {
        let fm = FileManager.default
        var copied = 0
        var skipped: [String] = []
        for file in files {
            let target = folder.appendingPathComponent(file.lastPathComponent)
            if file.standardizedFileURL == target.standardizedFileURL || fm.fileExists(atPath: target.path) {
                skipped.append(file.lastPathComponent); continue
            }
            do { try fm.copyItem(at: file, to: target); copied += 1 } catch { skipped.append(file.lastPathComponent) }
        }
        return (copied, skipped)
    }
}

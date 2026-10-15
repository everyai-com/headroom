import Foundation

/// Where Headroom keeps its own small state (history, activity log, map snapshots).
public enum HeadroomPaths {
    public static var support: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Everything Headroom removed, and where trashed things went — so any trashed item can be put back.
public struct ActivityLog: Codable, Sendable {
    public struct Item: Codable, Sendable, Hashable {
        public var original: String
        /// Where it landed in the Trash; nil when it was deleted for good.
        public var inTrash: String?

        public init(original: String, inTrash: String? = nil) {
            self.original = original
            self.inTrash = inTrash
        }
    }

    public struct Entry: Codable, Sendable, Identifiable, Hashable {
        public enum Kind: String, Codable, Sendable { case reclaimed, trashed, emptied, deleted, uninstalled, ranTool }
        public var id = UUID()
        public var date = Date()
        public var kind: Kind
        public var title: String
        public var bytes: Int64
        public var items: [Item]
        /// For build output: the command that brings it back.
        public var rebuild: String?
        public var automatic = false
        public var restored = false
        /// When its trashed copies were deleted for good from inside Headroom (optional: older logs lack it).
        public var purgedAt: Date?

        public init(kind: Kind, title: String, bytes: Int64, items: [Item], rebuild: String? = nil, automatic: Bool = false) {
            self.kind = kind
            self.title = title
            self.bytes = bytes
            self.items = items
            self.rebuild = rebuild
            self.automatic = automatic
        }

        /// Trashed items still sitting in the Trash, whose original place is free.
        public var canPutBack: Bool {
            !restored && items.contains { item in
                guard let t = item.inTrash else { return false }
                return FileManager.default.fileExists(atPath: t) && !FileManager.default.fileExists(atPath: item.original)
            }
        }

        /// The trashed copies still sitting in the Trash.
        public var stillInTrash: [URL] {
            guard !restored else { return [] }
            return items.compactMap { $0.inTrash }.filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
        }

        /// Its trashed copies can be deleted for good, so the space actually comes back.
        public var canDeleteFromTrash: Bool { !stillInTrash.isEmpty }
    }

    public var entries: [Entry] = []

    public init() {}

    public static var defaultURL: URL { HeadroomPaths.support.appendingPathComponent("activity.json") }

    public static func load(from url: URL = defaultURL) -> ActivityLog {
        guard let data = try? Data(contentsOf: url) else { return ActivityLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ActivityLog.self, from: data)) ?? ActivityLog()
    }

    public func save(to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }

    public mutating func record(_ entry: Entry, to url: URL = defaultURL) {
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(1000))
        save(to: url)
    }

    /// Move an entry's trashed items back where they were. Never overwrites: an item whose
    /// original place is taken again stays in the Trash.
    public static func putBack(_ entry: Entry) -> (restored: Int, failed: [String]) {
        let fm = FileManager.default
        var restored = 0
        var failed: [String] = []
        for item in entry.items {
            guard let t = item.inTrash, fm.fileExists(atPath: t) else { continue }
            let original = URL(fileURLWithPath: item.original)
            if fm.fileExists(atPath: original.path) { failed.append("\(original.lastPathComponent): something is there again"); continue }
            do {
                try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: URL(fileURLWithPath: t), to: original)
                restored += 1
            } catch { failed.append("\(original.lastPathComponent): \(error.localizedDescription)") }
        }
        return (restored, failed)
    }

    /// Only something inside a Trash folder (`~/.Trash/…`) can be finished off from Activity —
    /// never wherever a stale log entry happens to point.
    public static func isInTrash(_ url: URL, home: URL) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        let trash = home.standardizedFileURL.path.lowercased() + "/.trash/"
        return path.hasPrefix(trash) && path.count > trash.count
    }

    /// Delete an entry's trashed copies for good, through the Cleaner like every other removal.
    /// Returns what came back and what couldn't be removed.
    public static func deleteFromTrash(_ entry: Entry, guardrail: SafetyGuard) -> (freed: Int64, removed: Int, failed: [String]) {
        var failed: [String] = []
        var plan: [Finding] = []
        var sizes: Int64 = 0
        for url in entry.stillInTrash {
            guard isInTrash(url, home: guardrail.home) else {
                failed.append("\(url.lastPathComponent): not in the Trash any more"); continue
            }
            let bytes = DiskWalker.measure(url).allocated
            sizes += bytes
            plan.append(.picked(url, bytes: bytes, method: .delete))
        }
        guard !plan.isEmpty else { return (0, 0, failed) }
        let report = Cleaner(guardrail: guardrail).reclaim(plan)
        failed += report.skipped.map(\.reason)
        // The volume delta is the truth, but other writes blur it; never report more than went.
        let freed = report.freedBytes > 0 ? min(report.freedBytes, sizes) : sizes * Int64(report.reclaimed.count) / Int64(plan.count)
        return (freed, report.reclaimed.count, failed)
    }

    /// Activity for a finished reclaim.
    public static func entries(for findings: [Finding], report: CleanupReport, automatic: Bool = false) -> [Entry] {
        let trashed = Dictionary(report.trashed.map { ($0.original.path, $0.inTrash.path) }, uniquingKeysWith: { a, _ in a })
        return findings.filter { report.reclaimed.contains($0.id) }.map { f in
            let kind: Entry.Kind = switch f.method {
            case .trash: .trashed
            case .deleteContents: .emptied
            case .command: .ranTool
            default: f.id.hasPrefix("picked:") ? .deleted : .reclaimed
            }
            let items = f.paths.map { Item(original: $0.path, inTrash: trashed[$0.path]) }
            let title = f.project.map { "\($0) · \(f.title)" } ?? f.title
            return Entry(kind: kind, title: title, bytes: f.reclaimable, items: items, rebuild: f.rebuild, automatic: automatic)
        }
    }
}

/// Your never-touch list applied to scan results: excluded paths drop out of findings
/// (and the guard refuses them anyway, so nothing slips through a stale list).
public enum Exclusions {
    static func fold(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path.lowercased() }

    /// The path is excluded, inside an excluded folder, or contains one.
    public static func touches(_ path: String, _ excluded: [String]) -> Bool {
        let p = fold(path)
        return excluded.map(fold).contains { e in p == e || p.hasPrefix(e + "/") || e.hasPrefix(p + "/") }
    }

    public static func apply(_ findings: [Finding], excluded: [String]) -> [Finding] {
        guard !excluded.isEmpty else { return findings }
        return findings.compactMap { f in
            let kept = f.paths.filter { !touches($0.path, excluded) }
            if kept.count == f.paths.count { return f }
            guard !kept.isEmpty else { return nil }
            // Tools act on everything at once (`simctl delete a b`): if any part is excluded, skip it.
            if case .command = f.method { return nil }
            var trimmed = f
            trimmed.paths = kept
            trimmed.size = DiskWalker.measure(kept)
            return trimmed
        }
    }
}

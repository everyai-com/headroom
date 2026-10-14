import Foundation

/// The map's sizes over time — answers "where did my space go?" by folder, not just in total.
public struct GrowthHistory: Codable, Sendable {
    public struct Snapshot: Codable, Sendable {
        public var date: Date
        /// Tile id (a path, or a volume id) → bytes, for every group and tile on the map.
        public var bytes: [String: Int64]
        public var names: [String: String]
    }

    public struct Change: Sendable, Identifiable, Hashable {
        public var id: String
        public var name: String
        public var delta: Int64
        public var now: Int64
        public var url: URL? { id.hasPrefix("/") ? URL(fileURLWithPath: id) : nil }
    }

    public var snapshots: [Snapshot] = []

    public init() {}

    public static var defaultURL: URL { HeadroomPaths.support.appendingPathComponent("map-history.json") }

    public static func load(from url: URL = defaultURL) -> GrowthHistory {
        guard let data = try? Data(contentsOf: url) else { return GrowthHistory() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(GrowthHistory.self, from: data)) ?? GrowthHistory()
    }

    public func save(to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }

    public static func snapshot(of root: DiskNode, at date: Date = .now) -> Snapshot {
        var bytes: [String: Int64] = [:]
        var names: [String: String] = [:]
        for group in root.children {
            for tile in group.children {
                bytes[tile.id] = tile.bytes
                names[tile.id] = tile.url?.tildePath ?? "\(group.name) · \(tile.name)"
            }
            if group.children.isEmpty {
                bytes[group.id] = group.bytes
                names[group.id] = group.name
            }
        }
        return Snapshot(date: date, bytes: bytes, names: names)
    }

    /// Keep every snapshot from the last 6 hours, one per hour for two days, then one per day for 60 days.
    public mutating func record(_ root: DiskNode, at date: Date = .now, to url: URL? = defaultURL) {
        snapshots.append(Self.snapshot(of: root, at: date))
        var kept: [Snapshot] = []
        var seen = Set<String>()
        for s in snapshots.sorted(by: { $0.date > $1.date }) {
            let age = date.timeIntervalSince(s.date)
            guard age < 60 * 86_400 else { continue }
            if age < 6 * 3600 { kept.append(s); continue }
            let bucket = age < 2 * 86_400 ? "h\(Int(s.date.timeIntervalSince1970 / 3600))" : "d\(Int(s.date.timeIntervalSince1970 / 86_400))"
            if seen.insert(bucket).inserted { kept.append(s) }
        }
        snapshots = kept.reversed()
        if let url { save(to: url) }
    }

    /// The newest snapshot at least `hours` older than `date` (else the oldest there is).
    public func baseline(hoursBefore hours: Double, from date: Date = .now) -> Snapshot? {
        let cutoff = date.addingTimeInterval(-hours * 3600)
        return snapshots.last { $0.date <= cutoff } ?? snapshots.first { $0.date < date.addingTimeInterval(-60) }
    }

    /// What grew (and shrank) between two snapshots, biggest change first.
    public static func changes(from old: Snapshot, to new: Snapshot, minimum: Int64 = 100_000_000) -> [Change] {
        Set(old.bytes.keys).union(new.bytes.keys).compactMap { id in
            let delta = (new.bytes[id] ?? 0) - (old.bytes[id] ?? 0)
            guard abs(delta) >= minimum else { return nil }
            return Change(id: id, name: new.names[id] ?? old.names[id] ?? id, delta: delta, now: new.bytes[id] ?? 0)
        }.sorted { $0.delta > $1.delta }
    }
}

/// Single big files, collected while the map walks the disk (no second walk).
public struct BigFile: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var bytes: Int64
    public var modified: Date
}

public final class BigFileCollector: @unchecked Sendable {
    public let threshold: Int64
    let home: String
    private var found: [BigFile] = []
    private let lock = NSLock()

    public init(threshold: Int64 = 500_000_000, home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.threshold = threshold
        self.home = home.standardizedFileURL.path
    }

    /// Live virtual-machine disks: deleting one wipes every container and image inside.
    static let vmHomes = [".colima", ".lima", ".orbstack", ".docker", ".vagrant.d", ".minikube", ".multipass"]

    /// Your files only: under home, outside Library (app data), never inside apps, photo
    /// libraries, git history or a VM's disk.
    func wants(_ path: String) -> Bool {
        path.hasPrefix(home + "/") && !path.hasPrefix(home + "/Library/")
            && !path.contains(".app/") && !path.contains(".photoslibrary/") && !path.hasPrefix(home + "/.Trash/")
            && !path.contains("/.git/") && !Self.vmHomes.contains { path.hasPrefix(home + "/" + $0 + "/") }
    }

    func add(_ path: String, bytes: Int64, modified: Date) {
        guard wants(path) else { return }
        lock.lock(); defer { lock.unlock() }
        found.append(BigFile(url: URL(fileURLWithPath: path), bytes: bytes, modified: modified))
    }

    public var files: [BigFile] {
        lock.lock(); defer { lock.unlock() }
        return found.sorted { $0.bytes > $1.bytes }
    }
}

import Foundation

/// A node in the map of the whole disk — every GB is somewhere in this tree.
public struct DiskNode: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var url: URL?
    public var bytes: Int64
    /// Colour family for the treemap.
    public var area: Area
    /// Set when this exact folder is a reclaim candidate.
    public var safety: Safety?
    public var children: [DiskNode]
    /// Children not measured yet (drill-down loads them on demand).
    public var expandable: Bool

    public enum Area: String, Sendable, CaseIterable, Codable {
        case system, apps, developer, projects, agents, appData, caches, media, documents, downloads, systemData, other, free

        public var title: String {
            switch self {
            case .system: "macOS"
            case .apps: "Applications"
            case .developer: "Xcode & dev tools"
            case .projects: "Code projects"
            case .agents: "AI agents & dev homes"
            case .appData: "App data"
            case .caches: "Caches"
            case .media: "Photos, music & video"
            case .documents: "Documents"
            case .downloads: "Downloads"
            case .systemData: "System data"
            case .other: "Other & unreadable"
            case .free: "Free"
            }
        }
    }

    public init(id: String, name: String, url: URL? = nil, bytes: Int64, area: Area, safety: Safety? = nil,
                children: [DiskNode] = [], expandable: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.bytes = bytes
        self.area = area
        self.safety = safety
        self.children = children
        self.expandable = expandable
    }
}

/// Builds the disk map: every top-level area measured, two levels deep, so the whole
/// used space is accounted for — what we can't read is shown as such, never hidden.
public enum DiskMap {
    public struct Progress: Sendable {
        public var done: Int
        public var total: Int
        public var current: String
    }

    public static func build(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                             volume: VolumeStatus = .current(),
                             safetyByPath: [String: Safety] = [:],
                             progress: @escaping @Sendable (Progress) -> Void = { _ in },
                             isCancelled: @escaping @Sendable () -> Bool = { false }) async -> DiskNode {
        let fm = FileManager.default
        func url(_ p: String) -> URL { p.hasPrefix("/") ? URL(fileURLWithPath: p) : home.appendingPathComponent(p) }

        // (area, group title, roots whose children become tiles)
        var groups: [(DiskNode.Area, String, [URL])] = [
            (.apps, "Applications", [url("/Applications"), url("Applications")]),
            (.developer, "Xcode & dev tools", [url("/Library/Developer"), url("Library/Developer"), url("/opt/homebrew"), url("/usr/local")]),
            (.projects, "Desktop", [url("Desktop")]),
            (.documents, "Documents", [url("Documents")]),
            (.downloads, "Downloads", [url("Downloads")]),
            (.media, "Photos, music & video", [url("Pictures"), url("Movies"), url("Music")]),
            (.appData, "Application Support", [url("Library/Application Support")]),
            (.appData, "Containers", [url("Library/Containers"), url("Library/Group Containers")]),
            (.caches, "Caches", [url("Library/Caches"), url("Library/pnpm")]),
            (.systemData, "System data", [url("/private/var/vm"), url("/private/var/folders"), url("/Library/Updates"), url("/Library/Application Support")]),
        ]
        // Hidden folders in home: agent histories and tool homes (~/.claude, ~/.codex, ~/.npm, ~/.cargo…).
        let dotDirs = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".") && $0 != ".Trash" }
            .map { home.appendingPathComponent($0) }
        groups.append((.agents, "AI agents & dev homes", dotDirs))
        // The rest of ~/Library, and any other top-level home folders.
        let libraryCovered: Set<String> = ["Application Support", "Containers", "Group Containers", "Caches", "Developer", "pnpm"]
        let libraryRest = ((try? fm.contentsOfDirectory(atPath: url("Library").path)) ?? [])
            .filter { !libraryCovered.contains($0) }.map { url("Library").appendingPathComponent($0) }
        groups.append((.appData, "Rest of Library", libraryRest))
        let homeCovered: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library", "Applications"]
        let homeRest = ((try? fm.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { !$0.hasPrefix(".") && !homeCovered.contains($0) }.map { home.appendingPathComponent($0) }
        groups.append((.documents, "Other home folders", homeRest))
        groups.append((.other, "Trash", [url(".Trash")]))

        // Every tile = one child of a root, measured independently and in parallel.
        var tiles: [(group: Int, url: URL)] = []
        for (g, group) in groups.enumerated() {
            for root in group.2 where fm.fileExists(atPath: root.path) {
                let isGroupedList = group.1 == "AI agents & dev homes" || group.1 == "Rest of Library"
                    || group.1 == "Other home folders" || group.1 == "Trash"
                if isGroupedList {
                    tiles.append((g, root))
                } else {
                    let kids = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
                    if kids.isEmpty { continue }
                    tiles += kids.filter { $0 != ".DS_Store" && $0 != ".localized" }.map { (g, root.appendingPathComponent($0)) }
                }
            }
        }
        let total = tiles.count
        let counter = Counter()
        let measured: [(Int, URL, DirectorySize)] = await withTaskGroup(of: (Int, URL, DirectorySize).self) { group in
            var next = 0
            for _ in 0..<min(6, tiles.count) {
                let t = tiles[next]; next += 1
                group.addTask { (t.group, t.url, DiskWalker.measure(t.url, isCancelled: isCancelled)) }
            }
            var out: [(Int, URL, DirectorySize)] = []
            for await r in group {
                out.append(r)
                progress(Progress(done: counter.increment(), total: total, current: r.1.tildePath))
                if next < tiles.count {
                    let t = tiles[next]; next += 1
                    group.addTask { (t.group, t.url, DiskWalker.measure(t.url, isCancelled: isCancelled)) }
                }
            }
            return out
        }

        var groupNodes: [DiskNode] = []
        var unreadableFiles = 0
        for (g, group) in groups.enumerated() {
            let items = measured.filter { $0.0 == g && $0.2.allocated > 0 }
            unreadableFiles += measured.filter { $0.0 == g }.reduce(0) { $0 + $1.2.unreadable }
            guard !items.isEmpty else { continue }
            let children = items.map { _, u, size in
                DiskNode(id: u.path, name: u.lastPathComponent, url: u, bytes: size.allocated, area: group.0,
                         safety: safetyByPath[u.path], expandable: true)
            }.sorted { $0.bytes > $1.bytes }
            let sum = children.reduce(0) { $0 + $1.bytes }
            groupNodes.append(DiskNode(id: "group:\(group.1)", name: group.1, bytes: sum, area: group.0, children: children))
        }

        // macOS itself lives on the sealed system volume.
        if volume.systemUsed > 0 {
            groupNodes.append(DiskNode(id: "system", name: "macOS", bytes: volume.systemUsed, area: .system))
        }
        // What the disk says is used but no readable folder accounts for: other users, root-only
        // system folders, APFS snapshots and metadata. Shown, never silently dropped.
        let accounted = groupNodes.reduce(0) { $0 + $1.bytes }
        let other = volume.used - accounted
        if other > 500_000_000 {
            groupNodes.append(DiskNode(id: "other", name: unreadableFiles > 0 ? "Other (needs Full Disk Access to see inside)" : "Other system storage",
                                       bytes: other, area: .other))
        }
        return DiskNode(id: "root", name: "Macintosh HD", bytes: groupNodes.reduce(0) { $0 + $1.bytes }, area: .other,
                        children: groupNodes.sorted { $0.bytes > $1.bytes })
    }

    /// Children of a folder tile, for drilling into the map.
    public static func expand(_ node: DiskNode, safetyByPath: [String: Safety] = [:]) async -> [DiskNode] {
        guard let url = node.url else { return node.children }
        return await DiskWalker.children(of: url).filter { $0.size.allocated > 0 }.map {
            DiskNode(id: $0.url.path, name: $0.url.lastPathComponent, url: $0.url, bytes: $0.size.allocated, area: node.area,
                     safety: safetyByPath[$0.url.path], expandable: true)
        }
    }
}

/// Thread-safe progress counter.
final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

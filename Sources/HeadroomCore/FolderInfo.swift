import Foundation

/// What a folder card says before you open it: how many items are in it and what it all weighs.
public struct FolderSize: Sendable, Hashable {
    /// Items directly inside (what you see when you open it), hidden ones left out.
    public var items: Int
    public var bytes: Int64
    /// The walk stopped at its limit: there's more than `bytes`.
    public var partial: Bool
    public init(items: Int, bytes: Int64, partial: Bool = false) {
        self.items = items
        self.bytes = bytes
        self.partial = partial
    }

    /// "12 items · 3.4 GB", "1 item · 0 KB".
    public var label: String {
        let n = "\(items.formatted()) \(items == 1 ? "item" : "items")"
        return items == 0 ? "Empty" : "\(n) · \(ByteFormat.compact(bytes))\(partial ? "+" : "")"
    }
}

public enum FolderSizes {
    /// Count and size a folder, read-only: the same bounded walk as `Workspaces.summarize`
    /// (no hidden files, dependencies or build output in projects; iCloud-only files from metadata).
    public static func measure(_ path: String, limit: Int = 60_000, isCancelled: @Sendable () -> Bool = { false }) -> FolderSize {
        let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles]))?.count ?? 0
        let summary = Workspaces.summarize(folder: path, keep: 0, limit: limit, isCancelled: isCancelled)
        return FolderSize(items: items, bytes: summary.bytes, partial: summary.partial)
    }
}

// MARK: - Grouping

/// How a folder's items can be grouped on screen. Nothing moves on disk.
public enum FolderGrouping: String, CaseIterable, Sendable, Identifiable {
    case none = "None", kind = "Kind", dateAdded = "Date Added"
    public var id: String { rawValue }
}

/// A run of items under one heading: "Images", "Yesterday".
public struct ItemGroup: Sendable, Hashable, Identifiable {
    public var title: String
    public var items: [LibraryItem]
    public var id: String { title }
    public init(title: String, items: [LibraryItem]) {
        self.title = title
        self.items = items
    }
}

extension FolderGrouping {
    /// The date-added buckets, in order.
    public static let dateBuckets = ["Today", "Yesterday", "This Week", "Earlier"]

    /// Split items into groups, keeping their order inside each group. Empty groups are left out;
    /// `.none` is one untitled group.
    public func groups(_ items: [LibraryItem], now: Date = .now, calendar: Calendar = .current) -> [ItemGroup] {
        switch self {
        case .none:
            return [ItemGroup(title: "", items: items)]
        case .kind:
            let order = ["Folders"] + FileKind.allCases.map(\.title)
            let byTitle = Dictionary(grouping: items) { $0.isFolder ? "Folders" : $0.kind.title }
            return order.compactMap { t in byTitle[t].map { ItemGroup(title: t, items: $0) } }
        case .dateAdded:
            let byBucket = Dictionary(grouping: items) { Self.bucket($0.arrived, now: now, calendar: calendar) }
            return Self.dateBuckets.compactMap { t in byBucket[t].map { ItemGroup(title: t, items: $0) } }
        }
    }

    /// Today, Yesterday, This Week (since the calendar's start of the week) or Earlier.
    static func bucket(_ date: Date, now: Date, calendar: Calendar) -> String {
        if date >= calendar.startOfDay(for: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)), date >= yesterday { return "Yesterday" }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), date >= week.start { return "This Week" }
        return "Earlier"
    }
}

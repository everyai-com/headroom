import Foundation

/// Capacity of the startup disk, the way the user experiences it.
public struct VolumeStatus: Sendable, Hashable, Codable {
    public var total: Int64
    /// Free right now (what `df` reports).
    public var free: Int64
    /// Free including space macOS can purge on demand (iCloud-evictable, caches it manages).
    public var availableForImportantUsage: Int64
    /// Bytes used by the sealed system volume (macOS itself).
    public var systemUsed: Int64
    public var date: Date

    public var used: Int64 { max(0, total - free) }
    public var purgeable: Int64 { max(0, availableForImportantUsage - free) }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    public enum Health: String, Sendable { case good, tight, critical }

    /// Under 10 GB is tight; under 3 GB macOS itself starts to fail (swap, updates, apps crash).
    public var health: Health {
        if free < 3_000_000_000 { return .critical }
        if free < 10_000_000_000 { return .tight }
        return .good
    }

    public init(total: Int64, free: Int64, availableForImportantUsage: Int64, systemUsed: Int64, date: Date = .now) {
        self.total = total
        self.free = free
        self.availableForImportantUsage = availableForImportantUsage
        self.systemUsed = systemUsed
        self.date = date
    }

    /// Read the startup disk (the Data volume holds everything but macOS itself).
    public static func current() -> VolumeStatus {
        let data = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? data.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? free

        var sys = statfs()
        var systemUsed: Int64 = 0
        if statfs("/", &sys) == 0 {
            systemUsed = Int64(sys.f_blocks - sys.f_bfree) * Int64(sys.f_bsize)
        }
        return VolumeStatus(total: total, free: free, availableForImportantUsage: important, systemUsed: systemUsed)
    }
}

public enum ByteFormat {
    /// Finder-style decimal units ("12.4 GB"), so numbers match what macOS shows.
    public static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    /// Compact form for tight spaces ("12.4G").
    public static func compact(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 100 { return String(format: "%.0fG", gb) }
        if gb >= 1 { return String(format: "%.1fG", gb) }
        return String(format: "%.0fM", Double(bytes) / 1_000_000)
    }
}

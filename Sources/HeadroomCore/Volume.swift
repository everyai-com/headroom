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
        let data = URL(fileURLWithPath: HeadroomPaths.home)
        let values = try? data.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let important = values?.volumeAvailableCapacityForImportantUsage ?? free

        return VolumeStatus(total: total, free: free, availableForImportantUsage: important, systemUsed: systemVolumeUsed)
    }

    /// Bytes on the sealed macOS system volume. On APFS every volume shares one container,
    /// so `statfs("/")` reports the WHOLE container (it once made "macOS" look like 242 GB);
    /// only diskutil's `CapacityInUse` is the system volume's own size. Read once: it only
    /// changes with an OS update.
    public static let systemVolumeUsed: Int64 = {
        guard let xml = Shell.run("/usr/sbin/diskutil", ["info", "-plist", "/"], timeout: 10),
              let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let used = (plist["CapacityInUse"] as? NSNumber)?.int64Value else { return 0 }
        return used
    }()
}

/// The APFS volumes sharing the startup disk. Folders can't see most of them (Preboot,
/// swap, Recovery), so without this a large slice of "used" would be unexplained.
public struct APFSVolume: Sendable, Hashable {
    public var name: String
    public var role: String
    public var bytes: Int64

    /// Human name for a role.
    public var title: String {
        switch role {
        case "System": "macOS"
        case "Preboot": "Preboot (boot files & OS components)"
        case "VM": "Swap (virtual memory)"
        case "Recovery": "Recovery"
        case "Update": "Software update staging"
        case "Data": "Your data"
        default: name
        }
    }

    /// Volumes in the container that holds the startup disk.
    public static func startupContainer() -> [APFSVolume] {
        guard let xml = Shell.run("/usr/sbin/diskutil", ["apfs", "list", "-plist"], timeout: 15),
              let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else { return [] }
        for c in containers {
            let vols = (c["Volumes"] as? [[String: Any]]) ?? []
            let parsed = vols.map { v in
                APFSVolume(name: v["Name"] as? String ?? "?",
                           role: ((v["Roles"] as? [String]) ?? []).first ?? "",
                           bytes: (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0)
            }
            if parsed.contains(where: { $0.role == "System" }), parsed.contains(where: { $0.role == "Data" }) {
                return parsed
            }
        }
        return []
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
        if bytes >= 1_000_000 { return String(format: "%.0fM", Double(bytes) / 1_000_000) }
        return bytes <= 0 ? "0K" : String(format: "%.0fK", max(1, Double(bytes) / 1000))
    }
}

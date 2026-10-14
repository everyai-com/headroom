import Foundation

/// How safe it is to reclaim something. The app only ever reclaims `.safe` in one click.
public enum Safety: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Regenerable: a cache or build output your tools recreate automatically. Nothing is lost.
    case safe = 0
    /// Regenerable, but costly to rebuild or possibly in use right now. Opt-in.
    case review = 1
    /// Your data. Shown so you know where the space is — never deleted by Headroom.
    case keep = 2

    public static func < (a: Safety, b: Safety) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .safe: "Safe to reclaim"
        case .review: "Review first"
        case .keep: "Your data"
        }
    }
}

public enum StorageCategory: String, CaseIterable, Codable, Sendable {
    case projectArtifacts, packageCaches, developerTools, aiAgents, appCaches, browsers, logs, trash, userData

    public var title: String {
        switch self {
        case .projectArtifacts: "Project build artifacts"
        case .packageCaches: "Package manager caches"
        case .developerTools: "Xcode & simulators"
        case .aiAgents: "AI coding agents"
        case .appCaches: "App caches"
        case .browsers: "Browser engines"
        case .logs: "Logs"
        case .trash: "Trash"
        case .userData: "Your files & app data"
        }
    }

    public var symbol: String {
        switch self {
        case .projectArtifacts: "shippingbox.fill"
        case .packageCaches: "archivebox.fill"
        case .developerTools: "hammer.fill"
        case .aiAgents: "sparkles"
        case .appCaches: "square.stack.3d.up.fill"
        case .browsers: "globe"
        case .logs: "doc.text.fill"
        case .trash: "trash.fill"
        case .userData: "person.crop.square.fill"
        }
    }
}

/// How a finding is reclaimed.
public enum CleanupMethod: Codable, Sendable, Hashable {
    /// Delete the paths themselves (regenerable folders such as `node_modules`).
    case delete
    /// Empty the folders but keep them (apps expect their cache folder to exist).
    case deleteContents
    /// Run the tool's own cleanup (e.g. `xcrun simctl delete unavailable`, `pnpm store prune`).
    case command(executable: String, arguments: [String])
    /// Move to the Trash — recoverable until the Trash is emptied.
    case trash
    /// Never reclaimed by Headroom; reveal in Finder only.
    case none
}

/// One thing taking space, with everything needed to decide about it.
public struct Finding: Identifiable, Sendable, Hashable {
    public var id: String
    public var title: String
    /// Where it lives, for display ("~/Desktop/shop/node_modules").
    public var subtitle: String
    /// Why it is safe (or not), and what brings it back.
    public var detail: String
    public var category: StorageCategory
    public var safety: Safety
    public var paths: [URL]
    public var size: DirectorySize
    public var lastUsed: Date?
    public var method: CleanupMethod
    public var symbol: String
    /// For project artifacts: the command that recreates it ("pnpm install").
    public var rebuild: String?
    /// For artifacts: the project they belong to.
    public var project: String?

    /// What reclaiming would actually free.
    public var reclaimable: Int64 {
        switch method {
        case .none: 0
        default: size.reclaimable
        }
    }

    public init(
        id: String, title: String, subtitle: String, detail: String, category: StorageCategory, safety: Safety,
        paths: [URL], size: DirectorySize = DirectorySize(), lastUsed: Date? = nil, method: CleanupMethod,
        symbol: String, rebuild: String? = nil, project: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.detail = detail
        self.category = category
        self.safety = safety
        self.paths = paths
        self.size = size
        self.lastUsed = lastUsed
        self.method = method
        self.symbol = symbol
        self.rebuild = rebuild
        self.project = project
    }
}

extension URL {
    /// "~/Desktop/x" for display.
    public var tildePath: String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

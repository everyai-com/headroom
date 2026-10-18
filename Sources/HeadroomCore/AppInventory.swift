import Foundation
import CoreServices

/// Something an app left in your Library.
public struct Leftover: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    /// "Application Support", "Caches", "Containers"…
    public var kind: String
    public var size: DirectorySize
}

public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public var name: String
    public var bundleID: String
    public var version: String?
    public var url: URL
    public var appSize: DirectorySize
    public var leftovers: [Leftover]
    public var lastUsed: Date?
    /// True when `lastUsed` comes from Spotlight; false when it is inferred from the app's own
    /// data changing (Spotlight's index can be off or read-only — common on a full disk).
    public var lastUsedIsExact: Bool = true

    public var dataSize: Int64 { leftovers.reduce(0) { $0 + $1.size.allocated } }
    /// What uninstalling frees: the app plus everything it left behind.
    public var totalSize: Int64 { appSize.allocated + dataSize }
    public var isApple: Bool { bundleID.hasPrefix("com.apple.") }
}

/// Lists installed apps with the data they keep, and uninstalls them completely —
/// to the Trash, so an uninstall is always recoverable until you empty it.
public enum AppInventory {
    public static func appDirectories(home: URL = URL(fileURLWithPath: HeadroomPaths.home)) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    public static func scan(home: URL = URL(fileURLWithPath: HeadroomPaths.home),
                            isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [InstalledApp] {
        let fm = FileManager.default
        var bundles: [URL] = []
        for dir in appDirectories(home: home) {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let url = dir.appendingPathComponent(name)
                if name.hasSuffix(".app") { bundles.append(url) }
                // One level of folders ("Utilities", vendor suites).
                else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                        let inner = try? fm.contentsOfDirectory(atPath: url.path) {
                    bundles += inner.filter { $0.hasSuffix(".app") }.map { url.appendingPathComponent($0) }
                }
            }
        }
        let library = home.appendingPathComponent("Library")
        let index = LibraryIndex(library: library)
        let allIDs = Set(bundles.compactMap { Bundle(url: $0)?.bundleIdentifier?.lowercased() })
        return await withTaskGroup(of: InstalledApp?.self) { group in
            for bundle in bundles {
                group.addTask {
                    guard let info = Bundle(url: bundle)?.infoDictionary,
                          let id = info["CFBundleIdentifier"] as? String else { return nil }
                    let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                        ?? bundle.deletingPathExtension().lastPathComponent
                    let leftovers = index.leftovers(bundleID: id, name: name, executable: info["CFBundleExecutable"] as? String,
                                                    otherBundleIDs: allIDs).map {
                        Leftover(url: $0.url, kind: $0.kind, size: DiskWalker.measure($0.url, isCancelled: isCancelled))
                    }.filter { $0.size.allocated > 0 }
                    // Spotlight first; otherwise the newest change in the app's own data — apps
                    // write preferences and window state every time they run.
                    let spotlight = lastUsed(bundle)
                    let inferred = leftovers.compactMap(\.size.newestModification).max()
                    var app = InstalledApp(name: name, bundleID: id, version: info["CFBundleShortVersionString"] as? String,
                                           url: bundle, appSize: DiskWalker.measure(bundle, isCancelled: isCancelled),
                                           leftovers: leftovers.sorted { $0.size.allocated > $1.size.allocated },
                                           lastUsed: spotlight ?? inferred)
                    app.lastUsedIsExact = spotlight != nil
                    return app
                }
            }
            var out: [InstalledApp] = []
            for await app in group { if let app { out.append(app) } }
            return out.sorted { $0.totalSize > $1.totalSize }
        }
    }

    /// Spotlight's record of when the app was last opened.
    public static func lastUsed(_ bundle: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, bundle as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// The Library folders an app leaves data in, read once and matched by bundle ID.
    struct LibraryIndex: Sendable {
        let library: URL
        /// (subfolder, matching rule): exact bundle-ID names, or contains for group containers.
        static let places: [(folder: String, kind: String)] = [
            ("Application Support", "Application Support"), ("Caches", "Caches"), ("Containers", "App data folder"),
            ("Group Containers", "Shared data folder"), ("Preferences", "Preferences"), ("Preferences/ByHost", "Preferences"),
            ("Saved Application State", "Saved window state"), ("HTTPStorages", "Web storage"), ("WebKit", "Web data"),
            ("Cookies", "Cookies"), ("Logs", "Logs"), ("LaunchAgents", "Launch agent"), ("Application Scripts", "Scripts"),
        ]
        let listing: [String: [String]]

        init(library: URL) {
            self.library = library
            var listing: [String: [String]] = [:]
            for place in Self.places {
                listing[place.folder] = (try? FileManager.default.contentsOfDirectory(
                    atPath: library.appendingPathComponent(place.folder).path)) ?? []
            }
            self.listing = listing
        }

        /// Executable names too generic to stand for one app.
        static let genericNames: Set<String> = ["electron", "launcher", "app", "main", "helper", "runner", "stub", "run", "start"]

        /// Everything in the Library that belongs to this app: its bundle ID exactly, or the ID with a
        /// suffix (`com.vendor.app.ShipIt` updaters, `com.vendor.app.widget` extensions, helpers) —
        /// unless that suffixed ID is another installed app (`com.google.Chrome.canary`). Folders named
        /// after the app or its executable (VS Code keeps `Application Support/Code`) count only in
        /// Application Support, Caches and Logs, and only by exact name.
        func leftovers(bundleID: String, name: String, executable: String? = nil,
                       otherBundleIDs: Set<String> = []) -> [(url: URL, kind: String)] {
            let id = bundleID.lowercased()
            var names: Set<String> = [name.lowercased()]
            if let exe = executable?.lowercased(), exe.count >= 4, !Self.genericNames.contains(exe) { names.insert(exe) }
            // Longer IDs that start with ours belong to other apps.
            let others = otherBundleIDs.filter { $0 != id && $0.hasPrefix(id + ".") }
            func ownsID(_ stem: String) -> Bool {
                guard stem == id || stem.hasPrefix(id + ".") else { return false }
                return !others.contains { stem == $0 || stem.hasPrefix($0 + ".") }
            }
            var out: [(URL, String)] = []
            for place in Self.places {
                for entry in listing[place.folder] ?? [] {
                    let e = entry.lowercased()
                    let stem = e.replacingOccurrences(of: ".plist", with: "")
                        .replacingOccurrences(of: ".savedstate", with: "")
                        .replacingOccurrences(of: ".binarycookies", with: "")
                    let matches: Bool
                    switch place.folder {
                    case "Group Containers":
                        // "group.net.whatsapp.WhatsApp.shared", "TEAMID.com.vendor.app" — the ID as
                        // whole dot-separated parts, so com.vendor.Notes never matches NotesPro's.
                        matches = ("." + e + ".").contains("." + id + ".")
                            && !others.contains { ("." + e + ".").contains("." + $0 + ".") }
                    case "Application Support", "Logs", "Caches":
                        matches = ownsID(stem) || names.contains(e)
                    default:
                        matches = ownsID(stem)
                    }
                    if matches { out.append((library.appendingPathComponent(place.folder).appendingPathComponent(entry), place.kind)) }
                }
            }
            return out
        }
    }

    public struct UninstallReport: Sendable {
        public var trashed: [URL] = []
        /// Where each trashed item went, so the uninstall can be undone.
        public var inTrash: [URL: URL] = [:]
        public var failed: [(URL, String)] = []
        public var bytes: Int64 = 0

        public init() {}
    }

    /// Move the app and its leftovers to the Trash. Apple's apps and running apps are refused.
    public static func uninstall(_ app: InstalledApp, includeData: Bool = true, isRunning: Bool) -> UninstallReport {
        var report = UninstallReport()
        guard !app.isApple else { report.failed.append((app.url, "Apple apps are part of macOS")); return report }
        guard !isRunning else { report.failed.append((app.url, "Quit \(app.name) first")); return report }
        let targets = [app.url] + (includeData ? app.leftovers.map(\.url) : [])
        for url in targets {
            do {
                var landed: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
                report.trashed.append(url)
                if let landed = landed as URL? { report.inTrash[url] = landed }
            } catch {
                report.failed.append((url, error.localizedDescription))
            }
        }
        report.bytes = app.appSize.allocated * (report.trashed.contains(app.url) ? 1 : 0)
            + app.leftovers.filter { report.trashed.contains($0.url) }.reduce(0) { $0 + $1.size.allocated }
        return report
    }
}

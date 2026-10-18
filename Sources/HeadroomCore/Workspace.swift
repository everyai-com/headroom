import Foundation

/// One project on one page: folders and files from anywhere on this Mac (or a drive, or the cloud),
/// gathered by reference. Nothing is copied or moved — a workspace only remembers where things are.
public struct Workspace: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// A line under the title: "Everything for this year's return".
    public var note: String
    public var members: [Member]
    public var created: Date

    /// A folder or file in a workspace: its path, and a bookmark so it's found again after a rename or move.
    public struct Member: Codable, Hashable, Sendable {
        public var path: String
        public var bookmark: Data?
        public init(path: String, bookmark: Data? = nil) {
            self.path = path
            self.bookmark = bookmark
        }
    }

    public init(id: UUID = UUID(), name: String, note: String = "", members: [Member] = [], created: Date = .now) {
        self.id = id
        self.name = name
        self.note = note
        self.members = members
        self.created = created
    }

    public var paths: [String] { members.map(\.path) }
    public func contains(_ path: String) -> Bool { members.contains { $0.path == path } }

    /// Add paths not already here, in order. Returns how many were new.
    @discardableResult
    public mutating func add(_ paths: [String]) -> Int {
        var n = 0
        for p in paths {
            // Not `standardizingPath`: that turns /private/tmp into /tmp, a path the rest of the app never sees.
            var path = (p as NSString).expandingTildeInPath
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard !contains(path) else { continue }
            members.append(Member(path: path, bookmark: Workspaces.bookmark(for: path)))
            n += 1
        }
        return n
    }

    public mutating func remove(_ paths: Set<String>) {
        members.removeAll { paths.contains($0.path) }
    }
}

/// Reading workspaces: where each member is now, what a folder holds, what changed lately.
/// Read-only — it never writes, moves or deletes anything, and never reads an iCloud-only file.
public enum Workspaces {
    // MARK: Store

    public static var storeURL: URL { HeadroomPaths.support.appendingPathComponent("workspaces.json") }

    public static func load(from url: URL = storeURL) -> [Workspace] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Workspace].self, from: data)) ?? []
    }

    public static func save(_ workspaces: [Workspace], to url: URL = storeURL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(workspaces) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Following moves

    static func bookmark(for path: String) -> Data? {
        try? URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Members whose folder or file was renamed or moved get their new path (via the bookmark).
    /// Never mounts a drive or asks for anything; a member that can't be found keeps its old path.
    public static func relocated(_ workspace: Workspace) -> Workspace {
        var w = workspace
        let fm = FileManager.default
        for i in w.members.indices {
            let m = w.members[i]
            guard !fm.fileExists(atPath: m.path), let data = m.bookmark else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  fm.fileExists(atPath: url.path), !w.contains(url.path) else { continue }
            w.members[i] = Workspace.Member(path: url.path, bookmark: stale ? bookmark(for: url.path) : data)
        }
        return w
    }

    // MARK: Where it lives

    /// "Downloads", "Documents › Work", "iCloud Drive › Scans", "Dropbox › Brand", "T7 Shield › Footage":
    /// the folder a path sits in, the way a person would say it.
    public static func place(of path: String, home: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        return describe(folder, home: home)
    }

    /// A folder, said plainly (see `place(of:home:)`).
    public static func describe(_ folder: String, home: String) -> String {
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        let cloud = home + "/Library/CloudStorage/"
        var parts: [String]
        if folder == iCloud || folder.hasPrefix(iCloud + "/") {
            parts = ["iCloud Drive"] + components(String(folder.dropFirst(iCloud.count)))
        } else if folder.hasPrefix(cloud) {
            // "GoogleDrive-sam@gmail.com" → "Google Drive", "Dropbox" → "Dropbox", "OneDrive-Personal" → "OneDrive".
            var rest = components(String(folder.dropFirst(cloud.count)))
            let provider = rest.isEmpty ? "Cloud" : cloudName(rest.removeFirst())
            // Google Drive puts everything under "My Drive".
            if rest.first == "My Drive" { rest.removeFirst() }
            parts = [provider] + rest
        } else if folder.hasPrefix("/Volumes/") {
            parts = components(String(folder.dropFirst("/Volumes/".count)))
        } else if folder == home {
            parts = ["Home"]
        } else if folder.hasPrefix(home + "/") {
            parts = components(String(folder.dropFirst(home.count)))
        } else {
            parts = components(folder)
            if parts.isEmpty { parts = ["Macintosh HD"] }
        }
        // The last two say enough: "Documents › Work", not "Documents › Clients › Acme › Work".
        if parts.count > 2 { parts = [parts[0], "…", parts[parts.count - 1]] }
        return parts.joined(separator: " › ")
    }

    static func components(_ s: String) -> [String] { s.split(separator: "/").map(String.init) }

    static func cloudName(_ folder: String) -> String {
        let base = folder.split(separator: "-", maxSplits: 1).first.map(String.init) ?? folder
        switch base.lowercased() {
        case "googledrive": return "Google Drive"
        case "onedrive": return "OneDrive"
        case "dropbox": return "Dropbox"
        case "box": return "Box"
        default: return base
        }
    }

    // MARK: State

    public enum State: Sendable, Hashable {
        case present
        /// On a drive that isn't plugged in.
        case notConnected(drive: String)
        /// Moved or deleted, and the bookmark can't find it.
        case missing
    }

    public static func state(of path: String) -> State {
        if FileManager.default.fileExists(atPath: path) { return .present }
        if path.hasPrefix("/Volumes/") {
            let drive = components(String(path.dropFirst("/Volumes/".count))).first ?? ""
            if !drive.isEmpty, !FileManager.default.fileExists(atPath: "/Volumes/" + drive) { return .notConnected(drive: drive) }
        }
        return .missing
    }

    // MARK: Folders

    /// What a folder holds: how many files, how big, when something last changed, and the newest files.
    public struct FolderSummary: Sendable, Hashable {
        public var path: String
        public var files = 0
        public var bytes: Int64 = 0
        /// The newest change to anything inside (or the folder itself).
        public var changed: Date?
        /// The most recently changed files, newest first.
        public var recent: [LibraryItem] = []
        /// The walk stopped at its limit: there's more than `files`.
        public var partial = false
        /// The folder is a git repository.
        public var isRepo = false
        public init(path: String) { self.path = path }
    }

    /// Walk a folder (read-only): count and size its files, and keep the `keep` newest. Skips hidden
    /// files, code dependencies, build output inside projects and the insides of photo or VM libraries;
    /// iCloud-only files are counted from their metadata but never opened or listed.
    public static func summarize(folder: String, keep: Int = 12, limit: Int = 60_000,
                                 isCancelled: @Sendable () -> Bool = { false }) -> FolderSummary {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: folder)
        var summary = FolderSummary(path: folder)
        summary.isRepo = fm.fileExists(atPath: root.appendingPathComponent(".git").path)
        summary.changed = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var newest: [LibraryItem] = []
        var seen = 0
        let keys: [URLResourceKey] = LibraryScanner.keys
        func walk(_ dir: URL, inRepo: Bool, depth: Int) {
            guard depth < 24, !summary.partial, !isCancelled() else { return }
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                             options: [.skipsHiddenFiles]) else { return }
            let repo = inRepo || LibraryScanner.projectMarkers.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
            for url in children {
                seen += 1
                if seen > limit { summary.partial = true; return }
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
                let name = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                let modified = v.contentModificationDate ?? .distantPast
                if let c = summary.changed { summary.changed = max(c, modified) } else { summary.changed = modified }
                if v.isDirectory == true, v.isPackage != true, !LibraryScanner.skippedPackages.contains(ext) {
                    if LibraryScanner.skippedFolders.contains(name) || repo && LibraryScanner.skippedInRepo.contains(name) { continue }
                    walk(url, inRepo: repo, depth: depth + 1)
                    continue
                }
                summary.files += 1
                if LibraryScanner.isDataless(url) {
                    // Metadata only: its logical size, never its contents.
                    summary.bytes += Int64(v.fileSize ?? 0)
                    continue
                }
                var packageSize: DirectorySize?
                if v.isDirectory == true {
                    // A package (a Keynote file, an app, a photo library): one item, sized whole.
                    packageSize = DiskWalker.measure(url)
                    summary.bytes += packageSize?.allocated ?? 0
                } else {
                    summary.bytes += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                }
                // Only the newest few are kept as items (they get thumbnails).
                if newest.count < keep || modified > (newest.last?.modified ?? .distantPast) {
                    guard v.isDirectory != true || FileKind.of(extension: ext) != .other else { continue }
                    var kind = FileKind.of(extension: ext)
                    if ext == "key", v.isDirectory != true, (v.fileSize ?? 0) < 16_384 { kind = .other }
                    guard let item = LibraryScanner.makeItem(url, values: v, kind: kind, inProject: repo, packageSize: packageSize) else { continue }
                    newest.append(item)
                    newest.sort { $0.modified > $1.modified }
                    if newest.count > keep { newest.removeLast() }
                }
            }
        }
        walk(root, inRepo: false, depth: 0)
        summary.recent = newest
        return summary
    }

    /// The files changed most recently across a workspace's folders and loose files, newest first,
    /// no older than `since`.
    public static func changedLately(_ summaries: [FolderSummary], files: [LibraryItem], since: Date, limit: Int = 12) -> [LibraryItem] {
        var seen = Set<String>()
        let all = (summaries.flatMap(\.recent) + files.filter { !$0.isFolder })
            .filter { $0.modified >= since && seen.insert($0.path).inserted }
        return Array(all.sorted { $0.modified > $1.modified }.prefix(limit))
    }

    /// A file member as a library item (nil for a folder, a missing file or an iCloud-only one).
    public static func file(at path: String) -> LibraryItem? {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: Set(LibraryScanner.keys)) else { return nil }
        let ext = url.pathExtension.lowercased()
        if v.isDirectory == true, v.isPackage != true || ext.isEmpty { return nil }
        var kind = FileKind.of(extension: ext)
        if ext == "key", v.isDirectory != true, (v.fileSize ?? 0) < 16_384 { kind = .other }
        return LibraryScanner.makeItem(url, values: v, kind: kind)
    }

    /// Is this path a folder (not a package, which is one file to a person)?
    public static func isFolder(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else { return false }
        return v.isDirectory == true && (v.isPackage != true || url.pathExtension.isEmpty)
    }
}

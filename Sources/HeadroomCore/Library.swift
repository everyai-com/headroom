import Foundation

/// What a file is, the way a person would sort it: one shelf per kind.
public enum FileKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case image, video, audio, document, archive, app, other

    public var id: String { rawValue }

    /// The kinds that get a shelf (everything but `.other`).
    public static let shelves: [FileKind] = [.image, .video, .audio, .document, .archive, .app]

    public var title: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Music"
        case .document: "Documents"
        case .archive: "Archives"
        case .app: "Apps"
        case .other: "Other"
        }
    }

    public var singular: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Document"
        case .archive: "Archive"
        case .app: "App"
        case .other: "File"
        }
    }

    public var symbol: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .app: "app.dashed"
        case .other: "doc"
        }
    }

    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "svg", "avif",
                                      "jxl", "raw", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "psd", "ai", "eps"]
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "3gp",
                                      "m2ts", "hevc"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac", "ogg", "oga", "opus", "wma",
                                     "m4b", "caf", "mid", "midi", "m4r"]
    public static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "pages", "rtf", "rtfd", "txt", "md", "markdown", "odt", "key",
                                         "ppt", "pptx", "odp", "numbers", "xls", "xlsx", "csv", "tsv", "ods", "epub", "mobi",
                                         "azw3", "fig", "sketch", "xd", "tex", "vcf", "ics"]
    public static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "lz", "lzma",
                                        "dmg", "iso", "img", "pkg", "mpkg", "xip", "sit", "sitx", "cab"]
    /// Archives that install something — what "old installers" means.
    public static let installers: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]
    /// Plain-text documents: kept out of the library inside code projects, where they're source, not documents.
    static let plainText: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "tex"]

    /// The kind for a file name extension (case-insensitive). Unknown extensions are `.other`.
    public static func of(extension ext: String) -> FileKind {
        let e = ext.lowercased()
        if e == "app" { return .app }
        if imageExtensions.contains(e) { return .image }
        if videoExtensions.contains(e) { return .video }
        if audioExtensions.contains(e) { return .audio }
        if documentExtensions.contains(e) { return .document }
        if archiveExtensions.contains(e) { return .archive }
        return .other
    }
}

/// One file in your library. Plain values only, so the index can be cached and searched off the main thread.
public struct LibraryItem: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var kind: FileKind
    /// Logical size, like Finder shows.
    public var bytes: Int64
    /// What it takes on disk (clones and sparse files take less) — what trashing it frees.
    public var allocated: Int64
    public var created: Date
    public var modified: Date
    /// When it arrived in its folder (a download's download date). nil when the file system doesn't say.
    public var added: Date?
    /// Where it was downloaded from (`kMDItemWhereFroms`): the file URL first, then the page.
    public var whereFrom: [String]?
    /// The app that downloaded it, from the quarantine flag ("Safari", "Slack", "WhatsApp").
    public var downloadedBy: String?
    public var isScreenshot: Bool
    public var tags: [String]
    /// A folder (only when browsing a folder; the index lists files).
    public var isFolder: Bool
    /// Inside a code project (a git repo or package): shown, but never suggested for the Trash —
    /// removing a tracked file would quietly change someone's repo.
    public var inProject: Bool

    public init(path: String, kind: FileKind, bytes: Int64, allocated: Int64? = nil, created: Date, modified: Date,
                added: Date? = nil, whereFrom: [String]? = nil, downloadedBy: String? = nil, isScreenshot: Bool = false,
                tags: [String] = [], isFolder: Bool = false, inProject: Bool = false) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.allocated = allocated ?? bytes
        self.created = created
        self.modified = modified
        self.added = added
        self.whereFrom = whereFrom
        self.downloadedBy = downloadedBy
        self.isScreenshot = isScreenshot
        self.tags = tags
        self.isFolder = isFolder
        self.inProject = inProject
    }

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
    public var ext: String { (path as NSString).pathExtension.lowercased() }
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var isInstaller: Bool { FileKind.installers.contains(ext) }

    /// The date that best says "when did I get this": arrival, else creation.
    public var arrived: Date { added ?? created }
    /// When it came from somewhere (a download, AirDrop, a chat app). Copying a folder around isn't
    /// news: thousands of old PDFs moved into a new folder don't become "from last month".
    public var received: Date? { whereFrom != nil || downloadedBy != nil ? added : nil }
    /// The last time anything happened to it: created, changed or received.
    public var latest: Date { max(modified, created, received ?? .distantPast) }

    /// A short type label: "PDF", "PNG", "Folder"…
    public var typeLabel: String {
        if isFolder { return "Folder" }
        if kind == .app { return "App" }
        if ext.isEmpty { return kind.singular }
        switch ext {
        case "jpeg": return "JPEG"
        case "key": return "Keynote"
        case "pages": return "Pages"
        case "numbers": return "Numbers"
        case "markdown": return "MD"
        default: return ext.uppercased()
        }
    }
}

/// Everything in your library at one moment, with the totals the shelves show.
public struct LibraryIndex: Codable, Sendable {
    public var items: [LibraryItem]
    public var scannedAt: Date
    /// Folders that were walked (for "Locations" and display).
    public var roots: [String]

    public init(items: [LibraryItem] = [], scannedAt: Date = .distantPast, roots: [String] = []) {
        self.items = items
        self.scannedAt = scannedAt
        self.roots = roots
    }

    public struct Totals: Sendable, Hashable {
        public var count = 0
        public var bytes: Int64 = 0
        public init(count: Int = 0, bytes: Int64 = 0) {
            self.count = count
            self.bytes = bytes
        }
    }

    public func totals(_ kind: FileKind) -> Totals {
        items.reduce(into: Totals()) { t, i in
            if i.kind == kind { t.count += 1; t.bytes += i.bytes }
        }
    }

    /// Files in shelves (everything but `.other`).
    public var shelved: [LibraryItem] { items.filter { $0.kind != .other } }

    /// Newest arrivals first.
    public func recent(_ kind: FileKind? = nil, limit: Int = 50) -> [LibraryItem] {
        Array(items.lazy.filter { kind == nil ? $0.kind != .other : $0.kind == kind }
            .sorted { $0.latest > $1.latest }.prefix(limit))
    }

    public var screenshots: [LibraryItem] { items.filter(\.isScreenshot).sorted { $0.arrived > $1.arrived } }

    /// What landed in a Downloads folder, in the order it arrived (not when it last changed).
    public func downloads(in folder: String, limit: Int = 10) -> [LibraryItem] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return Array(items.filter { $0.path.hasPrefix(prefix) }.sorted { $0.arrived > $1.arrived }.prefix(limit))
    }

    // MARK: Cache

    public static var cacheURL: URL { HeadroomPaths.support.appendingPathComponent("library.plist") }

    public static func loadCache(from url: URL = cacheURL) -> LibraryIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(LibraryIndex.self, from: data)
    }

    public func saveCache(to url: URL = cacheURL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// Walks your folders and lists your stuff: photos, videos, music, documents, archives and apps.
/// Read-only — it never changes a file. Skips Library, hidden folders, code dependencies,
/// build output, photo/music libraries' insides, and files that live only in iCloud (reading
/// those would download them).
public enum LibraryScanner {
    /// Your own folders. Library and Applications are never walked (apps come from `AppInventory`).
    public static func defaultRoots(home: URL = URL(fileURLWithPath: HeadroomPaths.home)) -> [URL] {
        let fm = FileManager.default
        let skip: Set<String> = ["Library", "Applications", "Public", "Virtual Machines.localized"]
        var roots = ((try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                  options: [.skipsHiddenFiles])) ?? [])
            .filter { url in
                guard !skip.contains(url.lastPathComponent) else { return false }
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                return v?.isDirectory == true && v?.isPackage != true && v?.isSymbolicLink != true
            }
        // iCloud Drive's own folder (downloaded files only).
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) { roots.append(iCloud) }
        return roots.sorted { $0.path < $1.path }
    }

    /// Code dependencies: never your stuff, wherever they are.
    static let skippedFolders: Set<String> = ["node_modules", "bower_components", "Pods", "DerivedData", "__pycache__",
                                              "site-packages", "venv"]
    /// Build output — skipped inside code projects only (outside one, a "build" folder may be yours).
    static let skippedInRepo: Set<String> = ["env", "target", "build", "dist", "out", "vendor", "Carthage", "elm-stuff",
                                             "coverage", "tmp", "logs"]
    /// Files that say "this folder is code".
    static let projectMarkers = [".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "Package.swift", "Gemfile",
                                 "pom.xml", "build.gradle", "composer.json", "requirements.txt", "setup.py", "tsconfig.json",
                                 "deno.json", "mix.exs", "pubspec.yaml", "CMakeLists.txt", "Makefile"]
    /// Packages that are someone's database, not one file: never listed, never walked.
    static let skippedPackages: Set<String> = ["photoslibrary", "musiclibrary", "tvlibrary", "photolibrary", "aplibrary",
                                               "migratedphotolibrary", "imovielibrary", "fcpbundle", "theater", "pvm",
                                               "vmwarevm", "utm", "sparsebundle", "backupbundle", "xcarchive"]

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
                                         .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey,
                                         .addedToDirectoryDateKey, .tagNamesKey]

    /// Walk `roots` (each in parallel). `limit` bounds a pathological tree.
    public static func scan(roots: [URL] = defaultRoots(), limit: Int = 400_000,
                            isCancelled: @escaping @Sendable () -> Bool = { false }) async -> LibraryIndex {
        let items = await withTaskGroup(of: [LibraryItem].self) { group in
            for root in roots {
                group.addTask {
                    var out: [LibraryItem] = []
                    walk(root, inRepo: false, depth: 0, into: &out, limit: limit, isCancelled: isCancelled)
                    return out
                }
            }
            var all: [LibraryItem] = []
            for await part in group { all += part }
            return all
        }
        // A root inside another root (iCloud Desktop…) must not list a file twice.
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.path).inserted }
        return LibraryIndex(items: unique, scannedAt: .now, roots: roots.map(\.path))
    }

    static func walk(_ dir: URL, inRepo: Bool, depth: Int, into out: inout [LibraryItem], limit: Int,
                     isCancelled: @Sendable () -> Bool) {
        guard depth < 24, out.count < limit, !isCancelled() else { return }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else { return }
        // A code project (git, or a package manifest): its images are icons, its text files are source.
        let repo = inRepo || projectMarkers.contains { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        for url in children {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            // Before anything else: a VM or photo library whose app isn't installed looks like a plain folder.
            if skippedPackages.contains(ext) { continue }
            if v.isDirectory == true, v.isPackage != true {
                if skippedFolders.contains(name) || repo && skippedInRepo.contains(name) { continue }
                walk(url, inRepo: repo, depth: depth + 1, into: &out, limit: limit, isCancelled: isCancelled)
                continue
            }
            var kind = FileKind.of(extension: ext)
            // A tiny ".key" is a PEM private key, not a Keynote deck.
            if ext == "key", v.isDirectory != true, (v.fileSize ?? 0) < 16_384 { kind = .other }
            if repo {
                // Inside code: only real media and office files count as your stuff.
                if kind == .image || kind == .other || kind == .app || FileKind.plainText.contains(ext) { continue }
            }
            if kind == .other, v.isDirectory == true { continue } // unknown packages
            guard let item = makeItem(url, values: v, kind: kind, inProject: repo) else { continue }
            out.append(item)
            if out.count >= limit { return }
        }
    }

    /// One file (or package) as a library item; nil when it lives only in iCloud.
    static func makeItem(_ url: URL, values v: URLResourceValues, kind: FileKind, inProject: Bool = false,
                         packageSize: DirectorySize? = nil) -> LibraryItem? {
        if isDataless(url) { return nil }
        var bytes = Int64(v.fileSize ?? 0)
        var allocated = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        if v.isDirectory == true {
            // A package (Keynote file, app in Downloads): its size is everything inside.
            let size = packageSize ?? DiskWalker.measure(url)
            bytes = size.allocated
            allocated = size.reclaimable
        }
        let xattrs = readExtendedAttributes(url, isImageOrVideo: kind == .image || kind == .video)
        return LibraryItem(
            path: url.path, kind: kind, bytes: bytes, allocated: allocated,
            created: v.creationDate ?? v.contentModificationDate ?? .distantPast,
            modified: v.contentModificationDate ?? .distantPast,
            added: v.addedToDirectoryDate,
            whereFrom: xattrs.0, downloadedBy: xattrs.1,
            isScreenshot: xattrs.2 || (kind == .image && looksLikeScreenshot(url.lastPathComponent)),
            tags: v.tagNames ?? [], inProject: inProject
        )
    }

    /// One folder's contents, folders first — for browsing a folder like Finder. Read-only.
    public static func list(folder: URL, showHidden: Bool = false) -> [LibraryItem] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                         options: showHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        var out: [LibraryItem] = []
        for url in children {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true, v.isPackage != true || url.pathExtension.isEmpty {
                out.append(LibraryItem(path: url.path, kind: .other, bytes: 0, created: v.creationDate ?? .distantPast,
                                       modified: v.contentModificationDate ?? .distantPast, added: v.addedToDirectoryDate,
                                       tags: v.tagNames ?? [], isFolder: true))
                continue
            }
            let kind = FileKind.of(extension: url.pathExtension)
            if v.isDirectory == true, kind == .other {
                // An unknown package (a photo library, a VM): one opaque item.
                out.append(LibraryItem(path: url.path, kind: .other, bytes: 0, created: v.creationDate ?? .distantPast,
                                       modified: v.contentModificationDate ?? .distantPast, added: v.addedToDirectoryDate))
                continue
            }
            if let item = makeItem(url, values: v, kind: kind) { out.append(item) }
        }
        return out.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    /// iCloud "optimised storage": the file's data lives only in the cloud. Reading it downloads it.
    static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_flags & 0x4000_0000 != 0 // SF_DATALESS
    }

    /// Screenshot names macOS (and the popular tools) give, in the common languages.
    public static func looksLikeScreenshot(_ name: String) -> Bool {
        let n = name.lowercased()
        let prefixes = ["screenshot", "screen shot", "cleanshot", "capture d’écran", "capture d'écran", "bildschirmfoto",
                        "captura de pantalla", "schermata", "スクリーンショット", "截屏", "屏幕快照", "스크린샷",
                        "снимок экрана", "skärmavbild", "schermafbeelding", "zrzut ekranu"]
        return prefixes.contains { n.hasPrefix($0) }
    }

    // MARK: Extended attributes

    /// (where from, downloaded by, is a screen capture) — read straight from the file's attributes, no Spotlight needed.
    static func readExtendedAttributes(_ url: URL, isImageOrVideo: Bool) -> ([String]?, String?, Bool) {
        let path = url.path
        var whereFrom: [String]?
        if let data = xattr(path, "com.apple.metadata:kMDItemWhereFroms"),
           let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
            let clean = list.filter { !$0.isEmpty }
            whereFrom = clean.isEmpty ? nil : clean
        }
        var agent: String?
        if let data = xattr(path, "com.apple.quarantine"), let s = String(data: data, encoding: .utf8) {
            // "0083;65f1a2b3;Safari;8F2E…": flags; hex time; agent; event id.
            let parts = s.split(separator: ";", omittingEmptySubsequences: false)
            if parts.count > 2 {
                let name = parts[2].trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { agent = name }
            }
        }
        var screenCapture = false
        if isImageOrVideo, let data = xattr(path, "com.apple.metadata:kMDItemIsScreenCapture"),
           let value = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            screenCapture = (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
        }
        return (whereFrom, agent, screenCapture)
    }

    static func xattr(_ path: String, _ name: String) -> Data? {
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 1_000_000 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read > 0 ? data.prefix(read) : nil
    }
}

import Foundation

/// What a directory tree really costs on disk.
public struct DirectorySize: Sendable, Hashable {
    /// Bytes allocated on disk, each inode counted once (hard links are not double-counted).
    public var allocated: Int64 = 0
    /// Bytes that deleting this tree would actually free: files whose every hard link lives
    /// inside the tree. A pnpm `node_modules` is mostly hard links into the shared store, so
    /// its `allocated` is large but its `reclaimable` is small — and that is the honest number.
    public var reclaimable: Int64 = 0
    public var files: Int = 0
    public var directories: Int = 0
    /// Entries that could not be read (permissions, Full Disk Access).
    public var unreadable: Int = 0
    /// Newest modification time of any file inside.
    public var newestModification: Date?

    public init() {}

    public static func + (lhs: DirectorySize, rhs: DirectorySize) -> DirectorySize {
        var out = lhs
        out.allocated += rhs.allocated
        out.reclaimable += rhs.reclaimable
        out.files += rhs.files
        out.directories += rhs.directories
        out.unreadable += rhs.unreadable
        if let r = rhs.newestModification, r > (out.newestModification ?? .distantPast) {
            out.newestModification = r
        }
        return out
    }
}

/// A fast, physical (never follows symlinks), single-device directory walker built on `fts`.
public enum DiskWalker {
    private struct Inode: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    /// Measure a tree. `isCancelled` is polled so a UI can abandon long scans.
    public static func measure(_ url: URL, bigFiles: BigFileCollector? = nil, isCancelled: () -> Bool = { false }) -> DirectorySize {
        measure([url], bigFiles: bigFiles, isCancelled: isCancelled)
    }

    /// Measure several trees as ONE set: a hard link shared between them counts as reclaimable
    /// only if every link is inside the set (e.g. deleting all selected `node_modules` together).
    public static func measure(_ urls: [URL], bigFiles: BigFileCollector? = nil, isCancelled: () -> Bool = { false }) -> DirectorySize {
        var size = DirectorySize()
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return size }

        var cPaths: [UnsafeMutablePointer<CChar>?] = existing.map { strdup($0.path) }
        cPaths.append(nil)
        defer { cPaths.forEach { free($0) } }

        guard let fts = fts_open(&cPaths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            size.unreadable += 1
            return size
        }
        defer { fts_close(fts) }

        // Multiply-linked inodes: how many of their links we have seen so far.
        var linkSeen: [Inode: UInt16] = [:]
        var newest: Int = 0
        var ticks = 0

        while let entry = fts_read(fts) {
            ticks += 1
            if ticks & 0x3FF == 0, isCancelled() { break }
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let stp = entry.pointee.fts_statp else { continue }
                let st = stp.pointee
                let bytes = Int64(st.st_blocks) * 512
                size.files += 1
                let mtime = Int(st.st_mtimespec.tv_sec)
                if mtime > newest { newest = mtime }
                if let bigFiles, info == FTS_F, bytes >= bigFiles.threshold, let p = entry.pointee.fts_path {
                    bigFiles.add(String(cString: p), bytes: bytes, modified: Date(timeIntervalSince1970: TimeInterval(mtime)))
                }
                if st.st_nlink <= 1 {
                    size.allocated += bytes
                    size.reclaimable += bytes
                } else {
                    let key = Inode(dev: st.st_dev, ino: st.st_ino)
                    let seen = (linkSeen[key] ?? 0) + 1
                    linkSeen[key] = seen
                    if seen == 1 { size.allocated += bytes }
                    // Every link lives inside what we measured: deleting it all frees the bytes.
                    if seen == st.st_nlink { size.reclaimable += bytes }
                }
            case FTS_D:
                size.directories += 1
            case FTS_DNR, FTS_ERR, FTS_NS:
                size.unreadable += 1
            default:
                break
            }
        }
        if newest > 0 { size.newestModification = Date(timeIntervalSince1970: TimeInterval(newest)) }
        return size
    }

    /// Immediate children of a directory with their sizes, largest first (for the explorer).
    public static func children(of url: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [(url: URL, size: DirectorySize)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
        let urls = names.map { url.appendingPathComponent($0) }
        return await withTaskGroup(of: (URL, DirectorySize).self) { group in
            for child in urls {
                group.addTask { (child, DiskWalker.measure(child, isCancelled: isCancelled)) }
            }
            var out: [(url: URL, size: DirectorySize)] = []
            for await item in group { out.append((url: item.0, size: item.1)) }
            return out.sorted { $0.size.allocated > $1.size.allocated }
        }
    }
}

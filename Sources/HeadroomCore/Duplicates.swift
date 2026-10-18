import CryptoKit
import Foundation
import ImageIO
import Vision

/// Copies of the same file (byte for byte), or photos that look the same (bursts, edits, HEIC + JPEG pairs).
public struct DuplicateGroup: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case identical, lookAlike }

    /// Stable for the same files: the kind plus a hash of the sorted paths.
    public var id: String
    public var kind: Kind
    /// The suggested copy to keep first, then the rest (best first).
    public var items: [LibraryItem]
    /// Path of the suggested keeper (`items[0].path`).
    public var keep: String
    /// What trashing every copy but `keep` frees (sum of the others' `allocated`).
    public var wasted: Int64

    /// A group from items already in keeper-first order (see `Duplicates.ranked`).
    public init(kind: Kind, items: [LibraryItem]) {
        self.kind = kind
        self.items = items
        keep = items.first?.path ?? ""
        id = kind.rawValue + ":" + Duplicates.hexDigest(of: items.map(\.path).sorted().joined(separator: "\n"), length: 24)
        wasted = items.dropFirst().reduce(0) { $0 + $1.allocated }
    }

    /// What trashing every copy but `path` frees. A path outside the group keeps nothing.
    public func wasted(keeping path: String) -> Int64 {
        items.reduce(0) { $0 + ($1.path == path ? 0 : $1.allocated) }
    }
}

extension DuplicateGroup {
    /// Copies inside code projects are never trashed: one may be the keeper (it moves to the front),
    /// the rest leave the group. nil when fewer than two copies are left.
    public func sparingProjects() -> DuplicateGroup? {
        guard items.contains(where: \.inProject) else { return self }
        let project = items.filter(\.inProject)
        let others = items.filter { !$0.inProject }
        let kept = [project[0]] + others
        guard kept.count > 1 else { return nil }
        return DuplicateGroup(kind: kind, items: kept)
    }
}

/// Finds duplicate files and look-alike photos. Read-only: it opens files to read them and never
/// changes, moves or deletes anything (trashing the extra copies goes through `Cleaner`, like everything else).
public enum Duplicates {

    // MARK: Identical files

    /// Bytes read from each end of a file for the cheap first pass.
    static let edge = 64 * 1024
    /// Read size for the full hash: files are streamed, never loaded whole.
    static let chunk = 1 << 20

    /// Identical files by content: bucket by byte size → hash of the first and last 64 KB → full SHA-256.
    /// Only regular files of `bytes >= minBytes` (empty files never count — they free nothing); skips apps,
    /// packages and folders, files that are missing, unreadable or iCloud-only (reading those would
    /// download them), and hard links (one path per inode: deleting a link frees nothing).
    /// Groups come back biggest waste first; a cancelled run returns no groups.
    public static func identical(in items: [LibraryItem], minBytes: Int64 = 1,
                                 isCancelled: @escaping @Sendable () -> Bool = { false },
                                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> [DuplicateGroup] {
        let stop: @Sendable () -> Bool = { isCancelled() || Task.isCancelled }
        var report = Throttled(progress)
        let floor = max(minBytes, 1)

        // 1. Same size, as scanned. Only a size two files share can hold a copy.
        var seen = Set<String>()
        var bySize: [Int64: [LibraryItem]] = [:]
        for item in items where item.kind != .app && item.bytes >= floor && seen.insert(item.path).inserted {
            bySize[item.bytes, default: []].append(item)
        }
        let sized = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        guard !sized.isEmpty else { report(1); return [] }

        // 2. Still there, still a plain local file of that size — and one path per inode.
        let refs = await parallelMap(sized, width: 8, isCancelled: stop) { FileRef($0) }
        if stop() { return [] }
        var byInode: [FileRef.Inode: [FileRef]] = [:]
        for case let ref? in refs { byInode[ref.inode, default: []].append(ref) }
        var bySize2: [Int64: [FileRef]] = [:]
        for links in byInode.values {
            let best = links.count == 1 ? links[0] : bestLink(links)
            bySize2[best.size, default: []].append(best)
        }
        let candidates = bySize2.values.filter { $0.count > 1 }.flatMap { $0 }
        report(0.05)

        // 3. Cheap pass: the first and last 64 KB (the whole file when it's that small).
        let total = Double(candidates.count)
        let edges = await parallelMap(candidates, width: 4, isCancelled: stop,
                                      done: { report(0.05 + 0.25 * Double($0) / total) }) { ref in
            edgeDigest(ref, isCancelled: stop).map { (ref, $0) }
        }
        if stop() { return [] }
        var byEdges: [Data: [(ref: FileRef, whole: Bool)]] = [:]
        for case let (ref, digest)? in edges {
            byEdges[sizeKey(ref.size) + digest.data, default: []].append((ref, digest.whole))
        }

        // 4. Full SHA-256, streamed, for files that still match and weren't read whole already.
        var confirmed: [Data: [FileRef]] = [:]
        var toHash: [FileRef] = []
        for (key, refs) in byEdges where refs.count > 1 {
            if refs[0].whole { confirmed[key] = refs.map(\.ref) } else { toHash += refs.map(\.ref) }
        }
        let hashTotal = max(1, Double(toHash.reduce(Int64(0)) { $0 + $1.size }))
        var hashed: Int64 = 0
        let sizes = toHash.map(\.size)
        let full = await parallelMap(toHash, width: 4, isCancelled: stop, finished: { index in
                                         hashed += sizes[index]
                                         report(0.3 + 0.7 * Double(hashed) / hashTotal)
                                     }) { ref in
            fullDigest(ref, isCancelled: stop).map { (ref, $0) }
        }
        if stop() { return [] }
        for case let (ref, digest)? in full {
            confirmed[sizeKey(ref.size) + Data("full".utf8) + digest, default: []].append(ref)
        }

        let groups = confirmed.values.filter { $0.count > 1 }.map { refs in
            DuplicateGroup(kind: .identical, items: ranked(refs.map(\.item), kind: .identical, pixels: [:]))
        }
        report(1)
        return sorted(groups)
    }

    /// A file as it is on disk now: a regular, local (not iCloud-only) file, with its inode.
    struct FileRef: Sendable {
        struct Inode: Hashable, Sendable { var device: Int32; var number: UInt64 }
        var item: LibraryItem
        var size: Int64
        var inode: Inode

        init?(_ item: LibraryItem) {
            var st = stat()
            guard lstat(item.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & dataless == 0,
                  st.st_size > 0 else { return nil }
            self.item = item
            size = Int64(st.st_size)
            inode = Inode(device: st.st_dev, number: st.st_ino)
        }
    }

    /// SF_DATALESS: the data lives only in iCloud, and reading it would download it.
    static let dataless: UInt32 = 0x4000_0000

    /// Hard links to one file: report the path you'd keep anyway.
    static func bestLink(_ links: [FileRef]) -> FileRef {
        let best = ranked(links.map(\.item), kind: .identical, pixels: [:])[0]
        return links.first { $0.item.path == best.path } ?? links[0]
    }

    /// Opens a file for reading only if it is still the same regular local file (no symlink, no download).
    static func open(_ ref: FileRef) -> Int32? {
        let fd = Darwin.open(ref.item.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & dataless == 0,
              st.st_dev == ref.inode.device, st.st_ino == ref.inode.number, Int64(st.st_size) == ref.size else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_NOCACHE, 1) // one pass over each file: don't push everything else out of the cache
        return fd
    }

    /// Hash of the first and last 64 KB; `whole` when the file is small enough that this read all of it.
    static func edgeDigest(_ ref: FileRef, isCancelled: () -> Bool) -> (data: Data, whole: Bool)? {
        guard !isCancelled(), let fd = open(ref) else { return nil }
        defer { close(fd) }
        if ref.size <= Int64(2 * edge) {
            return stream(fd, expecting: ref.size, isCancelled: isCancelled).map { ($0, true) }
        }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: edge, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        for offset in [0, ref.size - Int64(edge)] {
            guard readFully(fd, into: buffer, at: offset) else { return nil }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        return (Data(hasher.finalize()), false)
    }

    static func fullDigest(_ ref: FileRef, isCancelled: () -> Bool) -> Data? {
        guard !isCancelled(), let fd = open(ref) else { return nil }
        defer { close(fd) }
        return stream(fd, expecting: ref.size, isCancelled: isCancelled)
    }

    /// SHA-256 of a whole file in 1 MB reads. nil if it was cancelled, unreadable or changed size.
    static func stream(_ fd: Int32, expecting size: Int64, isCancelled: () -> Bool) -> Data? {
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            if isCancelled() { return nil }
            let n = read(fd, buffer.baseAddress, chunk)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            total += Int64(n)
            if total > size { return nil }
        }
        return total == size ? Data(hasher.finalize()) : nil
    }

    static func readFully(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64) -> Bool {
        var done = 0
        while done < buffer.count {
            let n = pread(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset) + off_t(done))
            if n < 0, errno == EINTR { continue }
            if n <= 0 { return false }
            done += n
        }
        return true
    }

    static func sizeKey(_ size: Int64) -> Data { withUnsafeBytes(of: size.littleEndian) { Data($0) } }

    // MARK: Look-alike photos

    /// Images ImageIO can decode into pixels for Vision (not vector art or PostScript).
    static let decodable: Set<String> = FileKind.imageExtensions.subtracting(["svg", "ai", "eps"])
    /// Photo formats whose same-name siblings are one picture saved twice (IMG_0001.HEIC + IMG_0001.JPG).
    /// Not layered sources (PSD) and their exports: those are kept on purpose.
    static let pairable: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp", "avif", "jxl",
                                        "dng", "raw", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf"]
    /// Camera originals: a same-size JPEG/PNG beside one is a conversion of it, not a better copy.
    static let originalFormats: Set<String> = ["heic", "heif", "dng", "raw", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf"]
    static let lossless: Set<String> = ["png", "tif", "tiff"]
    static let maxImageBytes: Int64 = 60 * 1024 * 1024
    /// Every image is drawn at this size before Vision sees it: prints taken from different resolutions
    /// of one picture drift apart (a 4K photo vs its 512 px thumbnail measured 0.6), the same size keeps them comparable.
    static let printSize = 512
    /// Neighbours in time each photo is compared with, so a huge burst stays affordable.
    static let maxNeighbours = 32

    /// The default look-alike threshold, for Vision feature prints revision 2 (pinned — see below).
    ///
    /// Revision 2 prints (macOS 14+, the default on 15) are 768 unit-length floats and `computeDistance` is
    /// their Euclidean distance, 0…2; revision 1 prints were 2048 unnormalised floats with distances of ~0…40,
    /// so a threshold for one is meaningless for the other, and the two never compare. Measured here with
    /// revision 2 on images drawn at 512 px: the same photo re-saved, resized or converted HEIC↔JPEG 0.02–0.17;
    /// burst-like shifts, 5–10 % crops and 2° turns 0.13–0.24; brightness/colour edits 0.13–0.36;
    /// different shots of a similar scene 0.44–0.7; unrelated photos ≈ 1.0. 0.35 groups bursts and light edits
    /// with a margin below the closest different shots (a black-and-white conversion, 0.5+, stays apart).
    public static let defaultLookAlikeThreshold: Float = 0.35

    /// Look-alike photos: bursts, edits and HEIC/JPEG pairs. Two signals:
    ///  (a) the same name in the same folder with different photo extensions (IMG_0001.HEIC + IMG_0001.JPG) —
    ///      unless Vision says the two are clearly different pictures (two cameras both at IMG_0001);
    ///  (b) Vision feature prints closer than `threshold` between photos taken within `window` seconds of each
    ///      other (EXIF capture date, else the file's creation date) — neighbours only, so the cost stays linear.
    /// Linked pairs merge into groups. Only `.image` items up to 60 MB, at most the `limit` most recent.
    /// `excluding`: paths left out entirely — pass the copies identical groups would trash (or every path in
    /// them) so a look-alike group never repeats an exact duplicate. A cancelled run returns no groups.
    public static func lookAlikes(in items: [LibraryItem], threshold: Float = defaultLookAlikeThreshold,
                                  window: TimeInterval = 600, limit: Int = 4000, excluding: Set<String> = [],
                                  isCancelled: @escaping @Sendable () -> Bool = { false },
                                  progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> [DuplicateGroup] {
        let stop: @Sendable () -> Bool = { isCancelled() || Task.isCancelled }
        var report = Throttled(progress)
        var seen = Set<String>()
        let pool = Array(items.filter {
            $0.kind == .image && $0.bytes > 0 && $0.bytes <= maxImageBytes && decodable.contains($0.ext)
                && !excluding.contains($0.path) && seen.insert($0.path).inserted
        }
        .sorted { $0.created != $1.created ? $0.created > $1.created : $0.path < $1.path }
        .prefix(max(0, limit)))
        guard pool.count > 1 else { report(1); return [] }

        // Header only: pixel size (for picking the keeper) and when the photo was taken.
        let headers = await parallelMap(pool, width: 8, isCancelled: stop,
                                        done: { report(0.1 * Double($0) / Double(pool.count)) }) { imageHeader($0.path) }
        if stop() { return [] }
        var photos: [Photo] = []
        for (item, header) in zip(pool, headers) {
            guard let header else { continue }
            photos.append(Photo(item: item, pixels: header.pixels, time: header.taken ?? item.created))
        }

        // (a) Same name, same folder, different photo extensions.
        var byName: [String: [Int]] = [:]
        for (i, p) in photos.enumerated() where pairable.contains(p.item.ext) {
            byName[(p.item.folder + "/" + stem(p.item.name)).lowercased(), default: []].append(i)
        }
        var namePairs: [(Int, Int)] = []
        for members in byName.values where members.count > 1 {
            for a in 0..<members.count {
                for b in (a + 1)..<members.count where photos[members[a]].item.ext != photos[members[b]].item.ext {
                    namePairs.append((members[a], members[b]))
                }
            }
        }

        // (b) Neighbours in time.
        let order = photos.indices.sorted { photos[$0].time != photos[$1].time ? photos[$0].time < photos[$1].time : $0 < $1 }
        var timePairs: [(Int, Int)] = []
        for (k, i) in order.enumerated() {
            var next = k + 1
            while next < order.count, next - k <= maxNeighbours,
                  photos[order[next]].time.timeIntervalSince(photos[i].time) <= window {
                timePairs.append((i, order[next]))
                next += 1
            }
        }

        // Prints only for photos that have someone to compare with.
        var needed = Set<Int>()
        for (a, b) in namePairs + timePairs { needed.insert(a); needed.insert(b) }
        let wanted = needed.sorted()
        let paths = wanted.map { photos[$0].item.path }
        let computed = await parallelMap(paths, width: 4, isCancelled: stop,
                                         done: { report(0.1 + 0.85 * Double($0) / Double(max(1, paths.count))) }) {
            FeaturePrint(path: $0)
        }
        if stop() { return [] }
        var prints: [Int: FeaturePrint] = [:]
        for (i, print) in zip(wanted, computed) { prints[i] = print }

        var links = UnionFind(photos.count)
        for (a, b) in namePairs {
            // A name match is strong evidence; only a clearly different picture vetoes it.
            if let pa = prints[a], let pb = prints[b], let d = pa.distance(to: pb), d > 2 * threshold { continue }
            links.union(a, b)
        }
        for (a, b) in timePairs {
            if stop() { return [] }
            if let pa = prints[a], let pb = prints[b], let d = pa.distance(to: pb), d <= threshold { links.union(a, b) }
        }

        var components: [Int: [Int]] = [:]
        for i in photos.indices { components[links.find(i), default: []].append(i) }
        var pixels: [String: Int] = [:]
        for p in photos { pixels[p.item.path] = p.pixels }
        let groups = components.values.filter { $0.count > 1 }.map { members in
            DuplicateGroup(kind: .lookAlike, items: ranked(members.map { photos[$0].item }, kind: .lookAlike, pixels: pixels))
        }
        report(1)
        return sorted(groups)
    }

    struct Photo: Sendable {
        var item: LibraryItem
        var pixels: Int
        var time: Date
    }

    /// A Vision feature print (revision 2) of a photo drawn at `printSize`.
    final class FeaturePrint: @unchecked Sendable {
        let observation: VNFeaturePrintObservation

        init?(path: String) {
            guard let observation = autoreleasepool(invoking: { Duplicates.featurePrint(path) }) else { return nil }
            self.observation = observation
        }

        func distance(to other: FeaturePrint) -> Float? {
            var d: Float = 0
            do { try observation.computeDistance(&d, to: other.observation) } catch { return nil }
            return d
        }
    }

    static func featurePrint(_ path: String) -> VNFeaturePrintObservation? {
        guard isLocalFile(path),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: printSize,
            kCGImageSourceCreateThumbnailWithTransform: true, // EXIF-rotated and pixel-rotated copies compare alike
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFill // the whole frame counts, not just its centre
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        return request.results?.first
    }

    /// Pixel count and EXIF capture date, from the header alone.
    static func imageHeader(_ path: String) -> (pixels: Int, taken: Date?)? {
        guard isLocalFile(path),
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any] else { return nil }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let taken = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            .flatMap(exifDate)
        return (width * height, taken)
    }

    /// "2024:05:01 13:45:10" (camera local time) → a date.
    static func exifDate(_ s: String) -> Date? {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == " " }).prefix(6).compactMap { Int($0) }
        guard parts.count == 6, parts[0] > 1900, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let c = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5])
        return Calendar(identifier: .gregorian).date(from: c)
    }

    /// A regular file whose data is on this Mac (reading an iCloud-only file would download it).
    static func isLocalFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_flags & dataless == 0
    }

    static func pixelCount(_ path: String) -> Int { imageHeader(path)?.pixels ?? 0 }

    // MARK: Which copy to keep

    /// Which copy to keep, best first:
    ///  1. look-alikes only: full resolution (within 10 % of the largest) — a folder or a name can be fixed later,
    ///     lost pixels can't;
    ///  2. not in the Trash, a temp folder, Downloads or Desktop;
    ///  3. no copy-ish name (" copy", " copy 2", " (1)", "Copy of …"; "-1" / " 2" when the plain name is in the group too);
    ///  4. look-alikes only: more pixels; then a camera original (HEIC/RAW) over a same-size JPEG/PNG — the JPEG
    ///     beside a HEIC is a conversion of it (bigger, but a re-encode adds no detail, and the HEIC keeps its
    ///     Live Photo, depth and HDR data); then lossless over lossy; then the bigger file (in a burst the sharpest
    ///     frame compresses least);
    ///  5. the shallowest path; 6. the oldest; 7. the path, so it is always the same answer.
    /// Look-alike pixel sizes are read from the image headers.
    public static func ranked(_ items: [LibraryItem], kind: DuplicateGroup.Kind) -> [LibraryItem] {
        var pixels: [String: Int] = [:]
        if kind == .lookAlike { for item in items { pixels[item.path] = pixelCount(item.path) } }
        return ranked(items, kind: kind, pixels: pixels)
    }

    static func ranked(_ items: [LibraryItem], kind: DuplicateGroup.Kind, pixels: [String: Int]) -> [LibraryItem] {
        let stems = Set(items.map { stem($0.name).lowercased() })
        let most = items.map { pixels[$0.path] ?? 0 }.max() ?? 0
        struct Scored {
            var item: LibraryItem
            var place: Int
            var copy: Int
            var pixels: Int
            var reduced: Bool
            var format: Int
            var depth: Int
        }
        let scored = items.map { item -> Scored in
            let px = pixels[item.path] ?? 0
            let format = originalFormats.contains(item.ext) ? 0 : lossless.contains(item.ext) ? 1 : 2
            return Scored(item: item, place: placePenalty(item.path), copy: copyScore(item.name, stems: stems), pixels: px,
                          reduced: kind == .lookAlike && Double(px) < 0.9 * Double(most), format: format,
                          depth: item.path.split(separator: "/").count)
        }
        return scored.sorted { a, b in
            if a.reduced != b.reduced { return !a.reduced }
            if a.place != b.place { return a.place < b.place }
            if a.copy != b.copy { return a.copy < b.copy }
            if kind == .lookAlike {
                if a.pixels != b.pixels { return a.pixels > b.pixels }
                if a.format != b.format { return a.format < b.format }
                if a.item.bytes != b.item.bytes { return a.item.bytes > b.item.bytes }
            }
            if a.depth != b.depth { return a.depth < b.depth }
            if a.item.created != b.item.created { return a.item.created < b.item.created }
            return a.item.path < b.item.path
        }.map(\.item)
    }

    /// Where a copy shouldn't be the one you keep: the Trash (4), a temp folder (2), Downloads or Desktop (1). Added up.
    static func placePenalty(_ path: String) -> Int {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        var penalty = 0
        if parts.contains(".trash") || parts.contains(".trashes") { penalty += 4 }
        let tempRoots = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]
        if tempRoots.contains(where: path.hasPrefix) || parts.contains(where: { ["tmp", "temp", "temporary items"].contains($0) }) {
            penalty += 2
        }
        if parts.contains("downloads") || parts.contains("desktop") { penalty += 1 }
        return penalty
    }

    /// 2 for a name that says it's a copy ("photo copy", "photo (1)", "Copy of photo"); 1 for a trailing
    /// " 2" / "-1" when the plain name is in the group too ("Chapter 2" alone is a name, not a copy); else 0.
    static func copyScore(_ name: String, stems: Set<String>) -> Int {
        let s = stem(name)
        let range = NSRange(s.startIndex..., in: s)
        if strongCopy.firstMatch(in: s, range: range) != nil { return 2 }
        if let m = weakCopy.firstMatch(in: s, range: range), let base = Range(m.range(at: 1), in: s),
           stems.contains(String(s[base]).lowercased()) {
            return 1
        }
        return 0
    }

    // Finder's " copy" in a few languages, Windows' " - Copy", "Copy of …", browsers' " (1)".
    static let strongCopy = try! NSRegularExpression(
        pattern: #"(^(copy|kopie|copie|copia|kopia|cópia) (of|van|de|di|von|av) .+|[ _-](copy|kopie|copie|copia|kopia|cópia)( \d+)?|\((copy|kopie|copie|copia|kopia|cópia)( \d+)?\)| ?\(\d+\))$"#,
        options: [.caseInsensitive])
    static let weakCopy = try! NSRegularExpression(pattern: #"^(.+?)[ _-][1-9]\d?$"#)

    static func stem(_ name: String) -> String { (name as NSString).deletingPathExtension }

    // MARK: Helpers

    static func sorted(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.sorted { $0.wasted != $1.wasted ? $0.wasted > $1.wasted : $0.id < $1.id }
    }

    static func hexDigest(of string: String, length: Int) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length).description
    }

    /// `body` over every input on up to `width` tasks at once, results in input order (nil where skipped).
    /// Stops starting new work once cancelled. `done` gets the running count, `finished` the index just done.
    static func parallelMap<T: Sendable, R: Sendable>(_ inputs: [T], width: Int, isCancelled: @escaping @Sendable () -> Bool,
                                                      done: (Int) -> Void = { _ in }, finished: (Int) -> Void = { _ in },
                                                      _ body: @escaping @Sendable (T) -> R?) async -> [R?] {
        var results = [R?](repeating: nil, count: inputs.count)
        guard !inputs.isEmpty else { return results }
        await withTaskGroup(of: (Int, R?).self) { group in
            var next = 0
            var count = 0
            func start(_ group: inout TaskGroup<(Int, R?)>) {
                let i = next
                next += 1
                group.addTask { (i, isCancelled() ? nil : body(inputs[i])) }
            }
            while next < min(max(1, width), inputs.count) { start(&group) }
            while let (i, result) = await group.next() {
                results[i] = result
                count += 1
                done(count)
                finished(i)
                if next < inputs.count, !isCancelled() { start(&group) }
            }
        }
        return results
    }

    /// Progress that only speaks up when it has moved (the UI doesn't need ten thousand updates).
    struct Throttled {
        let send: @Sendable (Double) -> Void
        var last = -1.0
        init(_ send: @escaping @Sendable (Double) -> Void) { self.send = send }
        mutating func callAsFunction(_ value: Double) {
            let v = min(max(value, 0), 1)
            guard v - last >= 0.005 || (v == 1 && last < 1) else { return }
            last = v
            send(v)
        }
    }

    struct UnionFind {
        var parent: [Int]
        init(_ n: Int) { parent = Array(0..<n) }
        mutating func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var node = x
            while parent[node] != root { let up = parent[node]; parent[node] = root; node = up }
            return root
        }
        mutating func union(_ a: Int, _ b: Int) {
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
    }
}

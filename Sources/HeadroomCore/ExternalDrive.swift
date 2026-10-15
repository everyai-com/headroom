import Foundation

/// A USB drive plugged into this Mac, read straight from IOKit. Never asks diskutil: while
/// macOS checks a drive before mounting it, diskutil (and Disk Arbitration) hang with it.
public struct ExternalDrive: Sendable, Hashable, Identifiable {
    public var id: String { disk }
    public var name: String
    public var vendor: String
    /// Whole disk ("disk4") and the partition that holds the files ("disk4s1").
    public var disk: String
    public var partition: String?
    public var bytes: Int64
    public var link: Link
    public var mountPoint: URL?
    public var readOnly: Bool
    /// macOS is still checking the file system; the drive mounts when that finishes.
    public var macOSChecking: Bool

    public var mounted: Bool { mountPoint != nil }
    public var title: String { vendor.isEmpty ? name : "\(vendor) \(name)" }

    public enum Link: Int, Sendable {
        case usb1Low = 0, usb1Full, usb2, usb3, usb3Gen2, unknown = -1

        public var label: String {
            switch self {
            case .usb1Low, .usb1Full: "USB 1"
            case .usb2: "USB 2.0 · 480 Mb/s"
            case .usb3: "USB 3 · 5 Gb/s"
            case .usb3Gen2: "USB 3.2 · 10 Gb/s"
            case .unknown: "Unknown link"
            }
        }

        /// Slower than any modern drive can go: the cable or port is holding it back.
        public var isBottleneck: Bool { rawValue >= 0 && rawValue <= Link.usb2.rawValue }
        /// Rough real-world throughput, for copy estimates.
        public var bytesPerSecond: Double {
            switch self {
            case .usb1Low, .usb1Full: 1_000_000
            case .usb2: 30_000_000
            case .usb3: 350_000_000
            case .usb3Gen2: 800_000_000
            case .unknown: 30_000_000
            }
        }
    }

    /// Every USB storage device plugged in right now.
    public static func current() -> [ExternalDrive] {
        guard let tree = Shell.run("/usr/sbin/ioreg", ["-r", "-c", "IOUSBHostDevice", "-l", "-w0"], timeout: 10) else { return [] }
        let mounts = mountTable()
        let checking = (Shell.run("/bin/ps", ["ax", "-o", "command"], timeout: 5) ?? "")
            .split(separator: "\n").contains { $0.contains("fskit.") || $0.contains("fsck_") }
        return parse(ioreg: tree, mounts: mounts, checking: checking)
    }

    /// Split `ioreg -r -c IOUSBHostDevice` output into devices and keep those with a disk.
    static func parse(ioreg: String, mounts: [String: (URL, Bool)], checking: Bool) -> [ExternalDrive] {
        var blocks: [String] = []
        for line in ioreg.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+-o ") { blocks.append("") }
            if !blocks.isEmpty { blocks[blocks.count - 1] += line + "\n" }
        }
        return blocks.compactMap { block -> ExternalDrive? in
            let disks = values(#""BSD Name" = "(disk\d+(?:s\d+)?)""#, in: block)
            guard let whole = disks.first(where: { !$0.contains("s") }) ?? disks.first else { return nil }
            let partitions = disks.filter { $0.hasPrefix(whole + "s") }
            // Prefer a partition that's mounted, else the biggest data partition (the first listed).
            let partition = partitions.first { mounts[$0] != nil } ?? partitions.first
            let sizes = values(#""Size" = (\d+)"#, in: block).compactMap { Int64($0) }
            let mount = partition.flatMap { mounts[$0] } ?? mounts[whole]
            return ExternalDrive(
                name: values(#""USB Product Name" = "([^"]+)""#, in: block).first ?? "USB drive",
                vendor: values(#""USB Vendor Name" = "([^"]+)""#, in: block).first ?? "",
                disk: whole,
                partition: partition,
                bytes: sizes.max() ?? 0,
                link: Link(rawValue: Int(values(#""Device Speed" = (\d)"#, in: block).first ?? "") ?? -1) ?? .unknown,
                mountPoint: mount?.0,
                readOnly: mount?.1 ?? false,
                macOSChecking: mount == nil && checking
            )
        }
    }

    /// BSD name → (mount point, read-only), from the kernel's mount table.
    static func mountTable() -> [String: (URL, Bool)] {
        var out: [String: (URL, Bool)] = [:]
        var buf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buf, MNT_NOWAIT)
        guard count > 0, let buf else { return out }
        for i in 0..<Int(count) {
            var fs = buf[i]
            let from = withUnsafePointer(to: &fs.f_mntfromname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let on = withUnsafePointer(to: &fs.f_mntonname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            guard from.hasPrefix("/dev/disk") else { continue }
            out[String(from.dropFirst(5))] = (URL(fileURLWithPath: on), fs.f_flags & UInt32(MNT_RDONLY) != 0)
        }
        return out
    }

    static func values(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Shell script that skips macOS's check and mounts the partition read-only — nothing on
    /// the drive can change. Run as root (the app asks for the password through macOS).
    public var readOnlyMountScript: String? {
        guard let partition, partition.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let point = "/Volumes/\(name.filter { $0.isLetter || $0.isNumber })-ReadOnly"
        return """
        pkill -f 'fskit\\.(exfat|msdos)' ; pkill -x fsck_exfat ; pkill -x fsck_msdos ; sleep 2 ; \
        mkdir -p '\(point)' && \
        ( /sbin/mount -t exfat -o rdonly /dev/\(partition) '\(point)' || /sbin/mount -t msdos -o rdonly /dev/\(partition) '\(point)' || /sbin/mount -t apfs -o rdonly /dev/\(partition) '\(point)' )
        """
    }
}

/// Copies from a drive to the Mac. Only ever reads the drive. Resumable: a file already
/// copied whole (same size) is skipped, so a dropped cable costs nothing on the next run.
public final class DriveCopier: @unchecked Sendable {
    public struct Progress: Sendable {
        public var copied: Int64
        public var total: Int64
        public var files: Int
        public var skipped: Int
        public var current: String
        public var failed: [String]
        public var finished: Bool
        public var fraction: Double { total > 0 ? min(1, Double(copied) / Double(total)) : 0 }
    }

    public let source: URL
    public let destination: URL
    private let lock = NSLock()
    private var cancelled = false

    /// `destination` is the folder the source lands inside.
    public init(source: URL, into destination: URL) {
        self.source = source
        self.destination = destination
    }

    public func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Runs on the calling thread; call from a background task.
    public func run(progress: @escaping @Sendable (Progress) -> Void) {
        let fm = FileManager.default
        // (file on the drive, its path relative to the copy's root, size)
        var files: [(URL, String, Int64)] = []
        var isDir: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDir)
        let name = source.lastPathComponent
        if isDir.boolValue {
            // Path-based walk: relative paths, immune to /var vs /private/var style prefixes.
            let walker = fm.enumerator(atPath: source.path)
            while let rel = walker?.nextObject() as? String {
                if isCancelled { return }
                let leaf = (rel as NSString).lastPathComponent
                if leaf.hasPrefix("._") || leaf == ".DS_Store" { continue }
                guard walker?.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                let size = (walker?.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
                files.append((source.appendingPathComponent(rel), name + "/" + rel, size))
            }
        } else {
            files = [(source, name, Int64((try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))]
        }

        var p = Progress(copied: 0, total: files.reduce(0) { $0 + $1.2 }, files: 0, skipped: 0, current: "", failed: [], finished: false)
        // A few updates a second is plenty for a progress bar.
        var lastReport = Date.distantPast
        let report = { (p: Progress) in
            guard Date().timeIntervalSince(lastReport) > 0.25 else { return }
            lastReport = Date()
            progress(p)
        }
        for (url, rel, size) in files {
            if isCancelled { break }
            let target = destination.appendingPathComponent(rel)
            p.current = rel
            report(p)
            if let existing = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(existing) == size {
                p.copied += size; p.skipped += 1; p.files += 1
                continue
            }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyChunked(url, to: target) { n in
                    p.copied += n
                    report(p)
                }
                p.files += 1
            } catch {
                p.failed.append(rel)
            }
        }
        p.finished = true
        p.current = ""
        progress(p)
    }

    /// Copy in 4 MB chunks into a .partial file, renamed when whole, so progress is live and
    /// an interrupted copy never leaves a file that looks complete. Never deletes (that is
    /// Cleaner's job alone): a leftover .partial is truncated, an incomplete copy replaced.
    private func copyChunked(_ from: URL, to: URL, advanced: (Int64) -> Void) throws {
        let partial = to.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let input = try FileHandle(forReadingFrom: from)
        let output = try FileHandle(forWritingTo: partial)
        defer { try? input.close(); try? output.close() }
        while true {
            if isCancelled { throw CocoaError(.userCancelled) }
            guard let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            advanced(Int64(chunk.count))
        }
        try output.close()
        if FileManager.default.fileExists(atPath: to.path) {
            _ = try FileManager.default.replaceItemAt(to, withItemAt: partial)
        } else {
            try FileManager.default.moveItem(at: partial, to: to)
        }
    }
}

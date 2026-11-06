import Foundation

/// Optional tidy-up rules, off until you turn them on: old installers in Downloads go to the
/// Trash (through `Cleaner`), and screenshots get filed into a folder per month. Nothing is ever
/// deleted for good, and a filed screenshot can be put back from Activity.
public enum AutoRules {
    /// Installers in Downloads that haven't been touched in `days` — trashed through `Cleaner`.
    public static func oldInstallerPlan(_ index: LibraryIndex, home: String, days: Int, now: Date = .now) -> [Finding] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let downloads = home + "/Downloads/"
        return index.items
            .filter { $0.isInstaller && !$0.inProject && $0.path.hasPrefix(downloads) && max($0.latest, $0.added ?? .distantPast) < cutoff }
            .map { item in
                var f = Finding.picked(item.url, bytes: item.allocated, method: .trash)
                f.detail = "An installer in Downloads untouched for \(days) days."
                return f
            }
    }

    /// Where screenshots are saved: the system setting, else the Desktop.
    public static func screenshotFolder(home: URL = URL(fileURLWithPath: HeadroomPaths.home)) -> URL {
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !location.isEmpty {
            let expanded = (location as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }
        return home.appendingPathComponent("Desktop")
    }

    public struct Move: Sendable, Hashable {
        public var from: URL
        public var to: URL
    }

    /// Screenshots sitting loose in `folder` for more than a day → `folder/Screenshots/2026-10/…`.
    /// Today's stay put, so you can still drag them somewhere.
    public static func screenshotMoves(_ index: LibraryIndex, folder: URL, now: Date = .now, calendar: Calendar = .current) -> [Move] {
        let base = folder.standardizedFileURL.path
        let dayAgo = now.addingTimeInterval(-86_400)
        let target = folder.appendingPathComponent("Screenshots", isDirectory: true)
        return index.items.compactMap { item in
            guard item.isScreenshot, item.folder == base, item.arrived < dayAgo else { return nil }
            let c = calendar.dateComponents([.year, .month], from: item.arrived)
            let month = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            return Move(from: item.url, to: target.appendingPathComponent(month, isDirectory: true).appendingPathComponent(item.name))
        }
    }

    // MARK: Tidy a folder

    /// The folder a loose file goes into when a folder is tidied.
    public static func tidyFolder(for item: LibraryItem) -> String {
        if item.isScreenshot { return "Screenshots" }
        if item.isInstaller { return "Installers" }
        switch item.kind {
        case .image: return "Images"
        case .video: return "Videos"
        case .audio: return "Music"
        case .document: return item.ext == "pdf" ? "PDFs" : "Documents"
        case .archive: return "Archives"
        case .app: return "Apps"
        case .other: return "Other"
        }
    }

    /// A tidy-up of one folder: what moves where, and what stays put and why.
    public struct TidyPlan: Sendable {
        public var folder: URL
        public var moves: [Move] = []
        /// Subfolders: a tidy never moves a folder.
        public var folders = 0
        /// Downloads still arriving, files changed in the last few minutes, aliases and links.
        public var skipped: [String] = []
        public init(folder: URL) { self.folder = folder }

        /// Moves by destination folder name, biggest group first.
        public var groups: [(name: String, moves: [Move])] {
            Dictionary(grouping: moves) { $0.to.deletingLastPathComponent().lastPathComponent }
                .map { (name: $0.key, moves: $0.value) }
                .sorted { $0.moves.count != $1.moves.count ? $0.moves.count > $1.moves.count : $0.name < $1.name }
        }
    }

    /// Why a folder can't be tidied, or nil when it can. Only folders inside home; never home itself,
    /// Library, or a code project (moving its files would break it).
    public static func tidyRefusal(folder: URL, home: URL) -> String? {
        let path = folder.standardizedFileURL.path, homePath = home.standardizedFileURL.path
        guard path.hasPrefix(homePath + "/") else { return "Only folders in your home folder can be tidied" }
        let rel = String(path.dropFirst(homePath.count + 1))
        if rel.hasPrefix("Library/") && !rel.hasPrefix("Library/Mobile Documents/com~apple~CloudDocs/") || rel == "Library" {
            return "Library holds app data — it isn't tidied"
        }
        let fm = FileManager.default
        var dir = folder.standardizedFileURL
        while dir.path.hasPrefix(homePath + "/") {
            if LibraryScanner.projectMarkers.contains(where: { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
                return "This is a code project — moving its files would break it"
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Plan a tidy of `folder` (read-only — nothing moves until `perform`): every loose file into a
    /// folder for its kind (Screenshots, Images, PDFs, Documents, Installers…). Subfolders stay as
    /// they are; so do downloads still arriving, files changed in the last `settle` seconds, aliases
    /// and links.
    public static func tidyPlan(folder: URL, now: Date = .now, settle: TimeInterval = 300) -> TidyPlan {
        var plan = TidyPlan(folder: folder)
        let fm = FileManager.default
        let keys: [URLResourceKey] = LibraryScanner.keys + [.isAliasFileKey]
        guard let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return plan }
        let partial: Set<String> = ["crdownload", "download", "part", "partial", "opdownload", "tmp"]
        for url in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = url.lastPathComponent, ext = url.pathExtension.lowercased()
            if v.isDirectory == true, v.isPackage != true || ext.isEmpty { plan.folders += 1; continue }
            if v.isSymbolicLink == true || v.isAliasFile == true || ["webloc", "inetloc", "fileloc"].contains(ext) {
                plan.skipped.append("\(name) — a shortcut"); continue
            }
            if partial.contains(ext) { plan.skipped.append("\(name) — still downloading"); continue }
            if let m = v.contentModificationDate, now.timeIntervalSince(m) < settle {
                plan.skipped.append("\(name) — changed in the last few minutes"); continue
            }
            var kind = FileKind.of(extension: ext)
            if ext == "key", v.isDirectory != true, (v.fileSize ?? 0) < 16_384 { kind = .other }
            let shot = (kind == .image || kind == .video) && (LibraryScanner.looksLikeScreenshot(name)
                || LibraryScanner.readExtendedAttributes(url, isImageOrVideo: true).2)
            let item = LibraryItem(path: url.path, kind: kind, bytes: 0, created: .distantPast, modified: .distantPast, isScreenshot: shot)
            let target = tidyFolder(for: item)
            plan.moves.append(Move(from: url, to: folder.appendingPathComponent(target, isDirectory: true).appendingPathComponent(name)))
        }
        return plan
    }

    /// Carry out moves. Each source must pass the guard (inside home, not protected, not on the
    /// never-touch list) and still be a file (or a package, like a Keynote deck); nothing is ever overwritten.
    public static func perform(_ moves: [Move], guardrail: SafetyGuard) -> (moved: [Move], failed: [String]) {
        let fm = FileManager.default
        var moved: [Move] = []
        var failed: [String] = []
        for m in moves {
            let probe = Finding.picked(m.from, bytes: 0, method: .trash)
            if case .refused(let why) = guardrail.check(m.from, for: probe) { failed.append("\(m.from.lastPathComponent): \(why)"); continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: m.from.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue, (try? m.from.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true || m.from.pathExtension.isEmpty { continue }
            guard m.to.standardizedFileURL.path.hasPrefix(guardrail.home.path + "/") else {
                failed.append("\(m.from.lastPathComponent): destination outside your home folder"); continue
            }
            do {
                try fm.createDirectory(at: m.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                let dest = uniqueDestination(m.to)
                try fm.moveItem(at: m.from, to: dest)
                moved.append(Move(from: m.from, to: dest))
            } catch { failed.append("\(m.from.lastPathComponent): \(error.localizedDescription)") }
        }
        return (moved, failed)
    }

    /// "Shot.png" → "Shot 2.png" when the name is taken.
    static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for n in 2...999 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }

    /// The Activity entry for filed screenshots: Put Back moves each one home again.
    public static func entry(for moved: [Move], automatic: Bool, noun: String = "screenshots") -> ActivityLog.Entry {
        let bytes = moved.reduce(Int64(0)) { sum, m in
            sum + Int64((try? m.to.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ActivityLog.Entry(kind: .filed, title: moved.count == 1 ? moved[0].to.lastPathComponent : "\(moved.count) \(noun)",
                                 bytes: bytes, items: moved.map { .init(original: $0.from.path, inTrash: $0.to.path) }, automatic: automatic)
    }
}

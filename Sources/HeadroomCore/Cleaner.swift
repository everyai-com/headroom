import Foundation

/// The only code in Headroom that removes anything. Every path is checked against hard
/// rules before it is touched; anything that fails a check is skipped and reported.
public struct SafetyGuard: Sendable {
    public let home: URL
    /// Your never-touch list: nothing at, inside or containing these paths is removed.
    public let excluded: [String]

    public init(home: URL = URL(fileURLWithPath: HeadroomPaths.home), excluded: [String] = []) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
        self.excluded = excluded.map { URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased() }
    }

    /// Folders that must never be removed themselves, whatever a rule says.
    var protectedExact: Set<String> {
        let h = home.path
        return Set(["/", "/Applications", "/Library", "/System", "/Users", "/private", "/usr", "/opt", "/bin", "/sbin", "/var",
                    h, h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Library", h + "/Pictures", h + "/Movies",
                    h + "/Music", h + "/Library/Caches", h + "/Library/Application Support", h + "/Library/Developer",
                    h + "/.Trash", h + "/Developer", h + "/Projects", h + "/Code", h + "/code", h + "/src"])
    }

    /// Never inside these, whatever a rule says: credentials, iCloud, photo libraries.
    var protectedPrefixes: [String] {
        let h = home.path
        return [h + "/.ssh", h + "/.gnupg", h + "/Library/Keychains", h + "/Library/Mobile Documents",
                h + "/Library/Mail", h + "/Library/Messages", h + "/Pictures/Photos Library.photoslibrary"]
    }

    /// Roots Headroom may remove things under.
    var allowedRoots: [String] {
        [home.path, "/Library/Developer/CoreSimulator/Caches"]
    }

    public enum Verdict: Equatable, Sendable {
        case allowed
        case refused(String)
    }

    public func check(_ url: URL, for finding: Finding) -> Verdict {
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        if finding.safety == .keep { return .refused("marked as your data") }
        if case .none = finding.method { return .refused("not reclaimable") }
        // The startup disk is case-insensitive: ~/desktop IS ~/Desktop. Compare folded.
        let resolved = resolvedPath.lowercased()
        let home = self.home.path.lowercased()
        if protectedExact.contains(where: { $0.lowercased() == resolved }) { return .refused("protected folder") }
        if protectedPrefixes.map({ $0.lowercased() }).contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            return .refused("protected location")
        }
        // iPhone and iPad backups may be the only copy of a phone: one device's backup may go to the
        // Trash — never the Backup folder (or anything holding it), never a piece of one, never for good.
        let backups = home + "/library/application support/mobilesync/backup"
        if backups.hasPrefix(resolved + "/") || resolved == backups { return .refused("holds your iPhone and iPad backups") }
        if resolved.hasPrefix(backups + "/") {
            guard case .trash = finding.method, !resolved.dropFirst(backups.count + 1).contains("/") else {
                return .refused("an iPhone or iPad backup — it can only go to the Trash, a whole device at a time")
            }
        }
        // Inside an app bundle: deleting part of an app breaks it — uninstall the whole app instead.
        // An app already uninstalled to the Trash may be deleted for good — the whole bundle, never a piece of it.
        let trashedApp: Bool = {
            guard case .delete = finding.method else { return false }
            let trash = home + "/.trash/"
            return resolved.hasPrefix(trash) && !resolved.dropFirst(trash.count).contains("/") && resolved.hasSuffix(".app")
        }()
        if !trashedApp, let bundle = Self.enclosingAppBundle(resolvedPath) { return .refused("part of \(bundle) — uninstall the app instead") }
        // Git history: one object pack can be a whole repo's past. Build output never lives here.
        if resolved.hasSuffix("/.git") || resolved.contains("/.git/") { return .refused("git history — use git to slim a repo") }
        // A live VM's disk (Colima, Lima, OrbStack…): removing it wipes every container inside.
        // Its `backups` folder holds copies, not the live disk — those may go, to the Trash only.
        let runsOwnTool: Bool = { if case .command = finding.method { return true }; return false }()
        let trashesBackup: Bool = {
            guard case .trash = finding.method else { return false }
            return BigFileCollector.vmHomes.contains { resolved.hasPrefix(home + "/" + $0 + "/backups/") }
        }()
        if !runsOwnTool, !trashesBackup, BigFileCollector.vmHomes.contains(where: { resolved.hasPrefix(home + "/" + $0 + "/") || resolved == home + "/" + $0 }) {
            return .refused("a virtual machine's disk — clean it with its own tool (docker system prune)")
        }
        // A photo library under any name (they're often renamed or kept outside ~/Pictures).
        if resolved.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) {
            return .refused("photo library")
        }
        if excluded.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            return .refused("on your never-touch list")
        }
        if excluded.contains(where: { $0.hasPrefix(resolved + "/") }) {
            return .refused("contains something on your never-touch list")
        }
        // Below an allowed root — or, for "empty this folder", the root folder itself
        // (emptying /Library/Developer/CoreSimulator/Caches leaves the folder in place).
        let emptiesInPlace: Bool = { if case .deleteContents = finding.method { return true }; return false }()
        // Simulator runtimes live outside home, but only Xcode's own `simctl` ever removes them.
        let simctl: Bool = {
            if case .command(let exe, let args) = finding.method { return exe == "/usr/bin/xcrun" && args.first == "simctl" }
            return false
        }()
        let roots = allowedRoots.map { $0.lowercased() } + (simctl ? ["/library/developer/coresimulator"] : [])
        let inside = roots.contains { root in
            resolved.hasPrefix(root + "/") || (emptiesInPlace && resolved == root && root != home)
        }
        guard inside else { return .refused("outside the folders Headroom may clean") }
        // A path given through a symlink resolves elsewhere: refuse rather than follow.
        if resolvedPath != url.standardizedFileURL.path { return .refused("path goes through a symbolic link") }
        // Project artifacts must still look exactly like what was scanned.
        if finding.category == .projectArtifacts, ProjectScanner.byName[url.lastPathComponent] == nil {
            return .refused("not a recognised build artifact")
        }
        return .allowed
    }
}

extension SafetyGuard {
    /// "Slack.app" when the path is an app bundle or anything inside one. Only a real bundle
    /// counts (has Contents/Info.plist): cache folders are often named like `com.vendor.app`.
    static func enclosingAppBundle(_ path: String) -> String? {
        var prefix = ""
        for part in path.split(separator: "/") {
            prefix += "/" + part
            if part.lowercased().hasSuffix(".app"),
               FileManager.default.fileExists(atPath: prefix + "/Contents/Info.plist") { return String(part) }
        }
        return nil
    }
}

public struct CleanupReport: Sendable {
    public var freedBytes: Int64 = 0
    public var movedToTrashBytes: Int64 = 0
    /// Where each trashed item went, so it can be put back.
    public var trashed: [(original: URL, inTrash: URL)] = []
    public var reclaimed: [String] = []
    public var skipped: [(id: String, reason: String)] = []
    public var dryRun = false
}

/// Executes reclaim plans.
public struct Cleaner: Sendable {
    public let guardrail: SafetyGuard

    public init(guardrail: SafetyGuard = SafetyGuard()) {
        self.guardrail = guardrail
    }

    /// Reclaim the given findings. With `dryRun`, nothing is touched — the report says what would happen.
    public func reclaim(_ findings: [Finding], dryRun: Bool = false,
                        progress: @Sendable (Finding) -> Void = { _ in }) -> CleanupReport {
        var report = CleanupReport()
        report.dryRun = dryRun
        let before = VolumeStatus.current().free
        let fm = FileManager.default

        for finding in findings {
            progress(finding)
            // Every finding names what it touches; one that names nothing can't be checked.
            if finding.paths.isEmpty {
                report.skipped.append((finding.id, "nothing to check it against"))
                continue
            }
            let refusals = finding.paths.compactMap { url -> String? in
                if case .refused(let why) = guardrail.check(url, for: finding) { return "\(url.tildePath): \(why)" }
                return nil
            }
            if !refusals.isEmpty {
                report.skipped.append((finding.id, refusals.joined(separator: "; ")))
                continue
            }
            if dryRun {
                report.reclaimed.append(finding.id)
                report.freedBytes += finding.reclaimable
                continue
            }
            var failed: [String] = []
            switch finding.method {
            case .delete:
                for url in finding.paths where fm.fileExists(atPath: url.path) {
                    do { try fm.removeItem(at: url) } catch { failed.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
            case .deleteContents:
                for dir in finding.paths {
                    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                        let child = dir.appendingPathComponent(name)
                        do { try fm.removeItem(at: child) } catch { failed.append("\(name): \(error.localizedDescription)") }
                    }
                }
            case .trash:
                var trashedAny = false
                for url in finding.paths where fm.fileExists(atPath: url.path) {
                    do {
                        var landed: NSURL?
                        try fm.trashItem(at: url, resultingItemURL: &landed)
                        if let landed = landed as URL? { report.trashed.append((url, landed)) }
                        trashedAny = true
                    } catch { failed.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
                // The size is measured for the finding as a whole: count it once, not per path.
                if trashedAny { report.movedToTrashBytes += finding.size.allocated }
            case .command(let executable, let arguments):
                if Shell.run(executable, arguments, timeout: 600) == nil { failed.append("\(executable) failed") }
            case .none:
                break
            }
            if failed.isEmpty { report.reclaimed.append(finding.id) }
            // Partial success still counts what went; report what didn't.
            else { report.skipped.append((finding.id, failed.prefix(3).joined(separator: "; "))) }
        }

        if !dryRun {
            // The truth is the disk, not our estimate.
            report.freedBytes = max(0, VolumeStatus.current().free - before)
        }
        return report
    }
}

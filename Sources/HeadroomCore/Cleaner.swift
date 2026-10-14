import Foundation

/// The only code in Headroom that removes anything. Every path is checked against hard
/// rules before it is touched; anything that fails a check is skipped and reported.
public struct SafetyGuard: Sendable {
    public let home: URL

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Folders that must never be removed themselves, whatever a rule says.
    var protectedExact: Set<String> {
        let h = home.path
        return Set(["/", "/Applications", "/Library", "/System", "/Users", "/private", "/usr", "/opt", "/bin", "/sbin", "/var",
                    h, h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Library", h + "/Pictures", h + "/Movies",
                    h + "/Music", h + "/Library/Caches", h + "/Library/Application Support", h + "/Library/Developer",
                    h + "/Developer", h + "/Projects", h + "/Code", h + "/code", h + "/src"])
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
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        if finding.safety == .keep { return .refused("marked as your data") }
        if case .none = finding.method { return .refused("not reclaimable") }
        if protectedExact.contains(resolved) { return .refused("protected folder") }
        if protectedPrefixes.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            return .refused("protected location")
        }
        // Below an allowed root — or, for "empty this folder", the root folder itself
        // (emptying /Library/Developer/CoreSimulator/Caches leaves the folder in place).
        let emptiesInPlace: Bool = { if case .deleteContents = finding.method { return true }; return false }()
        let inside = allowedRoots.contains { root in
            resolved.hasPrefix(root + "/") || (emptiesInPlace && resolved == root && root != home.path)
        }
        guard inside else { return .refused("outside the folders Headroom may clean") }
        // A path given through a symlink resolves elsewhere: refuse rather than follow.
        if resolved != url.standardizedFileURL.path { return .refused("path goes through a symbolic link") }
        // Project artifacts must still look exactly like what was scanned.
        if finding.category == .projectArtifacts, ProjectScanner.byName[url.lastPathComponent] == nil {
            return .refused("not a recognised build artifact")
        }
        return .allowed
    }
}

public struct CleanupReport: Sendable {
    public var freedBytes: Int64 = 0
    public var movedToTrashBytes: Int64 = 0
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
                for url in finding.paths where fm.fileExists(atPath: url.path) {
                    do {
                        try fm.trashItem(at: url, resultingItemURL: nil)
                        report.movedToTrashBytes += finding.size.allocated
                    } catch { failed.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
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

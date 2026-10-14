import Foundation

/// Finds regenerable build output inside your code projects — the main reason an
/// agentic-coding Mac fills up: every repo an agent touches grows its own `node_modules`,
/// `.next`, `target`, virtualenv…
public enum ProjectScanner {
    struct Artifact {
        let name: String
        /// A file that must sit next to the folder for it to count (so a random folder named
        /// `target` is never mistaken for Rust output).
        let markers: [String]
        let title: String
        let rebuild: (URL) -> String
        let symbol: String
        /// Some artifacts are worth a confirm even when stale (virtualenvs can hold manual installs).
        let alwaysReview: Bool
    }

    static func nodeInstall(_ project: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: project.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm install" }
        if fm.fileExists(atPath: project.appendingPathComponent("bun.lockb").path)
            || fm.fileExists(atPath: project.appendingPathComponent("bun.lock").path) { return "bun install" }
        if fm.fileExists(atPath: project.appendingPathComponent("yarn.lock").path) { return "yarn install" }
        return "npm install"
    }

    static let artifacts: [Artifact] = [
        Artifact(name: "node_modules", markers: ["package.json"], title: "node_modules", rebuild: nodeInstall,
                 symbol: "shippingbox.fill", alwaysReview: false),
        Artifact(name: ".next", markers: ["package.json"], title: "Next.js build cache", rebuild: { _ in "next build" },
                 symbol: "n.square.fill", alwaysReview: false),
        Artifact(name: ".nuxt", markers: ["package.json"], title: "Nuxt build cache", rebuild: { _ in "nuxt build" },
                 symbol: "square.stack.fill", alwaysReview: false),
        Artifact(name: ".svelte-kit", markers: ["package.json"], title: "SvelteKit build cache", rebuild: { _ in "vite build" },
                 symbol: "square.stack.fill", alwaysReview: false),
        Artifact(name: ".turbo", markers: ["package.json"], title: "Turborepo cache", rebuild: { _ in "turbo run build" },
                 symbol: "bolt.horizontal.fill", alwaysReview: false),
        Artifact(name: ".parcel-cache", markers: ["package.json"], title: "Parcel cache", rebuild: { _ in "parcel build" },
                 symbol: "square.stack.fill", alwaysReview: false),
        Artifact(name: ".open-next", markers: ["package.json"], title: "OpenNext build output", rebuild: { _ in "opennextjs-cloudflare build" },
                 symbol: "cloud.fill", alwaysReview: false),
        Artifact(name: ".expo", markers: ["package.json"], title: "Expo cache", rebuild: { _ in "expo start" },
                 symbol: "iphone", alwaysReview: false),
        Artifact(name: "target", markers: ["Cargo.toml"], title: "Rust build output", rebuild: { _ in "cargo build" },
                 symbol: "gearshape.2.fill", alwaysReview: false),
        Artifact(name: ".build", markers: ["Package.swift"], title: "Swift build output", rebuild: { _ in "swift build" },
                 symbol: "swift", alwaysReview: false),
        Artifact(name: ".gradle", markers: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                 title: "Gradle project cache", rebuild: { _ in "./gradlew build" }, symbol: "gearshape.2.fill", alwaysReview: false),
        Artifact(name: "Pods", markers: ["Podfile"], title: "CocoaPods", rebuild: { _ in "pod install" },
                 symbol: "shippingbox", alwaysReview: true),
        Artifact(name: ".venv", markers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"], title: "Python virtualenv",
                 rebuild: { _ in "uv sync / pip install -r requirements.txt" }, symbol: "chevron.left.forwardslash.chevron.right", alwaysReview: true),
        Artifact(name: "venv", markers: ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"], title: "Python virtualenv",
                 rebuild: { _ in "pip install -r requirements.txt" }, symbol: "chevron.left.forwardslash.chevron.right", alwaysReview: true),
    ]

    static let byName: [String: Artifact] = Dictionary(uniqueKeysWithValues: artifacts.map { ($0.name, $0) })

    /// Folders worth searching. Anything else (Library, Pictures…) is never walked for projects.
    public static func defaultRoots(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        let candidates = ["Desktop", "Documents", "Developer", "Projects", "projects", "Code", "code", "src", "dev",
                          "GitHub", "repos", "work", "Sites"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return uniqueFolders(candidates)
    }

    /// The disk is case-insensitive: ~/Projects and ~/projects are ONE folder. Keep one URL
    /// per real folder (by file identity), or every project under it is counted twice.
    public static func uniqueFolders(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let key = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath?.lowercased()
                ?? url.standardizedFileURL.path.lowercased()
            return seen.insert(key).inserted
        }
    }

    /// Never descend into these while looking for projects.
    static let skip: Set<String> = [".git", "Library", ".Trash", "Applications", "Pictures", "Movies", "Music", ".cache"]

    /// Find every artifact folder under `roots`, measured and judged.
    /// `staleDays`: projects untouched this long have their artifacts marked safe; recent ones need review.
    public static func scan(roots: [URL], staleDays: Int = 7, maxDepth: Int = 7,
                            isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [Finding] {
        var hits: [(artifact: Artifact, url: URL, project: URL)] = []
        for root in roots { walk(root, depth: 0, maxDepth: maxDepth, hits: &hits, isCancelled: isCancelled) }
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })

        // Measure in parallel, a few at a time (node_modules trees are millions of files).
        let measured: [(Int, DirectorySize)] = await withTaskGroup(of: (Int, DirectorySize).self) { group in
            var next = 0
            let width = min(4, hits.count)
            for _ in 0..<width {
                let i = next; next += 1
                group.addTask { (i, DiskWalker.measure(hits[i].url, isCancelled: isCancelled)) }
            }
            var out: [(Int, DirectorySize)] = []
            for await r in group {
                out.append(r)
                if next < hits.count {
                    let i = next; next += 1
                    group.addTask { (i, DiskWalker.measure(hits[i].url, isCancelled: isCancelled)) }
                }
            }
            return out
        }

        let now = Date()
        return measured.compactMap { index, size -> Finding? in
            let hit = hits[index]
            guard size.allocated > 1_000_000 else { return nil } // ignore trivia under 1 MB
            let activity = lastActivity(of: hit.project)
            let idleDays = activity.map { Int(now.timeIntervalSince($0) / 86_400) } ?? 9_999
            let stale = idleDays >= staleDays
            let safety: Safety = (stale && !hit.artifact.alwaysReview) ? .safe : .review
            let rebuild = hit.artifact.rebuild(hit.project)
            let when = activity.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now) } ?? "a long time ago"
            let detail: String
            if safety == .safe {
                detail = "Project untouched since \(when). Run `\(rebuild)` to get it back exactly as it was."
            } else if hit.artifact.alwaysReview {
                detail = "Recreated with `\(rebuild)`, but may contain things installed by hand. Check before removing."
            } else {
                detail = "You worked on this project \(when) — removing it means running `\(rebuild)` before you continue."
            }
            return Finding(
                id: "artifact:" + hit.url.path, title: hit.artifact.title, subtitle: hit.url.tildePath, detail: detail,
                category: .projectArtifacts, safety: safety, paths: [hit.url], size: size, lastUsed: activity,
                method: .delete, symbol: hit.artifact.symbol, rebuild: rebuild,
                project: projectLabel(hit.project, roots: rootPaths)
            )
        }.sorted { $0.size.reclaimable > $1.size.reclaimable }
    }

    /// "realestate aios/platform" rather than a bare "platform": nested projects keep their parent.
    static func projectLabel(_ project: URL, roots: Set<String>) -> String {
        let parent = project.deletingLastPathComponent()
        if roots.contains(parent.standardizedFileURL.path) { return project.lastPathComponent }
        return parent.lastPathComponent + "/" + project.lastPathComponent
    }

    static func walk(_ dir: URL, depth: Int, maxDepth: Int, hits: inout [(artifact: Artifact, url: URL, project: URL)],
                     isCancelled: () -> Bool) {
        guard depth <= maxDepth, !isCancelled() else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let nameSet = Set(names)
        for name in names {
            let child = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // Symlinked folders are skipped: deleting through a link could reach outside the project.
            if (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
            if let artifact = byName[name] {
                if artifact.markers.contains(where: { nameSet.contains($0) }) {
                    hits.append((artifact, child, dir))
                }
                continue // never descend into an artifact (nested node_modules are part of it)
            }
            if skip.contains(name) || name.hasSuffix(".app") || name.hasSuffix(".photoslibrary") { continue }
            if name.hasPrefix("."), name != ".claude" { continue }
            walk(child, depth: depth + 1, maxDepth: maxDepth, hits: &hits, isCancelled: isCancelled)
        }
    }

    /// When you last worked on a project: the newest of its top-level files and its git activity.
    public static func lastActivity(of project: URL) -> Date? {
        let fm = FileManager.default
        var newest: Date?
        let candidates = ((try? fm.contentsOfDirectory(atPath: project.path)) ?? [])
            .filter { !byName.keys.contains($0) && $0 != ".git" }
            .map { project.appendingPathComponent($0) }
            + [".git/index", ".git/HEAD", ".git/logs/HEAD"].map { project.appendingPathComponent($0) }
        for url in candidates {
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               d > (newest ?? .distantPast) {
                newest = d
            }
        }
        return newest
    }
}

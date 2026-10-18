import Foundation

/// Git worktrees: the extra checkouts coding agents make for every task (Claude Code's
/// `.claude/worktrees`, Codex, Conductor, Cursor, T3 Code, or `git worktree add` by hand). Each one is a full
/// copy of a project, usually with its own `node_modules`, and they pile up fast.
///
/// Read-only until you remove one, and then only through git: `git worktree remove <path>` (never `--force`),
/// which refuses a worktree with uncommitted changes. Committed work stays on the branch in the main
/// repository. A worktree whose repository is gone can't be removed by git; it goes to the Trash.
public struct Worktree: Sendable, Hashable, Identifiable {
    public var path: String
    /// The main repository it belongs to; nil when that repository no longer exists (an orphan).
    public var repo: String?
    public var branch: String?
    /// Which tool made it, from where it lives ("Claude Code", "Codex"…).
    public var tool: String
    /// Files changed, added or untracked; nil when git can't say.
    public var changes: Int?
    public var size: DirectorySize
    public var lastActivity: Date?
    /// Uncommitted changes in worktrees nested inside this one (removing it would take them too).
    public var nestedChanges = 0
    /// Inside another worktree: its size is already part of that one's.
    public var isNested = false

    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
    public var repoName: String { repo.map { ($0 as NSString).lastPathComponent } ?? "Repository gone" }

    public init(path: String, repo: String?, branch: String?, tool: String, changes: Int?, size: DirectorySize = DirectorySize(),
                lastActivity: Date? = nil) {
        self.path = path
        self.repo = repo
        self.branch = branch
        self.tool = tool
        self.changes = changes
        self.size = size
        self.lastActivity = lastActivity
    }

    /// As a finding the rest of the app understands (Reclaim, the Coding screens, Activity).
    /// Never `.safe`: removing a checkout is always your call. Uncommitted changes make it `.keep`.
    public func finding(git: String?) -> Finding {
        let when = lastActivity.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? "a long time ago"
        let on = branch.map { "Branch \($0)" } ?? "Detached"
        var safety = Safety.review
        var method = CleanupMethod.none
        let detail: String
        if repo == nil {
            method = .trash
            detail = "\(tool) worktree whose repository is gone, so git can't use it any more. Goes to the Trash. Last touched \(when)."
        } else if nestedChanges > 0 {
            safety = .keep
            detail = "\(on) · holds another worktree with \(nestedChanges) uncommitted \(nestedChanges == 1 ? "change" : "changes") — removing this would take them too."
        } else if let changes, changes > 0 {
            safety = .keep
            detail = "\(on) · \(changes) uncommitted \(changes == 1 ? "change" : "changes") — commit or discard \(changes == 1 ? "it" : "them") in the worktree first. Last touched \(when)."
        } else if let git, let repo, changes == 0 {
            method = .command(executable: git, arguments: ["-C", repo, "worktree", "remove", path])
            detail = "\(on) · nothing uncommitted · last touched \(when). Removed with `git worktree remove`: commits stay on the branch in \(repoName); ignored files here (node_modules, .env) go with it."
        } else {
            safety = .keep
            detail = "\(on) · git isn't available to check it for uncommitted changes, so it's left alone."
        }
        return Finding(id: "worktree:" + path, title: name, subtitle: (path as NSString).abbreviatingWithTildeInPath, detail: detail,
                       category: .worktrees, safety: safety, paths: [URL(fileURLWithPath: path)], size: size, lastUsed: lastActivity,
                       method: method, symbol: "arrow.triangle.branch", project: repoName + " · " + tool)
    }
}

public enum Worktrees {
    /// Where agents keep worktrees outside your projects; walked as well as the project folders.
    public static func agentRoots(home: String = HeadroomPaths.home) -> [URL] {
        [".codex/worktrees", ".cursor/worktrees", "conductor/workspaces", ".t3/worktrees", ".claude/worktrees", ".worktrees"]
            .map { URL(fileURLWithPath: home + "/" + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Which tool made a worktree, judged by where it lives.
    public static func tool(for path: String) -> String {
        let p = path.lowercased()
        if p.contains("/.claude/worktrees/") { return "Claude Code" }
        if p.contains("/.codex/") { return "Codex" }
        if p.contains("/conductor/") { return "Conductor" }
        if p.contains("/.cursor/") { return "Cursor" }
        if p.contains("/.t3/") || p.contains("/t3code/") { return "T3 Code" }
        if p.contains("/.ao/") { return "ao" }
        return "Git"
    }

    /// One spelling per folder (`/private/var/…` and `/var/…` are the same place), so a worktree found by
    /// walking and the same one listed by its repository match.
    static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    /// What a `.git` file says about the folder: a worktree of `repo` (nil repo = the repository is gone),
    /// or nil when it isn't a worktree (a submodule, or no `.git` file at all).
    static func classify(_ folder: String) -> (isWorktree: Bool, repo: String?) {
        let dotGit = folder + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir), !isDir.boolValue,
              let gitDir = Git.gitDir(repo: folder), gitDir.contains("/worktrees/") else { return (false, nil) }
        // ".../main/.git/worktrees/<name>" → ".../main"
        guard let range = gitDir.range(of: "/.git/worktrees/") else { return (true, nil) }
        let repo = String(gitDir[..<range.lowerBound])
        let alive = FileManager.default.fileExists(atPath: gitDir) && FileManager.default.fileExists(atPath: repo + "/.git")
        return (true, alive ? canonical(repo) : nil)
    }

    /// The worktrees a main repository knows about (its `.git/worktrees/*/gitdir`), that still exist.
    static func registered(in repo: String) -> [String] {
        let admin = repo + "/.git/worktrees"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: admin)) ?? []
        return names.compactMap { name in
            guard let text = try? String(contentsOfFile: admin + "/" + name + "/gitdir", encoding: .utf8) else { return nil }
            var p = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.hasSuffix("/.git") { p = String(p.dropLast(5)) }
            return FileManager.default.fileExists(atPath: p) ? canonical(p) : nil
        }
    }

    /// Find worktree folders under `roots`: through the repositories found there (wherever their worktrees
    /// live) and any `.git` file met on the way (orphans included). Paths only — nothing is measured yet.
    public static func find(roots: [URL], maxDepth: Int = 7, isCancelled: @Sendable () -> Bool = { false }) -> [(path: String, repo: String?)] {
        var found: [String: String?] = [:]
        let fm = FileManager.default
        let skip = ProjectScanner.skip.union(ProjectScanner.byName.keys).union(LibraryScanner.skippedFolders)
        func walk(_ dir: String, depth: Int) {
            guard depth <= maxDepth, !isCancelled() else { return }
            let c = classify(dir)
            if c.isWorktree {
                let key = canonical(dir)
                if found[key] == nil { found[key] = .some(c.repo) }
                return // a worktree's insides are its own checkout
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir + "/.git", isDirectory: &isDir), isDir.boolValue {
                for wt in registered(in: dir) where found[wt] == nil { found[wt] = .some(canonical(dir)) }
            }
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for name in names where !skip.contains(name) {
                if name.hasPrefix("."), name != ".claude", name != ".worktrees" { continue }
                if name == ".claude" {
                    // Inside .claude only its worktrees folder holds checkouts.
                    let wts = dir + "/.claude/worktrees"
                    if fm.fileExists(atPath: wts) { walk(wts, depth: depth + 1) }
                    continue
                }
                let child = dir + "/" + name
                var d: ObjCBool = false
                guard fm.fileExists(atPath: child, isDirectory: &d), d.boolValue,
                      (try? URL(fileURLWithPath: child).resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey])).map({ $0.isSymbolicLink != true && $0.isPackage != true }) ?? false
                else { continue }
                walk(child, depth: depth + 1)
            }
        }
        for root in roots { walk(root.standardizedFileURL.path, depth: 0) }
        return found.map { (path: $0.key, repo: $0.value) }.sorted { $0.path < $1.path }
    }

    /// Find, then measure and check each worktree (a few at a time): size, branch, uncommitted changes.
    public static func scan(roots: [URL], isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [Worktree] {
        let hits = find(roots: roots, isCancelled: isCancelled)
        let git = Git.executable
        return await withTaskGroup(of: Worktree.self) { group in
            var next = 0
            func add() {
                let hit = hits[next]; next += 1
                group.addTask {
                    var changes: Int?
                    if let git, hit.repo != nil,
                       let out = Shell.run(git, ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", hit.path, "status", "--porcelain"], timeout: 20) {
                        changes = Git.changeCount(porcelain: out)
                    }
                    return Worktree(path: hit.path, repo: hit.repo, branch: Git.branch(repo: hit.path), tool: tool(for: hit.path),
                                    changes: changes, size: DiskWalker.measure(URL(fileURLWithPath: hit.path), isCancelled: isCancelled),
                                    lastActivity: ProjectScanner.lastActivity(of: URL(fileURLWithPath: hit.path)))
                }
            }
            for _ in 0..<min(4, hits.count) { add() }
            var out: [Worktree] = []
            for await w in group {
                out.append(w)
                if next < hits.count { add() }
            }
            return nest(out).sorted { $0.size.allocated > $1.size.allocated }
        }
    }

    /// Mark worktrees inside other worktrees, and carry their uncommitted changes up to every one holding them.
    static func nest(_ list: [Worktree]) -> [Worktree] {
        list.map { w in
            var w = w
            let inside = list.filter { $0.path.hasPrefix(w.path + "/") }
            w.nestedChanges = inside.reduce(0) { $0 + ($1.changes ?? 1) } // unknown counts as changed
            w.isNested = list.contains { w.path.hasPrefix($0.path + "/") }
            return w
        }
    }

    /// The space they take, counting nested ones once.
    public static func total(_ list: [Worktree]) -> Int64 {
        list.filter { !$0.isNested }.reduce(0) { $0 + $1.size.allocated }
    }
}

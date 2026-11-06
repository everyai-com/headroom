import Foundation

/// A folder's git state for the path bar: the branch and how many files have uncommitted changes.
public struct GitStatus: Sendable, Hashable {
    /// The repository's top folder (the one holding `.git`).
    public var root: String
    /// "main", or the short commit when HEAD is detached.
    public var branch: String
    /// Files changed, added or untracked; nil when git isn't installed or couldn't say.
    public var changes: Int?
    public init(root: String, branch: String, changes: Int? = nil) {
        self.root = root
        self.branch = branch
        self.changes = changes
    }
}

/// Reads git state, never changes it: the branch comes from `.git/HEAD`, changes from
/// `git status --porcelain` with optional locks off (so not even the index is refreshed).
/// Never fetches, pulls or writes. Without the developer tools it says nothing.
public enum Git {
    /// The repository a folder is in: the folder itself or the nearest folder above it with a `.git`
    /// (a folder, or a file for worktrees and submodules). Home and `/` themselves never count —
    /// a dotfiles repo in home would badge every folder.
    public static func repoRoot(containing path: String, home: String = HeadroomPaths.home) -> String? {
        let fm = FileManager.default
        var p = path
        while p != "/", p != home, !p.isEmpty {
            if fm.fileExists(atPath: p + "/.git") { return p }
            let up = (p as NSString).deletingLastPathComponent
            if up == p { break }
            p = up
        }
        return nil
    }

    /// The git directory of a repo: `.git` itself, or where a `.git` file ("gitdir: …") points.
    static func gitDir(repo: String) -> String? {
        let dotGit = repo + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return target.hasPrefix("/") ? target : (repo as NSString).appendingPathComponent(target)
    }

    /// "ref: refs/heads/feature/x" → "feature/x"; a detached HEAD's commit → its first 7 characters.
    public static func branch(fromHead head: String) -> String? {
        let s = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("ref:") {
            let ref = s.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let heads = "refs/heads/"
            let name = ref.hasPrefix(heads) ? String(ref.dropFirst(heads.count)) : ref
            return name.isEmpty ? nil : name
        }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard s.count >= 7, s.unicodeScalars.allSatisfy(hex.contains) else { return nil }
        return String(s.prefix(7))
    }

    /// The branch, read from HEAD (no git needed).
    public static func branch(repo: String) -> String? {
        guard let dir = gitDir(repo: repo), let head = try? String(contentsOfFile: dir + "/HEAD", encoding: .utf8) else { return nil }
        return branch(fromHead: head)
    }

    /// How many files `git status --porcelain` lists.
    public static func changeCount(porcelain: String) -> Int {
        porcelain.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// `/usr/bin/git`, only when the developer tools behind it are installed — without them the
    /// stub asks to install them, which a path bar must never do.
    public static let executable: String? = {
        let stub = "/usr/bin/git"
        // The App Store edition runs no other tools: the branch (read from .git/HEAD) shows, the change count doesn't.
        guard !HeadroomPaths.isSandboxed, FileManager.default.isExecutableFile(atPath: stub),
              let dir = Shell.run("/usr/bin/xcode-select", ["-p"], timeout: 5)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dir.isEmpty, FileManager.default.isExecutableFile(atPath: dir + "/usr/bin/git") else { return nil }
        return stub
    }()

    /// The branch and change count for the repo a folder is in (nil when it isn't in one).
    public static func status(of path: String, home: String = HeadroomPaths.home) -> GitStatus? {
        guard let root = repoRoot(containing: path, home: home), let branch = branch(repo: root) else { return nil }
        var status = GitStatus(root: root, branch: branch)
        if let git = executable,
           let out = Shell.run(git, ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", root,
                                     "status", "--porcelain", "--ignore-submodules=dirty"], timeout: 8) {
            status.changes = changeCount(porcelain: out)
        }
        return status
    }
}

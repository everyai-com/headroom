import Foundation
import XCTest
@testable import HeadroomCore

/// Worktrees with real git in a throwaway home: found wherever they live, judged by their uncommitted
/// changes, removed only through `git worktree remove` — and the branch's commits survive.
final class WorktreeTests: XCTestCase {
    var home: URL!
    var repo: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        guard Git.executable != nil else { throw XCTSkip("git isn't installed") }
        home = fm.temporaryDirectory.appendingPathComponent("headroom-wt-\(UUID().uuidString)").resolvingSymlinksInPath()
        repo = home.appendingPathComponent("Desktop/app")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "first")
    }

    override func tearDownWithError() throws { if let home { try? fm.removeItem(at: home) } }

    @discardableResult
    func git(_ dir: URL, _ args: String...) throws -> String {
        guard let out = Shell.run(Git.executable!, ["-C", dir.path] + args, timeout: 30) else {
            throw NSError(domain: "git", code: 1, userInfo: [NSLocalizedDescriptionKey: args.joined(separator: " ")])
        }
        return out
    }

    func worktree(_ rel: String, branch: String) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try git(repo, "worktree", "add", "-q", "-b", branch, url.path)
        return url
    }

    func testFindsAgentWorktreesWhereverTheyLive() async throws {
        let claude = try worktree("Desktop/app/.claude/worktrees/quick-fix", branch: "quick-fix")
        let codex = try worktree(".codex/worktrees/abc/app", branch: "codex-task")
        let found = await Worktrees.scan(roots: [home.appendingPathComponent("Desktop"), home.appendingPathComponent(".codex/worktrees")])
        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.path, $0) })
        XCTAssertEqual(Set(byPath.keys), [claude.path, codex.path], "the main checkout itself is never a worktree")
        XCTAssertEqual(byPath[claude.path]?.tool, "Claude Code")
        XCTAssertEqual(byPath[codex.path]?.tool, "Codex")
        XCTAssertEqual(byPath[claude.path]?.branch, "quick-fix")
        XCTAssertEqual(byPath[claude.path]?.repo, repo.path)
        XCTAssertEqual(byPath[claude.path]?.changes, 0)
    }

    func testCleanRemovesThroughGitAndKeepsTheBranch() async throws {
        let wt = try worktree("Desktop/app/.claude/worktrees/done", branch: "done")
        try "work".write(to: wt.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try git(wt, "add", ".")
        try git(wt, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "feature")
        let scanned = await Worktrees.scan(roots: [home.appendingPathComponent("Desktop")])
        let w = try XCTUnwrap(scanned.first)
        let f = w.finding(git: Git.executable)
        XCTAssertEqual(f.safety, .review, "never one-click")
        guard case .command(_, let args) = f.method else { return XCTFail("removed through git") }
        XCTAssertFalse(args.contains("--force"))
        let report = Cleaner(guardrail: SafetyGuard(home: home)).reclaim([f])
        XCTAssertEqual(report.reclaimed, [f.id])
        XCTAssertFalse(fm.fileExists(atPath: wt.path))
        XCTAssertTrue(try git(repo, "branch", "--list", "done").contains("done"), "the branch and its commit stay")
        XCTAssertTrue(try git(repo, "log", "--oneline", "done").contains("feature"))
    }

    func testUncommittedChangesKeepIt() async throws {
        let wt = try worktree("Desktop/app/.claude/worktrees/wip", branch: "wip")
        try "draft".write(to: wt.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        let scanned = await Worktrees.scan(roots: [home.appendingPathComponent("Desktop")])
        let w = try XCTUnwrap(scanned.first)
        XCTAssertEqual(w.changes, 1)
        let f = w.finding(git: Git.executable)
        XCTAssertEqual(f.safety, .keep)
        XCTAssertEqual(f.method, .none)
        // Even if something tried, git itself refuses a dirty worktree without --force.
        let forced = Finding(id: "x", title: "x", subtitle: "", detail: "", category: .worktrees, safety: .review, paths: [wt],
                             method: .command(executable: Git.executable!, arguments: ["-C", repo.path, "worktree", "remove", wt.path]),
                             symbol: "x")
        _ = Cleaner(guardrail: SafetyGuard(home: home)).reclaim([forced])
        XCTAssertTrue(fm.fileExists(atPath: wt.appendingPathComponent("draft.txt").path))
    }

    func testANestedDirtyWorktreeKeepsItsParent() async throws {
        let outer = try worktree("Desktop/app/.claude/worktrees/outer", branch: "outer")
        try "outer/inner\n".write(to: outer.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try git(outer, "add", ".gitignore")
        try git(outer, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "ignore inner")
        let inner = try worktree("Desktop/app/.claude/worktrees/outer/inner", branch: "inner")
        try "x".write(to: inner.appendingPathComponent("wip.txt"), atomically: true, encoding: .utf8)
        let found = await Worktrees.scan(roots: [home.appendingPathComponent("Desktop")])
        let o = try XCTUnwrap(found.first { $0.path == outer.path })
        XCTAssertGreaterThan(o.nestedChanges, 0)
        XCTAssertEqual(o.finding(git: Git.executable).safety, .keep)
        XCTAssertTrue(try XCTUnwrap(found.first { $0.path == inner.path }).isNested)
        XCTAssertEqual(Worktrees.total(found), o.size.allocated, "nested ones count once")
    }

    func testAnOrphanGoesToTheTrash() async throws {
        let wt = try worktree("Desktop/old-task", branch: "old")
        try fm.removeItem(at: repo)
        let scanned = await Worktrees.scan(roots: [home.appendingPathComponent("Desktop")])
        let w = try XCTUnwrap(scanned.first)
        XCTAssertNil(w.repo)
        XCTAssertEqual(w.path, wt.path)
        XCTAssertEqual(w.finding(git: Git.executable).method, .trash)
    }
}

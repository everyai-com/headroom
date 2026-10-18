import Foundation
import XCTest
@testable import HeadroomCore

private typealias LibraryItem = HeadroomCore.LibraryItem

/// Folder sizes, grouping, the git badge and the terminal/editor picks — all in a throwaway folder.
final class FolderToolsTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("headroom-folders-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    @discardableResult
    func write(_ rel: String, bytes: Int = 10_000, text: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) } else { try Data(repeating: 1, count: bytes).write(to: url) }
        return url
    }

    // MARK: Sizes

    func testFolderSizeCountsItemsInsideAndWeighsEverythingBelow() throws {
        try write("Trip/a.jpg", bytes: 200_000)
        try write("Trip/b.jpg", bytes: 200_000)
        try write("Trip/Day 2/c.jpg", bytes: 400_000)
        try write("Trip/.DS_Store", bytes: 50_000)
        let size = FolderSizes.measure(root.appendingPathComponent("Trip").path)
        XCTAssertEqual(size.items, 3, "two photos and a folder — hidden files aren't items")
        XCTAssertGreaterThanOrEqual(size.bytes, 800_000)
        XCTAssertLessThan(size.bytes, 1_000_000, "the hidden file isn't counted either")
        XCTAssertFalse(size.partial)
        XCTAssertEqual(FolderSizes.measure(root.appendingPathComponent("nope").path).items, 0)
        XCTAssertEqual(FolderSize(items: 0, bytes: 0).label, "Empty")
        XCTAssertTrue(FolderSize(items: 1, bytes: 2_000_000).label.hasPrefix("1 item · "))
    }

    func testFolderSizeSkipsDependenciesInProjectsAndStopsAtItsLimit() throws {
        try write("app/package.json", text: "{}")
        try write("app/src/index.ts", bytes: 1_000)
        try write("app/node_modules/dep/index.js", bytes: 2_000_000)
        let size = FolderSizes.measure(root.appendingPathComponent("app").path)
        XCTAssertEqual(size.items, 3)
        XCTAssertLessThan(size.bytes, 1_000_000, "node_modules is regenerable, like the workspace summary says")
        for i in 0..<20 { try write("many/f\(i).txt", bytes: 10) }
        XCTAssertTrue(FolderSizes.measure(root.appendingPathComponent("many").path, limit: 5).partial)
    }

    func testSummaryWithNothingToKeepListsNoFiles() throws {
        try write("docs/a.pdf")
        let s = Workspaces.summarize(folder: root.appendingPathComponent("docs").path, keep: 0)
        XCTAssertEqual(s.files, 1)
        XCTAssertTrue(s.recent.isEmpty)
    }

    // MARK: Grouping

    fileprivate func item(_ name: String, kind: FileKind, added: Date, folder: Bool = false) -> LibraryItem {
        LibraryItem(path: root.appendingPathComponent(name).path, kind: kind, bytes: 1, created: added, modified: added,
                    added: added, isFolder: folder)
    }

    func testGroupingByKindPutsFoldersFirstAndKeepsOrder() {
        let now = Date()
        let items = [item("b.pdf", kind: .document, added: now), item("x", kind: .other, added: now, folder: true),
                     item("a.jpg", kind: .image, added: now), item("a.pdf", kind: .document, added: now)]
        let groups = FolderGrouping.kind.groups(items)
        XCTAssertEqual(groups.map(\.title), ["Folders", "Images", "Documents"])
        XCTAssertEqual(groups[2].items.map(\.name), ["b.pdf", "a.pdf"], "order inside a group is the folder's order")
        XCTAssertEqual(FolderGrouping.none.groups(items).first?.items.count, 4)
    }

    func testGroupingByDateAddedUsesTodayYesterdayThisWeekEarlier() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 2 // Monday
        // Friday 2026-10-16 15:00 UTC.
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 15))!
        func at(_ day: Int, _ hour: Int = 12) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
        let items = [item("today", kind: .other, added: at(16, 1)), item("yesterday", kind: .other, added: at(15, 23)),
                     item("monday", kind: .other, added: at(12, 0)), item("lastweek", kind: .other, added: at(11, 23)),
                     item("future", kind: .other, added: at(17))]
        let groups = FolderGrouping.dateAdded.groups(items, now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "This Week", "Earlier"])
        XCTAssertEqual(groups[0].items.map(\.name), ["today", "future"], "a clock ahead of ours still reads as today")
        XCTAssertEqual(groups[2].items.map(\.name), ["monday"])
        XCTAssertEqual(groups[3].items.map(\.name), ["lastweek"])
    }

    // MARK: Git

    func testGitBranchComesFromHeadWithoutRunningGit() throws {
        XCTAssertEqual(Git.branch(fromHead: "ref: refs/heads/main\n"), "main")
        XCTAssertEqual(Git.branch(fromHead: "ref: refs/heads/feature/new-card"), "feature/new-card")
        XCTAssertEqual(Git.branch(fromHead: "8b9dbaf0c3a1e2d4f5a6b7c8d9e0f1a2b3c4d5e6"), "8b9dbaf", "detached: the short commit")
        XCTAssertNil(Git.branch(fromHead: "garbage"))
        XCTAssertEqual(Git.changeCount(porcelain: " M a.swift\n?? new.txt\n\n"), 2)
        XCTAssertEqual(Git.changeCount(porcelain: ""), 0)

        try write("shop/.git/HEAD", text: "ref: refs/heads/launch\n")
        try write("shop/src/app.ts", text: "x")
        let home = root.path
        XCTAssertEqual(Git.repoRoot(containing: root.appendingPathComponent("shop/src").path, home: home), root.appendingPathComponent("shop").path)
        XCTAssertEqual(Git.branch(repo: root.appendingPathComponent("shop").path), "launch")
        XCTAssertNil(Git.repoRoot(containing: root.appendingPathComponent("plain").path, home: home))
        // A worktree's .git is a file pointing at the real git dir.
        try write("wt-git/HEAD", text: "ref: refs/heads/side\n")
        try write("wt/.git", text: "gitdir: \(root.appendingPathComponent("wt-git").path)\n")
        XCTAssertEqual(Git.branch(repo: root.appendingPathComponent("wt").path), "side")
    }

    func testHomeItselfIsNeverTreatedAsARepo() throws {
        try write(".git/HEAD", text: "ref: refs/heads/dotfiles\n")
        try write("Documents/notes.md", text: "x")
        XCTAssertNil(Git.repoRoot(containing: root.appendingPathComponent("Documents").path, home: root.path))
        XCTAssertNil(Git.status(of: root.path, home: root.path))
    }

    func testGitStatusCountsChangesAndWritesNothing() throws {
        guard Git.executable != nil else { throw XCTSkip("no developer tools") }
        let repo = root.appendingPathComponent("repo")
        try write("repo/a.txt", text: "one")
        let git = "/usr/bin/git"
        for args in [["init", "-q", "-b", "main"], ["add", "."], ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init"]] {
            XCTAssertNotNil(Shell.run(git, ["-C", repo.path] + args), args.joined(separator: " "))
        }
        try write("repo/a.txt", text: "two")
        try write("repo/b.txt", text: "new")
        let index = repo.appendingPathComponent(".git/index")
        let before = try fm.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        let status = Git.status(of: repo.path, home: root.deletingLastPathComponent().path)
        XCTAssertEqual(status?.branch, "main")
        XCTAssertEqual(status?.changes, 2)
        let after = try fm.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "reading status never refreshes the index")
    }

    // MARK: Terminal and editor

    func testTerminalAndEditorPicks() {
        let installed: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.zed.Zed-Preview", "com.jetbrains.pycharm.ce"]
        let has = { installed.contains($0) }
        XCTAssertEqual(DevApps.terminal(has: has)?.name, "iTerm", "iTerm beats Terminal; Ghostty and Warp aren't here")
        XCTAssertEqual(DevApps.terminal(has: { $0 == "com.mitchellh.ghostty" || has($0) })?.name, "Ghostty")
        XCTAssertEqual(DevApps.editor(preferred: nil, has: has)?.name, "Zed")
        XCTAssertEqual(DevApps.editor(preferred: nil, has: has)?.bundleIDs, ["dev.zed.Zed-Preview"], "only the installed edition")
        XCTAssertEqual(DevApps.editor(preferred: "PyCharm", has: has)?.name, "PyCharm")
        XCTAssertEqual(DevApps.editor(preferred: "Cursor", has: has)?.name, "Zed", "a choice that's gone falls back")
        XCTAssertNil(DevApps.editor(preferred: nil, has: { _ in false }))
    }
}

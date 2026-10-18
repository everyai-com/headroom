import Foundation
import XCTest
@testable import HeadroomCore

private typealias LibraryItem = HeadroomCore.LibraryItem

/// Clean-up cards and the optional tidy-up rules, in a throwaway "home" — nothing here touches real files.
final class CleanUpTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("headroom-cleanup-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    fileprivate func item(_ rel: String, kind: FileKind? = nil, bytes: Int64 = 1_000, age days: Double, screenshot: Bool = false) -> LibraryItem {
        let date = now.addingTimeInterval(-days * day)
        let path = home.appendingPathComponent(rel).path
        return LibraryItem(path: path, kind: kind ?? FileKind.of(extension: (rel as NSString).pathExtension), bytes: bytes,
                           created: date, modified: date, added: date, isScreenshot: screenshot)
    }

    func app(_ name: String, used days: Double?, exact: Bool = true, bundle: String? = nil) -> InstalledApp {
        InstalledApp(name: name, bundleID: bundle ?? "com.example.\(name.lowercased())", version: nil,
                     url: URL(fileURLWithPath: "/Applications/\(name).app"), appSize: DirectorySize(), leftovers: [],
                     lastUsed: days.map { now.addingTimeInterval(-$0 * day) }, lastUsedIsExact: exact)
    }

    // MARK: Cards

    func testInstallersForInstalledAppsAndOldOnesAreSuggested() {
        let index = LibraryIndex(items: [
            item("Downloads/Slack-4.41.105-macOS.dmg", age: 3),     // Slack is installed
            item("Downloads/Arc-Installer.pkg", age: 0.2),          // installed, but it only just arrived
            item("Downloads/SomeTool.dmg", age: 45),                // not installed, but old
            item("Downloads/NewThing.dmg", age: 5),                 // neither
            item("Downloads/notes.pdf", age: 400),                  // not an installer at all
        ], scannedAt: now)
        let card = CleanUp.oldInstallers(index, apps: [app("Slack", used: 1), app("Arc", used: 1)], home: home.path, now: now, days: 30)
        XCTAssertEqual(Set(card.items.map(\.name)), ["Slack-4.41.105-macOS.dmg", "SomeTool.dmg"])
        XCTAssertTrue(card.installed.contains(home.appendingPathComponent("Downloads/Slack-4.41.105-macOS.dmg").path))
    }

    func testForgottenDownloadsRespectSpotlightsLastOpened() {
        let opened = item("Downloads/still-reading.pdf", age: 200)
        let index = LibraryIndex(items: [opened, item("Downloads/old.zip", age: 120), item("Downloads/new.zip", age: 10),
                                         item("Documents/old.pdf", age: 300)], scannedAt: now)
        let list = CleanUp.forgottenDownloads(index, home: home.path, lastUsed: [opened.path: now.addingTimeInterval(-2 * day)],
                                              now: now, days: 90)
        XCTAssertEqual(list.map(\.name), ["old.zip"])
    }

    func testScreenshotsVideosAndAppsCards() {
        let index = LibraryIndex(items: [
            item("Desktop/Screenshot 1.png", age: 40, screenshot: true),
            item("Desktop/Screenshot 2.png", age: 5, screenshot: true),
            item("Movies/trip.mov", bytes: 2_000_000_000, age: 300),
            item("Movies/small.mov", bytes: 20_000_000, age: 300),
            item("Movies/recent.mov", bytes: 2_000_000_000, age: 20),
        ], scannedAt: now)
        XCTAssertEqual(CleanUp.oldScreenshots(index, now: now, days: 30).map(\.name), ["Screenshot 1.png"])
        XCTAssertEqual(CleanUp.bigOldVideos(index, lastUsed: [:], now: now, days: 180, minBytes: 500_000_000).map(\.name), ["trip.mov"])
        let apps = [app("Old", used: 200), app("Fresh", used: 3), app("Unknown", used: 200, exact: false),
                    app("Never", used: nil), app("Notes", used: 400, bundle: "com.apple.Notes")]
        // Only a sure "not opened in 3 months" — never a guess, never Apple's own.
        XCTAssertEqual(CleanUp.unusedApps(apps, now: now, days: 90).map(\.name), ["Old"])
    }

    func testCardsAreNeverEmptyAndInstallersArentCountedTwice() {
        let index = LibraryIndex(items: [item("Downloads/Big.dmg", age: 200)], scannedAt: now)
        let cards = CleanUp.suggestions(index, apps: [], home: home.path, now: now)
        XCTAssertEqual(cards.map(\.kind), [.oldInstallers], "an old installer in Downloads is not also a forgotten download")
        XCTAssertFalse(cards.contains { $0.items.isEmpty && $0.apps.isEmpty })
    }

    func testNormalisedNamesMatchInstallersToApps() {
        XCTAssertEqual(CleanUp.normalized("Google Chrome"), "googlechrome")
        XCTAssertEqual(CleanUp.normalized("googlechrome-universal"), "googlechrome")
        XCTAssertTrue(CleanUp.normalized("Docker-arm64 4.30").hasPrefix(CleanUp.normalized("Docker")))
    }

    // MARK: Auto rules

    func testOldInstallerPlanTrashesThroughTheCleanerOnly() {
        let index = LibraryIndex(items: [item("Downloads/Old.dmg", age: 40), item("Downloads/New.dmg", age: 2),
                                         item("Documents/Old.dmg", age: 400)], scannedAt: now)
        let plan = AutoRules.oldInstallerPlan(index, home: home.path, days: 30, now: now)
        XCTAssertEqual(plan.map(\.title), ["Old.dmg"])
        XCTAssertEqual(plan.first?.method, .trash)
        XCTAssertNotEqual(plan.first?.safety, .safe, "never one-click safe")
    }

    func testScreenshotsAreFiledByMonthAndNeverOverwritten() throws {
        let desktop = home.appendingPathComponent("Desktop")
        let shot = item("Desktop/Screenshot A.png", age: 3, screenshot: true)
        let today = item("Desktop/Screenshot B.png", age: 0.2, screenshot: true)
        let nested = item("Desktop/Work/Screenshot C.png", age: 30, screenshot: true)
        let photo = item("Desktop/photo.png", age: 30)
        for i in [shot, today, nested, photo] {
            try fm.createDirectory(at: i.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: i.url)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let moves = AutoRules.screenshotMoves(LibraryIndex(items: [shot, today, nested, photo], scannedAt: now),
                                              folder: desktop, now: now, calendar: calendar)
        XCTAssertEqual(moves.map(\.from.lastPathComponent), ["Screenshot A.png"], "only loose screenshots older than a day")
        let month = moves[0].to.deletingLastPathComponent()
        XCTAssertEqual(month.deletingLastPathComponent().lastPathComponent, "Screenshots")
        // Something with that name is already filed: the move picks a new name, never overwrites.
        try fm.createDirectory(at: month, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: moves[0].to)
        let result = AutoRules.perform(moves, guardrail: SafetyGuard(home: home))
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(result.moved.first?.to.lastPathComponent, "Screenshot A 2.png")
        XCTAssertEqual(try String(contentsOf: moves[0].to, encoding: .utf8), "older")
        XCTAssertFalse(fm.fileExists(atPath: shot.path))

        // Activity: Put Back moves it home; it is never "in the Trash" or counted as freed.
        let entry = AutoRules.entry(for: result.moved, automatic: true)
        XCTAssertEqual(entry.kind, .filed)
        XCTAssertTrue(entry.canPutBack)
        XCTAssertFalse(entry.canDeleteFromTrash)
        XCTAssertEqual(ActivityLog.putBack(entry).restored, 1)
        XCTAssertTrue(fm.fileExists(atPath: shot.path))
    }

    func testFilingRespectsTheNeverTouchList() throws {
        let shot = item("Desktop/Screenshot A.png", age: 3, screenshot: true)
        try fm.createDirectory(at: shot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: shot.url)
        let moves = [AutoRules.Move(from: shot.url, to: home.appendingPathComponent("Desktop/Screenshots/2026-10/Screenshot A.png"))]
        let guarded = SafetyGuard(home: home, excluded: [home.appendingPathComponent("Desktop").path])
        let result = AutoRules.perform(moves, guardrail: guarded)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: shot.path))
    }

    func testFilingNeverLeavesHome() throws {
        let shot = item("Desktop/Screenshot A.png", age: 3, screenshot: true)
        try fm.createDirectory(at: shot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: shot.url)
        let away = fm.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString)/Screenshot A.png")
        let result = AutoRules.perform([AutoRules.Move(from: shot.url, to: away)], guardrail: SafetyGuard(home: home))
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: shot.path))
    }

    // MARK: Spotlight queries

    func testSpotlightQueriesCantBreakOutOfTheirQuotes() {
        XCTAssertEqual(Spotlight.sanitize(#"wifi" || kMDItemFSName == "*"#), "wifi  kMDItemFSName")
        XCTAssertEqual(Spotlight.sanitize("Wi-Fi 5.0"), "Wi-Fi 5.0")
    }
}

/// Files inside code projects are shown but never suggested for the Trash.
final class ProjectFilesTests: XCTestCase {
    func testDuplicatesKeepProjectCopiesAndDropTheRestOfThem() {
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ p: String, project: Bool) -> HeadroomCore.LibraryItem {
            HeadroomCore.LibraryItem(path: p, kind: .video, bytes: 100, created: d, modified: d, inProject: project)
        }
        let mixed = DuplicateGroup(kind: .identical, items: [item("/h/Documents/a.mp4", project: false), item("/h/code/x/docs/a.mp4", project: true),
                                                             item("/h/Downloads/a.mp4", project: false), item("/h/code/y/docs/a.mp4", project: true)])
        let spared = mixed.sparingProjects()
        XCTAssertEqual(spared?.keep, "/h/code/x/docs/a.mp4", "a project copy stays put and is the one kept")
        XCTAssertEqual(spared?.items.map(\.path), ["/h/code/x/docs/a.mp4", "/h/Documents/a.mp4", "/h/Downloads/a.mp4"])
        XCTAssertEqual(spared?.wasted, 200)
        let onlyProjects = DuplicateGroup(kind: .identical, items: [item("/h/code/x/a.mp4", project: true), item("/h/code/y/a.mp4", project: true)])
        XCTAssertNil(onlyProjects.sparingProjects(), "nothing to trash when every copy is in a project")
    }

    func testCleanUpCardsSkipProjectFiles() {
        let now = Date()
        let old = now.addingTimeInterval(-400 * 86_400)
        let index = LibraryIndex(items: [
            HeadroomCore.LibraryItem(path: "/h/code/app/demo.mov", kind: .video, bytes: 2_000_000_000, created: old, modified: old, inProject: true),
            HeadroomCore.LibraryItem(path: "/h/code/app/Tool.dmg", kind: .archive, bytes: 1_000, created: old, modified: old, inProject: true),
        ], scannedAt: now)
        XCTAssertTrue(CleanUp.suggestions(index, apps: [], home: "/h", now: now).isEmpty)
    }

    func testTheScannerMarksProjectFiles() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("headroom-projects-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: home) }
        for (rel, isProject) in [("Desktop/app/package.json", true), ("Desktop/app/docs/demo.mp4", true), ("Desktop/clip.mp4", false)] {
            let url = home.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 10).write(to: url)
            _ = isProject
        }
        let index = await LibraryScanner.scan(roots: [home.appendingPathComponent("Desktop")])
        let byName = Dictionary(uniqueKeysWithValues: index.items.map { ($0.name, $0) })
        XCTAssertEqual(byName["demo.mp4"]?.inProject, true)
        XCTAssertEqual(byName["clip.mp4"]?.inProject, false)
    }
}

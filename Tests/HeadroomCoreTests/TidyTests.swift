import Foundation
import XCTest
@testable import HeadroomCore

/// Tidying a folder in a throwaway home: planning reads only; performing moves loose files into
/// folders by kind, never folders, never overwriting, and Put Back moves everything home.
final class TidyTests: XCTestCase {
    var home: URL!
    var desktop: URL!
    let fm = FileManager.default
    let old = Date().addingTimeInterval(-86_400 * 3)

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("headroom-tidy-\(UUID().uuidString)").resolvingSymlinksInPath()
        desktop = home.appendingPathComponent("Desktop")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    @discardableResult
    func write(_ rel: String, modified: Date? = nil) throws -> URL {
        let url = desktop.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000).write(to: url)
        try fm.setAttributes([.modificationDate: modified ?? old], ofItemAtPath: url.path)
        return url
    }

    func listing() -> Set<String> {
        Set(fm.enumerator(atPath: desktop.path)?.compactMap { $0 as? String } ?? [])
    }

    func testPlanSortsLooseFilesByKindAndLeavesTheRest() throws {
        try write("Screenshot 2026-10-01 at 09.12.41.png")
        try write("beach.jpg")
        try write("Invoice-0923.pdf")
        try write("Budget-Q4.xlsx")
        try write("Zoom.pkg")
        try write("fonts.zip")
        try write("team-offsite.mov")
        try write("license.lic")
        try write("Unconfirmed 418235.crdownload")
        try write("notes.txt", modified: Date())
        try write("Receipts/one.pdf")
        try fm.createDirectory(at: desktop.appendingPathComponent("Untitled folder"), withIntermediateDirectories: true)
        let before = listing()
        let plan = AutoRules.tidyPlan(folder: desktop)
        XCTAssertEqual(listing(), before, "planning moves nothing")
        let to = Dictionary(uniqueKeysWithValues: plan.moves.map { ($0.from.lastPathComponent, $0.to.deletingLastPathComponent().lastPathComponent) })
        XCTAssertEqual(to, ["Screenshot 2026-10-01 at 09.12.41.png": "Screenshots", "beach.jpg": "Images", "Invoice-0923.pdf": "PDFs",
                            "Budget-Q4.xlsx": "Documents", "Zoom.pkg": "Installers", "fonts.zip": "Archives",
                            "team-offsite.mov": "Videos", "license.lic": "Other"])
        XCTAssertEqual(plan.folders, 2, "folders stay where they are")
        XCTAssertEqual(plan.skipped.count, 2, "a download still arriving and a file just changed")
        XCTAssertEqual(plan.groups.first?.moves.count, 1)
    }

    func testPerformMovesPackagesNeverOverwritesAndPutsBack() throws {
        try write("Images/beach.jpg")            // already there: the newcomer becomes "beach 2.jpg"
        let loose = try write("beach.jpg")
        let deck = desktop.appendingPathComponent("Pitch.key")
        try fm.createDirectory(at: deck, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 20_000).write(to: deck.appendingPathComponent("Index.zip"))
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: deck.path)
        let plan = AutoRules.tidyPlan(folder: desktop)
        let result = AutoRules.perform(plan.moves, guardrail: SafetyGuard(home: home))
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(result.moved.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: desktop.appendingPathComponent("Images/beach 2.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: desktop.appendingPathComponent("Images/beach.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: desktop.appendingPathComponent("Documents/Pitch.key/Index.zip").path), "a Keynote deck moves whole")
        let entry = AutoRules.entry(for: result.moved, automatic: false, noun: "files")
        XCTAssertEqual(entry.kind, .filed)
        XCTAssertEqual(entry.title, "2 files")
        XCTAssertEqual(ActivityLog.putBack(entry).restored, 2)
        XCTAssertTrue(fm.fileExists(atPath: loose.path))
        XCTAssertTrue(fm.fileExists(atPath: deck.appendingPathComponent("Index.zip").path))
    }

    func testRefusesHomeLibraryAndCodeProjects() throws {
        XCTAssertNil(AutoRules.tidyRefusal(folder: desktop, home: home))
        XCTAssertNotNil(AutoRules.tidyRefusal(folder: home, home: home))
        XCTAssertNotNil(AutoRules.tidyRefusal(folder: home.appendingPathComponent("Library/Caches"), home: home))
        XCTAssertNotNil(AutoRules.tidyRefusal(folder: URL(fileURLWithPath: "/tmp"), home: home))
        let app = desktop.appendingPathComponent("my-app")
        try write("my-app/package.json")
        try fm.createDirectory(at: app.appendingPathComponent("src/assets"), withIntermediateDirectories: true)
        XCTAssertNotNil(AutoRules.tidyRefusal(folder: app, home: home))
        XCTAssertNotNil(AutoRules.tidyRefusal(folder: app.appendingPathComponent("src/assets"), home: home), "inside a project too")
    }

    func testANeverTouchDesktopIsLeftAlone() throws {
        try write("beach.jpg")
        let plan = AutoRules.tidyPlan(folder: desktop)
        let result = AutoRules.perform(plan.moves, guardrail: SafetyGuard(home: home, excluded: [desktop.path]))
        XCTAssertEqual(result.moved.count, 0)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(fm.fileExists(atPath: desktop.appendingPathComponent("beach.jpg").path))
    }
}

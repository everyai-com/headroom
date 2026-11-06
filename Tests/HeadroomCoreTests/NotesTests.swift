import Foundation
import XCTest
@testable import HeadroomCore

/// The notepad in a throwaway home: new files never replace one, saves never lose another app's edit,
/// and nothing is made in Library or inside a bundle.
final class NotesTests: XCTestCase {
    var home: URL!
    var folder: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("headroom-notes-\(UUID().uuidString)").resolvingSymlinksInPath()
        folder = home.appendingPathComponent("Documents")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    func testNewFilesNeverReplaceOne() throws {
        try Data("keep me".utf8).write(to: folder.appendingPathComponent("Untitled.md"))
        let first = try Notes.create(.markdown, in: folder, home: home.path)
        let second = try Notes.create(.markdown, in: folder, home: home.path)
        XCTAssertNotEqual(first.lastPathComponent, "Untitled.md")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("Untitled.md"), encoding: .utf8), "keep me")
        XCTAssertEqual(try Data(contentsOf: first).count, 0)
    }

    func testNamesSkipTakenOnes() {
        var taken: Set<String> = []
        for _ in 0..<5 {
            let name = Notes.name(ext: "md") { taken.contains($0) }
            XCTAssertFalse(taken.contains(name))
            XCTAssertTrue(name.hasSuffix(".md"))
            taken.insert(name)
        }
    }

    func testSaveRefusesAnotherAppsEdit() throws {
        let url = try Notes.create(.text, in: folder, home: home.path)
        let opened = try Notes.read(url)
        try Data("theirs".utf8).write(to: url)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        XCTAssertThrowsError(try Notes.save("mine", to: url, expected: opened.modified)) {
            XCTAssertEqual($0 as? Notes.Problem, .changedElsewhere)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "theirs")
        try Notes.save("mine", to: url, expected: opened.modified, force: true)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "mine")
    }

    func testSavesKeepGoingAfterTheFirst() throws {
        let url = try Notes.create(.markdown, in: folder, home: home.path)
        var date = try Notes.read(url).modified
        for text in ["# One", "# One\ntwo", "# One\ntwo\nthree"] {
            date = try Notes.save(text, to: url, expected: date)
        }
        XCTAssertEqual(try Notes.read(url).text, "# One\ntwo\nthree")
    }

    func testOnlyYourOwnFolders() throws {
        let library = home.appendingPathComponent("Library/Preferences")
        let bundle = home.appendingPathComponent("Applications/Thing.app/Contents")
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        XCTAssertTrue(Notes.canCreate(in: folder.path, home: home.path))
        XCTAssertFalse(Notes.canCreate(in: library.path, home: home.path))
        XCTAssertFalse(Notes.canCreate(in: bundle.path, home: home.path))
        XCTAssertFalse(Notes.canCreate(in: "/usr/bin", home: home.path))
        XCTAssertThrowsError(try Notes.create(.markdown, in: library, home: home.path))
    }

    func testEditsOnlyPlainText() throws {
        let pdf = folder.appendingPathComponent("a.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        XCTAssertFalse(Notes.canEdit(pdf))
        XCTAssertFalse(Notes.canEdit(folder))
        XCTAssertThrowsError(try Notes.save("x", to: pdf, expected: nil))
        XCTAssertTrue(Notes.canEdit(try Notes.create(.markdown, in: folder, home: home.path)))
    }
}

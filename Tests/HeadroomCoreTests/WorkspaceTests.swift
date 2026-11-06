import Foundation
import XCTest
@testable import HeadroomCore

/// Workspaces in a throwaway folder: they only remember paths and read what's there — nothing is
/// copied, moved or written except the store file itself.
final class WorkspaceTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("headroom-workspace-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    @discardableResult
    func write(_ rel: String, bytes: Int = 1_000, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        if let modified { try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    /// Every file under root, with its size and date — to prove a walk changed nothing.
    func snapshot() -> [String: [FileAttributeKey: AnyHashable]] {
        var out: [String: [FileAttributeKey: AnyHashable]] = [:]
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil)! {
            let a = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
            out[url.path] = [.size: a[.size] as? Int ?? -1, .modificationDate: a[.modificationDate] as? Date ?? .distantPast]
        }
        return out
    }

    func testAddKeepsOrderSkipsRepeatsAndRemoves() throws {
        let a = try write("Taxes/statement.pdf").deletingLastPathComponent().path
        let b = try write("Receipts/taxi.jpg").path
        var w = Workspace(name: "Taxes 2026")
        XCTAssertEqual(w.add([a, b, a]), 2)
        XCTAssertEqual(w.add([a + "/"]), 0, "a trailing slash is the same folder")
        XCTAssertEqual(w.paths, [a, b])
        XCTAssertNotNil(w.members[0].bookmark)
        w.remove([a])
        XCTAssertEqual(w.paths, [b])
        XCTAssertTrue(fm.fileExists(atPath: a), "removing from a workspace never touches the folder")
    }

    func testStoreRoundTrips() throws {
        let store = root.appendingPathComponent("workspaces.json")
        var w = Workspace(name: "Japan Trip", note: "Tickets and bookings")
        w.add([try write("Trip/ticket.pdf").path])
        Workspaces.save([w], to: store)
        XCTAssertEqual(Workspaces.load(from: store), [w])
        XCTAssertEqual(Workspaces.load(from: root.appendingPathComponent("none.json")), [])
    }

    func testFollowsARenamedFolder() throws {
        let old = try write("Brand/logo.png").deletingLastPathComponent()
        var w = Workspace(name: "Rebrand")
        w.add([old.path])
        let new = root.appendingPathComponent("Brand Assets")
        try fm.moveItem(at: old, to: new)
        // The temp folder is /var/… but resolves to /private/var/… — compare them the same way.
        let found = Workspaces.relocated(w).paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        XCTAssertEqual(found, [new.resolvingSymlinksInPath().path])
    }

    func testStateSaysWhyAMemberIsGone() throws {
        XCTAssertEqual(Workspaces.state(of: root.path), .present)
        XCTAssertEqual(Workspaces.state(of: root.appendingPathComponent("gone").path), .missing)
    }

    func testNotConnectedDrive() {
        let drive = "NoSuchDrive-\(UUID().uuidString.prefix(6))"
        XCTAssertEqual(Workspaces.state(of: "/Volumes/\(drive)/Footage"), .notConnected(drive: drive))
    }

    func testPlaceReadsLikeAPersonWouldSayIt() {
        let home = "/Users/sam"
        XCTAssertEqual(Workspaces.place(of: "/Users/sam/Downloads/a.pdf", home: home), "Downloads")
        XCTAssertEqual(Workspaces.place(of: "/Users/sam/Documents/Work/Payslips", home: home), "Documents › Work")
        XCTAssertEqual(Workspaces.place(of: "/Users/sam/Documents/Clients/Acme/Work/x.pdf", home: home), "Documents › … › Work")
        XCTAssertEqual(Workspaces.place(of: "/Users/sam/Library/Mobile Documents/com~apple~CloudDocs/Scans/Receipts", home: home),
                       "iCloud Drive › Scans")
        XCTAssertEqual(Workspaces.place(of: "/Users/sam/Library/CloudStorage/Dropbox/Brand/logo.png", home: home), "Dropbox › Brand")
        XCTAssertEqual(Workspaces.place(of: "/Users/sam/Library/CloudStorage/GoogleDrive-sam@gmail.com/My Drive/Trip/t.pdf", home: home),
                       "Google Drive › Trip")
        XCTAssertEqual(Workspaces.place(of: "/Volumes/T7 Shield/Footage", home: home), "T7 Shield")
        XCTAssertEqual(Workspaces.place(of: "/Users/sam/Desktop", home: home), "Home")
    }

    func testSummaryCountsSizesAndSkipsWhatIsNotYours() throws {
        let now = Date()
        try write("Launch/plan.pdf", bytes: 4_096, modified: now.addingTimeInterval(-3_600))
        try write("Launch/Footage/teaser.mov", bytes: 8_192, modified: now.addingTimeInterval(-86_400 * 30))
        try write("Launch/.secret", bytes: 9_999)
        try write("Launch/site/package.json", bytes: 100, modified: now.addingTimeInterval(-60))
        try write("Launch/site/node_modules/lib/index.js", bytes: 50_000)
        try write("Launch/site/build/out.js", bytes: 50_000)
        let before = snapshot()
        let s = Workspaces.summarize(folder: root.appendingPathComponent("Launch").path, keep: 2)
        XCTAssertEqual(snapshot(), before, "summarising reads only")
        XCTAssertEqual(s.files, 3, "plan, teaser and package.json — not hidden files, dependencies or build output")
        XCTAssertGreaterThanOrEqual(s.bytes, 4_096 + 8_192)
        XCTAssertFalse(s.partial)
        XCTAssertEqual(s.recent.map(\.name), ["package.json", "plan.pdf"], "the newest two, newest first")
        XCTAssertTrue(s.recent[0].inProject)
    }

    func testSummaryStopsAtItsLimit() throws {
        for i in 0..<8 { try write("Many/f\(i).txt") }
        let s = Workspaces.summarize(folder: root.appendingPathComponent("Many").path, limit: 5)
        XCTAssertTrue(s.partial)
        XCTAssertLessThanOrEqual(s.files, 5)
    }

    func testSummaryNotesAGitRepo() throws {
        try fm.createDirectory(at: root.appendingPathComponent("App/.git"), withIntermediateDirectories: true)
        try write("App/README.md")
        XCTAssertTrue(Workspaces.summarize(folder: root.appendingPathComponent("App").path).isRepo)
    }

    func testChangedLatelyMergesFoldersAndFilesNewestFirst() throws {
        let now = Date()
        try write("A/old.pdf", modified: now.addingTimeInterval(-86_400 * 40))
        try write("A/new.pdf", modified: now.addingTimeInterval(-60))
        let loose = try write("loose.docx", modified: now.addingTimeInterval(-3_600))
        let folder = Workspaces.summarize(folder: root.appendingPathComponent("A").path)
        let file = try XCTUnwrap(Workspaces.file(at: loose.path))
        let changed = Workspaces.changedLately([folder, folder], files: [file], since: now.addingTimeInterval(-86_400 * 14))
        XCTAssertEqual(changed.map(\.name), ["new.pdf", "loose.docx"], "no repeats, nothing older than two weeks")
    }

    func testFileAndFolderMembers() throws {
        let pdf = try write("Docs/plan.pdf")
        XCTAssertEqual(Workspaces.file(at: pdf.path)?.kind, .document)
        XCTAssertNil(Workspaces.file(at: pdf.deletingLastPathComponent().path), "a folder is not a file")
        XCTAssertTrue(Workspaces.isFolder(pdf.deletingLastPathComponent().path))
        XCTAssertFalse(Workspaces.isFolder(pdf.path))
        let deck = root.appendingPathComponent("Pitch.key")
        try fm.createDirectory(at: deck, withIntermediateDirectories: true)
        try write("Pitch.key/Index.zip", bytes: 20_000)
        XCTAssertFalse(Workspaces.isFolder(deck.path), "a Keynote package is one file to a person")
        XCTAssertEqual(Workspaces.file(at: deck.path)?.kind, .document)
    }
}

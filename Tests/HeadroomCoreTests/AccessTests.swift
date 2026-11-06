import Foundation
import XCTest
@testable import HeadroomCore

/// Folders behind a permission prompt are looked at on their own thread, never waited on.
final class AccessTests: XCTestCase {
    func testWhichFoldersCanPrompt() {
        let home = "/Users/sam"
        XCTAssertEqual(Access.guardedFolder(of: URL(fileURLWithPath: "/Users/sam/Desktop/app/node_modules"), home: home), "/Users/sam/Desktop")
        XCTAssertEqual(Access.guardedFolder(of: URL(fileURLWithPath: "/Users/sam/Library/Containers/com.apple.mail/Data"), home: home),
                       "/Users/sam/Library/Containers/com.apple.mail", "other apps' data prompts per app")
        XCTAssertEqual(Access.guardedFolder(of: URL(fileURLWithPath: "/Users/sam/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"), home: home),
                       "/Users/sam/Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
        XCTAssertNil(Access.guardedFolder(of: URL(fileURLWithPath: "/Users/sam/Library/Caches/pip"), home: home))
        XCTAssertNil(Access.guardedFolder(of: URL(fileURLWithPath: "/Users/sam/.npm/_cacache"), home: home))
        XCTAssertNil(Access.guardedFolder(of: URL(fileURLWithPath: "/Users/sam/Desktopper"), home: home), "a name that only starts the same isn't it")
    }

    func testReadableFoldersPassAndOrderIsKept() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("access-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let urls = ["Desktop", "Documents", "Projects"].map { home.appendingPathComponent($0) }
        for u in urls { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        XCTAssertEqual(Access.readable(urls, home: home.path), urls)
        XCTAssertTrue(Access.waiting.allSatisfy { !$0.hasPrefix(home.path) })
    }
}

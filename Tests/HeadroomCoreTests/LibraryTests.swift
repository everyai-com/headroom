import Foundation
import XCTest
@testable import HeadroomCore

/// HeadroomCore's, not DeveloperToolsSupport's (which PDFKit pulls in).
private typealias LibraryItem = HeadroomCore.LibraryItem

/// The library scanner and where downloads came from, in a throwaway "home" — nothing here touches real files.
final class LibraryTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("headroom-library-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    @discardableResult
    func write(_ rel: String, bytes: Int = 1_000) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    /// Scan the fake home's own folders; items keyed by their path inside home.
    private func scan() async -> [String: LibraryItem] {
        let index = await LibraryScanner.scan(roots: LibraryScanner.defaultRoots(home: home))
        var byPath: [String: LibraryItem] = [:]
        // Paths come back as /private/var/…, home as /var/… — key by what follows the home folder's own name.
        let marker = "/" + home.lastPathComponent + "/"
        for item in index.items {
            guard let range = item.path.range(of: marker) else { continue }
            byPath[String(item.path[range.upperBound...])] = item
        }
        return byPath
    }

    // MARK: - Scanner

    func testDefaultRootsAreYourOwnFolders() throws {
        for folder in ["Desktop", "Documents", "Downloads", "Library/Caches", "Applications", "Public", ".config", "Foo.app/Contents"] {
            try fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try write("loose.txt")
        let roots = LibraryScanner.defaultRoots(home: home).map(\.lastPathComponent)
        XCTAssertEqual(roots, ["Desktop", "Documents", "Downloads"])
    }

    func testKindsByExtension() async throws {
        let files = ["Documents/a.pdf": FileKind.document, "Documents/b.DOCX": .document, "Documents/sheet.numbers": .document,
                     "Pictures/c.JPG": .image, "Pictures/d.heic": .image, "Movies/e.mov": .video, "Movies/f.MP4": .video,
                     "Music/g.mp3": .audio, "Music/h.flac": .audio, "Downloads/i.zip": .archive, "Downloads/Setup.dmg": .archive,
                     "Downloads/j.xyz": .other, "Documents/no-extension": .other]
        for path in files.keys { try write(path) }
        let found = await scan()
        XCTAssertEqual(found.count, files.count)
        for (path, kind) in files { XCTAssertEqual(found[path]?.kind, kind, path) }
        XCTAssertEqual(found["Downloads/Setup.dmg"]?.isInstaller, true)
        XCTAssertEqual(found["Documents/a.pdf"]?.bytes, 1_000)
        XCTAssertEqual(found["Documents/a.pdf"]?.typeLabel, "PDF")
        XCTAssertEqual(FileKind.of(extension: "PNG"), .image)
        XCTAssertEqual(FileKind.of(extension: "app"), .app)
        XCTAssertEqual(FileKind.of(extension: ""), .other)
    }

    func testHiddenFilesAndDependenciesAreSkipped() async throws {
        try write("Documents/visible.pdf")
        try write("Documents/.secret.pdf")
        try write("Documents/.hidden/inside.pdf")
        try write(".config/app/settings.pdf")
        try write("Documents/site/node_modules/pkg/readme.pdf")
        try write("Downloads/node_modules/clip.mp4") // anywhere, not just in code projects
        try write("Documents/tool/__pycache__/x.pdf")
        try write("Documents/ios/Pods/Lib/guide.pdf")
        let found = await scan()
        XCTAssertEqual(Set(found.keys), ["Documents/visible.pdf"])
    }

    func testCodeProjectsKeepOnlyRealMediaAndOfficeFiles() async throws {
        try write("Documents/app/.git/HEAD")
        try write("Documents/app/logo.png")
        try write("Documents/app/README.md")
        try write("Documents/app/notes.txt")
        try write("Documents/app/demo.mp4")
        try write("Documents/app/docs/spec.pdf")
        try write("Documents/app/docs/diagram.jpg")
        try write("Documents/app/build/output.pdf")
        try write("Documents/app/dist/bundle.zip")
        try write("Documents/app/Tool.app/Contents/Info.plist")
        // Outside a code project, a "build" or "dist" folder may be yours.
        try write("Documents/build/report.pdf")
        try write("Documents/dist/photo.jpg")
        try write("Documents/notes.md")
        try write("Documents/photo.png")

        let found = await scan()
        XCTAssertEqual(Set(found.keys), ["Documents/app/demo.mp4", "Documents/app/docs/spec.pdf", "Documents/build/report.pdf",
                                         "Documents/dist/photo.jpg", "Documents/notes.md", "Documents/photo.png"])
    }

    func testPhotoLibrariesAreNeverWalked() async throws {
        try write("Pictures/Photos Library.photoslibrary/originals/A/IMG_0001.heic")
        try write("Pictures/Photos Library.photoslibrary/database/Photos.sqlite")
        try write("Pictures/mine.heic")
        let found = await scan()
        XCTAssertEqual(Set(found.keys), ["Pictures/mine.heic"])
    }

    /// A database package whose app isn't installed is a plain folder to macOS (`isPackage` false), so the
    /// directory branch in `LibraryScanner.walk` walks into it before `skippedPackages` is ever checked.
    func testDatabasePackagesAreNeverWalkedEvenWhenTheirAppIsMissing() async throws {
        try write("Documents/Ubuntu.utm/Data/disk-0.img", bytes: 4_096)
        try write("Documents/Windows.pvm/Windows.png")
        try write("Documents/report.pdf")
        let found = await scan()
        let unregistered = ["Documents/Ubuntu.utm", "Documents/Windows.pvm"].filter {
            (try? home.appendingPathComponent($0).resourceValues(forKeys: [.isPackageKey]).isPackage) != true
        }
        XCTAssertEqual(Set(found.keys), ["Documents/report.pdf"], "VM disks inside \(unregistered) must not be listed as archives")
    }

    func testAnAppBundleIsOneItem() async throws {
        try write("Downloads/Tool.app/Contents/Info.plist", bytes: 500)
        try write("Downloads/Tool.app/Contents/MacOS/tool", bytes: 50_000)
        try write("Downloads/Tool.app/Contents/Resources/icon.png", bytes: 2_000)
        let found = await scan()
        XCTAssertEqual(Array(found.keys), ["Downloads/Tool.app"])
        let app = try XCTUnwrap(found["Downloads/Tool.app"])
        XCTAssertEqual(app.kind, .app)
        XCTAssertEqual(app.typeLabel, "App")
        XCTAssertGreaterThanOrEqual(app.bytes, 52_000, "its size is everything inside")
    }

    func testScreenshotsAreFlaggedByName() async throws {
        try write("Desktop/Screenshot 2026-10-01 at 10.00.00.png")
        try write("Desktop/Screen Shot 2020-01-01 at 1.00.00 PM.png")
        try write("Desktop/CleanShot 2026-10-01 at 10.00.00@2x.png")
        try write("Desktop/holiday.png")
        try write("Desktop/Screenshot notes.pdf")
        let found = await scan()
        XCTAssertEqual(Set(found.filter { $0.value.isScreenshot }.keys),
                       ["Desktop/Screenshot 2026-10-01 at 10.00.00.png", "Desktop/Screen Shot 2020-01-01 at 1.00.00 PM.png",
                        "Desktop/CleanShot 2026-10-01 at 10.00.00@2x.png"], "images only, by the names macOS and the tools use")
        XCTAssertTrue(LibraryScanner.looksLikeScreenshot("Bildschirmfoto 2026-01-01 um 10.00.00.png"))
        XCTAssertFalse(LibraryScanner.looksLikeScreenshot("my screenshot.png"))
    }

    func testWhereFromAndDownloadingAppComeFromExtendedAttributes() async throws {
        let report = try write("Downloads/report.pdf")
        let urls = ["https://files.example.com/r/report.pdf", "https://www.example.com/reports"]
        let plist = try PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0)
        try setAttribute(report, "com.apple.metadata:kMDItemWhereFroms", plist)
        try setAttribute(report, "com.apple.quarantine", Data("0083;65f1a2b3;Slack;8F2E6B1C-0000-4000-8000-000000000000".utf8))

        let page = try write("Downloads/page.html")
        try setAttribute(page, "com.apple.quarantine", Data("0081;65f1a2b3;Safari;".utf8))
        try write("Downloads/plain.zip")

        let found = await scan()
        XCTAssertEqual(found["Downloads/report.pdf"]?.whereFrom, urls)
        XCTAssertEqual(found["Downloads/report.pdf"]?.downloadedBy, "Slack")
        XCTAssertEqual(found["Downloads/page.html"]?.downloadedBy, "Safari")
        XCTAssertNil(found["Downloads/page.html"]?.whereFrom)
        XCTAssertNil(found["Downloads/plain.zip"]?.downloadedBy)
        XCTAssertNil(found["Downloads/plain.zip"]?.whereFrom)
        XCTAssertNotNil(found["Downloads/report.pdf"]?.added, "the download date")
    }

    func setAttribute(_ url: URL, _ name: String, _ value: Data) throws {
        let result = value.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, value.count, 0, 0) }
        if result != 0 { throw XCTSkip("can't set \(name) here (errno \(errno))") }
    }

    // MARK: - Index

    func testIndexTotalsRecentAndDownloads() {
        func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
        let a = LibraryItem(path: "/Users/me/Downloads/a.pdf", kind: .document, bytes: 100, created: at(1), modified: at(100), added: at(10))
        let b = LibraryItem(path: "/Users/me/Downloads/b.zip", kind: .archive, bytes: 200, created: at(50), modified: at(50), added: at(50))
        let c = LibraryItem(path: "/Users/me/Downloads/sub/c.jpg", kind: .image, bytes: 300, created: at(30), modified: at(30),
                            isScreenshot: true)
        let d = LibraryItem(path: "/Users/me/Documents/d.pdf", kind: .document, bytes: 400, created: at(200), modified: at(200))
        let e = LibraryItem(path: "/Users/me/Documents/e.xyz", kind: .other, bytes: 500, created: at(300), modified: at(300))
        let f = LibraryItem(path: "/Users/me/Downloads2/f.pdf", kind: .document, bytes: 600, created: at(5), modified: at(5))
        let index = LibraryIndex(items: [a, b, c, d, e, f], scannedAt: at(1_000), roots: ["/Users/me"])

        XCTAssertEqual(index.totals(.document), LibraryIndex.Totals(count: 3, bytes: 1_100))
        XCTAssertEqual(index.totals(.video), LibraryIndex.Totals())
        XCTAssertEqual(index.shelved.map(\.path), [a, b, c, d, f].map(\.path), "everything but Other")
        XCTAssertEqual(index.recent().map(\.path), [d, a, b, c, f].map(\.path), "newest anything-happened first, no Other")
        XCTAssertEqual(index.recent(limit: 2).map(\.path), [d, a].map(\.path))
        XCTAssertEqual(index.recent(.image).map(\.path), [c.path])
        XCTAssertEqual(index.recent(.other).map(\.path), [e.path])
        XCTAssertEqual(index.screenshots.map(\.path), [c.path])
        // Downloads in the order they arrived — a.pdf changed lately but arrived first; Downloads2 isn't Downloads.
        XCTAssertEqual(index.downloads(in: "/Users/me/Downloads").map(\.path), [b, c, a].map(\.path))
        XCTAssertEqual(index.downloads(in: "/Users/me/Downloads/").map(\.path), [b, c, a].map(\.path))
        XCTAssertEqual(index.downloads(in: "/Users/me/Downloads", limit: 1).map(\.path), [b.path])
    }

    func testCacheRoundTrip() throws {
        let item = LibraryItem(path: "/Users/me/Downloads/a b.pdf", kind: .document, bytes: 1_234, allocated: 4_096,
                               created: Date(timeIntervalSince1970: 1_700_000_000.25), modified: Date(timeIntervalSince1970: 1_700_000_100),
                               added: Date(timeIntervalSince1970: 1_700_000_050), whereFrom: ["https://x.com/a", "https://x.com/"],
                               downloadedBy: "Safari", isScreenshot: false, tags: ["Red", "Work"])
        let other = LibraryItem(path: "/Users/me/Pictures/b.png", kind: .image, bytes: 10, created: .distantPast, modified: .distantPast,
                                isScreenshot: true)
        let index = LibraryIndex(items: [item, other], scannedAt: Date(timeIntervalSince1970: 1_700_001_000), roots: ["/Users/me/Downloads"])
        let url = home.appendingPathComponent("library.plist")
        index.saveCache(to: url)
        let loaded = try XCTUnwrap(LibraryIndex.loadCache(from: url))
        XCTAssertEqual(loaded.items, index.items)
        XCTAssertEqual(loaded.scannedAt, index.scannedAt)
        XCTAssertEqual(loaded.roots, index.roots)
        XCTAssertNil(LibraryIndex.loadCache(from: home.appendingPathComponent("missing.plist")))
    }

    // MARK: - Download sources

    func source(_ urls: [String], agent: String? = nil) -> String? { DownloadSources.source(urls: urls, agent: agent)?.id }

    func testKnownDownloadSources() {
        XCTAssertEqual(source(["https://mail-attachment.googleusercontent.com/attachment/u/0/?ui=2&ik=abc&attid=0.1&disp=safe",
                               "https://mail.google.com/mail/u/0/#inbox/FMfcgzQ"], agent: "Google Chrome"), "gmail")
        XCTAssertEqual(source(["https://mail-attachment.googleusercontent.com/attachment/u/0/?ui=2"]), "gmail",
                       "Gmail's attachment host, not Drive's googleusercontent.com")
        XCTAssertEqual(source(["https://drive.usercontent.google.com/download?id=1abc&export=download", "https://drive.google.com/"]), "drive")
        XCTAssertEqual(source(["https://doc-0k-2s-docs.googleusercontent.com/docs/securesc/abc/report.pdf"]), "drive")
        XCTAssertEqual(source(["https://files.oaiusercontent.com/file-AbC123?se=2026-10-18&sig=x", "https://chatgpt.com/c/68f1a2b3"]), "chatgpt")
        XCTAssertEqual(source(["https://files.oaiusercontent.com/file-AbC123"]), "chatgpt")
        XCTAssertEqual(source(["https://export-download.canva.com/DAF/design.png?X-Amz-Algorithm=AWS4", "https://www.canva.com/design/DAF/edit"]),
                       "canva")
        XCTAssertEqual(source(["https://pbs.twimg.com/media/GZx.jpg?format=jpg&name=large", "https://x.com/someone/status/1"]), "x")
        XCTAssertEqual(source(["https://pbs.twimg.com/media/GZx.jpg", "https://twitter.com/someone/status/1"]), "x")
        XCTAssertEqual(source([], agent: "Slack"), "slack", "Slack downloads straight to disk, with no URL")
        XCTAssertEqual(source([], agent: "slack"), "slack")
        XCTAssertEqual(source(["blob:https://web.whatsapp.com/5b7c2e0a-1111-2222-3333-444455556666"]), "whatsapp")
        XCTAssertEqual(source(["chrome-extension://abcdefghijklmnop/export.html"]), "extensions")
        XCTAssertEqual(source(["moz-extension://1234/page.html"]), "extensions")
        XCTAssertEqual(source(["message:%3C1234.5678@mail.example.com%3E"]), "mail")
        XCTAssertEqual(source([], agent: "Mail"), "mail")
        XCTAssertNil(source([], agent: "Safari"), "a browser says nothing about where from")
        XCTAssertNil(source([], agent: nil))
        XCTAssertNil(source(["file:///Users/me/a.pdf"]))
    }

    func testUnknownSitesUseThePageDomain() throws {
        let page = try XCTUnwrap(DownloadSources.source(urls: ["https://cdn.files-host.net/x/report.pdf", "https://www.example.co.uk/reports"],
                                                        agent: "Safari"))
        XCTAssertEqual(page, .site("example.co.uk"))
        XCTAssertEqual(page.id, "site:example.co.uk")
        XCTAssertEqual(page.domain, "example.co.uk")
        XCTAssertFalse(page.isKnown)
        XCTAssertEqual(source(["https://downloads.example.com/a.zip"]), "site:example.com", "the file's domain when there's no page")
        XCTAssertNil(DownloadSources.named("gmail")?.domain)

        let item = LibraryItem(path: "/Users/me/Downloads/a.pdf", kind: .document, bytes: 1, created: .now, modified: .now,
                               whereFrom: ["https://files.oaiusercontent.com/f", "https://chatgpt.com/c/1"], downloadedBy: "Safari")
        XCTAssertEqual(DownloadSources.source(of: item)?.name, "ChatGPT")
        XCTAssertNil(DownloadSources.source(of: LibraryItem(path: "/a.pdf", kind: .document, bytes: 1, created: .now, modified: .now)))
    }

    func testRegistrableDomain() {
        XCTAssertEqual(DownloadSources.registrableDomain("files.example.co.uk"), "example.co.uk")
        XCTAssertEqual(DownloadSources.registrableDomain("example.co.uk"), "example.co.uk")
        XCTAssertEqual(DownloadSources.registrableDomain("www.example.com"), "example.com")
        XCTAssertEqual(DownloadSources.registrableDomain("WWW.Example.COM"), "example.com")
        XCTAssertEqual(DownloadSources.registrableDomain("a.b.example.com"), "example.com")
        XCTAssertEqual(DownloadSources.registrableDomain("shop.example.com.au"), "example.com.au")
        XCTAssertEqual(DownloadSources.registrableDomain("example.com"), "example.com")
        XCTAssertEqual(DownloadSources.registrableDomain("192.168.1.20"), "192.168.1.20", "an IP address stays whole")
    }

    func testLookupByWord() {
        XCTAssertEqual(DownloadSources.lookup("twitter")?.id, "x")
        XCTAssertEqual(DownloadSources.lookup("  Twitter ")?.id, "x")
        XCTAssertEqual(DownloadSources.lookup("Google Drive")?.id, "drive")
        XCTAssertEqual(DownloadSources.lookup("gmail")?.id, "gmail")
        XCTAssertEqual(DownloadSources.lookup("youtube.com")?.id, "youtube")
        XCTAssertEqual(DownloadSources.lookup("example.com"), .site("example.com"))
        XCTAssertEqual(DownloadSources.lookup("www.example.co.uk"), .site("example.co.uk"))
        XCTAssertNil(DownloadSources.lookup(""))
        XCTAssertNil(DownloadSources.lookup("my holiday"))
        XCTAssertTrue(DownloadSources.isBrowser("Safari"))
        XCTAssertTrue(DownloadSources.isBrowser("google chrome"))
        XCTAssertFalse(DownloadSources.isBrowser("Slack"))
        XCTAssertEqual(Set(DownloadSources.all.map(\.id)).count, DownloadSources.all.count, "ids are unique")
    }

    /// Reading an iCloud-only file would download it: text recognition skips it and caches nothing,
    /// so it's read once the file is back on this Mac.
    func testTextRecognitionNeverReadsICloudOnlyFiles() throws {
        let url = try write("Desktop/Screenshot 2026-10-01.png")
        let d = Date(timeIntervalSince1970: 1_700_000_000)
        let item = LibraryItem(path: url.path, kind: .image, bytes: 1_000, created: d, modified: d)
        let text = TextIndex(url: home.appendingPathComponent("text.plist"))
        text.isDataless = { _ in true }
        XCTAssertEqual(text.text(for: item), "")
        text.index([item])
        XCTAssertNil(text.cached(item), "nothing read, nothing remembered")
        text.isDataless = { _ in false }
        _ = text.text(for: item)
        XCTAssertNotNil(text.cached(item), "read once it's local")
    }
}

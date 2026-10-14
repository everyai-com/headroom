import XCTest
@testable import HeadroomCore

/// Every test runs in its own temporary "home" — nothing here touches real files.
final class HeadroomCoreTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("headroom-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    @discardableResult
    func write(_ rel: String, bytes: Int = 64 * 1024) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    // MARK: - Walker

    func testHardLinksAreCountedOnceAndOnlyReclaimableWhenEveryLinkIsInside() throws {
        let store = try write("store/pkg.js", bytes: 1_000_000)
        try fm.createDirectory(at: home.appendingPathComponent("app/node_modules"), withIntermediateDirectories: true)
        try fm.linkItem(at: store, to: home.appendingPathComponent("app/node_modules/pkg.js"))
        try write("app/node_modules/own.js", bytes: 200_000)

        let modules = DiskWalker.measure(home.appendingPathComponent("app/node_modules"))
        XCTAssertGreaterThan(modules.allocated, 1_000_000, "the linked file is part of what's there")
        XCTAssertLessThan(modules.reclaimable, 400_000, "but deleting node_modules alone doesn't free the store's copy")

        let both = DiskWalker.measure([home.appendingPathComponent("app"), home.appendingPathComponent("store")])
        XCTAssertGreaterThan(both.reclaimable, 1_000_000, "with every link inside the set, it is freed")
        XCTAssertLessThan(both.allocated, 1_400_000, "and counted once, not twice")
    }

    // MARK: - Safety guard

    func finding(_ url: URL, safety: Safety = .safe, method: CleanupMethod = .delete, category: StorageCategory = .packageCaches) -> Finding {
        Finding(id: url.path, title: "t", subtitle: "", detail: "", category: category, safety: safety, paths: [url],
                method: method, symbol: "x")
    }

    func testGuardRefusesEverythingDangerous() throws {
        let guardrail = SafetyGuard(home: home)
        let cache = try write("Library/Caches/app/blob").deletingLastPathComponent()
        XCTAssertEqual(guardrail.check(cache, for: finding(cache)), .allowed)

        func refused(_ url: URL, _ f: Finding? = nil) -> Bool {
            if case .refused = guardrail.check(url, for: f ?? finding(url)) { return true }
            return false
        }
        XCTAssertTrue(refused(cache, finding(cache, safety: .keep)), "your data is never reclaimed")
        XCTAssertTrue(refused(cache, finding(cache, method: .none)), "keep-only findings are never reclaimed")
        XCTAssertTrue(refused(home), "home itself")
        XCTAssertTrue(refused(home.appendingPathComponent("Desktop")), "a top-level home folder")
        XCTAssertTrue(refused(home.appendingPathComponent("Library/Caches")), "the Caches folder itself (only its contents)")
        XCTAssertTrue(refused(URL(fileURLWithPath: "/Applications/Safari.app")), "outside home")
        XCTAssertTrue(refused(URL(fileURLWithPath: "/etc")), "outside home")
        XCTAssertTrue(refused(home.appendingPathComponent(".ssh/id_ed25519")), "credentials")
        XCTAssertTrue(refused(home.appendingPathComponent("Library/Mobile Documents/x")), "iCloud Drive")

        // A path that reaches outside through a symlink is refused, not followed.
        let outside = fm.temporaryDirectory.appendingPathComponent("headroom-outside-\(UUID().uuidString)")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: outside) }
        let link = home.appendingPathComponent("Library/Caches/link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertTrue(refused(link), "symlink escaping home")

        // Project artifacts must still be a recognised artifact folder.
        let src = try write("Desktop/shop/src/index.ts").deletingLastPathComponent()
        XCTAssertTrue(refused(src, finding(src, category: .projectArtifacts)), "source code is never an artifact")
    }

    // MARK: - Cleaner

    func testCleanerRemovesOnlyWhatItWasGiven() throws {
        let modules = try write("Desktop/shop/node_modules/react/index.js").deletingLastPathComponent().deletingLastPathComponent()
        let source = try write("Desktop/shop/src/app.ts")
        let cacheFile = try write("Library/Caches/com.app/data.bin")
        let cacheDir = cacheFile.deletingLastPathComponent() // ~/Library/Caches/com.app — emptied in place

        let cleaner = Cleaner(guardrail: SafetyGuard(home: home))
        let plan = [
            finding(modules, category: .projectArtifacts),
            finding(cacheDir, method: .deleteContents, category: .appCaches),
            finding(source, safety: .keep, method: .none, category: .userData),
        ]

        let dry = cleaner.reclaim(plan, dryRun: true)
        XCTAssertTrue(fm.fileExists(atPath: modules.path), "dry run touches nothing")
        XCTAssertEqual(dry.reclaimed.count, 2)

        let report = cleaner.reclaim(plan)
        XCTAssertFalse(fm.fileExists(atPath: modules.path), "node_modules removed")
        XCTAssertTrue(fm.fileExists(atPath: cacheDir.path), "the cache folder stays…")
        XCTAssertFalse(fm.fileExists(atPath: cacheFile.path), "…emptied")
        XCTAssertTrue(fm.fileExists(atPath: source.path), "your files are untouched")
        XCTAssertEqual(report.skipped.map(\.id), [source.path], "the keep item is reported as skipped")
    }

    // MARK: - Projects

    func testProjectScannerFindsArtifactsOnlyNextToTheirMarkers() async throws {
        try write("Desktop/shop/package.json", bytes: 100)
        try write("Desktop/shop/pnpm-lock.yaml", bytes: 100)
        try write("Desktop/shop/node_modules/a/index.js", bytes: 2_000_000)
        try write("Desktop/shop/node_modules/a/node_modules/b/x.js", bytes: 2_000_000) // nested: part of the parent
        try write("Desktop/notes/target/report.pdf", bytes: 2_000_000) // a folder named target, but no Cargo.toml
        try write("Desktop/rusty/Cargo.toml", bytes: 100)
        try write("Desktop/rusty/target/debug/app", bytes: 2_000_000)

        let found = await ProjectScanner.scan(roots: [home.appendingPathComponent("Desktop")])
        let paths = Set(found.map { $0.paths[0].lastPathComponent + "@" + ($0.project ?? "") })
        XCTAssertEqual(paths, ["node_modules@shop", "target@rusty"])
        let modules = try XCTUnwrap(found.first { $0.project == "shop" })
        XCTAssertEqual(modules.rebuild, "pnpm install")
        XCTAssertEqual(modules.safety, .review, "a project edited just now needs review, not one click")
        XCTAssertGreaterThan(modules.size.allocated, 3_900_000, "nested node_modules counted inside the parent")
    }

    func testStaleProjectsAreSafe() async throws {
        try write("Desktop/old/package.json", bytes: 100)
        try write("Desktop/old/node_modules/a.js", bytes: 2_000_000)
        let old = Date().addingTimeInterval(-30 * 86_400)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: home.appendingPathComponent("Desktop/old/package.json").path)
        let found = await ProjectScanner.scan(roots: [home.appendingPathComponent("Desktop")], staleDays: 7)
        XCTAssertEqual(found.first?.safety, .safe)
    }

    func testCaseInsensitiveDuplicateRootsCollapse() throws {
        try fm.createDirectory(at: home.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        let roots = ProjectScanner.uniqueFolders([home.appendingPathComponent("Projects"), home.appendingPathComponent("projects")])
        XCTAssertEqual(roots.count, 1)
    }

    // MARK: - Versioned caches

    func testOnlyOldBrowserVersionsAreOffered() throws {
        for name in ["chromium-1234", "chromium-1248", "chromium_headless_shell-1243", "chromium_headless_shell-1248", "ffmpeg-1013"] {
            try write("ms-playwright/\(name)/x")
        }
        let old = Catalog.oldVersions(in: home.appendingPathComponent("ms-playwright")).map(\.lastPathComponent)
        XCTAssertEqual(old, ["chromium-1234", "chromium_headless_shell-1243"])
    }

    // MARK: - Treemap

    func testTreemapTilesFillTheBoundsWithoutOverlap() {
        let values: [Double] = [50, 3, 20, 10, 10, 5, 2]
        let bounds = Treemap.Rect(x: 0, y: 0, width: 300, height: 200)
        let rects = Treemap.layout(values, in: bounds)
        XCTAssertEqual(rects.count, values.count)
        XCTAssertEqual(rects.reduce(0) { $0 + $1.area }, bounds.area, accuracy: 0.5)
        for (i, r) in rects.enumerated() {
            XCTAssertEqual(r.area / bounds.area, values[i] / values.reduce(0, +), accuracy: 0.001, "area ∝ value")
            XCTAssertGreaterThanOrEqual(r.x, -0.001); XCTAssertLessThanOrEqual(r.x + r.width, 300.001)
            for (j, o) in rects.enumerated() where j > i {
                let overlapW = min(r.x + r.width, o.x + o.width) - max(r.x, o.x)
                let overlapH = min(r.y + r.height, o.y + o.height) - max(r.y, o.y)
                XCTAssertFalse(overlapW > 0.01 && overlapH > 0.01, "tiles \(i) and \(j) overlap")
            }
        }
        let biggest = rects[0]
        XCTAssertLessThan(max(biggest.width / biggest.height, biggest.height / biggest.width), 3, "squarified, not slivers")
    }

    // MARK: - Apps

    func testLeftoversMatchByBundleIDNotLooseNames() throws {
        let lib = home.appendingPathComponent("Library")
        for rel in ["Application Support/com.vendor.Notes", "Application Support/Notes", "Application Support/NotesSync",
                    "Caches/com.vendor.Notes", "Containers/com.vendor.Notes", "Group Containers/ABCDE.com.vendor.Notes.shared",
                    "Saved Application State/com.vendor.Notes.savedState", "Caches/com.vendor.NotesPro"] {
            try fm.createDirectory(at: lib.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: lib.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
        try Data().write(to: lib.appendingPathComponent("Preferences/com.vendor.Notes.plist"))
        try Data().write(to: lib.appendingPathComponent("Preferences/com.vendor.NotesPro.plist"))

        let found = AppInventory.LibraryIndex(library: lib).leftovers(bundleID: "com.vendor.Notes", name: "Notes")
        let names = Set(found.map { $0.url.path.replacingOccurrences(of: lib.path + "/", with: "") })
        XCTAssertEqual(names, [
            "Application Support/com.vendor.Notes", "Application Support/Notes", "Caches/com.vendor.Notes",
            "Containers/com.vendor.Notes", "Group Containers/ABCDE.com.vendor.Notes.shared",
            "Saved Application State/com.vendor.Notes.savedState", "Preferences/com.vendor.Notes.plist",
        ], "exact bundle-ID matches and the app's own name only — never NotesSync or NotesPro")
    }
}

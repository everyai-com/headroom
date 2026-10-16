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
        // The disk is case-insensitive: a differently-cased path is the same protected folder.
        XCTAssertTrue(refused(home.appendingPathComponent("desktop")), "a top-level home folder, any case")
        XCTAssertTrue(refused(home.appendingPathComponent(".SSH/id_ed25519")), "credentials, any case")
        XCTAssertTrue(refused(home.appendingPathComponent("library/keychains/login.keychain-db")), "keychains, any case")

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

    func testMapPicksGoThroughTheSameGuard() throws {
        let guardrail = SafetyGuard(home: home)
        func verdict(_ url: URL, _ method: CleanupMethod = .trash) -> SafetyGuard.Verdict {
            guardrail.check(url, for: .picked(url, bytes: 1, method: method))
        }
        let movie = try write("Movies/old-render.mov")
        XCTAssertEqual(verdict(movie), .allowed, "your own file, your call — after a confirm")
        XCTAssertEqual(verdict(movie, .delete), .allowed)
        XCTAssertNotEqual(verdict(home.appendingPathComponent("Movies")), .allowed, "never a top-level folder")
        XCTAssertNotEqual(verdict(home.appendingPathComponent(".ssh/config")), .allowed)

        // Inside an app bundle: refused (uninstall the app instead). A cache folder merely
        // NAMED like an app is not a bundle and stays allowed.
        try write("Applications/Notes.app/Contents/Info.plist", bytes: 10)
        let resources = try write("Applications/Notes.app/Contents/Resources/big.bin")
        XCTAssertNotEqual(verdict(resources), .allowed)
        XCTAssertNotEqual(verdict(home.appendingPathComponent("Applications/Notes.app")), .allowed)
        let cache = try write("Library/Caches/com.vendor.app/blob").deletingLastPathComponent()
        XCTAssertEqual(verdict(cache, .deleteContents), .allowed)

        // Photo libraries under any name, anywhere.
        let photos = try write("Documents/Trip 2019.photoslibrary/originals/a.heic")
        XCTAssertNotEqual(verdict(photos), .allowed)
    }

    func testMapReflectsARemovalWithoutRescanning() {
        let deep = DiskNode(id: "/h/Movies/a/b", name: "b", bytes: 30, area: .media)
        let folder = DiskNode(id: "/h/Movies/a", name: "a", bytes: 50, area: .media, children: [deep])
        let group = DiskNode(id: "group:media", name: "Media", bytes: 80, area: .media,
                             children: [folder, DiskNode(id: "/h/Movies/c", name: "c", bytes: 30, area: .media)])
        let root = DiskNode(id: "root", name: "HD", bytes: 100, area: .other, children: [group])

        let gone = root.reflecting(removalOf: "/h/Movies/a/b", remaining: 0, freed: 30)
        XCTAssertEqual(gone?.bytes, 70)
        XCTAssertEqual(gone?.children[0].bytes, 50)
        XCTAssertEqual(gone?.children[0].children[0].bytes, 20)
        XCTAssertTrue(gone?.children[0].children[0].children.isEmpty == true, "the removed square is gone")

        // Emptied in place: the square stays with what's left.
        let emptied = root.reflecting(removalOf: "/h/Movies/c", remaining: 2, freed: 28)
        XCTAssertEqual(emptied?.children[0].children[1].bytes, 2)
        XCTAssertEqual(emptied?.bytes, 72)

        // A drill-down loaded outside the tree still shrinks its known ancestors.
        let outside = root.reflecting(removalOf: "/h/Movies/a/b/zzz", remaining: 0, freed: 5,
                                      ancestors: ["root", "group:media", "/h/Movies/a"])
        XCTAssertEqual(outside?.bytes, 95)
        XCTAssertEqual(outside?.children[0].children[0].bytes, 45)
        XCTAssertEqual(outside?.children[0].children[1].bytes, 30, "siblings untouched")
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

    func testPuppeteerVersionsCompareInFull() throws {
        for name in ["mac_arm-131.0.6778.85", "mac_arm-131.0.6778.108", "mac_arm-130.0.6723.58"] {
            try write("puppeteer/chrome/\(name)/x")
        }
        let old = Catalog.oldVersions(in: home.appendingPathComponent("puppeteer/chrome")).map(\.lastPathComponent)
        XCTAssertEqual(old, ["mac_arm-130.0.6723.58", "mac_arm-131.0.6778.85"], ".108 is newer than .85")
    }

    // MARK: - Stale verdicts

    func testOneClickDropsProjectsTouchedSinceTheScan() async throws {
        let manifest = try write("Desktop/old/package.json", bytes: 100)
        try write("Desktop/old/node_modules/a.js", bytes: 2_000_000)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-30 * 86_400)], ofItemAtPath: manifest.path)
        let found = await ProjectScanner.scan(roots: [home.appendingPathComponent("Desktop")], staleDays: 7)
        XCTAssertEqual(found.first?.safety, .safe)
        XCTAssertEqual(ProjectScanner.revalidated(found, staleDays: 7).first?.safety, .safe, "still untouched")

        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: manifest.path) // you opened it again
        XCTAssertEqual(ProjectScanner.revalidated(found, staleDays: 7).first?.safety, .review)
    }

    // MARK: - Shell

    func testShellTimesOutOnASilentTool() {
        let started = Date()
        XCTAssertNil(Shell.run("/bin/sleep", ["30"], timeout: 1))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the timeout fires even with no output")
        // stderr is never read, so a tool flooding it can't stall.
        XCTAssertEqual(Shell.run("/bin/sh", ["-c", "head -c 1000000 /dev/zero >&2; echo ok"], timeout: 20), "ok\n")
    }

    // MARK: - Dev tools

    func testDockerSizesParse() {
        XCTAssertEqual(DevTools.parseDockerSize("1.5GB (40%)"), 1_500_000_000)
        XCTAssertEqual(DevTools.parseDockerSize("512MB"), 512_000_000)
        XCTAssertEqual(DevTools.parseDockerSize("12.5kB"), 12_500)
        XCTAssertEqual(DevTools.parseDockerSize("0B"), 0)
        XCTAssertNil(DevTools.parseDockerSize("lots"))
        XCTAssertNil(DevTools.parseDockerSize("-5.11e+08B (-19%)"), "docker sometimes reports a negative; never trust it")
    }

    func testOnlyOlderToolchainVersionsAreOffered() throws {
        for v in ["v18.17.0", "v18.20.4", "v20.11.0", "v22.1.0"] { try write("nvm/\(v)/bin/node") }
        let old = DevTools.olderVersions(in: home.appendingPathComponent("nvm")) { _, v in "\(v[0])" }.map(\.lastPathComponent)
        XCTAssertEqual(old, ["v18.17.0"], "the newest of every major stays")

        for v in ["3.11.4", "3.11.9", "3.12.1", "myproject-env"] { try write("pyenv/\(v)/bin/python") }
        let py = DevTools.olderVersions(in: home.appendingPathComponent("pyenv")) { _, v in v.count >= 2 ? "\(v[0]).\(v[1])" : nil }
        XCTAssertEqual(py.map(\.lastPathComponent), ["3.11.4"], "named virtualenvs are never offered")
    }

    func testOldInstallersAreOnlyOldDiskImagesAndPackages() throws {
        let old = Date().addingTimeInterval(-60 * 86_400)
        for name in ["Slack.dmg", "tool.pkg", "notes.pdf"] {
            let url = try write("Downloads/\(name)", bytes: 6_000_000)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        try write("Downloads/fresh.dmg", bytes: 6_000_000)
        let f = try XCTUnwrap(DevTools.oldInstallers(home: home))
        XCTAssertEqual(Set(f.paths.map(\.lastPathComponent)), ["Slack.dmg", "tool.pkg"])
        XCTAssertEqual(f.method, .trash, "installers go to the Trash, never straight to deletion")
        XCTAssertEqual(SafetyGuard(home: home).check(f.paths[0], for: f), .allowed)
    }

    func testSimctlMayReachRuntimesButNothingElseMay() {
        let guardrail = SafetyGuard(home: home)
        let runtime = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes/iOS_23F77")
        let simctl = Finding(id: "rt", title: "", subtitle: "", detail: "", category: .developerTools, safety: .review,
                             paths: [runtime], method: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", "x"]),
                             symbol: "")
        XCTAssertEqual(guardrail.check(runtime, for: simctl), .allowed)
        XCTAssertNotEqual(guardrail.check(runtime, for: finding(runtime)), .allowed, "a plain delete of it is still refused")
        XCTAssertNotEqual(guardrail.check(runtime, for: finding(runtime, method: .command(executable: "/bin/rm", arguments: ["-rf"]))), .allowed)
    }

    func testSharedSimulatorCachesGoThroughSimctlOnly() {
        let guardrail = SafetyGuard(home: home)
        let caches = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches")
        let simctl = Finding(id: "sc", title: "", subtitle: "", detail: "", category: .developerTools, safety: .safe, paths: [caches],
                             method: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "dyld_shared_cache", "remove", "--all"]),
                             symbol: "")
        XCTAssertEqual(guardrail.check(caches, for: simctl), .allowed)
        XCTAssertNotEqual(guardrail.check(caches, for: finding(caches, method: .delete)), .allowed)
    }

    func testAFindingThatNamesNoPathsIsNeverRun() {
        let f = Finding(id: "x", title: "", subtitle: "", detail: "", category: .developerTools, safety: .safe, paths: [],
                        method: .command(executable: "/usr/bin/true", arguments: []), symbol: "")
        let report = Cleaner(guardrail: SafetyGuard(home: home)).reclaim([f])
        XCTAssertEqual(report.skipped.map(\.id), ["x"])
    }

    // MARK: - Never-touch list

    func testNeverTouchListIsEnforcedByTheGuardAndTheScan() throws {
        let project = home.appendingPathComponent("Desktop/keepme")
        let modules = try write("Desktop/keepme/node_modules/a.js").deletingLastPathComponent()
        let other = try write("Desktop/other/node_modules/a.js").deletingLastPathComponent()
        let guardrail = SafetyGuard(home: home, excluded: [project.path])
        XCTAssertNotEqual(guardrail.check(modules, for: finding(modules, category: .projectArtifacts)), .allowed, "inside an excluded folder")
        XCTAssertNotEqual(guardrail.check(home.appendingPathComponent("Desktop/KEEPME"), for: finding(project)), .allowed, "any case")
        XCTAssertNotEqual(guardrail.check(home.appendingPathComponent("Desktop/keepme/.."), for: finding(project)), .allowed)
        XCTAssertEqual(guardrail.check(other, for: finding(other, category: .projectArtifacts)), .allowed)

        let multi = Finding(id: "m", title: "", subtitle: "", detail: "", category: .appCaches, safety: .safe,
                            paths: [modules, other], method: .delete, symbol: "")
        let applied = Exclusions.apply([multi, finding(modules)], excluded: [project.path])
        XCTAssertEqual(applied.count, 1, "a finding entirely on the list disappears")
        XCTAssertEqual(applied.first?.paths, [other], "a mixed one keeps only what's allowed")
    }

    // MARK: - Activity & undo

    func testTrashedItemsCanBePutBack() throws {
        let file = try write("Movies/clip.mov")
        let logURL = home.appendingPathComponent("activity.json")
        let f = Finding.picked(file, bytes: 65_536, method: .trash)
        let report = Cleaner(guardrail: SafetyGuard(home: home)).reclaim([f])
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertEqual(report.trashed.count, 1, "the Trash location is recorded")

        var log = ActivityLog()
        for e in ActivityLog.entries(for: [f], report: report) { log.record(e, to: logURL) }
        let entry = try XCTUnwrap(ActivityLog.load(from: logURL).entries.first)
        XCTAssertEqual(entry.kind, .trashed)
        XCTAssertTrue(entry.canPutBack)
        XCTAssertEqual(ActivityLog.putBack(entry).restored, 1)
        XCTAssertTrue(fm.fileExists(atPath: file.path), "back where it was")
        XCTAssertFalse(entry.canPutBack)
    }

    func testTrashedCopiesCanBeDeletedForGoodButOnlyFromTheTrash() throws {
        let inTrash = try write(".Trash/clip.mov")
        let elsewhere = try write("Documents/notes.txt")
        let guardrail = SafetyGuard(home: home)
        let entry = ActivityLog.Entry(kind: .trashed, title: "clip.mov", bytes: 65_536, items: [
            .init(original: home.appendingPathComponent("Movies/clip.mov").path, inTrash: inTrash.path),
            // A log pointing outside the Trash must never delete what's there now.
            .init(original: home.appendingPathComponent("x").path, inTrash: elsewhere.path),
        ])
        XCTAssertTrue(entry.canDeleteFromTrash)
        let result = ActivityLog.deleteFromTrash(entry, guardrail: guardrail)
        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: inTrash.path), "gone for good")
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.path), "outside the Trash: untouched")
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertEqual(guardrail.check(home.appendingPathComponent(".Trash"), for: .picked(home.appendingPathComponent(".Trash"), bytes: 1, method: .delete)),
                       .refused("protected folder"), "the Trash folder itself is never removed")
    }

    func testExplainerNamesWhatThingsAreAndWhoOwnsThem() throws {
        let names = ["com.tinyspeck.slackmacgap": "Slack", "net.whatsapp.WhatsApp": "WhatsApp"]
        let lookup: (String) -> String? = { names[$0] }
        func explain(_ rel: String, dir: Bool = true) throws -> Explanation {
            let url = home.appendingPathComponent(rel)
            if dir { try fm.createDirectory(at: url, withIntermediateDirectories: true) } else { try write(rel) }
            return Explainer.explain(url, home: home, appName: lookup)
        }
        let cache = try explain("Library/Caches/com.tinyspeck.slackmacgap.ShipIt")
        XCTAssertEqual(cache.what, "Slack's cache")
        XCTAssertEqual(cache.verdict, .safe)
        XCTAssertEqual(cache.ownerBundleID, "com.tinyspeck.slackmacgap", "suffixed IDs resolve to the app")
        let group = try explain("Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
        XCTAssertEqual(group.what, "WhatsApp's shared data")
        XCTAssertEqual(group.verdict, .keep)
        XCTAssertEqual(try explain("Desktop/site/node_modules").verdict, .safe)
        XCTAssertEqual(try explain("Downloads/Figma.dmg", dir: false).what, "An installer")
        XCTAssertEqual(try explain("Movies/talk.mov", dir: false).verdict, .keep, "your videos are never called safe")
        XCTAssertTrue(try explain("Desktop/mystery.xyz", dir: false).isGuess)
    }

    // MARK: - Growth & big files

    func testGrowthNamesTheFolderThatGrew() {
        func map(_ claude: Int64, _ docs: Int64) -> DiskNode {
            DiskNode(id: "root", name: "HD", bytes: 0, area: .other, children: [
                DiskNode(id: "group:a", name: "Agents", bytes: claude, area: .agents, children: [
                    DiskNode(id: "/h/.claude", name: ".claude", url: URL(fileURLWithPath: "/h/.claude"), bytes: claude, area: .agents)]),
                DiskNode(id: "group:d", name: "Docs", bytes: docs, area: .documents, children: [
                    DiskNode(id: "/h/Documents/x", name: "x", url: URL(fileURLWithPath: "/h/Documents/x"), bytes: docs, area: .documents)]),
            ])
        }
        var history = GrowthHistory()
        let yesterday = Date().addingTimeInterval(-26 * 3600)
        history.record(map(1_000_000_000, 5_000_000_000), at: yesterday, to: nil)
        history.record(map(5_000_000_000, 4_000_000_000), to: nil)
        let base = try! XCTUnwrap(history.baseline(hoursBefore: 24))
        let changes = GrowthHistory.changes(from: base, to: history.snapshots.last!)
        XCTAssertEqual(changes.first?.id, "/h/.claude")
        XCTAssertEqual(changes.first?.delta, 4_000_000_000)
        XCTAssertEqual(changes.last?.delta, -1_000_000_000, "shrinking shows too")

        // Two maps minutes apart (a rescan) both stay, so "what grew" works right away.
        var recent = GrowthHistory()
        recent.record(map(1_000_000_000, 5_000_000_000), at: Date().addingTimeInterval(-300), to: nil)
        recent.record(map(3_000_000_000, 5_000_000_000), to: nil)
        XCTAssertEqual(recent.snapshots.count, 2)
        XCTAssertNotNil(recent.baseline(hoursBefore: 24), "falls back to the earlier map")
    }

    func testBigFilesAreCollectedWhileMeasuring() throws {
        try write("Movies/big.mov", bytes: 3_000_000)
        try write("Movies/small.mov", bytes: 10_000)
        try write("Library/Containers/x/disk.img", bytes: 3_000_000)
        let collector = BigFileCollector(threshold: 2_000_000, home: home)
        _ = DiskWalker.measure([home.appendingPathComponent("Movies"), home.appendingPathComponent("Library")], bigFiles: collector)
        XCTAssertEqual(collector.files.map(\.url.lastPathComponent), ["big.mov"], "app data in Library is never listed")

        try write("code/.git/objects/pack/pack-1.pack", bytes: 3_000_000)
        try write(".colima/_lima/_disks/colima/datadisk", bytes: 3_000_000)
        let more = BigFileCollector(threshold: 2_000_000, home: home)
        _ = DiskWalker.measure([home.appendingPathComponent("code"), home.appendingPathComponent(".colima")], bigFiles: more)
        XCTAssertTrue(more.files.isEmpty, "git history and live VM disks are never offered")
        let guardrail = SafetyGuard(home: home)
        for rel in ["code/.git/objects/pack/pack-1.pack", "code/.git", ".colima/_lima/_disks/colima/datadisk"] {
            let url = home.appendingPathComponent(rel)
            XCTAssertNotEqual(guardrail.check(url, for: .picked(url, bytes: 1, method: .trash)), .allowed, rel)
        }
        let colima = home.appendingPathComponent(".colima")
        let prune = finding(colima, method: .command(executable: "/opt/homebrew/bin/docker", arguments: ["builder", "prune", "-f"]))
        XCTAssertEqual(guardrail.check(colima, for: prune), .allowed, "docker's own prune still runs")
    }

    // MARK: - Updates

    func testVersionsCompareNumerically() {
        XCTAssertTrue(Updates.isNewer("0.10.0", than: "0.9.3"))
        XCTAssertTrue(Updates.isNewer("v1.2", than: "1.1.9"))
        XCTAssertTrue(Updates.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(Updates.isNewer("1.0", than: "1.0.0"), "equal is not newer")
        XCTAssertFalse(Updates.isNewer("0.2.0", than: "0.10.0"))
        XCTAssertFalse(Updates.isNewer("1.0.0-beta", than: "1.0.0"))
    }

    func testUpdateFeedIsReadAndOnlyNewerReleasesAreOffered() async throws {
        let feed = home.appendingPathComponent("update.json")
        try Data(#"{"version": "0.3.0", "url": "https://example.com/Headroom.zip", "notes": "Faster map", "minimumSystem": "15.0"}"#.utf8)
            .write(to: feed)
        let release = try await Updates.check(feed: feed, current: "0.2.0")
        XCTAssertEqual(release?.version, "0.3.0")
        XCTAssertEqual(release?.notes, "Faster map")
        let none = try await Updates.check(feed: feed, current: "0.3.0")
        XCTAssertNil(none, "already on it")
        try Data(#"{"version": "9.0.0", "url": "https://example.com/x.zip", "minimumSystem": "99.0"}"#.utf8).write(to: feed)
        let tooNew = try await Updates.check(feed: feed, current: "0.2.0")
        XCTAssertNil(tooNew, "never offer a release this Mac can't run")
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
                    "Saved Application State/com.vendor.Notes.savedState", "Caches/com.vendor.NotesPro",
                    "Group Containers/ABCDE.com.vendor.NotesPro.shared", "Group Containers/group.com.vendor.Notesy"] {
            try fm.createDirectory(at: lib.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: lib.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
        try Data().write(to: lib.appendingPathComponent("Preferences/com.vendor.Notes.plist"))
        try Data().write(to: lib.appendingPathComponent("Preferences/com.vendor.NotesPro.plist"))

        // Suffixed IDs are the app's own (updater cache, widget sandbox, helper prefs)…
        for rel in ["Caches/com.vendor.Notes.ShipIt", "Containers/com.vendor.Notes.widget", "Application Support/NotesKit",
                    "Caches/com.vendor.Notes.beta", "Application Support/Electron"] {
            try fm.createDirectory(at: lib.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        try Data().write(to: lib.appendingPathComponent("Preferences/com.vendor.Notes.helper.plist"))

        // …unless another installed app owns the longer ID (com.vendor.Notes.beta).
        let found = AppInventory.LibraryIndex(library: lib).leftovers(bundleID: "com.vendor.Notes", name: "Notes", executable: "NotesKit",
                                                                    otherBundleIDs: ["com.vendor.notes", "com.vendor.notes.beta"])
        let names = Set(found.map { $0.url.path.replacingOccurrences(of: lib.path + "/", with: "") })
        XCTAssertEqual(names, [
            "Application Support/com.vendor.Notes", "Application Support/Notes", "Caches/com.vendor.Notes",
            "Containers/com.vendor.Notes", "Group Containers/ABCDE.com.vendor.Notes.shared",
            "Saved Application State/com.vendor.Notes.savedState", "Preferences/com.vendor.Notes.plist",
            "Caches/com.vendor.Notes.ShipIt", "Containers/com.vendor.Notes.widget", "Application Support/NotesKit",
            "Preferences/com.vendor.Notes.helper.plist",
        ], "bundle ID (+ its own suffixes) and the app's exact names — never NotesSync, NotesPro, another app's .beta or a generic Electron")
        XCTAssertTrue(AppInventory.LibraryIndex(library: lib).leftovers(bundleID: "x.y", name: "Y", executable: "Electron")
            .allSatisfy { !$0.url.path.hasSuffix("/Electron") }, "generic executable names never match")
    }

    // MARK: - External drives

    func testDriveParsingFindsTheDiskLinkAndMount() {
        let ioreg = """
        +-o Portable SSD@00100000  <class IOUSBHostDevice>
          |   "USB Product Name" = "Portable SSD"
          |   "USB Vendor Name" = "SanDisk"
          |   "Device Speed" = 2
          |           |   "BSD Name" = "disk4"
          |           |   "Size" = 2000398934016
          |           |   "BSD Name" = "disk4s1"
          |           |   "Size" = 2000396836864
        +-o USB Receiver@00200000  <class IOUSBHostDevice>
          |   "USB Product Name" = "USB Receiver"
          |   "Device Speed" = 1
        """
        let checking = ExternalDrive.parse(ioreg: ioreg, mounts: [:], checking: true)
        XCTAssertEqual(checking.count, 1, "a keyboard receiver has no disk and is not a drive")
        let d = checking[0]
        XCTAssertEqual(d.title, "SanDisk Portable SSD")
        XCTAssertEqual(d.disk, "disk4")
        XCTAssertEqual(d.partition, "disk4s1")
        XCTAssertEqual(d.bytes, 2000398934016)
        XCTAssertEqual(d.link, .usb2)
        XCTAssertTrue(d.link.isBottleneck)
        XCTAssertTrue(d.macOSChecking)
        XCTAssertNotNil(d.readOnlyMountScript)

        let open = ExternalDrive.parse(ioreg: ioreg, mounts: ["disk4s1": (URL(fileURLWithPath: "/Volumes/SSD"), true)], checking: true)[0]
        XCTAssertEqual(open.mountPoint?.path, "/Volumes/SSD")
        XCTAssertTrue(open.readOnly)
        XCTAssertFalse(open.macOSChecking, "once mounted it's no longer waiting on the check")
    }

    func testDriveCopyIsCompleteResumableAndNeverTouchesTheSource() throws {
        try write("drive/Photos/a.jpg", bytes: 3_000_000)
        try write("drive/Photos/trip/b.mov", bytes: 5_000_000)
        try write("drive/Photos/._a.jpg", bytes: 4096)
        let source = home.appendingPathComponent("drive/Photos")
        let rescue = home.appendingPathComponent("rescue")
        let before = try fm.attributesOfItem(atPath: source.appendingPathComponent("a.jpg").path)[.modificationDate] as? Date

        var last: DriveCopier.Progress?
        DriveCopier(source: source, into: rescue).run { last = $0 }
        XCTAssertEqual(last?.finished, true)
        XCTAssertEqual(last?.total, 8_000_000, "AppleDouble ._ files are skipped")
        XCTAssertEqual(last?.failed, [])
        XCTAssertEqual(try Data(contentsOf: rescue.appendingPathComponent("Photos/trip/b.mov")).count, 5_000_000)
        XCTAssertFalse(fm.fileExists(atPath: rescue.appendingPathComponent("Photos/._a.jpg").path))
        XCTAssertFalse(fm.fileExists(atPath: rescue.appendingPathComponent("Photos/a.jpg.partial").path))

        // Interrupted earlier: one file cut short, plus a stale .partial. A re-run finishes the job.
        try Data(repeating: 1, count: 1000).write(to: rescue.appendingPathComponent("Photos/trip/b.mov"))
        try Data(repeating: 1, count: 10).write(to: rescue.appendingPathComponent("Photos/trip/b.mov.partial"))
        DriveCopier(source: source, into: rescue).run { last = $0 }
        XCTAssertEqual(last?.skipped, 1, "a.jpg was already whole")
        XCTAssertEqual(try Data(contentsOf: rescue.appendingPathComponent("Photos/trip/b.mov")).count, 5_000_000)
        XCTAssertFalse(fm.fileExists(atPath: rescue.appendingPathComponent("Photos/trip/b.mov.partial").path))

        XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("._a.jpg").path), "the drive is only read")
        let after = try fm.attributesOfItem(atPath: source.appendingPathComponent("a.jpg").path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }
}

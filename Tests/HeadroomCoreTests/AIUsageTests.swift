import XCTest
@testable import HeadroomCore

/// AI usage and device backups, each in a throwaway "home".
final class AIUsageTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("headroom-ai-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    @discardableResult
    func write(_ rel: String, bytes: Int = 64 * 1024, data: Data? = nil) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data ?? Data(repeating: 7, count: bytes)).write(to: url)
        return url
    }

    func testModelsAreListedOnePerModelAndNeverOneClick() async throws {
        try write(".cache/huggingface/hub/models--mlx-community--whisper-large/blobs/a", bytes: 2_000_000)
        try write(".cache/huggingface/hub/.locks/x")
        try write(".lmstudio/models/lmstudio-community/Qwen-7B-GGUF/q4.gguf", bytes: 1_000_000)
        let manifest = #"{"config":{"digest":"sha256:c"},"layers":[{"digest":"sha256:a"},{"digest":"sha256:b"}]}"#
        try write(".ollama/models/manifests/registry.ollama.ai/library/llama3/8b", data: Data(manifest.utf8))
        try write(".ollama/models/blobs/sha256-a", bytes: 3_000_000)
        try write(".ollama/models/blobs/sha256-b", bytes: 100_000)

        let tools = await AIUsage.scan(home: home, processes: [], servers: [])
        let hf = try XCTUnwrap(tools.first { $0.id == "huggingface" })
        XCTAssertEqual(hf.items.map(\.title), ["mlx-community/whisper-large"], "lock folders aren't models")
        XCTAssertEqual(tools.first { $0.id == "lmstudio" }?.items.map(\.title), ["lmstudio-community/Qwen-7B-GGUF"])

        let ollama = AIUsage.ollamaModels(home: home, ollama: "/opt/homebrew/bin/ollama")
        XCTAssertEqual(ollama.map(\.title), ["llama3:8b"])
        XCTAssertEqual(ollama.first?.method, .command(executable: "/opt/homebrew/bin/ollama", arguments: ["rm", "llama3:8b"]))
        XCTAssertGreaterThan(ollama.first?.size.allocated ?? 0, 3_000_000, "sized by the blobs its manifest names")
        XCTAssertEqual(AIUsage.ollamaModels(home: home, ollama: nil).first?.method, CleanupMethod.none, "no ollama command, no removal")

        let models = tools.flatMap(\.items) + ollama
        XCTAssertTrue(models.allSatisfy { $0.safety == .review }, "models are never one-click")
        let guardrail = SafetyGuard(home: home)
        for m in models where m.method != .none { XCTAssertEqual(guardrail.check(m.paths[0], for: m), .allowed, m.title) }
    }

    func testHistoryIsKeptAndCachesAreSafe() async throws {
        try write(".claude/projects/a/session.jsonl")
        try write("Library/Application Support/Claude/Cache/data_0")
        let tools = await AIUsage.scan(home: home, processes: [], servers: [])
        let claude = try XCTUnwrap(tools.first { $0.id == "claude" })
        let history = try XCTUnwrap(claude.items.first { $0.title.contains("history") })
        XCTAssertEqual(history.safety, .keep)
        XCTAssertNotEqual(SafetyGuard(home: home).check(history.paths[0], for: history), .allowed)
        XCTAssertEqual(claude.items.first { $0.title == "Claude app cache" }?.safety, .safe)
    }

    func testRunningToolsAndTheirServers() async {
        let ollama = ProcessInfoSnapshot(pid: 4242, parent: 1, name: "ollama", path: "/opt/homebrew/bin/ollama", uid: getuid(), footprint: 1, started: nil)
        let chat = ProcessInfoSnapshot(pid: 77, parent: 1, name: "chat", path: "/usr/local/bin/chat", uid: getuid(), footprint: 1, started: nil)
        let servers = AIUsage.parseLsof("p4242\ncollama\nn127.0.0.1:11434\nn127.0.0.1:11434\np900\ncnode\nn*:3000\n")
        XCTAssertEqual(servers.count, 2, "duplicate sockets collapse")
        XCTAssertEqual(servers.last?.exposed, true, "* means reachable from your network")
        let tools = await AIUsage.scan(home: home, processes: [ollama, chat], servers: servers)
        XCTAssertEqual(tools.map(\.id), ["ollama"], "a generic `chat` binary isn't GPT4All")
        XCTAssertEqual(tools.first?.servers.map(\.port), [11434])
    }

    func testDeviceBackupsAreNamedDatedAndOnlyEverTrashed() throws {
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Device Name": "Phani's iPhone", "Product Type": "iPhone15,2",
                                                                          "Last Backup Date": Date(timeIntervalSince1970: 1_600_000_000)],
                                                       format: .xml, options: 0)
        try write("Library/Application Support/MobileSync/Backup/00008110-ABC/Info.plist", data: plist)
        try write("Library/Application Support/MobileSync/Backup/00008110-ABC/Manifest.db", bytes: 500_000)
        let backups = Catalog.deviceBackups(home: home)
        let b = try XCTUnwrap(backups.first)
        XCTAssertEqual(b.title, "Phani's iPhone backup")
        XCTAssertEqual(b.safety, .review)
        XCTAssertEqual(b.method, .trash, "may be the only copy of a phone: recoverable only")
        XCTAssertTrue(b.detail.hasPrefix("Over six months old"))
        XCTAssertEqual(SafetyGuard(home: home).check(b.paths[0], for: b), .allowed)
        let root = home.appendingPathComponent("Library/Application Support/MobileSync/Backup")
        XCTAssertTrue(backups.allSatisfy { $0.paths[0] != root }, "never the Backup folder itself")
    }

    /// The Map builds its own picked findings: the guard alone must keep backups recoverable.
    func testTheGuardOnlyEverTrashesOneWholeDeviceBackup() throws {
        let manifest = try write("Library/Application Support/MobileSync/Backup/00008110-ABC/Manifest.db")
        let device = manifest.deletingLastPathComponent()
        let root = device.deletingLastPathComponent()
        let guardrail = SafetyGuard(home: home)
        XCTAssertEqual(guardrail.check(device, for: .picked(device, bytes: 1, method: .trash)), .allowed)
        for method in [CleanupMethod.delete, .deleteContents] {
            XCTAssertNotEqual(guardrail.check(device, for: .picked(device, bytes: 1, method: method)), .allowed, "never for good")
            XCTAssertNotEqual(guardrail.check(root, for: .picked(root, bytes: 1, method: method)), .allowed, "never emptied")
        }
        XCTAssertNotEqual(guardrail.check(root, for: .picked(root, bytes: 1, method: .trash)), .allowed, "never the Backup folder")
        let mobileSync = root.deletingLastPathComponent()
        XCTAssertNotEqual(guardrail.check(mobileSync, for: .picked(mobileSync, bytes: 1, method: .trash)), .allowed, "nor what holds it")
        XCTAssertNotEqual(guardrail.check(manifest, for: .picked(manifest, bytes: 1, method: .trash)), .allowed, "never a piece of one")
        let folded = URL(fileURLWithPath: device.path.replacingOccurrences(of: "MobileSync", with: "mobilesync"))
        XCTAssertNotEqual(guardrail.check(folded, for: .picked(folded, bytes: 1, method: .delete)), .allowed, "case-folded")
    }

    func testAnUninstalledAppInTheTrashCanBeDeletedForGoodButNothingElseOfAnApp() throws {
        try write(".Trash/Old.app/Contents/Info.plist")
        try write("Applications/Live.app/Contents/Info.plist")
        let guardrail = SafetyGuard(home: home)
        func pick(_ rel: String, _ method: CleanupMethod) -> (URL, Finding) {
            let url = home.appendingPathComponent(rel)
            return (url, .picked(url, bytes: 1, method: method))
        }
        let (bundle, delete) = pick(".Trash/Old.app", .delete)
        XCTAssertEqual(guardrail.check(bundle, for: delete), .allowed)
        let (inside, part) = pick(".Trash/Old.app/Contents", .delete)
        XCTAssertNotEqual(guardrail.check(inside, for: part), .allowed, "never a piece of an app")
        let (live, liveDelete) = pick("Applications/Live.app", .delete)
        XCTAssertNotEqual(guardrail.check(live, for: liveDelete), .allowed, "installed apps are uninstalled, not deleted")
        let (_, trash) = pick(".Trash/Old.app", .trash)
        XCTAssertNotEqual(guardrail.check(bundle, for: trash), .allowed)
    }

    func testCommandLinesAreDescribedInWords() {
        XCTAssertEqual(ProcessExplainer.plain(["node", "--no-warnings", "/Applications/job champ/web/node_modules/wrangler/wrangler-dist/cli.js", "dev", "--port", "8787"], kind: "JavaScript"),
                       "wrangler dev · web project · port 8787")
        XCTAssertEqual(ProcessExplainer.plain(["node", "/Users/me/shop/node_modules/@next/cli/bin.js"], kind: "JavaScript"), "cli · shop project")
        XCTAssertEqual(ProcessExplainer.plain(["python3", "-m", "http.server"], kind: "Python"), "Python: http.server")
    }
}

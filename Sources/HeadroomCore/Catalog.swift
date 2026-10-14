import Foundation

/// Every known space hog on a developer's Mac, with a safety verdict for each.
public enum Catalog {
    struct Rule {
        let id: String
        let title: String
        let paths: [String] // home-relative, or absolute when starting with "/"
        let category: StorageCategory
        let safety: Safety
        let method: CleanupMethod
        let detail: String
        let symbol: String
    }

    static let rules: [Rule] = [
        // Xcode & simulators
        Rule(id: "xcode-deriveddata", title: "Xcode build cache (DerivedData)", paths: ["Library/Developer/Xcode/DerivedData"],
             category: .developerTools, safety: .safe, method: .deleteContents,
             detail: "Rebuilt automatically the next time you build in Xcode.", symbol: "hammer.fill"),
        Rule(id: "xcode-devicesupport", title: "Xcode device support files",
             paths: ["Library/Developer/Xcode/iOS DeviceSupport", "Library/Developer/Xcode/watchOS DeviceSupport",
                     "Library/Developer/Xcode/tvOS DeviceSupport", "Library/Developer/Xcode/visionOS DeviceSupport"],
             category: .developerTools, safety: .safe, method: .deleteContents,
             detail: "Copied again from a device the next time you plug it in.", symbol: "iphone"),
        Rule(id: "simulator-caches", title: "Simulator caches",
             paths: ["Library/Developer/CoreSimulator/Caches", "/Library/Developer/CoreSimulator/Caches"],
             category: .developerTools, safety: .safe, method: .deleteContents,
             detail: "Shared simulator caches, rebuilt when a simulator next boots.", symbol: "iphone.gen3"),
        Rule(id: "xcode-archives", title: "Xcode archives", paths: ["Library/Developer/Xcode/Archives"],
             category: .developerTools, safety: .keep, method: .none,
             detail: "Builds you shipped, with their debug symbols. Keep unless you've backed them up.", symbol: "archivebox"),
        Rule(id: "simulator-devices", title: "Simulator devices & their app data", paths: ["Library/Developer/CoreSimulator/Devices"],
             category: .developerTools, safety: .review, method: .none,
             detail: "Each simulator's installed apps and data. Erase unused ones in Xcode → Devices and Simulators.", symbol: "iphone.gen3.radiowaves.left.and.right"),
        Rule(id: "simulator-runtimes", title: "Simulator runtimes (iOS, watchOS…)", paths: ["/Library/Developer/CoreSimulator/Volumes"],
             category: .developerTools, safety: .review, method: .none,
             detail: "Whole OS images for simulators. Remove versions you don't target in Xcode → Settings → Components.", symbol: "cpu"),

        // Package managers
        Rule(id: "npm-cache", title: "npm cache", paths: [".npm/_cacache"], category: .packageCaches, safety: .safe,
             method: .deleteContents, detail: "Downloaded package tarballs. npm fetches them again when needed.", symbol: "shippingbox"),
        Rule(id: "yarn-cache", title: "Yarn cache", paths: ["Library/Caches/Yarn"], category: .packageCaches, safety: .safe,
             method: .deleteContents, detail: "Downloaded packages. Yarn fetches them again when needed.", symbol: "shippingbox"),
        Rule(id: "bun-cache", title: "Bun cache", paths: [".bun/install/cache"], category: .packageCaches, safety: .safe,
             method: .deleteContents, detail: "Downloaded packages. Bun fetches them again when needed.", symbol: "shippingbox"),
        Rule(id: "pip-cache", title: "pip cache", paths: ["Library/Caches/pip"], category: .packageCaches, safety: .safe,
             method: .deleteContents, detail: "Downloaded Python wheels, fetched again when needed.", symbol: "shippingbox"),
        Rule(id: "uv-cache", title: "uv cache", paths: [".cache/uv"], category: .packageCaches, safety: .safe,
             method: .deleteContents, detail: "Downloaded Python packages, fetched again when needed.", symbol: "shippingbox"),
        Rule(id: "homebrew-cache", title: "Homebrew downloads", paths: ["Library/Caches/Homebrew"], category: .packageCaches,
             safety: .safe, method: .deleteContents, detail: "Installer downloads of formulae already installed.", symbol: "mug.fill"),
        Rule(id: "go-build", title: "Go build cache", paths: ["Library/Caches/go-build"], category: .packageCaches, safety: .safe,
             method: .deleteContents, detail: "Compiled Go packages, rebuilt on the next `go build`.", symbol: "shippingbox"),
        Rule(id: "cargo-registry", title: "Cargo registry cache", paths: [".cargo/registry/cache", ".cargo/registry/src"],
             category: .packageCaches, safety: .safe, method: .deleteContents,
             detail: "Downloaded crates, fetched again on the next build.", symbol: "shippingbox"),
        Rule(id: "gradle-cache", title: "Gradle caches", paths: [".gradle/caches"], category: .packageCaches, safety: .safe,
             method: .deleteContents, detail: "Downloaded dependencies and build caches, refetched on the next build.", symbol: "shippingbox"),
        Rule(id: "cocoapods-cache", title: "CocoaPods cache", paths: ["Library/Caches/CocoaPods"], category: .packageCaches,
             safety: .safe, method: .deleteContents, detail: "Downloaded pods, fetched again on `pod install`.", symbol: "shippingbox"),
        Rule(id: "electron-cache", title: "Electron downloads", paths: ["Library/Caches/electron"], category: .packageCaches,
             safety: .safe, method: .deleteContents, detail: "Electron binaries, downloaded again when a project needs them.", symbol: "bolt.fill"),
        Rule(id: "node-gyp", title: "node-gyp headers", paths: ["Library/Caches/node-gyp"], category: .packageCaches,
             safety: .safe, method: .deleteContents, detail: "Node headers for native modules, fetched again when needed.", symbol: "shippingbox"),
        Rule(id: "rustup-toolchains", title: "Rust toolchains", paths: [".rustup/toolchains"], category: .packageCaches,
             safety: .review, method: .none, detail: "Installed Rust compilers. Remove old ones with `rustup toolchain uninstall`.", symbol: "gearshape.2.fill"),
        Rule(id: "docker-disk", title: "Docker disk image", paths: ["Library/Containers/com.docker.docker/Data/vms"],
             category: .developerTools, safety: .review, method: .none,
             detail: "Images, containers and volumes. Reclaim with `docker system prune` (it asks before deleting).", symbol: "shippingbox.circle.fill"),

        // AI coding agents
        Rule(id: "claude-sessions", title: "Claude Code session history", paths: [".claude/projects"], category: .aiAgents,
             safety: .keep, method: .none, detail: "Your agent conversations, kept so you can resume them.", symbol: "sparkles"),
        Rule(id: "codex-sessions", title: "Codex session history", paths: [".codex/sessions"], category: .aiAgents,
             safety: .keep, method: .none, detail: "Your Codex conversations, kept so you can resume them.", symbol: "sparkles"),
        Rule(id: "cursor-cache", title: "Cursor caches",
             paths: ["Library/Application Support/Cursor/Cache", "Library/Application Support/Cursor/CachedData",
                     "Library/Application Support/Cursor/CachedExtensionVSIXs", "Library/Application Support/Cursor/Code Cache",
                     "Library/Application Support/Cursor/GPUCache", "Library/Application Support/Cursor/logs"],
             category: .aiAgents, safety: .safe, method: .deleteContents,
             detail: "Editor caches and logs. Cursor rebuilds them; your settings and extensions stay.", symbol: "cursorarrow.rays"),
        Rule(id: "vscode-cache", title: "VS Code caches",
             paths: ["Library/Application Support/Code/Cache", "Library/Application Support/Code/CachedData",
                     "Library/Application Support/Code/CachedExtensionVSIXs", "Library/Application Support/Code/Code Cache",
                     "Library/Application Support/Code/GPUCache", "Library/Application Support/Code/logs"],
             category: .aiAgents, safety: .safe, method: .deleteContents,
             detail: "Editor caches and logs. VS Code rebuilds them; your settings and extensions stay.", symbol: "chevron.left.forwardslash.chevron.right"),

        // Logs, Trash
        Rule(id: "user-logs", title: "Logs", paths: ["Library/Logs"], category: .logs, safety: .safe, method: .deleteContents,
             detail: "Diagnostic logs apps write. Nothing reads them back.", symbol: "doc.text.fill"),
        Rule(id: "trash", title: "Trash", paths: [".Trash"], category: .trash, safety: .review, method: .deleteContents,
             detail: "Emptying the Trash is permanent — look inside first.", symbol: "trash.fill"),

        // Your data — shown, never touched
        Rule(id: "downloads", title: "Downloads", paths: ["Downloads"], category: .userData, safety: .keep, method: .none,
             detail: "Installers and files you downloaded. Sort by size in Finder to find old ones.", symbol: "arrow.down.circle.fill"),
        Rule(id: "ios-backups", title: "iPhone & iPad backups", paths: ["Library/Application Support/MobileSync/Backup"],
             category: .userData, safety: .keep, method: .none,
             detail: "Device backups. Manage them in Finder → your device → Manage Backups.", symbol: "iphone.and.arrow.forward"),
        Rule(id: "whatsapp", title: "WhatsApp media", paths: ["Library/Group Containers/group.net.whatsapp.WhatsApp.shared"],
             category: .userData, safety: .keep, method: .none,
             detail: "Chats and media. Clear per chat in WhatsApp → Settings → Storage and Data → Manage Storage.", symbol: "bubble.left.and.bubble.right.fill"),
        Rule(id: "mail", title: "Mail", paths: ["Library/Mail"], category: .userData, safety: .keep, method: .none,
             detail: "Mailboxes and attachments.", symbol: "envelope.fill"),
        Rule(id: "messages", title: "Messages attachments", paths: ["Library/Messages/Attachments"], category: .userData,
             safety: .keep, method: .none, detail: "Photos and files from conversations. Remove in Messages → Settings → keep messages.", symbol: "message.fill"),
    ]

    static func resolve(_ path: String, home: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : home.appendingPathComponent(path)
    }

    /// Measure every catalog rule that exists on this Mac.
    public static func scanKnownLocations(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                                          isCancelled: @escaping @Sendable () -> Bool = { false }) async -> [Finding] {
        let fm = FileManager.default
        var findings: [Finding] = await withTaskGroup(of: Finding?.self) { group in
            for rule in rules {
                let urls = rule.paths.map { resolve($0, home: home) }.filter { fm.fileExists(atPath: $0.path) }
                guard !urls.isEmpty else { continue }
                group.addTask {
                    let size = DiskWalker.measure(urls, isCancelled: isCancelled)
                    guard size.allocated > 0 else { return nil }
                    return Finding(id: rule.id, title: rule.title, subtitle: urls.map(\.tildePath).joined(separator: ", "),
                                   detail: rule.detail, category: rule.category, safety: rule.safety, paths: urls, size: size,
                                   lastUsed: size.newestModification, method: rule.method, symbol: rule.symbol)
                }
            }
            var out: [Finding] = []
            for await f in group { if let f { out.append(f) } }
            return out
        }
        findings.append(contentsOf: await scanVersionedCaches(home: home))
        if let f = await remainingAppCaches(home: home, isCancelled: isCancelled) { findings.append(f) }
        if let f = await unavailableSimulators(home: home) { findings.append(f) }
        if let f = pnpmStore(home: home) { findings.append(f) }
        return findings.sorted { $0.size.allocated > $1.size.allocated }
    }

    /// Browser engines downloaded by Playwright/Puppeteer: every version but the newest per browser.
    static func scanVersionedCaches(home: URL) async -> [Finding] {
        let roots = [("playwright-old", "Old Playwright browsers", "Library/Caches/ms-playwright"),
                     ("puppeteer-old", "Old Puppeteer browsers", ".cache/puppeteer")]
        var out: [Finding] = []
        for (id, title, rel) in roots {
            let root = home.appendingPathComponent(rel)
            let old = oldVersions(in: root)
            guard !old.isEmpty else { continue }
            let size = DiskWalker.measure(old)
            out.append(Finding(id: id, title: title, subtitle: old.map(\.lastPathComponent).joined(separator: ", "),
                               detail: "Older browser builds. Your projects use the newest one, which is kept; any other version downloads again on demand.",
                               category: .browsers, safety: .safe, paths: old, size: size,
                               lastUsed: size.newestModification, method: .delete, symbol: "globe"))
        }
        return out
    }

    /// `chromium-1234`, `chromium-1248` → keep the highest number per family.
    public static func oldVersions(in root: URL) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        var families: [String: [(Int, String)]] = [:]
        for name in names where !name.hasPrefix(".") {
            // Puppeteer nests by browser: puppeteer/chrome/mac_arm-131.0…; Playwright is flat: chromium-1248.
            guard let dash = name.lastIndex(of: "-"), let num = Int(name[name.index(after: dash)...].prefix { $0.isNumber }) else { continue }
            families[String(name[..<dash]), default: []].append((num, name))
        }
        var old: [URL] = []
        for (_, versions) in families where versions.count > 1 {
            let sorted = versions.sorted { $0.0 > $1.0 }
            old.append(contentsOf: sorted.dropFirst().map { root.appendingPathComponent($0.1) })
        }
        return old.sorted { $0.path < $1.path }
    }

    /// Everything in ~/Library/Caches not already covered by a specific rule.
    static func remainingAppCaches(home: URL, isCancelled: @escaping @Sendable () -> Bool) async -> Finding? {
        let caches = home.appendingPathComponent("Library/Caches")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: caches.path) else { return nil }
        let covered: Set<String> = ["Yarn", "pip", "Homebrew", "go-build", "CocoaPods", "electron", "node-gyp", "ms-playwright"]
        let urls = names.filter { !covered.contains($0) && !$0.hasPrefix(".") }.map { caches.appendingPathComponent($0) }
        guard !urls.isEmpty else { return nil }
        let size = DiskWalker.measure(urls, isCancelled: isCancelled)
        guard size.allocated > 0 else { return nil }
        return Finding(id: "app-caches", title: "App caches", subtitle: "~/Library/Caches (\(urls.count) apps)",
                       detail: "Temporary data apps keep to load faster. Each app rebuilds its own cache — quit apps first for the best result.",
                       category: .appCaches, safety: .safe, paths: urls, size: size, lastUsed: size.newestModification,
                       method: .deleteContents, symbol: "square.stack.3d.up.fill")
    }

    /// Simulators whose runtime is gone — dead weight, removed by Xcode's own tool.
    static func unavailableSimulators(home: URL) async -> Finding? {
        guard let json = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "-j"]),
              let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = parsed["devices"] as? [String: [[String: Any]]] else { return nil }
        let udids = byRuntime.values.flatMap { $0 }.compactMap { $0["udid"] as? String }
        guard !udids.isEmpty else { return nil }
        let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
        let urls = udids.map { devices.appendingPathComponent($0) }
        let size = DiskWalker.measure(urls)
        return Finding(id: "simulators-unavailable", title: "Unavailable simulators",
                       subtitle: "\(udids.count) simulator(s) whose iOS version is no longer installed",
                       detail: "They can't boot anymore. Removed with Xcode's own `simctl delete unavailable`.",
                       category: .developerTools, safety: .safe, paths: urls, size: size,
                       method: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"]),
                       symbol: "iphone.slash")
    }

    /// The pnpm store: `pnpm store prune` removes only packages no project references.
    static func pnpmStore(home: URL) -> Finding? {
        let store = home.appendingPathComponent("Library/pnpm/store")
        guard FileManager.default.fileExists(atPath: store.path), let pnpm = Shell.which("pnpm") else { return nil }
        var size = DiskWalker.measure(store)
        // Prune frees an unknown share (unreferenced packages); never promise more than we can see.
        size.reclaimable = 0
        return Finding(id: "pnpm-store", title: "pnpm store (unreferenced packages)", subtitle: store.tildePath,
                       detail: "The shared package store. Pruning removes only packages no project uses — run it after clearing old node_modules.",
                       category: .packageCaches, safety: .safe, paths: [store], size: size,
                       method: .command(executable: pnpm, arguments: ["store", "prune"]), symbol: "shippingbox.fill")
    }
}

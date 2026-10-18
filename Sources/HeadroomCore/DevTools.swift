import Foundation

/// Space held by developer tools that need their own logic (not just "a folder"): Docker,
/// simulator runtimes and devices, old toolchain versions, Time Machine snapshots, installers.
public enum DevTools {
    public static func scan(home: URL = URL(fileURLWithPath: NSHomeDirectory())) async -> [Finding] {
        async let docker = dockerFindings(home: home)
        async let sims = simulatorFindings(home: home)
        var out = await docker + sims
        out += toolchainFindings(home: home)
        if let f = timeMachineSnapshots() { out.append(f) }
        if let f = oldInstallers(home: home) { out.append(f) }
        if let f = vmDiskBackups(home: home, health: { dockerDiskHealth() }) { out.append(f) }
        return out
    }

    // MARK: VM disk backups

    /// Is Docker's VM disk healthy right now? Docker must answer, and the VM's kernel must
    /// report no filesystem errors since it booted. nil reason = healthy.
    public static func dockerDiskHealth() -> String? {
        guard let docker = Shell.which("docker") else { return "Docker isn't installed or isn't on the PATH" }
        guard Shell.run(docker, ["system", "df"], timeout: 20) != nil else { return "Docker isn't answering — start it and rescan" }
        if let colima = Shell.which("colima"),
           let kernel = Shell.run(colima, ["ssh", "--", "sudo", "dmesg"], timeout: 20),
           let line = kernel.split(separator: "\n").first(where: { $0.contains("EXT4-fs error") || $0.contains("I/O error") }) {
            return "its disk reported errors since it started (\(line.suffix(80)))"
        }
        return nil
    }

    /// Copies of a VM's disk kept as a safety net (e.g. `~/.colima/backups/datadisk-….img`, made
    /// before repairing a damaged disk). Offered only once the live disk checks healthy, and only
    /// to the Trash — until then it's the only way back, so it's shown as your data.
    public static func vmDiskBackups(home: URL, health: () -> String?) -> Finding? {
        let dirs = BigFileCollector.vmHomes.map { home.appendingPathComponent($0).appendingPathComponent("backups") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let files = dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }.map { dir.appendingPathComponent($0) }
        }
        guard !files.isEmpty else { return nil }
        let size = DiskWalker.measure(files)
        guard size.allocated > 0 else { return nil }
        let problem = health()
        let when = size.newestModification.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? "a while ago"
        let common = "A copy of Docker's disk made \(when) as a safety net. Disk copies on APFS share unchanged blocks with the live disk, so removing it frees up to this much — the more Docker changed since, the more."
        if let problem {
            return Finding(id: "vm-disk-backups", title: "Docker disk backup (keep for now)", subtitle: files.map(\.tildePath).joined(separator: ", "),
                           detail: common + " Keep it: \(problem). It may be the only way back.",
                           category: .developerTools, safety: .keep, paths: files, size: size, lastUsed: size.newestModification,
                           method: .none, symbol: "externaldrive.badge.timemachine")
        }
        return Finding(id: "vm-disk-backups", title: "Docker disk backup", subtitle: files.map(\.tildePath).joined(separator: ", "),
                       detail: common + " Docker's disk checked healthy just now. If you keep databases in Docker, open them once first. It goes to the Trash — delete it for good from Activity to free the space.",
                       category: .developerTools, safety: .review, paths: files, size: size, lastUsed: size.newestModification,
                       method: .trash, symbol: "externaldrive.badge.timemachine")
    }

    // MARK: Docker

    /// "1.234GB", "512MB", "0B", "12.5kB" (docker prints SI units) → bytes.
    public static func parseDockerSize(_ text: String) -> Int64? {
        let s = text.split(separator: " ").first.map(String.init) ?? text
        guard let split = s.firstIndex(where: { !$0.isNumber && $0 != "." }), let value = Double(s[..<split]) else { return nil }
        let unit = s[split...].lowercased()
        let scale: Double = switch unit {
        case "b": 1
        case "kb": 1e3
        case "mb": 1e6
        case "gb": 1e9
        case "tb": 1e12
        default: -1
        }
        return scale < 0 ? nil : Int64(value * scale)
    }

    /// Where the Docker VM's disk lives, for the guard and for display.
    static func dockerHome(_ home: URL) -> URL? {
        ["Library/Containers/com.docker.docker", ".colima", ".orbstack", ".docker"]
            .map { home.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func dockerFindings(home: URL) async -> [Finding] {
        guard let docker = Shell.which("docker"), let dataDir = dockerHome(home),
              let out = Shell.run(docker, ["system", "df", "--format", "{{json .}}"], timeout: 20) else { return [] }
        var reclaimable: [String: Int64] = [:]
        for line in out.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["Type"] as? String, let r = obj["Reclaimable"] as? String,
                  let bytes = parseDockerSize(r) else { continue }
            reclaimable[type] = bytes
        }
        func finding(_ id: String, _ type: String, _ title: String, _ safety: Safety, _ args: [String]?, _ detail: String) -> Finding? {
            guard let bytes = reclaimable[type], bytes > 50_000_000 else { return nil }
            var size = DirectorySize()
            size.allocated = bytes
            size.reclaimable = bytes
            return Finding(id: id, title: title, subtitle: "docker · \(type.lowercased())", detail: detail,
                           category: .developerTools, safety: safety, paths: [dataDir], size: size,
                           method: args.map { .command(executable: docker, arguments: $0) } ?? .none,
                           symbol: "shippingbox.circle.fill")
        }
        return [
            finding("docker-build-cache", "Build Cache", "Docker build cache", .safe, ["builder", "prune", "-f"],
                    "Cached build layers. The next `docker build` recreates them (a little slower once)."),
            finding("docker-images", "Images", "Unused Docker images", .review, ["image", "prune", "-a", "-f"],
                    "Images no container uses. Pulled or rebuilt again when you need them — check you can rebuild private ones."),
            finding("docker-containers", "Containers", "Stopped Docker containers", .review, ["container", "prune", "-f"],
                    "Containers that aren't running. Anything written inside them (not in a volume) goes with them."),
            finding("docker-volumes", "Local Volumes", "Unused Docker volumes", .review, nil,
                    "Volumes no container uses — they often hold databases. Review with `docker volume ls`, then `docker volume rm`."),
        ].compactMap { $0 }
    }

    // MARK: Simulators

    static let isoDate: ISO8601DateFormatter = ISO8601DateFormatter()

    static func simulatorFindings(home: URL) async -> [Finding] {
        var out: [Finding] = []
        // Runtimes: whole OS images. Keep the newest per platform; older ones are for versions you may not target.
        if let json = Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"], timeout: 30),
           let runtimes = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: [String: Any]] {
            let byPlatform = Dictionary(grouping: runtimes.values) { $0["platformIdentifier"] as? String ?? "" }
            for (_, list) in byPlatform {
                let sorted = list.sorted { versionParts($0["version"] as? String ?? "").lexicographicallyPrecedes(versionParts($1["version"] as? String ?? "")) }
                for rt in sorted.dropLast() where rt["deletable"] as? Bool == true {
                    guard let id = rt["identifier"] as? String, let bytes = (rt["sizeBytes"] as? NSNumber)?.int64Value else { continue }
                    let version = rt["version"] as? String ?? "?"
                    let platform = (rt["runtimeIdentifier"] as? String)?.components(separatedBy: ".").last?.components(separatedBy: "-").first ?? "Simulator"
                    let mount = (rt["mountPath"] as? String).map(URL.init(fileURLWithPath:)) ?? URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes")
                    var size = DirectorySize()
                    size.allocated = bytes
                    size.reclaimable = bytes
                    let lastUsed = (rt["lastUsedAt"] as? String).flatMap(isoDate.date(from:))
                    out.append(Finding(id: "sim-runtime:" + id, title: "\(platform) \(version) simulator runtime",
                                       subtitle: "Older than the newest \(platform) runtime you have", detail:
                                        "A whole OS image. Delete it unless you test on \(platform) \(version); Xcode → Settings → Components downloads it again.",
                                       category: .developerTools, safety: .review, paths: [mount], size: size, lastUsed: lastUsed,
                                       method: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "runtime", "delete", id]),
                                       symbol: "cpu"))
                }
            }
        }
        // Devices not booted in 90 days: their installed apps and data.
        if let json = Shell.run("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 30),
           let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let byRuntime = parsed["devices"] as? [String: [[String: Any]]] {
            let cutoff = Date().addingTimeInterval(-90 * 86_400)
            let stale = byRuntime.values.flatMap { $0 }.filter { d in
                guard d["isAvailable"] as? Bool == true, d["state"] as? String == "Shutdown",
                      let booted = (d["lastBootedAt"] as? String).flatMap(isoDate.date(from:)) else { return false }
                return booted < cutoff
            }
            let devices = home.appendingPathComponent("Library/Developer/CoreSimulator/Devices")
            let udids = stale.compactMap { $0["udid"] as? String }
            let urls = udids.map { devices.appendingPathComponent($0) }
            let size = DiskWalker.measure(urls)
            if size.allocated > 100_000_000 {
                out.append(Finding(id: "simulators-unused", title: "Simulators unused for 90+ days",
                                   subtitle: stale.compactMap { $0["name"] as? String }.joined(separator: ", "),
                                   detail: "Each one's installed apps and data. Xcode recreates a device in seconds if you need it again.",
                                   category: .developerTools, safety: .review, paths: urls, size: size, lastUsed: size.newestModification,
                                   method: .command(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete"] + udids),
                                   symbol: "iphone.gen3"))
            }
        }
        return out
    }

    // MARK: Toolchains

    /// "v18.17.1" / "3.11.4" / "1.70.0" → [18, 17, 1]; non-numeric parts end the version.
    static func versionParts(_ s: String) -> [Int] {
        var parts: [Int] = []
        for p in s.drop(while: { !$0.isNumber }).split(separator: ".") {
            guard let n = Int(p.prefix { $0.isNumber }) else { break }
            parts.append(n)
            if p.contains(where: { !$0.isNumber }) { break }
        }
        return parts
    }

    /// Everything but the newest version in each family.
    public static func olderVersions(in dir: URL, family: (String, [Int]) -> String?) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var families: [String: [([Int], String)]] = [:]
        for name in names where !name.hasPrefix(".") {
            let v = versionParts(name)
            guard !v.isEmpty, let f = family(name, v) else { continue }
            families[f, default: []].append((v, name))
        }
        return families.values.flatMap { versions in
            versions.sorted { $0.0.lexicographicallyPrecedes($1.0) }.dropLast().map { dir.appendingPathComponent($0.1) }
        }.sorted { $0.path < $1.path }
    }

    static func toolchainFindings(home: URL) -> [Finding] {
        let byMajor: (String, [Int]) -> String? = { _, v in "\(v[0])" }
        let byMinor: (String, [Int]) -> String? = { _, v in v.count >= 2 ? "\(v[0]).\(v[1])" : nil }
        struct Source { let id, title, rel, detail, symbol: String; let family: (String, [Int]) -> String?; let safety: Safety }
        let sources = [
            Source(id: "nvm-old", title: "Older Node versions (nvm)", rel: ".nvm/versions/node",
                   detail: "Older patch releases of each Node major. The newest of each is kept; `nvm install` brings any back.",
                   symbol: "hexagon.fill", family: byMajor, safety: .review),
            Source(id: "fnm-old", title: "Older Node versions (fnm)", rel: ".local/share/fnm/node-versions",
                   detail: "Older patch releases of each Node major. The newest of each is kept; `fnm install` brings any back.",
                   symbol: "hexagon.fill", family: byMajor, safety: .review),
            Source(id: "fnm-old-as", title: "Older Node versions (fnm)", rel: "Library/Application Support/fnm/node-versions",
                   detail: "Older patch releases of each Node major. The newest of each is kept; `fnm install` brings any back.",
                   symbol: "hexagon.fill", family: byMajor, safety: .review),
            Source(id: "volta-old", title: "Older Node versions (Volta)", rel: ".volta/tools/image/node",
                   detail: "Older patch releases of each Node major. The newest of each is kept; Volta fetches pinned versions on demand.",
                   symbol: "hexagon.fill", family: byMajor, safety: .review),
            Source(id: "pyenv-old", title: "Older Python versions (pyenv)", rel: ".pyenv/versions",
                   detail: "Older patch releases of each Python minor, with packages installed into them. The newest of each is kept.",
                   symbol: "chevron.left.forwardslash.chevron.right", family: byMinor, safety: .review),
            Source(id: "gradle-wrapper-old", title: "Older Gradle distributions", rel: ".gradle/wrapper/dists",
                   detail: "Gradle versions downloaded by project wrappers. The newest is kept; `./gradlew` downloads any other on demand.",
                   symbol: "gearshape.2.fill", family: { name, _ in name.hasSuffix("-all") ? "all" : "bin" }, safety: .safe),
        ]
        var out: [Finding] = []
        for s in sources {
            let old = olderVersions(in: home.appendingPathComponent(s.rel), family: s.family)
            guard !old.isEmpty else { continue }
            let size = DiskWalker.measure(old)
            guard size.allocated > 50_000_000 else { continue }
            out.append(Finding(id: s.id, title: s.title, subtitle: old.map(\.lastPathComponent).joined(separator: ", "),
                               detail: s.detail, category: .packageCaches, safety: s.safety, paths: old, size: size,
                               lastUsed: size.newestModification, method: .delete, symbol: s.symbol))
        }
        // Rust: pinned (1.70.0-…) and dated nightly toolchains; the newest of each kind is kept,
        // channel toolchains (stable-…, beta-…, nightly-<triple>) are never offered.
        let toolchains = home.appendingPathComponent(".rustup/toolchains")
        let oldRust = olderVersions(in: toolchains) { name, _ in
            if name.first?.isNumber == true { return "pinned" }
            if name.hasPrefix("nightly-"), name.dropFirst(8).first?.isNumber == true { return "nightly" }
            return nil
        }
        if !oldRust.isEmpty, let rustup = Shell.which("rustup") {
            let size = DiskWalker.measure(oldRust)
            if size.allocated > 50_000_000 {
                out.append(Finding(id: "rustup-old", title: "Older Rust toolchains",
                                   subtitle: oldRust.map(\.lastPathComponent).joined(separator: ", "),
                                   detail: "Pinned and dated-nightly toolchains older than your newest. Projects pinning one reinstall it on the next build.",
                                   category: .packageCaches, safety: .review, paths: oldRust, size: size,
                                   method: .command(executable: rustup, arguments: ["toolchain", "uninstall"] + oldRust.map(\.lastPathComponent)),
                                   symbol: "gearshape.2.fill"))
            }
        }
        // Android system images: every API level but the newest.
        let images = home.appendingPathComponent("Library/Android/sdk/system-images")
        let oldImages = olderVersions(in: images) { name, _ in name.hasPrefix("android-") ? "android" : nil }
        if !oldImages.isEmpty {
            let size = DiskWalker.measure(oldImages)
            if size.allocated > 100_000_000 {
                out.append(Finding(id: "android-images-old", title: "Older Android system images",
                                   subtitle: oldImages.map(\.lastPathComponent).joined(separator: ", "),
                                   detail: "Emulator OS images for older API levels. Emulators built on them stop booting; Android Studio's SDK Manager downloads them again.",
                                   category: .developerTools, safety: .review, paths: oldImages, size: size,
                                   method: .delete, symbol: "apps.iphone"))
            }
        }
        return out
    }

    // MARK: Time Machine, installers

    /// Local snapshots: part of "System data". macOS doesn't report their size and frees them
    /// on its own when space runs low, so this explains rather than deletes.
    static func timeMachineSnapshots() -> Finding? {
        guard let out = Shell.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 15) else { return nil }
        let snaps = out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }
        guard !snaps.isEmpty else { return nil }
        return Finding(id: "tm-snapshots", title: "Time Machine local snapshots (\(snaps.count))",
                       subtitle: "Part of “System data” — macOS doesn't report their size",
                       detail: "Hourly backups kept on this disk. macOS deletes them by itself when space runs low. To remove them now: `sudo tmutil deletelocalsnapshots /`.",
                       category: .developerTools, safety: .review, paths: [], method: .none, symbol: "clock.arrow.circlepath")
    }

    /// Disk images, packages and archives in Downloads untouched for 30+ days — usually
    /// installers whose app is long installed.
    public static func oldInstallers(home: URL, olderThanDays days: Int = 30) -> Finding? {
        let downloads = home.appendingPathComponent("Downloads")
        let exts: Set<String> = ["dmg", "pkg", "mpkg", "zip", "xip", "iso"]
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let urls = ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? [])
            .map { downloads.appendingPathComponent($0) }
            .filter { url in
                guard exts.contains(url.pathExtension.lowercased()),
                      let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
                return mod < cutoff
            }
        guard !urls.isEmpty else { return nil }
        let size = DiskWalker.measure(urls)
        guard size.allocated > 10_000_000 else { return nil }
        return Finding(id: "old-installers", title: "Old installers in Downloads",
                       subtitle: "\(urls.count) disk images, packages and archives untouched for \(days)+ days",
                       detail: "Usually installers for apps you already have. They go to the Trash, so you can still get one back.",
                       category: .userData, safety: .review, paths: urls, size: size, lastUsed: size.newestModification,
                       method: .trash, symbol: "opticaldiscdrive.fill")
    }
}

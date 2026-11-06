import Foundation
import Darwin

/// The Mac's memory right now, as Activity Monitor counts it.
public struct MemoryStatus: Sendable, Equatable {
    public enum Pressure: Int, Sendable, Comparable {
        case normal = 1, warning = 2, critical = 4
        public static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self { case .normal: "Plenty free"; case .warning: "Getting tight"; case .critical: "Running out" }
        }
    }

    public var total: Int64
    /// Memory apps are using (minus what they've marked purgeable).
    public var app: Int64
    /// Kernel and drivers — can't be freed.
    public var wired: Int64
    /// Squeezed in RAM by macOS so more fits.
    public var compressed: Int64
    /// Copies of files kept around to make things fast; macOS drops them the moment an app needs room.
    public var cached: Int64
    public var free: Int64
    public var swapUsed: Int64
    public var swapTotal: Int64
    public var pressure: Pressure
    public var date = Date()

    /// What's actually spoken for: app + wired + compressed (Activity Monitor's "Memory Used").
    public var used: Int64 { app + wired + compressed }
    public var usedFraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }

    public static func current() -> MemoryStatus {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let page = Int64(vm_kernel_page_size)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)
        guard kr == KERN_SUCCESS else {
            return MemoryStatus(total: total, app: 0, wired: 0, compressed: 0, cached: 0, free: total,
                                swapUsed: Int64(swap.xsu_used), swapTotal: Int64(swap.xsu_total), pressure: Pressure(rawValue: Int(level)) ?? .normal)
        }
        let app = max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count)) * page
        let wired = Int64(stats.wire_count) * page
        let compressed = Int64(stats.compressor_page_count) * page
        let cached = (Int64(stats.external_page_count) + Int64(stats.purgeable_count)) * page
        let free = max(0, total - app - wired - compressed - cached)
        return MemoryStatus(total: total, app: app, wired: wired, compressed: compressed, cached: cached, free: free,
                            swapUsed: Int64(swap.xsu_used), swapTotal: Int64(swap.xsu_total),
                            pressure: Pressure(rawValue: Int(level)) ?? .normal)
    }
}

/// One running process and the memory it holds (its footprint — what Activity Monitor shows).
public struct ProcessInfoSnapshot: Sendable, Hashable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var parent: Int32
    public var name: String
    public var path: String?
    public var uid: uid_t
    public var footprint: Int64
    public var started: Date?
    /// The full command line, when it's yours to read ("node next dev").
    public var arguments: [String] = []

    /// The outermost `.app` the executable lives in, so Chrome Helper counts as Chrome.
    public var appBundle: String? {
        guard let path else { return nil }
        var prefix = ""
        for part in path.split(separator: "/") {
            prefix += "/" + part
            if part.hasSuffix(".app") { return prefix }
        }
        return nil
    }
}

/// Processes added up per app (all of Chrome's helpers as one Chrome), or one process on its own.
public struct MemoryGroup: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable { case app, developer, background, system }
    public var id: String
    public var name: String
    /// The app bundle, when it is one.
    public var bundlePath: String?
    public var kind: Kind
    public var processes: [ProcessInfoSnapshot]
    public var footprint: Int64 { processes.reduce(0) { $0 + $1.footprint } }
    public var mainPID: Int32 { processes.min { $0.pid < $1.pid }?.pid ?? 0 }
    public var oldestStart: Date? { processes.compactMap(\.started).min() }
}

public enum ProcessScanner {
    /// Every process you can see, with its memory. Others' processes (root, other users) can't be
    /// measured without admin rights and are left out — they're summed as "System" by the caller.
    public static func snapshot(includeArguments: Bool = true) -> [ProcessInfoSnapshot] {
        let me = getuid()
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        count = pids.withUnsafeMutableBufferPointer { proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size)) }
        var out: [ProcessInfoSnapshot] = []
        for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { continue }
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            let len = proc_pidpath(pid, &buf, UInt32(buf.count))
            let path = len > 0 ? String(cString: buf) : nil
            let name = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
                let s = String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                return s.isEmpty ? (path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "pid \(pid)") : s
            }
            var p = ProcessInfoSnapshot(pid: pid, parent: Int32(bsd.pbi_ppid), name: name, path: path, uid: bsd.pbi_uid,
                                        footprint: Int64(usage.ri_phys_footprint),
                                        started: bsd.pbi_start_tvsec > 0 ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)) : nil)
            if includeArguments, bsd.pbi_uid == me { p.arguments = arguments(of: pid) }
            out.append(p)
        }
        return out
    }

    /// argv of a process you own (KERN_PROCARGS2: argc, exec path, then the arguments).
    public static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return [] }
        let argc = data.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, data[i] != 0 { i += 1 }    // exec path
        while i < size, data[i] == 0 { i += 1 }    // padding
        var args: [String] = []
        var start = i
        while i < size, args.count < Int(argc) {
            if data[i] == 0 {
                args.append(String(decoding: data[start..<i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        return args
    }

    static let developerNames: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "java", "go", "cargo", "rustc",
                                              "next-server", "vite", "esbuild", "webpack", "tsserver", "swift-frontend",
                                              "sourcekit-lsp", "clangd", "rust-analyzer", "gopls", "postgres", "redis-server",
                                              "mongod", "mysqld", "qemu-system-aarch64", "limactl", "colima", "docker",
                                              "com.apple.Virtualization.VirtualMachine", "uvicorn", "gunicorn", "celery", "claude", "codex"]

    /// Group processes by app, everything else by process.
    public static func groups(_ processes: [ProcessInfoSnapshot], me: uid_t = getuid()) -> [MemoryGroup] {
        var byApp: [String: [ProcessInfoSnapshot]] = [:]
        var loose: [ProcessInfoSnapshot] = []
        for p in processes where p.footprint > 0 {
            if let app = p.appBundle, p.uid == me { byApp[app, default: []].append(p) } else { loose.append(p) }
        }
        var out: [MemoryGroup] = byApp.map { app, procs in
            let isSystem = app.hasPrefix("/System/")
            return MemoryGroup(id: app, name: URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent, bundlePath: app,
                               kind: isSystem ? .system : .app, processes: procs.sorted { $0.footprint > $1.footprint })
        }
        for p in loose {
            let kind: MemoryGroup.Kind
            if p.uid != me || ProcessGuard.isSystemPath(p.path) { kind = .system }
            else if developerNames.contains(p.name) || developerNames.contains(p.name.lowercased()) { kind = .developer }
            else { kind = .background }
            out.append(MemoryGroup(id: "pid:\(p.pid)", name: p.name, bundlePath: nil, kind: kind, processes: [p]))
        }
        return out.sorted { $0.footprint > $1.footprint }
    }
}

/// The only code that stops processes. Yours only, never macOS's own, never Headroom itself.
public enum ProcessGuard {
    /// Processes macOS needs to keep your session alive — quitting them logs you out or blanks the screen.
    static let essential: Set<String> = ["kernel_task", "launchd", "WindowServer", "loginwindow", "Dock", "Finder", "SystemUIServer",
                                         "ControlCenter", "NotificationCenter", "coreaudiod", "mds", "mds_stores", "mdworker",
                                         "cfprefsd", "distnoted", "UserEventAgent", "trustd", "securityd", "opendirectoryd",
                                         "corebrightnessd", "WallpaperAgent", "Spotlight", "TextInputMenuAgent", "universalaccessd"]

    public static func isSystemPath(_ path: String?) -> Bool {
        guard let path else { return true }
        return ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/", "/private/var/db/"].contains { path.hasPrefix($0) }
            && !path.hasPrefix("/usr/local/")
    }

    public enum Verdict: Equatable, Sendable { case allowed, refused(String) }

    public static func check(_ p: ProcessInfoSnapshot, me: uid_t = getuid(), selfPID: Int32 = getpid()) -> Verdict {
        if p.pid <= 1 { return .refused("part of macOS") }
        if p.pid == selfPID { return .refused("that's Headroom") }
        if p.uid != me { return .refused("runs as another user — part of macOS or another account") }
        if essential.contains(p.name) { return .refused("macOS needs it for your session") }
        if isSystemPath(p.path) { return .refused("part of macOS — it restarts on its own and frees nothing") }
        return .allowed
    }

    /// Ask a process to quit (SIGTERM — it can save and clean up), or end it now (SIGKILL).
    /// Re-checks the process first: a pid may have been reused since the snapshot.
    @discardableResult
    public static func stop(_ p: ProcessInfoSnapshot, force: Bool) -> Verdict {
        guard case .allowed = check(p) else { return check(p) }
        var bsd = proc_bsdinfo()
        guard proc_pidinfo(p.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return .allowed } // already gone
        let started = bsd.pbi_start_tvsec > 0 ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)) : nil
        if bsd.pbi_uid != getuid() || (p.started != nil && started != p.started) { return .refused("that process changed since the list was made") }
        return kill(p.pid, force ? SIGKILL : SIGTERM) == 0 ? .allowed : .refused(String(cString: strerror(errno)))
    }
}

/// What a process is, in plain words — so you know what quitting it does.
public enum ProcessExplainer {
    /// A command line in words: "wrangler dev · job champ project · port 8787", not the raw arguments.
    static func plain(_ argv: [String], kind: String) -> String {
        let args = Array(argv.dropFirst())
        // The script being run, and from it the tool (the package in node_modules) and the project around it.
        guard let script = args.first(where: { !$0.hasPrefix("-") && $0.contains("/") }) else {
            let words = args.filter { !$0.hasPrefix("-") }.prefix(3).joined(separator: " ")
            return words.isEmpty ? "\(kind) program." : "\(kind): \(words)"
        }
        let parts = script.split(separator: "/").map(String.init)
        var tool = URL(fileURLWithPath: script).deletingPathExtension().lastPathComponent
        var project: String?
        if let i = parts.lastIndex(of: "node_modules") {
            if i + 1 < parts.count { tool = parts[i + 1].hasPrefix("@") && i + 2 < parts.count ? parts[i + 2] : parts[i + 1] }
            if i > 0 { project = parts[i - 1] }
        } else if parts.count > 1 {
            project = parts[parts.count - 2]
        }
        let after = args.drop { $0 != script }.dropFirst()
        let command = after.prefix { !$0.hasPrefix("-") }.prefix(2).joined(separator: " ")
        var port: String?
        if let i = after.firstIndex(where: { $0 == "--port" || $0 == "-p" }), after.index(after: i) < after.endIndex { port = after[after.index(after: i)] }
        else if let p = after.first(where: { $0.hasPrefix("--port=") }) { port = String(p.dropFirst(7)) }
        var out = [command.isEmpty ? tool : "\(tool) \(command)"]
        if let project, !["bin", "dist", "lib", "src", "build"].contains(project) { out.append("\(project) project") }
        if let port { out.append("port \(port)") }
        return out.joined(separator: " · ")
    }

    public static func explain(_ g: MemoryGroup) -> String {
        let p = g.processes.first
        let args = p?.arguments.dropFirst().joined(separator: " ") ?? ""
        switch g.name {
        case "kernel_task": return "The core of macOS. Also holds memory back to cool the Mac down when it's hot."
        case "WindowServer": return "Draws everything on your screen. More displays and windows mean more memory."
        case "mds_stores", "mds", "mdworker", "mdworker_shared": return "Spotlight indexing your files. Busy after big changes, then settles."
        case "photoanalysisd", "mediaanalysisd": return "Photos analysing your library for faces and search. Settles when done."
        case "com.apple.Virtualization.VirtualMachine", "qemu-system-aarch64":
            return "A virtual machine — usually Docker, OrbStack, Colima or a VM app. Holds its memory until you stop it."
        case "Simulator": return "The iOS Simulator. Each booted device holds memory; quit it when you're not testing."
        case "node", "bun", "deno":
            return args.isEmpty ? "A JavaScript program — a dev server, build or tool an agent started." : plain(p?.arguments ?? [], kind: "JavaScript")
        case "python", "python3": return args.isEmpty ? "A Python program." : plain(p?.arguments ?? [], kind: "Python")
        case "next-server": return "A Next.js dev server. Restarts with `next dev`."
        case "tsserver": return "TypeScript language server for your editor. Restarts on its own."
        case "sourcekit-lsp", "swift-frontend": return "Swift tooling for your editor or a build."
        case "claude", "codex": return "An AI coding agent session. Quitting ends that session."
        default: break
        }
        switch g.kind {
        case .app:
            return g.processes.count > 1 ? "\(g.name), counting each of its open tabs, windows and extensions."
                : "The \(g.name) app."
        case .developer: return args.isEmpty ? "A developer tool or server." : plain(p?.arguments ?? [], kind: "Developer tool")
        case .system: return "Part of macOS. It manages its own memory."
        case .background: return args.isEmpty ? "Something running in the background — started by you or an app." : plain(p?.arguments ?? [], kind: "Background program")
        }
    }
}

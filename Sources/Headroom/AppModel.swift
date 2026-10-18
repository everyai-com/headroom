import SwiftUI
import HeadroomCore

/// Everything the UI shows, and every action it can take. One instance, shared by the
/// notch, the menu bar and the main window.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case idle, scanning(String), reclaiming(String), done(Int64) }

    @Published var volume = VolumeStatus.current()
    @Published var findings: [Finding] = []
    @Published var selected: Set<String> = []
    @Published var apps: [InstalledApp] = []
    @Published var selectedApps: Set<String> = []
    @Published var map: DiskNode?
    @Published var mapProgress: DiskMap.Progress?
    @Published var phase: Phase = .idle
    @Published var appsPhase: Phase = .idle
    @Published var lastScan: Date?
    @Published var lastReport: CleanupReport?
    @Published var history = History.load()
    @Published var activity = ActivityLog.load()
    @Published var growth = GrowthHistory.load()
    @Published var bigFiles: [BigFile] = []
    @Published var hasFullDiskAccess = AppModel.checkFullDiskAccess()
    /// Your never-touch list (paths). The guard enforces it; scans hide what's on it.
    @Published var excluded: [String] = UserDefaults.standard.stringArray(forKey: "neverTouch") ?? [] {
        didSet { UserDefaults.standard.set(excluded, forKey: "neverTouch") }
    }

    @AppStorage("lowSpaceThresholdGB") var lowSpaceThresholdGB: Double = 15
    @AppStorage("staleDays") var staleDays: Int = 7
    @AppStorage("notificationsEnabled") var notificationsEnabled = true
    @AppStorage("showNotch") var showNotch = true
    @AppStorage("autoReclaim") var autoReclaim = false
    /// The banner at the bottom of the window after an action — with Undo when it can be put back.
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var message: String
        var failed = false
        var undo: ActivityLog.Entry.ID?
    }
    @Published var toast: Toast?

    /// Failures land in Application Support/Headroom/problems.log too — a toast is gone in seconds.
    static func logProblem(_ message: String) {
        let url = URL(fileURLWithPath: HeadroomPaths.home).appendingPathComponent("Library/Application Support/Headroom/problems.log")
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }

    func show(_ message: String, failed: Bool = false, undo: ActivityLog.Entry.ID? = nil) {
        var message = message
        // Without Full Disk Access macOS blocks the Trash and other apps' data — say so instead of a vague failure.
        let blocked = ["permission", "not permitted", "skipped", "couldn't"].contains { message.lowercased().contains($0) }
        if blocked, Edition.appStore {
            // Sandboxed: Full Disk Access doesn't apply; folders open when you choose them.
            message += " — Headroom can only open folders you've given it. Choose your home folder on Home, or the folder when asked."
        } else if blocked || failed {
            hasFullDiskAccess = Self.checkFullDiskAccess()
            if !hasFullDiskAccess {
                message += " — Headroom needs Full Disk Access for this: System Settings → Privacy & Security → Full Disk Access → turn on Headroom"
            }
        }
        if blocked || failed { Self.logProblem(message) }
        let t = Toast(message: message, failed: failed, undo: undo)
        toast = t
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(undo == nil ? 4 : 8))
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    func undo(_ toast: Toast) {
        self.toast = nil
        guard let id = toast.undo, let entry = activity.entries.first(where: { $0.id == id }) else { return }
        show(putBack(entry))
    }

    /// A newer release from the update feed, when there is one.
    @Published var update: Updates.Release?
    @Published var updateStatus: String?

    /// `--demo` (for recording): projects and personal files are limited to what
    /// scripts/demo-seed.sh made, so your real projects and documents never appear on camera.
    static let demoMode = CommandLine.arguments.contains("--demo")
    static let demoRoot = ProcessInfo.processInfo.environment["HEADROOM_DEMO_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? URL(fileURLWithPath: HeadroomPaths.home).appendingPathComponent("Desktop/headroom-demo")

    static func isDemoPath(_ url: URL) -> Bool {
        let p = url.path
        return p.hasPrefix(demoRoot.path + "/") || url.lastPathComponent.contains("-demo")
    }

    // MARK: Derived

    var safeFindings: [Finding] { findings.filter { $0.safety == .safe && $0.reclaimable > 0 } }
    var safeReclaimable: Int64 { safeFindings.reduce(0) { $0 + $1.reclaimable } }
    var reviewReclaimable: Int64 { findings.filter { $0.safety == .review }.reduce(0) { $0 + $1.reclaimable } }
    var selectedFindings: [Finding] { findings.filter { selected.contains($0.id) } }
    var selectedBytes: Int64 { selectedFindings.reduce(0) { $0 + $1.reclaimable } }
    var safetyByPath: [String: Safety] {
        var out: [String: Safety] = [:]
        for f in findings { for p in f.paths { out[p.path] = f.safety } }
        return out
    }
    /// Every removal goes through this: the standard rules plus your never-touch list.
    var guardrail: SafetyGuard { SafetyGuard(excluded: excluded) }
    var isBusy: Bool {
        if case .idle = phase { return false }
        if case .done = phase { return false }
        return true
    }

    // MARK: Scans

    func refreshVolume() {
        volume = .current()
        hasFullDiskAccess = Self.checkFullDiskAccess()
    }

    /// macOS gives no API for this; the TCC database opens only with Full Disk Access.
    nonisolated static func checkFullDiskAccess() -> Bool {
        FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") != nil
    }

    /// The reclaim scan: known locations + every project's build output (~20 s).
    func scan() async {
        guard !isBusy else { return }
        phase = .scanning("Looking for space you can safely get back…")
        let stale = staleDays
        let excluded = self.excluded
        let roots = Self.demoMode ? [Self.demoRoot] : ProjectScanner.defaultRoots()
        async let projects = ProjectScanner.scan(roots: roots, staleDays: stale)
        async let known = Catalog.scanKnownLocations()
        let found = await projects + known
        var all = await Task.detached { Exclusions.apply(found, excluded: excluded) }.value
            .sorted { $0.size.allocated > $1.size.allocated }
        if Self.demoMode {
            // Personal files (installers in Downloads…) only when they're the demo's own.
            all = all.compactMap { f in
                guard f.category == .userData, f.method != .none else { return f }
                var d = f
                d.paths = f.paths.filter(Self.isDemoPath)
                guard !d.paths.isEmpty else { return nil }
                d.size = DiskWalker.measure(d.paths)
                d.subtitle = "\(d.paths.count) disk image untouched for 30+ days"
                return d
            }
        }
        // The App Store edition can't run other tools (simctl, docker, brew…): those findings stay out.
        if Edition.appStore { all.removeAll { if case .command = $0.method { true } else { false } } }
        findings = all
        // Safe items are pre-selected; review items wait for you.
        selected = Set(all.filter { $0.safety == .safe && $0.reclaimable > 0 }.map(\.id))
        lastScan = .now
        refreshVolume()
        history.record(volume: volume, safe: safeReclaimable)
        phase = .idle
    }

    /// Every GB, by area. Slower (walks the whole disk), so it runs on its own.
    func buildMap() async {
        mapProgress = DiskMap.Progress(done: 0, total: 1, current: "")
        let safety = safetyByPath
        let volume = self.volume
        let collector = BigFileCollector(threshold: 100_000_000)
        let root = await DiskMap.build(volume: volume, safetyByPath: safety, bigFiles: collector, progress: { p in
            Task { @MainActor [weak self] in self?.mapProgress = p }
        })
        map = root
        bigFiles = collector.files.filter { !Self.demoMode || Self.isDemoPath($0.url) }
        mapProgress = nil
        growth.record(root)
    }

    func scanApps() async {
        appsPhase = .scanning("Measuring apps and their data…")
        apps = await AppInventory.scan()
        appsPhase = .idle
    }

    // MARK: Actions

    /// Reclaim the selection. With `safeOnly`, exactly the safe set — the one-click path.
    @discardableResult
    func reclaim(safeOnly: Bool = false, automatic: Bool = false) async -> (report: CleanupReport, plan: [Finding])? {
        guard !isBusy else { return nil }
        // One click never acts on a stale verdict: drop projects you've touched since the scan.
        let plan = safeOnly
            ? ProjectScanner.revalidated(safeFindings, staleDays: staleDays).filter { $0.safety == .safe }
            : selectedFindings
        guard !plan.isEmpty else { return nil }
        phase = .reclaiming("Freeing up \(plan.reduce(0) { $0 + $1.reclaimable }.gb)…")
        let guardrail = self.guardrail
        let report = await Task.detached(priority: .userInitiated) {
            Cleaner(guardrail: guardrail).reclaim(plan)
        }.value
        lastReport = report
        for entry in ActivityLog.entries(for: plan, report: report, automatic: automatic) { activity.record(entry) }
        phase = .done(report.freedBytes)
        refreshVolume()
        history.record(volume: volume, safe: 0, freed: report.freedBytes)
        // Say what happened — a reclaim that skipped everything must not look like a no-op.
        if !automatic {
            let names = Dictionary(plan.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            if let skip = report.skipped.first {
                let what = names[skip.id] ?? skip.id
                show((report.reclaimed.isEmpty ? "Couldn't free up space" : "Freed \(report.freedBytes.gb) · \(report.skipped.count) skipped")
                     + " — \(what): \(skip.reason)", failed: report.reclaimed.isEmpty)
            } else {
                show("Freed \(report.freedBytes.gb) from \(report.reclaimed.count) item\(report.reclaimed.count == 1 ? "" : "s")")
            }
        }
        // Rescan quietly so the lists reflect reality.
        try? await Task.sleep(for: .seconds(1.5))
        phase = .idle
        await scan()
        if map != nil { await buildMap() }
        return (report, plan)
    }

    // MARK: Growth, activity, never-touch

    /// What grew (or shrank) since about `hours` ago, by folder.
    func growthChanges(overHours hours: Double = 24) -> [GrowthHistory.Change] {
        guard let map, let base = growth.baseline(hoursBefore: hours) else { return [] }
        return GrowthHistory.changes(from: base, to: GrowthHistory.snapshot(of: map))
    }

    func putBack(_ entry: ActivityLog.Entry) -> String {
        let result = ActivityLog.putBack(entry)
        if let i = activity.entries.firstIndex(where: { $0.id == entry.id }), result.restored > 0 {
            activity.entries[i].restored = true
            activity.save()
        }
        refreshVolume()
        Task { await scan() }
        if let fail = result.failed.first { return "Put back \(result.restored); \(fail)" }
        return "Put back \(entry.title)"
    }

    /// Space still held by things Headroom moved to the Trash.
    var waitingInTrash: (entries: [ActivityLog.Entry], bytes: Int64) {
        let list = activity.entries.filter(\.canDeleteFromTrash)
        return (list, list.reduce(0) { $0 + $1.bytes })
    }

    /// Finish off what an entry moved to the Trash: deleted for good, so the space comes back.
    func deleteFromTrash(_ entries: [ActivityLog.Entry]) async -> String {
        let guardrail = self.guardrail
        let results = await Task.detached(priority: .userInitiated) {
            entries.map { ($0.id, ActivityLog.deleteFromTrash($0, guardrail: guardrail)) }
        }.value
        var freed: Int64 = 0
        var failures: [String] = []
        for (id, r) in results {
            freed += r.freed
            failures += r.failed
            if r.removed > 0, let i = activity.entries.firstIndex(where: { $0.id == id }) { activity.entries[i].purgedAt = .now }
        }
        activity.save()
        refreshVolume()
        if freed > 0 { history.record(volume: volume, safe: safeReclaimable, freed: freed) }
        if let fail = failures.first { return "Freed \(freed.gb) · couldn't remove \(failures.count): \(fail)" }
        return entries.count == 1 ? "Deleted \(entries[0].title) for good — freed \(freed.gb)" : "Emptied \(entries.count) items from the Trash — freed \(freed.gb)"
    }

    /// Trash (or delete) several large files in one go, as one Activity entry you can put back.
    func remove(_ files: [BigFile], permanently: Bool) async -> (message: String, removed: Set<String>, undo: ActivityLog.Entry.ID?) {
        await removeFiles(files.map { ($0.url, $0.bytes) }, permanently: permanently, label: "large files")
    }

    /// Move files to the Trash as one Activity entry you can put back (the library, duplicates, clean-up cards).
    func trashFiles(_ files: [(url: URL, bytes: Int64)], label: String? = nil) async -> (message: String, removed: Set<String>, undo: ActivityLog.Entry.ID?) {
        await removeFiles(files, permanently: false, label: label ?? "files")
    }

    func removeFiles(_ files: [(url: URL, bytes: Int64)], permanently: Bool, label: String) async
        -> (message: String, removed: Set<String>, undo: ActivityLog.Entry.ID?) {
        let plan = files.map { Finding.picked($0.url, bytes: $0.bytes, method: permanently ? .delete : .trash) }
        guard !plan.isEmpty else { return ("Nothing selected", [], nil) }
        let guardrail = self.guardrail
        let report = await Task.detached(priority: .userInitiated) { Cleaner(guardrail: guardrail).reclaim(plan) }.value
        let done = plan.filter { report.reclaimed.contains($0.id) }
        let bytes = done.reduce(0) { $0 + $1.reclaimable }
        var undo: ActivityLog.Entry.ID?
        if !done.isEmpty {
            let entry: ActivityLog.Entry
            if done.count == 1, let one = ActivityLog.entries(for: done, report: report).first {
                entry = one
            } else {
                let landed = Dictionary(report.trashed.map { ($0.original.path, $0.inTrash.path) }, uniquingKeysWith: { a, _ in a })
                entry = .init(kind: permanently ? .deleted : .trashed, title: "\(done.count) \(label)", bytes: bytes,
                              items: done.flatMap(\.paths).map { .init(original: $0.path, inTrash: landed[$0.path]) })
            }
            activity.record(entry)
            if !permanently { undo = entry.id }
        }
        refreshVolume()
        if permanently, report.freedBytes > 0 { history.record(volume: volume, safe: safeReclaimable, freed: report.freedBytes) }
        let removed = Set(done.compactMap { $0.paths.first?.path })
        let what = done.count == 1 ? "“\(done[0].title)”" : "\(done.count) \(label)"
        var message = done.isEmpty ? "Couldn't move \(files.count == 1 ? "it" : "them") to the Trash"
            : permanently ? "Deleted \(what) — freed \(bytes.gb)" : "Moved \(what) to the Trash (\(bytes.gb))"
        if let skip = report.skipped.first { message += " · \(report.skipped.count) skipped: \(skip.reason)" }
        return (message, removed, undo)
    }

    // MARK: Memory

    @Published var memory = MemoryStatus.current()
    @Published var memoryGroups: [MemoryGroup] = []

    func refreshMemory() async {
        let (status, groups) = await Task.detached(priority: .utility) {
            (MemoryStatus.current(), ProcessScanner.groups(ProcessScanner.snapshot()))
        }.value
        memory = status
        memoryGroups = groups
    }

    /// nil when the group can be quit; otherwise why not.
    func quitRefusal(_ g: MemoryGroup) -> String? {
        if g.kind == .system { return "Part of macOS — it manages its own memory" }
        guard let main = g.processes.min(by: { $0.pid < $1.pid }) else { return "Not running" }
        if case .refused(let why) = ProcessGuard.check(main) { return why.prefix(1).uppercased() + why.dropFirst() }
        return nil
    }

    /// Quit apps the polite way (they can save), or force them; stop other processes with SIGTERM/SIGKILL.
    func quit(_ groups: [MemoryGroup], force: Bool) async -> String {
        let targets = groups.filter { quitRefusal($0) == nil }
        guard !targets.isEmpty else { return "Nothing to quit" }
        let before = targets.reduce(0) { $0 + $1.footprint }
        var failed: [String] = []
        for g in targets {
            if let bundle = g.bundlePath,
               let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == bundle }) {
                let ok = force ? app.forceTerminate() : app.terminate()
                if !ok { failed.append(g.name) }
            } else {
                // Children first, then the parent, so nothing restarts what we just stopped.
                for p in g.processes.sorted(by: { $0.pid > $1.pid }) {
                    if case .refused(let why) = ProcessGuard.stop(p, force: force) { failed.append("\(g.name): \(why)"); break }
                }
            }
        }
        // Judge by the processes we asked to stop, not the group: a lingering helper or an app that
        // relaunches itself keeps the group alive even though the quit worked. Apps can take seconds.
        func alive(_ p: ProcessInfoSnapshot) -> Bool {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(p.pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return false }
            let started = bsd.pbi_start_tvsec > 0 ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)) : nil
            return p.started == nil || started == p.started // same pid, same start: still the same process
        }
        func mainAlive(_ g: MemoryGroup) -> Bool { g.processes.first { $0.pid == g.mainPID }.map(alive) ?? false }
        let deadline = Date().addingTimeInterval(force ? 2 : 8)
        while Date() < deadline, targets.contains(where: mainAlive) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let waiting = targets.filter(mainAlive)
        let freed = targets.flatMap(\.processes).filter { !alive($0) }.reduce(0) { $0 + $1.footprint }
        await refreshMemory()
        if !failed.isEmpty { return "Couldn't quit \(failed.joined(separator: ", "))" }
        if !waiting.isEmpty {
            // Usually a Save dialog: bring it to the front so it isn't hidden behind Headroom.
            for g in waiting {
                if let bundle = g.bundlePath,
                   let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.path == bundle }) {
                    app.activate()
                }
            }
            let quit = targets.count - waiting.count
            let who = waiting.count == 1 ? waiting[0].name : "\(waiting.count) apps"
            return (quit > 0 ? "Quit \(quit), freed \(freed.gb) · " : "")
                + "\(who) didn't quit yet — check for a Save dialog, or use Force Quit"
        }
        let names = targets.count == 1 ? targets[0].name : "\(targets.count) apps"
        return "Quit \(names) — freed about \(max(freed, before).gb) of memory"
    }

    // MARK: Headroom's own data

    var ownDataBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: HeadroomPaths.support, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Forget what Headroom removed. Nothing on disk changes; trashed items stay in the Trash.
    func clearActivityLog() {
        activity = ActivityLog()
        activity.save()
    }

    /// Forget free-space history and folder growth snapshots.
    func clearHistory() {
        history = History()
        try? FileManager.default.removeItem(at: History.url)
        growth = GrowthHistory()
        growth.save()
    }

    func clearNeverTouch() {
        excluded = []
        Task { await scan() }
    }

    func exclude(_ urls: [URL]) {
        let new = urls.map(\.path).filter { !excluded.contains($0) }
        guard !new.isEmpty else { return }
        excluded += new
        findings = Exclusions.apply(findings, excluded: excluded)
        selected = selected.filter { id in findings.contains { $0.id == id } }
    }

    func unexclude(_ path: String) {
        excluded.removeAll { $0 == path }
        Task { await scan() }
    }

    func uninstallSelectedApps() async -> AppInventory.UninstallReport {
        var total = AppInventory.UninstallReport()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for app in apps where selectedApps.contains(app.id) {
            let r = AppInventory.uninstall(app, isRunning: running.contains(app.bundleID))
            if !r.trashed.isEmpty {
                activity.record(.init(kind: .uninstalled, title: app.name, bytes: r.bytes,
                                      items: r.trashed.map { .init(original: $0.path, inTrash: r.inTrash[$0]?.path) }))
            }
            total.trashed += r.trashed
            total.failed += r.failed
            total.bytes += r.bytes
        }
        selectedApps = []
        await scanApps()
        refreshVolume()
        return total
    }

    // MARK: Map actions

    /// What you can do to something you found on the map. Destructive ones always confirm first.
    enum MapAction: String, Identifiable {
        case reclaim, trash, emptyContents, delete, uninstall
        var id: String { rawValue }
    }

    struct MapOutcome {
        var message: String
        var failed: Bool
        /// The node to update on the map, with what's left of it (0 = gone).
        var nodeID: String
        var remaining: Int64
        var freedFromMap: Int64
    }

    /// The scan's verdict for this exact folder, if it is a known finding.
    func knownFinding(for url: URL) -> Finding? {
        findings.first { $0.paths.contains { $0.standardizedFileURL.path == url.standardizedFileURL.path } }
    }

    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            && url.pathExtension.lowercased() != "app"
    }

    /// nil when `action` is possible on `node`; otherwise why not, in plain words.
    func refusal(_ action: MapAction, for node: DiskNode) -> String? {
        guard let url = node.url else { return "A summary tile, not a folder — look inside to act on what's in it" }
        if action == .uninstall {
            guard url.pathExtension == "app" else { return "Not an app" }
            if let id = Bundle(url: url)?.bundleIdentifier, id.hasPrefix("com.apple.") { return "Apple apps are part of macOS" }
            return nil
        }
        let known = knownFinding(for: url)
        // Your data can go to the Trash (recoverable, after a warning) — never emptied or deleted for good here.
        if action != .trash, known?.safety == .keep || safetyByPath[url.path] == .keep {
            return "Your data — move it to the Trash instead, so it can come back"
        }
        let method: CleanupMethod
        switch action {
        case .reclaim:
            guard let known, known.method != .none else { return "Not something Headroom knows is safe to remove" }
            method = known.method
        case .emptyContents:
            guard isDirectory(url) else { return "Not a folder" }
            method = .deleteContents
        case .delete: method = .delete
        default: method = .trash
        }
        let finding = action == .reclaim ? known! : .picked(url, bytes: node.bytes, method: method)
        if case .refused(let why) = guardrail.check(url, for: finding) { return why.prefix(1).uppercased() + why.dropFirst() }
        return nil
    }

    /// Carry out a confirmed map action through the Cleaner (or the uninstaller for apps).
    func perform(_ action: MapAction, on node: DiskNode) async -> MapOutcome {
        guard let url = node.url, refusal(action, for: node) == nil else {
            return MapOutcome(message: refusal(action, for: node) ?? "Not possible", failed: true,
                              nodeID: node.id, remaining: node.bytes, freedFromMap: 0)
        }
        if action == .uninstall { return await uninstall(appAt: url, node: node) }

        var finding: Finding
        switch action {
        case .reclaim:
            finding = knownFinding(for: url)!
            finding.paths = [url]
        case .emptyContents: finding = .picked(url, bytes: node.bytes, method: .deleteContents)
        case .delete: finding = .picked(url, bytes: node.bytes, method: .delete)
        default: finding = .picked(url, bytes: node.bytes, method: .trash)
        }
        let plan = finding
        let guardrail = self.guardrail
        let (report, remaining) = await Task.detached(priority: .userInitiated) { () -> (CleanupReport, Int64) in
            let report = Cleaner(guardrail: guardrail).reclaim([plan])
            let left = FileManager.default.fileExists(atPath: url.path) ? DiskWalker.measure(url).allocated : 0
            return (report, left)
        }.value
        for entry in ActivityLog.entries(for: [plan], report: report) { activity.record(entry) }
        refreshVolume()
        if report.freedBytes > 0 { history.record(volume: volume, safe: safeReclaimable, freed: report.freedBytes) }
        // The reclaim list must match the disk again; it rescans quietly in the background.
        Task { await scan() }

        let name = url.lastPathComponent
        let freed = max(0, node.bytes - remaining)
        if let skip = report.skipped.first {
            return MapOutcome(message: "Couldn't finish \(name): \(skip.reason)", failed: true,
                              nodeID: node.id, remaining: remaining, freedFromMap: freed)
        }
        let message: String
        switch plan.method {
        case .trash: message = "Moved \(name) to the Trash — \(node.bytes.gb) comes back when you empty it"
        case .deleteContents: message = "Emptied \(name) — freed \(report.freedBytes.gb)"
        default: message = "Removed \(name) — freed \(report.freedBytes.gb)"
        }
        return MapOutcome(message: message, failed: false, nodeID: node.id, remaining: remaining, freedFromMap: freed)
    }

    private func uninstall(appAt url: URL, node: DiskNode) async -> MapOutcome {
        if apps.isEmpty { await scanApps() }
        guard let app = apps.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }) else {
            return MapOutcome(message: "Couldn't read \(url.lastPathComponent)", failed: true,
                              nodeID: node.id, remaining: node.bytes, freedFromMap: 0)
        }
        let r = await uninstallApp(app)
        return MapOutcome(message: r.message, failed: r.failed, nodeID: node.id,
                          remaining: r.trashed.contains(app.url.path) ? 0 : node.bytes,
                          freedFromMap: r.trashed.contains(app.url.path) ? node.bytes : 0)
    }

    /// Uninstall one app with every bit of data it keeps (to the Trash, one Activity entry).
    func uninstallApp(_ app: InstalledApp) async -> (message: String, failed: Bool, trashed: Set<String>) {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == app.bundleID }
        let report = AppInventory.uninstall(app, isRunning: running)
        if !report.trashed.isEmpty {
            activity.record(.init(kind: .uninstalled, title: app.name, bytes: report.bytes,
                                  items: report.trashed.map { .init(original: $0.path, inTrash: report.inTrash[$0]?.path) }))
        }
        await scanApps()
        refreshVolume()
        let trashed = Set(report.trashed.map(\.path))
        if let fail = report.failed.first {
            return ("Couldn't uninstall \(app.name): \(fail.1)", true, trashed)
        }
        return ("Moved \(app.name) and all its data (\(report.bytes.gb)) to the Trash", false, trashed)
    }

    // MARK: What is this?

    func appName(forBundleID id: String) -> String? {
        let lower = id.lowercased()
        if let app = apps.first(where: { $0.bundleID.lowercased() == lower }) { return app.name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return url.deletingPathExtension().lastPathComponent
    }

    /// What a square on the map is and what deleting it means. The scan's own verdict wins when
    /// it knows the exact folder.
    func explanation(for node: DiskNode) -> Explanation? {
        guard let url = node.url else { return nil }
        var e = Explainer.explain(url, appName: { [weak self] in self?.appName(forBundleID: $0) })
        if let known = knownFinding(for: url) {
            e.detail = known.detail
            e.verdict = known.safety
            if let rebuild = known.rebuild { e.ifDeleted = "Comes back with `\(rebuild)` when you need it." }
        }
        return e
    }

    /// The installed app this square is, or whose data it is — so it can go with everything it keeps.
    func owningApp(of node: DiskNode) -> InstalledApp? {
        guard let url = node.url else { return nil }
        let path = url.standardizedFileURL.path
        if let app = apps.first(where: { $0.url.standardizedFileURL.path == path }) { return app }
        if let app = apps.first(where: { app in
            app.leftovers.contains { path == $0.url.path || path.hasPrefix($0.url.path + "/") }
        }) { return app }
        guard let id = explanation(for: node)?.ownerBundleID?.lowercased() else { return nil }
        return apps.first { $0.bundleID.lowercased() == id }
    }

    /// Update the map in place after an action (rebuilding it walks the whole disk).
    func reflect(_ outcome: MapOutcome, ancestors: Set<String>) {
        map = map?.reflecting(removalOf: outcome.nodeID, remaining: outcome.remaining, freed: outcome.freedFromMap,
                              ancestors: ancestors)
    }

    /// Ask the release feed for a newer version. Quiet unless `manual` (the Settings button).
    @discardableResult
    func checkForUpdates(manual: Bool = false) async -> Updates.Release? {
        guard let feed = Updates.feedURL else {
            if manual { updateStatus = "Updates aren't set up in this build." }
            return nil
        }
        if manual { updateStatus = "Checking…" }
        do {
            update = try await Updates.check(feed: feed)
            updateStatus = update.map { "Headroom \($0.version) is available." } ?? "You're up to date (\(Updates.currentVersion))."
        } catch {
            if manual { updateStatus = "Couldn't reach the update feed." }
        }
        return update
    }

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func openInTerminal(_ url: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func toggle(_ finding: Finding) {
        guard finding.safety != .keep, finding.reclaimable > 0 || finding.method != .none else { return }
        if selected.contains(finding.id) { selected.remove(finding.id) } else { selected.insert(finding.id) }
    }
}

/// Free-space history: powers "where did my space go?" and the growth alert.
struct History: Codable {
    struct Point: Codable {
        var date: Date
        var free: Int64
        var safe: Int64
        var freed: Int64?
    }

    var points: [Point] = []

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> History {
        guard let data = try? Data(contentsOf: url), let h = try? JSONDecoder().decode(History.self, from: data) else { return History() }
        return h
    }

    mutating func record(volume: VolumeStatus, safe: Int64, freed: Int64? = nil) {
        points.append(Point(date: volume.date, free: volume.free, safe: safe, freed: freed))
        points = Array(points.suffix(500))
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url) }
    }

    /// Space lost over the last `hours` (positive = the disk filled up).
    func lost(overHours hours: Double, now: VolumeStatus) -> Int64? {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        guard let past = points.last(where: { $0.date <= cutoff }) ?? points.first else { return nil }
        return past.free - now.free
    }

    var totalFreed: Int64 { points.compactMap(\.freed).reduce(0, +) }
}

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

    @AppStorage("lowSpaceThresholdGB") var lowSpaceThresholdGB: Double = 15
    @AppStorage("staleDays") var staleDays: Int = 7
    @AppStorage("notificationsEnabled") var notificationsEnabled = true
    @AppStorage("showNotch") var showNotch = true

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
    var isBusy: Bool {
        if case .idle = phase { return false }
        if case .done = phase { return false }
        return true
    }

    // MARK: Scans

    func refreshVolume() {
        volume = .current()
    }

    /// The reclaim scan: known locations + every project's build output (~20 s).
    func scan() async {
        guard !isBusy else { return }
        phase = .scanning("Looking for space you can safely get back…")
        let stale = staleDays
        async let projects = ProjectScanner.scan(roots: ProjectScanner.defaultRoots(), staleDays: stale)
        async let known = Catalog.scanKnownLocations()
        let all = await (projects + known).sorted { $0.size.allocated > $1.size.allocated }
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
        let root = await DiskMap.build(volume: volume, safetyByPath: safety, progress: { p in
            Task { @MainActor [weak self] in self?.mapProgress = p }
        })
        map = root
        mapProgress = nil
    }

    func scanApps() async {
        appsPhase = .scanning("Measuring apps and their data…")
        apps = await AppInventory.scan()
        appsPhase = .idle
    }

    // MARK: Actions

    /// Reclaim the selection. With `safeOnly`, exactly the safe set — the one-click path.
    func reclaim(safeOnly: Bool = false) async {
        let plan = safeOnly ? safeFindings : selectedFindings
        guard !plan.isEmpty, !isBusy else { return }
        phase = .reclaiming("Reclaiming \(plan.reduce(0) { $0 + $1.reclaimable }.gb)…")
        let report = await Task.detached(priority: .userInitiated) {
            Cleaner().reclaim(plan)
        }.value
        lastReport = report
        phase = .done(report.freedBytes)
        refreshVolume()
        history.record(volume: volume, safe: 0, freed: report.freedBytes)
        // Rescan quietly so the lists reflect reality.
        try? await Task.sleep(for: .seconds(1.5))
        phase = .idle
        await scan()
        if map != nil { await buildMap() }
    }

    func uninstallSelectedApps() async -> AppInventory.UninstallReport {
        var total = AppInventory.UninstallReport()
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for app in apps where selectedApps.contains(app.id) {
            let r = AppInventory.uninstall(app, isRunning: running.contains(app.bundleID))
            total.trashed += r.trashed
            total.failed += r.failed
            total.bytes += r.bytes
        }
        selectedApps = []
        await scanApps()
        refreshVolume()
        return total
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

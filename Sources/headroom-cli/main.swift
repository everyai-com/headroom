import Foundation
import HeadroomCore

// headroom-cli — read-only reports. It never deletes anything; reclaiming happens in the app,
// where you see exactly what will go before it goes.
//
//   headroom-cli status          free space and health
//   headroom-cli reclaim         what can be reclaimed, grouped by safety (dry run)
//   headroom-cli projects        build artifacts in your code folders
//   headroom-cli apps            installed apps with their leftover data
//   headroom-cli map             every GB, by area
//   headroom-cli files           single files over 500 MB in your folders
//   headroom-cli growth [hours]  what grew since the app's map snapshot ~N hours ago (default 24)
//   headroom-cli activity        what Headroom removed, and what can still be put back
//   headroom-cli library         your files by kind (images, videos, music…) and where downloads came from
//   headroom-cli search "<q>"    find files in plain English: "pdfs from last week over 5 mb"
//
//
// The planner (the only commands that write — and only Headroom's own planner.json):
//   headroom-cli today                         today's tasks (★ = one of the Big 3), habits, level
//   headroom-cli add "<task>" [--big] [--tomorrow|--day YYYY-MM-DD|--inbox] [--project name] [--from claude]
//   headroom-cli done <n|words> · later <n|words>
//   headroom-cli habits · habit add "<habit>" [--identity …] [--cue …] [--two-minute …] [--at 21:00] [--days mon,wed]
//   headroom-cli habit done <n|words> [--undo]
//   headroom-cli habit add "<habit>" --avoid · habit slip <n|words> [--undo]   a habit to break: clean days count
//   headroom-cli focus start "<what>"|<n> [--area a] · focus stop · focus   20 XP an hour, up to 3 h a session
//   headroom-cli rewards · reward add "<reward>" <coins> · buy <n|words>       coins come 1:1 with XP
//   headroom-cli challenge add "<habit>" <times> [--days 30] · stats           areas, rank, challenges, what earned what
//   headroom-cli timeline [--day YYYY-MM-DD] · season · season set "<main>" 20 ["<side>" 8] · season end
//   headroom-cli habit add "<quest>" --minutes 240 --track "<project>"          a daily quest that fills from the timeline
//
// Add --json to any of them for machine-readable output (for scripts and coding agents —
// e.g. check free space before a large install).

var args = Array(CommandLine.arguments.dropFirst())
let json = args.contains("--json")
args.removeAll { $0 == "--json" }
let command = args.first ?? "status"
let gb = ByteFormat.string

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
func say(_ s: String = "") { if !json { print(s) } }
func emit(_ object: Any) {
    guard json, let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
    print(String(decoding: data, as: UTF8.self))
}
let iso = ISO8601DateFormatter()
func date(_ d: Date?) -> Any { d.map { iso.string(from: $0) } ?? NSNull() }

func findingJSON(_ f: Finding) -> [String: Any] {
    let method: String = switch f.method {
    case .delete: "delete"
    case .deleteContents: "deleteContents"
    case .trash: "trash"
    case .command(let exe, let a): ([exe] + a).joined(separator: " ")
    case .none: "none"
    }
    return ["id": f.id, "title": f.title, "category": f.category.rawValue, "safety": "\(f.safety)",
            "paths": f.paths.map(\.path), "bytes": f.size.allocated, "reclaimableBytes": f.reclaimable,
            "lastUsed": date(f.lastUsed), "method": method, "rebuild": f.rebuild ?? NSNull(), "project": f.project ?? NSNull()]
}

// The planner writes only Headroom's own planner.json, and skips the disk header.
if PlannerCommands.names.contains(command) {
    PlannerCommands.run(args, json: json)
    exit(0)
}

let volume = VolumeStatus.current()
let volumeJSON: [String: Any] = ["totalBytes": volume.total, "freeBytes": volume.free, "purgeableBytes": volume.purgeable,
                                 "health": volume.health.rawValue]
say("Macintosh HD — \(gb(volume.free)) free of \(gb(volume.total))  [\(volume.health.rawValue)]")
if volume.purgeable > 0 { say("  + \(gb(volume.purgeable)) macOS can purge on demand") }
say()

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    switch command {
    case "status":
        emit(volumeJSON)
    case "reclaim", "projects":
        let started = Date()
        var findings = await ProjectScanner.scan(roots: ProjectScanner.defaultRoots())
        if command == "reclaim" { findings += await Catalog.scanKnownLocations() }
        let excluded = UserDefaults(suiteName: "app.headroom.Headroom")?.stringArray(forKey: "neverTouch") ?? []
        findings = Exclusions.apply(findings, excluded: excluded)
        for safety in Safety.allCases {
            let group = findings.filter { $0.safety == safety }.sorted { $0.size.allocated > $1.size.allocated }
            guard !group.isEmpty else { continue }
            let reclaim = group.reduce(0) { $0 + $1.reclaimable }
            let size = group.reduce(0) { $0 + $1.size.allocated }
            say("\(safety.label.uppercased()) — \(group.count) items, \(gb(size)) on disk\(safety == .keep ? "" : ", \(gb(reclaim)) reclaimable")")
            for f in group.prefix(safety == .keep ? 12 : 25) {
                let freed = f.reclaimable == f.size.allocated ? "" : "  (frees \(gb(f.reclaimable)))"
                say("  \(pad(gb(f.size.allocated), 10)) \(pad(f.title, 34)) \(f.subtitle)\(freed)")
            }
            say()
        }
        let dry = Cleaner(guardrail: SafetyGuard(excluded: excluded)).reclaim(findings.filter { $0.safety == .safe }, dryRun: true)
        say("One click (safe only) would free \(gb(dry.freedBytes)). Skipped by the safety guard: \(dry.skipped.count).")
        for s in dry.skipped.prefix(5) { say("  skip \(s.id): \(s.reason)") }
        say(String(format: "scan took %.1fs", Date().timeIntervalSince(started)))
        emit(["volume": volumeJSON, "oneClickBytes": dry.freedBytes, "findings": findings.map(findingJSON)])
    case "apps":
        let apps = await AppInventory.scan()
        say("\(apps.count) apps — \(gb(apps.reduce(0) { $0 + $1.totalSize })) including their data\n")
        for app in apps.prefix(30) {
            let last = app.lastUsed.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? "never/unknown"
            say("  \(pad(gb(app.totalSize), 10)) \(pad(app.name, 28)) app \(pad(gb(app.appSize.allocated), 9)) data \(pad(gb(app.dataSize), 9)) used \(last)")
        }
        emit(apps.map { ["name": $0.name, "bundleID": $0.bundleID, "path": $0.url.path, "appBytes": $0.appSize.allocated,
                         "dataBytes": $0.dataSize, "lastUsed": date($0.lastUsed), "lastUsedIsExact": $0.lastUsedIsExact] })
    case "map", "files":
        let collector = BigFileCollector()
        let root = await DiskMap.build(bigFiles: collector, progress: { p in
            if !json { FileHandle.standardError.write("\r  measuring \(p.done)/\(p.total)".data(using: .utf8)!) }
        })
        if !json { FileHandle.standardError.write("\n".data(using: .utf8)!) }
        if command == "files" {
            for f in collector.files.prefix(40) { say("  \(pad(gb(f.bytes), 10)) \(f.url.tildePath)") }
            emit(collector.files.map { ["path": $0.url.path, "bytes": $0.bytes, "modified": date($0.modified)] })
        } else {
            say("Every GB on \(root.name) — \(gb(root.bytes)) accounted (disk says \(gb(volume.used)) used)\n")
            for group in root.children {
                say("\(pad(gb(group.bytes), 10)) \(group.name)")
                for child in group.children.prefix(6) { say("    \(pad(gb(child.bytes), 10)) \(child.name)") }
            }
            emit(root.children.map { g in ["name": g.name, "bytes": g.bytes,
                                           "children": g.children.map { ["name": $0.name, "path": $0.url.map { $0.path as Any } ?? NSNull(), "bytes": $0.bytes] }] })
        }
    case "growth":
        let hours = args.dropFirst().first.flatMap(Double.init) ?? 24
        let history = GrowthHistory.load()
        guard let newest = history.snapshots.last, let base = history.baseline(hoursBefore: hours, from: newest.date) else {
            say("No map history yet — the app records one each time it maps the disk.")
            emit(["changes": []])
            return
        }
        let changes = GrowthHistory.changes(from: base, to: newest)
        say("Change from \(iso.string(from: base.date)) to \(iso.string(from: newest.date)):\n")
        for c in changes.prefix(20) { say("  \(pad((c.delta > 0 ? "+" : "-") + gb(abs(c.delta)), 12)) \(c.name)") }
        emit(["from": date(base.date), "to": date(newest.date),
              "changes": changes.map { ["name": $0.name, "id": $0.id, "deltaBytes": $0.delta, "bytes": $0.now] }])
    case "activity":
        let log = ActivityLog.load()
        for e in log.entries.prefix(30) {
            say("  \(pad(iso.string(from: e.date), 22)) \(pad(e.kind.rawValue, 12)) \(pad(gb(e.bytes), 10)) \(e.title)\(e.canPutBack ? "  [can put back]" : "")")
        }
        if log.entries.isEmpty { say("Nothing removed yet.") }
        emit(log.entries.map { ["date": date($0.date), "kind": $0.kind.rawValue, "title": $0.title, "bytes": $0.bytes,
                                "paths": $0.items.map(\.original), "canPutBack": $0.canPutBack, "automatic": $0.automatic] })
    case "library":
        let started = Date()
        let index = await LibraryScanner.scan()
        say("\(index.items.count) files in \(index.roots.count) folders (\(String(format: "%.1f", Date().timeIntervalSince(started)))s)\n")
        for kind in FileKind.allCases {
            let t = index.totals(kind)
            say("  \(pad(kind.title, 12)) \(pad("\(t.count)", 8)) \(gb(t.bytes))")
        }
        let sources = Dictionary(grouping: index.items.compactMap { item in DownloadSources.source(of: item).map { ($0, item) } }, by: { $0.0 })
        say("\nDownloaded from (\(sources.values.reduce(0) { $0 + $1.count }) files):")
        for (source, list) in sources.sorted(by: { $0.value.count > $1.value.count }).prefix(20) {
            say("  \(pad(source.name, 24)) \(pad("\(list.count)", 6)) \(gb(list.reduce(0) { $0 + $1.1.bytes }))")
        }
        say("\nScreenshots: \(index.screenshots.count)")
        if args.contains("--ext") {
            for kind in FileKind.allCases {
                let byExt = Dictionary(grouping: index.items.filter { $0.kind == kind }, by: \.ext).map { ($0.key, $0.value.count) }
                say("  \(kind.title): " + byExt.sorted { $0.1 > $1.1 }.prefix(12).map { "\($0.0)=\($0.1)" }.joined(separator: " "))
            }
        }
        emit(["files": index.items.count, "kinds": Dictionary(uniqueKeysWithValues: FileKind.allCases.map { k in
            (k.rawValue, ["count": index.totals(k).count, "bytes": index.totals(k).bytes]) })])
    case "search":
        let text = args.dropFirst().joined(separator: " ")
        var cached = LibraryIndex.loadCache()
        if cached == nil { cached = await LibraryScanner.scan() }
        let index = cached ?? LibraryIndex()
        let q = LibraryQuery.parse(text)
        let context = LibraryQuery.MatchContext(recognizedText: TextIndex().all)
        let found = index.items.filter { q.matches($0, in: context) }.sorted { $0.latest > $1.latest }
        say("Looking for: " + (q.chips.isEmpty ? "everything" : q.chips.map(\.label).joined(separator: " · ")))
        say("\(found.count) files · \(gb(found.reduce(0) { $0 + $1.bytes }))\n")
        for item in found.prefix(30) {
            say("  \(pad(gb(item.bytes), 10)) \(pad(iso.string(from: item.latest).prefix(10).description, 11)) \(item.url.tildePath)")
        }
        emit(found.prefix(500).map { ["path": $0.path, "kind": $0.kind.rawValue, "bytes": $0.bytes, "modified": date($0.modified),
                                      "source": DownloadSources.source(of: $0)?.name as Any] })
    case "battery":
        guard let b = BatteryStatus.current() else { say("No battery (this Mac is a desktop)."); emit(["battery": NSNull()]); break }
        say("Battery \(b.percent)% · \(b.pluggedIn ? (b.charging ? "charging" : "on the charger") : "on battery")")
        say("  health      \(b.healthPercent)% (\(b.maxCapacity) of \(b.designCapacity) mAh)")
        say("  cycles      \(b.cycles) of \(b.designCycles)")
        say(String(format: "  temperature %.1f °C", b.temperature))
        say(String(format: "  battery     %+.1f W", b.batteryWatts))
        if let w = b.systemWatts { say(String(format: "  Mac         %.1f W", w)) }
        if let a = b.adapterWatts { say("  charger     \(b.adapterName ?? "\(a) W")\(b.adapterDelivering.map { String(format: ", delivering %.1f W", $0) } ?? "")") }
        let log = BatteryLog.load()
        if let t = log.trend() {
            say(String(format: "\nWear %.1f%% a year · %.0f cycles a month", t.wearPerYear * 100, t.cyclesPerMonth)
                + (t.yearsTo80.map { String(format: " · about %.1f years until 80%%", $0) } ?? ""))
        }
        say("\n\(log.samples.count) readings recorded")
        emit(["percent": b.percent, "pluggedIn": b.pluggedIn, "charging": b.charging, "health": b.health, "cycles": b.cycles,
              "designCycles": b.designCycles, "maxCapacity": b.maxCapacity, "designCapacity": b.designCapacity,
              "temperature": b.temperature, "batteryWatts": b.batteryWatts, "systemWatts": b.systemWatts as Any,
              "adapterWatts": b.adapterWatts as Any, "readings": log.samples.count])
    default:
        print("usage: headroom-cli [status|reclaim|projects|apps|map|files|growth [hours]|activity|library|search \"query\"|battery|today|add|done|later|habits|habit|focus|rewards|reward|buy|challenge|stats|timeline|season] [--json]")
    }
}
semaphore.wait()

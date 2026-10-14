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
    default:
        print("usage: headroom-cli [status|reclaim|projects|apps|map|files|growth [hours]|activity] [--json]")
    }
}
semaphore.wait()

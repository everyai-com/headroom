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

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "status"
let gb = ByteFormat.string

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }

let volume = VolumeStatus.current()
print("Macintosh HD — \(gb(volume.free)) free of \(gb(volume.total))  [\(volume.health.rawValue)]")
if volume.purgeable > 0 { print("  + \(gb(volume.purgeable)) macOS can purge on demand") }
print("")

let semaphore = DispatchSemaphore(value: 0)
Task {
    defer { semaphore.signal() }
    switch command {
    case "status":
        break
    case "reclaim", "projects":
        let started = Date()
        var findings = await ProjectScanner.scan(roots: ProjectScanner.defaultRoots())
        if command == "reclaim" { findings += await Catalog.scanKnownLocations() }
        for safety in Safety.allCases {
            let group = findings.filter { $0.safety == safety }.sorted { $0.size.allocated > $1.size.allocated }
            guard !group.isEmpty else { continue }
            let reclaim = group.reduce(0) { $0 + $1.reclaimable }
            let size = group.reduce(0) { $0 + $1.size.allocated }
            print("\(safety.label.uppercased()) — \(group.count) items, \(gb(size)) on disk\(safety == .keep ? "" : ", \(gb(reclaim)) reclaimable")")
            for f in group.prefix(safety == .keep ? 12 : 25) {
                let freed = f.reclaimable == f.size.allocated ? "" : "  (frees \(gb(f.reclaimable)))"
                print("  \(pad(gb(f.size.allocated), 10)) \(pad(f.title, 34)) \(f.subtitle)\(freed)")
            }
            print("")
        }
        let dry = Cleaner().reclaim(findings.filter { $0.safety == .safe }, dryRun: true)
        print("One click (safe only) would free \(gb(dry.freedBytes)). Skipped by the safety guard: \(dry.skipped.count).")
        for s in dry.skipped.prefix(5) { print("  skip \(s.id): \(s.reason)") }
        print(String(format: "scan took %.1fs", Date().timeIntervalSince(started)))
    case "apps":
        let apps = await AppInventory.scan()
        print("\(apps.count) apps — \(gb(apps.reduce(0) { $0 + $1.totalSize })) including their data\n")
        for app in apps.prefix(30) {
            let last = app.lastUsed.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: .now) } ?? "never/unknown"
            print("  \(pad(gb(app.totalSize), 10)) \(pad(app.name, 28)) app \(pad(gb(app.appSize.allocated), 9)) data \(pad(gb(app.dataSize), 9)) used \(last)")
        }
    case "map":
        let root = await DiskMap.build(progress: { p in
            FileHandle.standardError.write("\r  measuring \(p.done)/\(p.total)".data(using: .utf8)!)
        })
        FileHandle.standardError.write("\n".data(using: .utf8)!)
        print("Every GB on \(root.name) — \(gb(root.bytes)) accounted (disk says \(gb(volume.used)) used)\n")
        for group in root.children {
            print("\(pad(gb(group.bytes), 10)) \(group.name)")
            for child in group.children.prefix(6) {
                print("    \(pad(gb(child.bytes), 10)) \(child.name)")
            }
        }
    default:
        print("usage: headroom-cli [status|reclaim|projects|apps|map]")
    }
}
semaphore.wait()

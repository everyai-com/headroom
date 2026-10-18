import SwiftUI
import AppKit
import HeadroomCore

/// The demo reel: `Headroom --reel <dir> --demo` runs the real flow on the demo data from
/// scripts/demo-seed.sh — scan, map, reclaim idle projects, trash a big file, put it back —
/// and renders each step as a captioned 1920×1080 frame. scripts/make-reel.sh cuts them into a video.
@MainActor
enum Reel {
    struct Shot {
        var name: String
        var seconds: Double
    }

    static let canvas = CGSize(width: 1920, height: 1080)
    static let window = CGSize(width: 1180, height: 780)

    static func make(to dir: URL) {
        guard AppModel.demoMode, FileManager.default.fileExists(atPath: AppModel.demoRoot.path) else {
            print("Run scripts/demo-seed.sh first, then: Headroom --reel <dir> --demo")
            return
        }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // The reel shares Application Support with the real app: keep its logs exactly as they were.
        let support = HeadroomPaths.support
        let stateFiles = ["activity.json", "map-history.json", "history.json"]
        let saved = Dictionary(uniqueKeysWithValues: stateFiles.map { ($0, try? Data(contentsOf: support.appendingPathComponent($0))) })
        defer {
            for (name, data) in saved {
                let url = support.appendingPathComponent(name)
                if let data { try? data.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
            }
        }
        UserDefaults.standard.set(true, forKey: "fdaBannerDismissed")

        let model = AppModel()
        model.excluded = []
        var shots: [Shot] = []
        let library = LibraryModel(app: model)
        func shot<V: View>(_ name: String, _ seconds: Double, _ view: V) {
            Snapshots.save(view.environmentObject(model).environmentObject(library), size: canvas, to: dir.appendingPathComponent(name + ".png"))
            shots.append(Shot(name: name, seconds: seconds))
            print("  ✓ \(name)")
        }
        func app(_ screen: Screen, scroll: CGFloat = 0, _ override: AnyView? = nil) -> some View {
            MainView(screen: screen, override: override).environment(\.snapshotScroll, scroll)
        }

        run {
            print("Scanning the demo data and mapping the disk…")
            await model.scan()
            await model.buildMap()
        }

        // 1–2. The notch.
        shot("01-notch", 3.5, NotchShot(expanded: false, title: "Headroom lives in your notch.",
                                        subtitle: "Free space, live — always one glance away."))
        shot("02-notch-open", 4, NotchShot(expanded: true, title: "Hover it.",
                                           subtitle: "The biggest safe wins, and one click to get them back."))
        // 3–4. Overview.
        shot("03-overview", 4.5, Framed(title: "Every gigabyte, accounted for.",
                                        subtitle: "Including the parts macOS hides — system volumes, swap, “Other”.", content: app(.overview)))
        shot("04-growth", 4.5, Framed(title: "See what grew.",
                                      subtitle: "Agents spin up repos all day. Headroom shows exactly where the space went.",
                                      content: app(.overview, scroll: 330)))
        // 5–6. The map, drilled into a demo project with its node_modules selected.
        shot("05-map", 4, Framed(title: "The whole disk as a map.",
                                 subtitle: "Square size is space. Glowing green is safe to delete.", content: app(.map)))
        var drilled: [DiskNode] = []
        var pick: DiskNode?
        run {
            guard let desktop = model.map?.children.first(where: { $0.name == "Desktop" }),
                  var demo = desktop.children.first(where: { $0.url?.path == AppModel.demoRoot.path }) else { return }
            demo.children = await DiskMap.expand(demo, safetyByPath: model.safetyByPath)
            guard var project = demo.children.first(where: { $0.name == "checkout-agent" }) else { return }
            project.children = await DiskMap.expand(project, safetyByPath: model.safetyByPath)
            drilled = [desktop, demo, project]
            pick = project.children.first { $0.name == "node_modules" }
        }
        shot("06-map-pick", 4.5, Framed(title: "Pick anything.",
                                        subtitle: "Reclaim it, trash it, delete it, open it in Terminal — always after a confirm.",
                                        content: app(.map, AnyView(MapView(path: drilled, selected: pick)))))

        // 7. Reclaim by project, idle ones selected.
        let idle = model.findings.filter {
            $0.category == .projectArtifacts && $0.safety == .safe && AppModel.isDemoPath($0.paths[0])
        }
        model.selected = Set(idle.map(\.id))
        shot("07-reclaim", 5, Framed(title: "It knows what you're working on.",
                                     subtitle: "Idle projects are safe. Today's ask first. Select every idle one in a click.",
                                     content: app(.reclaim, AnyView(ReclaimView(byProject: true)))))

        // 8. Reclaim for real (demo data only), then the activity log.
        run {
            print("Reclaiming the idle demo projects…")
            guard !idle.isEmpty, idle.allSatisfy({ AppModel.isDemoPath($0.paths[0]) }) else { return }
            await model.reclaim()
        }
        // Background rescans (started by the reclaim) finish before the next frame.
        settle(model)
        // 9. A big forgotten file, trashed and put back.
        shot("08-files", 4, Framed(title: "Find the forgotten giants.",
                                   subtitle: "Single big files the folder view hides — never app data, git history or VM disks.",
                                   content: app(.files)))
        run {
            guard let movie = model.bigFiles.first(where: { $0.url.lastPathComponent == "headroom-demo-recording.mov" }) else { return }
            let node = DiskNode(id: movie.url.path, name: movie.url.lastPathComponent, url: movie.url, bytes: movie.bytes, area: .media)
            _ = await model.perform(.trash, on: node)
        }
        settle(model)
        shot("09-activity", 5, Framed(title: "Everything is logged. Anything trashed comes back.",
                                      subtitle: "Rebuild commands for build output, Put Back for the Trash.", content: app(.activity)))
        if let entry = model.activity.entries.first(where: { $0.canPutBack }) { _ = model.putBack(entry) }
        settle(model)

        // 10. Settings: never touch, auto-reclaim.
        let wasAuto = model.autoReclaim
        model.autoReclaim = true
        model.excluded = [AppModel.demoRoot.appendingPathComponent("live-dashboard").path]
        shot("10-settings", 4, Framed(title: "You stay in charge.",
                                      subtitle: "A never-touch list the safety guard enforces, and optional auto-reclaim when space runs low.",
                                      content: app(.settings)))
        model.excluded = []
        model.autoReclaim = wasAuto

        // 11. The CLI, for agents.
        shot("11-cli", 4, CLIShot(volume: model.volume))
        // 12. End card.
        shot("12-end", 4, EndCard(freed: model.activity.entries.filter { $0.kind == .reclaimed }.reduce(0) { $0 + $1.bytes }))

        let manifest = shots.map { "\($0.name).png \($0.seconds)" }.joined(separator: "\n")
        try? manifest.write(to: dir.appendingPathComponent("shots.txt"), atomically: true, encoding: .utf8)
        print("reel frames in \(dir.path)")
    }

    /// Wait until no scan is running, so frames never show a spinner.
    static func settle(_ model: AppModel) {
        run {
            try? await Task.sleep(for: .milliseconds(300))
            while model.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
        }
    }

    /// Run async work to completion on the main actor, pumping the run loop meanwhile.
    static func run(_ work: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in await work(); done = true }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}

// MARK: - Frames

private struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.safe.opacity(0.16), .clear], center: .topTrailing, startRadius: 20, endRadius: 1100)
            RadialGradient(colors: [Color(hex: 0x6A4C93).opacity(0.22), .clear], center: .bottomLeading, startRadius: 20, endRadius: 1000)
        }
    }
}

private struct Caption: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 50, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Text(subtitle).font(.system(size: 23, weight: .medium)).foregroundStyle(Theme.textSecondary)
        }
        .multilineTextAlignment(.center)
    }
}

/// The app window, framed like a Mac window, under a caption.
private struct Framed<Content: View>: View {
    var title: String
    var subtitle: String
    var content: Content

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 34) {
                Caption(title: title, subtitle: subtitle)
                content
                    .frame(width: Reel.window.width, height: Reel.window.height)
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 8) {
                            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                        }
                        .padding(14)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
                    .scaleEffect(0.98)
            }
        }
        .frame(width: Reel.canvas.width, height: Reel.canvas.height)
    }
}

private struct NotchShot: View {
    @EnvironmentObject var model: AppModel
    var expanded: Bool
    var title: String
    var subtitle: String

    var body: some View {
        let g = NotchController.geometry()
        let w = g.map { $0.notchWidth > 0 ? $0.notchWidth : 185 } ?? 185
        let h = g.map { $0.notchHeight } ?? 32
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2B3A67), Color(hex: 0x6A4C93), Color(hex: 0xC06C84)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    NotchView(notchWidth: w, notchHeight: h, expanded: expanded, openApp: {})
                    NotchShape(radius: 9).fill(Color.black).frame(width: w, height: h)
                }
                .scaleEffect(expanded ? 1.9 : 3.2, anchor: .top)
                Spacer()
                Caption(title: title, subtitle: subtitle)
                    .padding(.horizontal, 40).padding(.vertical, 26)
                    .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color.black.opacity(0.35)))
                    .padding(.bottom, 90)
            }
        }
        .frame(width: Reel.canvas.width, height: Reel.canvas.height)
    }
}

private struct CLIShot: View {
    var volume: VolumeStatus

    var body: some View {
        let json = """
        {
          "freeBytes" : \(volume.free),
          "health" : "\(volume.health.rawValue)",
          "purgeableBytes" : \(volume.purgeable),
          "totalBytes" : \(volume.total)
        }
        """
        ZStack {
            Backdrop()
            VStack(spacing: 40) {
                Caption(title: "Your agents can ask, too.",
                        subtitle: "headroom-cli --json: check space before a big install. Read-only, always.")
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: UInt32($0))).frame(width: 12, height: 12) }
                    }
                    (Text("$ ").foregroundColor(Theme.safe) + Text("headroom-cli status --json").foregroundColor(.white))
                    Text(json).foregroundStyle(Theme.textSecondary)
                    (Text("$ ").foregroundColor(Theme.safe) + Text("headroom-cli growth 24 --json | jq '.changes[0]'").foregroundColor(.white))
                }
                .font(.system(size: 22, design: .monospaced))
                .padding(30)
                .frame(width: 1000, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x0E0F13)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.6), radius: 40, y: 18)
            }
        }
        .frame(width: Reel.canvas.width, height: Reel.canvas.height)
    }
}

private struct EndCard: View {
    var freed: Int64

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 26) {
                ZStack {
                    GaugeRing(fraction: 0.72, tint: Theme.safe, lineWidth: 18).frame(width: 150, height: 150)
                    Image(systemName: "sparkles").font(.system(size: 48, weight: .bold)).foregroundStyle(Theme.safe)
                        .shadow(color: Theme.safe.opacity(0.6), radius: 16)
                }
                Text("Headroom").font(.system(size: 76, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text("See every GB. Get it back safely.").font(.system(size: 30, weight: .medium)).foregroundStyle(Theme.textSecondary)
                if freed > 0 {
                    Text("This demo just reclaimed \(freed.gb) — and nothing you made was touched.")
                        .font(.system(size: 20)).foregroundStyle(Theme.safe).padding(.top, 8)
                }
            }
        }
        .frame(width: Reel.canvas.width, height: Reel.canvas.height)
    }
}

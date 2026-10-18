import SwiftUI
import AppKit
import HeadroomCore

/// Renders every screen with real scan data to PNGs — how the design is reviewed without
/// clicking through the app (`Headroom --render <dir>`).
@MainActor
enum Snapshots {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel()
        let library = LibraryModel(app: model)
        let done = DispatchSemaphore(value: 0)
        // `--fast`: the file library only (no reclaim scan, map or app sizes) — for reviewing those screens quickly.
        let fast = CommandLine.arguments.contains("--fast")
        Task { @MainActor in
            if !fast {
                await model.scan()
                await model.buildMap()
                await model.scanApps()
                await model.refreshMemory()
            }
            await library.scan()
            await library.findDuplicates()
            // The demo library is small: read its screenshots now, so searching their text shows something.
            if AppModel.demoMode {
                let text = library.text, todo = TextIndex.candidates(library.index)
                await Task.detached { text.index(todo) }.value
                library.recognized = text.all
            }
            done.signal()
        }
        // Drive the main run loop until the scans finish.
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let size = CGSize(width: 1180, height: 780)
        let drives = DrivesModel()
        let drivesDone = DispatchSemaphore(value: 0)
        Task { @MainActor in await drives.refresh(); drivesDone.signal() }
        while drivesDone.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let ai = AIModel()
        let aiDone = DispatchSemaphore(value: 0)
        Task { @MainActor in await ai.refresh(); aiDone.signal() }
        while aiDone.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // Thumbnails load asynchronously in the app; a render has to have them first.
        var shown: [LibraryItem] = FileKind.shelves.flatMap { library.recent($0, limit: 30) }
        shown += Array(library.screenshots.prefix(30))
        for g in (library.duplicates + library.lookAlikes).prefix(6) { shown += g.items }
        for g in library.bySource.prefix(10) { shown += Array(g.items.prefix(3)) }
        for s in library.suggestions { shown += Array(s.items.prefix(3)) }
        Thumbnails.shared.preload(shown.map(\.url), size: 320)
        Thumbnails.shared.preload(shown.map(\.url), size: 160)
        Thumbnails.shared.preload(shown.map(\.url), size: 64)
        // A workspace to draw: yours if you have one, else a made-up one (never saved).
        if library.workspaces.isEmpty {
            library.persistWorkspaces = false
            let home = library.home
            let docs = library.recent(.document, limit: 2).map(\.path)
            let folders = ["Documents", "Downloads", "Pictures", "Desktop"].map { home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
            library.workspaces = [Workspace(name: "Product Launch", note: "Website, brand and launch video")]
            library.workspaces[0].add(folders + docs)
        }
        library.workspaceID = library.workspaces.first?.id
        if let w = library.currentWorkspace {
            let wsDone = DispatchSemaphore(value: 0)
            Task { @MainActor in await library.refreshWorkspace(w.id); wsDone.signal() }
            while wsDone.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            let items = library.changedLately(w) + w.paths.compactMap { library.members[$0]?.file }
                + w.paths.flatMap { library.members[$0]?.folder?.recent ?? [] }
            Thumbnails.shared.preload(items.map(\.url), size: 320)
            Thumbnails.shared.preload(items.map(\.url), size: 160)
        }
        // The folder screen: the demo's git project (sizes on its folders, the branch in the path bar), else Downloads.
        let repo = library.home + "/Documents/launch-site"
        library.browsePath = AppModel.demoMode && FileManager.default.fileExists(atPath: repo) ? repo : library.home + "/Downloads"
        for folder in [library.browsePath!, library.home, library.home + "/Downloads"] { FolderInfoStore.shared.prewarm(folder: folder) }
        if let first = library.saved.first { library.savedID = first.id }
        for scheme in [ColorScheme.dark, .light] {
            for screen in Screen.allCases where screen != .saved || library.savedID != nil {
                let override = screen == .drives ? AnyView(DrivesView(model: drives)) : screen == .ai ? AnyView(AIView(ai: ai)) : nil
                if screen == .search {
                    library.searchText = AppModel.demoMode ? "screenshots with wifi password" : "pdfs from last month"
                    library.scheduleSearch(delay: 0)
                    settle(library)
                }
                save(MainView(screen: screen, override: override).environmentObject(model).environmentObject(library), size: size,
                     to: dir.appendingPathComponent("\(screen.rawValue.lowercased())\(scheme == .light ? "-light" : "").png"), scheme: scheme)
                if screen == .search { library.searchText = "" }
            }
        }
        // Minimal look, both ways.
        Theme.look = .minimal
        UserDefaults.standard.set(Look.minimal.rawValue, forKey: "look")
        for scheme in [ColorScheme.dark, .light] {
            save(MainView(screen: .home).environmentObject(model).environmentObject(library), size: size,
                 to: dir.appendingPathComponent("home-minimal\(scheme == .light ? "-light" : "").png"), scheme: scheme)
        }
        Theme.look = .playful
        UserDefaults.standard.set(Look.playful.rawValue, forKey: "look")
        // A file picked with the inspector open, and the list view.
        if let pick = library.recent(.image, limit: 1).first {
            library.selection = [pick.path]
            library.focused = pick.path
            library.showInspector = true
            save(MainView(screen: .images).environmentObject(model).environmentObject(library), size: size,
                 to: dir.appendingPathComponent("images-inspector.png"))
            library.showInspector = false
            library.viewMode = .list
            save(MainView(screen: .documents).environmentObject(model).environmentObject(library), size: size,
                 to: dir.appendingPathComponent("documents-list.png"))
            library.viewMode = .grid
            library.selection = []
        }
        // The plan before a tidy of the Desktop (or Downloads), drawn without moving anything.
        for folder in ["Desktop", "Downloads"] {
            let plan = AutoRules.tidyPlan(folder: URL(fileURLWithPath: library.home + "/" + folder), settle: 0)
            guard !plan.moves.isEmpty else { continue }
            for scheme in [ColorScheme.dark, .light] {
                save(TidySheet(plan: plan).environmentObject(library), size: CGSize(width: 480, height: 560),
                     to: dir.appendingPathComponent("tidy\(scheme == .light ? "-light" : "").png"), scheme: scheme)
            }
            break
        }
        // A folder grouped by kind, and by date added (nothing moves).
        let browsed = library.browsePath
        library.browsePath = library.home + "/Downloads"
        let savedGrouping = UserDefaults.standard.string(forKey: "folderGrouping")
        for (grouping, name) in [(FolderGrouping.kind, "folder-by-kind"), (.dateAdded, "folder-by-date")] {
            UserDefaults.standard.set(grouping.rawValue, forKey: "folderGrouping")
            save(MainView(screen: .folder).environmentObject(model).environmentObject(library), size: size,
                 to: dir.appendingPathComponent("\(name).png"))
        }
        UserDefaults.standard.set(savedGrouping, forKey: "folderGrouping")
        library.browsePath = browsed
        // Narrow: tiled into a third of the screen.
        save(MainView(screen: .images).environmentObject(model).environmentObject(library), size: CGSize(width: 700, height: 780),
             to: dir.appendingPathComponent("images-narrow.png"))
        // Quick Search in each state: empty, typed (Top Hit and sections), ⌘K, the calculator, ⌘I.
        // Apple's own apps only, so no personal ones show; each waits for its search to finish.
        func quick(_ name: String, text: String = "", actions: Bool = false, info: Bool = false) {
            let state = QuickSearchState()
            state.remembersInfo = false
            state.library = library
            state.useApps(QuickApp.list(roots: [URL(fileURLWithPath: "/System/Applications")]), panes: SettingsPane.list())
            state.showInfo = info
            state.text = text
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in await state.settle(); done.signal() }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            state.actionsOpen = actions
            save(QuickSearchView(state: state, close: {}).environmentObject(library).environmentObject(model),
                 size: CGSize(width: QuickSearchView.width, height: QuickSearchView.height), to: dir.appendingPathComponent(name))
        }
        quick("quick-search.png")
        quick("quick-search-typed.png", text: "re")
        quick("quick-search-actions.png", text: "notes", actions: true)
        quick("quick-search-calc.png", text: "1920 * 1.25 - 80")
        quick("quick-search-info.png", text: "saf", info: true)
        let downloads = library.index.downloads(in: library.home + "/Downloads", limit: 10)
        Thumbnails.shared.preload(downloads.map(\.url), size: 64)
        for scheme in [ColorScheme.dark, .light] {
            save(MenuBarView(preloaded: downloads, openWindow: {}, quickSearch: {}, close: {}).environmentObject(model).environmentObject(library)
                .frame(maxHeight: .infinity, alignment: .top).background(Theme.surface), size: CGSize(width: 360, height: 640),
                 to: dir.appendingPathComponent("menu-bar\(scheme == .light ? "-light" : "").png"), scheme: scheme)
        }
        // The map with something picked: the inspector beside it (an app's data, so every action shows).
        if let map = model.map {
            func all(_ n: DiskNode) -> [DiskNode] { [n] + n.children.flatMap(all) }
            let owned = all(map).filter { model.owningApp(of: $0) != nil && $0.url?.pathExtension != "app" }
            if let pick = owned.max(by: { $0.bytes < $1.bytes }) {
                save(MainView(screen: .map, override: AnyView(MapView(selected: pick))).environmentObject(model).environmentObject(library), size: size,
                     to: dir.appendingPathComponent("map-selected.png"))
            }
        }
        // The notch, collapsed and expanded, over a wallpaper-ish backdrop with the camera housing drawn in.
        let g = NotchController.geometry()
        let notchW = g.map { $0.notchWidth > 0 ? $0.notchWidth : 185 } ?? 185
        let notchH = g.map { $0.notchHeight } ?? 32
        for expanded in [false, true] {
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: 0x2B3A67), Color(hex: 0x6A4C93), Color(hex: 0xC06C84)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                NotchView(notchWidth: notchW, notchHeight: notchH, expanded: expanded, openApp: {})
                    .environmentObject(model)
                // The physical notch, so the composite shows how it wraps the camera.
                NotchShape(radius: 9).fill(Color.black).frame(width: notchW, height: notchH)
            }
            save(view, size: CGSize(width: 760, height: expanded ? 300 : 110),
                 to: dir.appendingPathComponent(expanded ? "notch-expanded.png" : "notch-collapsed.png"))
        }
        print("rendered to \(dir.path)")
    }

    /// The app icon: a glowing capacity ring on a graphite squircle, with the notch at the top.
    static func renderIcon(to url: URL) {
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1C2029), Color(hex: 0x07080B)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 230, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 6))
                .padding(100)
            GaugeRing(fraction: 0.72, tint: Theme.safe, lineWidth: 64).frame(width: 470, height: 470)
            Image(systemName: "sparkles").font(.system(size: 150, weight: .bold)).foregroundStyle(Theme.safe)
                .shadow(color: Theme.safe.opacity(0.6), radius: 30)
            NotchShape(radius: 38).fill(Color.black).frame(width: 300, height: 74).offset(y: -312)
        }
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    /// Let queued async work (a search) finish before drawing.
    static func settle(_ library: LibraryModel) {
        let deadline = Date().addingTimeInterval(8)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        while library.searching, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func save<V: View>(_ view: V, size: CGSize, to url: URL, scheme: ColorScheme = .dark) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .background(Theme.background)
            .environment(\.snapshotMode, true).environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            print("could not render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }
}

import SwiftUI
import HeadroomCore

enum Screen: String, CaseIterable, Identifiable {
    case home = "Home", today = "Today", recents = "Recents",
         images = "Images", videos = "Videos", music = "Music", documents = "Documents", archives = "Archives", apps = "Apps",
         overview = "Overview",
         files = "Large files", screenshots = "Screenshots", duplicates = "Duplicates", cleanUp = "Clean up", downloads = "Downloaded from",
         worktrees = "Worktrees", buildOutput = "Build output", devCaches = "Dev caches",
         map = "Map", reclaim = "Reclaim", memory = "Memory", battery = "Battery", ai = "AI", drives = "Drives", activity = "Activity",
         search = "Search", saved = "Saved search", folder = "Folder", workspace = "Workspace",
         settings = "Settings"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .home: "house"
        case .today: "checkmark.circle"
        case .recents: "clock"
        case .images: "photo"
        case .videos: "film"
        case .music: "music.note"
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .apps: "app.badge"
        case .overview: "gauge.with.dots.needle.67percent"
        case .files: "doc.text.magnifyingglass"
        case .screenshots: "camera.viewfinder"
        case .duplicates: "square.on.square"
        case .cleanUp: "wand.and.stars"
        case .downloads: "arrow.down.circle"
        case .worktrees: "arrow.triangle.branch"
        case .buildOutput: "shippingbox"
        case .devCaches: "hammer"
        case .map: "square.grid.3x3.square"
        case .reclaim: "sparkles"
        case .memory: "memorychip"
        case .battery: "battery.75percent"
        case .ai: "sparkles.rectangle.stack"
        case .drives: "externaldrive"
        case .activity: "clock.arrow.circlepath"
        case .search: "magnifyingglass"
        case .saved: "magnifyingglass.circle"
        case .folder: "folder"
        case .workspace: "rectangle.stack"
        case .settings: "gearshape"
        }
    }

    /// ⌘1…⌘9.
    static let numbered: [Screen] = [.home, .recents, .images, .videos, .music, .documents, .archives, .apps, .overview]

    var shortcut: String? {
        if let i = Self.numbered.firstIndex(of: self) { return "⌘\(i + 1)" }
        switch self {
        case .duplicates: return "⇧⌘D"
        case .cleanUp: return "⇧⌘K"
        case .downloads: return "⇧⌘J"
        case .settings: return "⌘,"
        default: return nil
        }
    }

    var kind: FileKind? {
        switch self {
        case .images: .image
        case .videos: .video
        case .music: .audio
        case .documents: .document
        case .archives: .archive
        default: nil
        }
    }

    static func forKind(_ kind: FileKind) -> Screen {
        switch kind {
        case .image: .images
        case .video: .videos
        case .audio: .music
        case .document: .documents
        case .archive: .archives
        case .app, .other: .apps
        }
    }

    /// Screens that show files in the grid (with the inspector and view controls).
    var showsFiles: Bool {
        [.recents, .images, .videos, .music, .documents, .archives, .screenshots, .search, .saved, .folder, .workspace, .downloads, .cleanUp].contains(self)
    }
}

/// A count or size on a sidebar row.
struct SidebarBadge {
    var text: String
    var color: Color
    var whiteText = false
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: LibraryModel
    @State var screen: Screen = .home
    @State private var beforeSearch: Screen = .home
    @State private var removeWorkspace: Workspace?
    @State private var promptName = ""
    @AppStorage("sidebarHidden") private var sidebarHidden = false
    @AppStorage("look") private var look: Look = .playful
    @AppStorage("appearance") private var appearance: Appearance = .system
    var launchAtLogin: Binding<Bool> = .constant(false)
    /// The demo reel opens screens in a set state (a drilled-in map, a selection…).
    var override: AnyView? = nil
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        // The look is read by every colour; rebuilding the screens below picks up a switch at once.
        let _ = { Theme.look = look }()
        GeometryReader { geo in
            let narrow = geo.size.width < 860
            HStack(spacing: 0) {
                if !sidebarHidden && !narrow {
                    sidebar
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
                VStack(alignment: .leading, spacing: 0) {
                    toolbar(showSidebarButton: sidebarHidden || narrow)
                        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 14)
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 16) {
                            titleRow
                            content
                        }
                        .padding(.horizontal, 26)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        if library.showInspector, screen.showsFiles, geo.size.width > 980 {
                            Rectangle().fill(Theme.hairline).frame(width: 1)
                            InspectorView()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .id(look)
        }
        .foregroundStyle(Theme.textPrimary)
        .background(
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.accent.opacity(Theme.minimal ? 0 : 0.06), .clear], center: .topTrailing, startRadius: 10, endRadius: 650)
            }
        )
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast, undo: { model.undo(toast) }, dismiss: { model.toast = nil })
                    .padding(.bottom, 22).padding(.leading, sidebarHidden ? 0 : 232)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.toast)
        .animation(.easeInOut(duration: 0.2), value: library.showInspector)
        .animation(.easeInOut(duration: 0.2), value: sidebarHidden)
        .background(shortcuts)
        .task(id: screen) {
            if screen == .apps, model.apps.isEmpty { await model.scanApps() }
        }
        .onAppear {
            guard !snapshot else { return }
            Self.apply(appearance)
            if let s = library.requestedScreen { screen = s }
            if !library.searchText.trimmingCharacters(in: .whitespaces).isEmpty { screen = .search }
            library.requestedScreen = nil
        }
        .onChange(of: appearance) { _, a in Self.apply(a) }
        .onChange(of: library.searchText) { old, new in
            let empty = new.trimmingCharacters(in: .whitespaces).isEmpty
            if !empty, screen != .search { beforeSearch = screen; screen = .search }
            if empty, !old.isEmpty, screen == .search { screen = beforeSearch == .search ? .home : beforeSearch }
        }
        .onReceive(NotificationCenter.default.publisher(for: .headroomShowScreen)) { note in
            if let s = note.object as? Screen { screen = s; library.requestedScreen = nil }
        }
        .confirmSheet(trashTitle, isPresented: Binding(get: { library.trashRequest != nil }, set: { if !$0 { library.trashRequest = nil } }),
                      presenting: library.trashRequest) { items in
            Button("Move to Trash", role: .destructive) { Task { await library.trash(items) } }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            let folders = items.filter(\.isFolder).count
            Text((folders > 0 ? "Folders go with everything in them. " : "")
                 + "Put \(items.count == 1 ? "it" : "them") back any time from Activity — the space comes back when you empty the Trash.")
        }
        .confirmSheet("Remove “\(removeWorkspace?.name ?? "")”?", isPresented: Binding(get: { removeWorkspace != nil }, set: { if !$0 { removeWorkspace = nil } }),
                      presenting: removeWorkspace) { w in
            Button("Remove Workspace", role: .destructive) { library.removeWorkspace(w.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Only the workspace goes. Every folder and file in it stays exactly where it is.")
        }
        .sheet(isPresented: Binding(get: { library.tidyPlan != nil }, set: { if !$0 { library.tidyPlan = nil } })) {
            if let plan = library.tidyPlan { TidySheet(plan: plan).environmentObject(library) }
        }
        .alert(promptTitle, isPresented: Binding(get: { library.workspacePrompt != nil }, set: { if !$0 { library.workspacePrompt = nil } })) {
            TextField("Name", text: $promptName)
            Button(promptIsRename ? "Rename" : "Create") { commitPrompt() }
            Button("Cancel", role: .cancel) { library.workspacePrompt = nil }
        } message: {
            Text(promptIsRename ? "" : "A workspace gathers folders and files from anywhere on one page. Nothing is copied or moved.")
        }
        .onChange(of: library.workspacePrompt?.id) { _, _ in
            if case .rename(let id)? = library.workspacePrompt { promptName = library.workspaces.first { $0.id == id }?.name ?? "" } else { promptName = "" }
        }
    }

    /// Light, dark or the Mac's own setting, for the whole app (the notch stays dark regardless).
    static func apply(_ appearance: Appearance) {
        NSApp.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var promptIsRename: Bool { if case .rename? = library.workspacePrompt { true } else { false } }
    var promptTitle: String {
        switch library.workspacePrompt {
        case .create(let paths)? where !paths.isEmpty: "New workspace with \(paths.count == 1 ? "1 item" : "\(paths.count) items")"
        case .rename?: "Rename workspace"
        default: "New workspace"
        }
    }

    func commitPrompt() {
        switch library.workspacePrompt {
        case .create(let paths)?: library.createWorkspace(name: promptName, paths: paths)
        case .rename(let id)?: library.renameWorkspace(id, to: promptName)
        case nil: break
        }
        library.workspacePrompt = nil
    }

    var trashTitle: String {
        guard let items = library.trashRequest else { return "" }
        return items.count == 1 ? "Move “\(items[0].name)” to the Trash?" : "Move \(items.count) items to the Trash?"
    }

    // MARK: Content

    @ViewBuilder var content: some View {
        if let override { override } else { screenContent }
    }

    @ViewBuilder var screenContent: some View {
        if !Edition.available(screen) { FullVersionOnly(screen: screen) } else {
        switch screen {
        case .home: HomeView(go: { screen = $0 })
        case .today: TodayView()
        case .recents, .images, .videos, .music, .documents, .archives, .screenshots: KindScreen(screen: screen).id(screen)
        case .search: SearchScreen()
        case .saved: SavedSearchScreen().id(library.savedID)
        case .folder: FolderScreen()
        case .workspace: WorkspaceScreen().id(library.workspaceID)
        case .duplicates: DuplicatesView()
        case .downloads: DownloadedFromView()
        case .cleanUp: CleanUpView(openReclaim: { screen = .reclaim }, openDuplicates: { screen = .duplicates })
        case .overview: OverviewView(openReclaim: { screen = .reclaim }, openMap: { screen = .map })
        case .worktrees, .buildOutput, .devCaches: CodingScreen(screen: screen).id(screen)
        case .map: MapView()
        case .reclaim: ReclaimView()
        case .files: FilesView()
        case .apps: AppsView()
        case .memory: MemoryView()
        case .battery: BatteryView()
        case .ai: AIView()
        case .drives: DrivesView()
        case .activity: ActivityView()
        case .settings: SettingsView(launchAtLogin: launchAtLogin)
        }
        }
    }

    // MARK: Title

    var title: String {
        switch screen {
        case .home: HomeView.greeting()
        case .saved: library.saved.first { $0.id == library.savedID }?.name ?? "Saved search"
        case .workspace: library.currentWorkspace?.name ?? "Workspace"
        case .folder: library.browsePath.map { $0 == library.home ? (AppModel.demoMode ? "Home" : NSUserName()) : FileManager.default.displayName(atPath: $0) } ?? "Folder"
        default: screen.rawValue
        }
    }

    var subtitle: String? {
        switch screen {
        case .today:
            return Date().formatted(.dateTime.weekday(.wide).day().month(.wide))
        case .home:
            guard library.hasScanned else { return nil }
            let t = library.shelvedTotals
            return "\(t.count.formatted()) files · \(ByteFormat.string(t.bytes)) across your Mac"
        case .images, .videos, .music, .documents, .archives:
            guard let kind = screen.kind else { return nil }
            let t = library.totals(kind)
            return "\(t.count.formatted()) items · \(ByteFormat.string(t.bytes))"
        case .workspace:
            guard let w = library.currentWorkspace, !w.members.isEmpty else { return nil }
            let infos = w.paths.compactMap { library.members[$0] }
            let folders = infos.filter { $0.folder != nil }.count, files = infos.filter { $0.file != nil }.count
            let bytes = infos.reduce(Int64(0)) { $0 + ($1.folder?.bytes ?? $1.file?.bytes ?? 0) }
            var parts: [String] = []
            if folders > 0 { parts.append("\(folders) \(folders == 1 ? "folder" : "folders")") }
            if files > 0 { parts.append("\(files) \(files == 1 ? "file" : "files")") }
            if bytes > 0 { parts.append(ByteFormat.string(bytes)) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ") + " · nothing moved"
        case .worktrees, .buildOutput, .devCaches:
            let items = CodingScreen.items(screen, model: model)
            guard !items.isEmpty else { return nil }
            let bytes = screen == .worktrees ? Worktrees.total(model.worktrees) : items.reduce(0) { $0 + $1.size.allocated }
            return "\(items.count) \(screen == .worktrees ? "worktrees" : "items") · \(ByteFormat.string(bytes))"
        case .screenshots:
            let s = library.screenshots
            return "\(s.count.formatted()) screenshots · \(ByteFormat.string(s.reduce(0) { $0 + $1.bytes }))"
        default: return nil
        }
    }

    var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary) }
            }
            Spacer()
            if screen.showsFiles && screen != .cleanUp && (screen != .downloads || library.sourceID != nil) { viewControls }
            if screen == .home { diskPill }
        }
    }

    /// Sort, grid or list, card size.
    var viewControls: some View {
        HStack(spacing: 8) {
            if snapshot {
                Label("Sort: \(library.sort.rawValue)", systemImage: "arrow.up.arrow.down").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                if screen == .folder { GroupMenu() }
            } else {
                sortMenu
                if screen == .folder { GroupMenu() }
                if library.viewMode == .grid {
                    Slider(value: $library.cardSize, in: 110...320).frame(width: 90).controlSize(.mini).help("Card size  ⌘+  ⌘−")
                }
            }
            HStack(spacing: 2) {
                modeButton(.grid, "square.grid.2x2", "Grid  ⌃⌘1")
                modeButton(.list, "list.bullet", "List  ⌃⌘2")
            }
            .padding(2).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(0.06)))
        }
    }

    var sortMenu: some View {
            Menu {
                ForEach(LibraryModel.Sort.allCases) { s in
                    Button { library.sort = s } label: { if library.sort == s { Label(s.rawValue, systemImage: "checkmark") } else { Text(s.rawValue) } }
                }
                Divider()
                Button(library.ascending ? "Descending" : "Ascending") { library.ascending.toggle() }
            } label: {
                Label("Sort: \(library.sort.rawValue)", systemImage: "arrow.up.arrow.down").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
    }

    func modeButton(_ mode: LibraryModel.ViewMode, _ symbol: String, _ help: String) -> some View {
        Button { library.viewMode = mode } label: {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)).frame(width: 26, height: 22)
                .foregroundStyle(library.viewMode == mode ? Theme.textPrimary : Theme.textTertiary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(library.viewMode == mode ? Theme.surface : .clear))
        }
        .buttonStyle(.plain).help(help)
    }

    /// Free space at a glance, and the safe one-click reclaim.
    var diskPill: some View {
        HStack(spacing: 10) {
            GaugeRing(fraction: model.volume.usedFraction, tint: Theme.color(for: model.volume.health), lineWidth: 3.5)
                .frame(width: 18, height: 18)
            Text("\(model.volume.free.gb) free").font(.system(size: 12, weight: .semibold))
            if model.safeReclaimable > 0 {
                Button { screen = .reclaim } label: {
                    Text("Reclaim \(ByteFormat.compact(model.safeReclaimable)) safely").font(.system(size: 11.5, weight: .semibold))
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.leading, 10).padding(.trailing, model.safeReclaimable > 0 ? 4 : 12).padding(.vertical, 4)
        .background(Capsule().fill(Theme.surface).shadow(color: Theme.shadow, radius: 6, y: 2))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    // MARK: Toolbar

    func toolbar(showSidebarButton: Bool) -> some View {
        HStack(spacing: 10) {
            if showSidebarButton {
                Button { sidebarHidden = false } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(GhostButtonStyle()).help("Show sidebar  ⌃⌘S").padding(.leading, sidebarHidden ? 64 : 0)
            }
            LibrarySearchBar().frame(maxWidth: 560)
            Spacer(minLength: 8)
            MiniPlayer(player: library.player)
            statusLine
            lookSwitch
            if screen.showsFiles {
                Button { library.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(GhostButtonStyle()).help(library.showInspector ? "Hide info  ⌘I" : "Show info  ⌘I")
            }
        }
    }

    var lookSwitch: some View {
        HStack(spacing: 2) {
            ForEach(Look.allCases) { l in
                Button { look = l } label: {
                    Image(systemName: l == .playful ? "paintpalette" : "circle.lefthalf.filled")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 22)
                        .foregroundStyle(look == l ? Theme.textPrimary : Theme.textTertiary)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(look == l ? Theme.surface : .clear))
                }
                .buttonStyle(.plain).help("\(l.title) look  ⌃⌘T")
            }
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(0.06)))
    }

    var statusLine: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .scanning(let s), .reclaiming(let s):
                ProgressView().controlSize(.small)
                Text(s).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            case .done(let freed):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.safe)
                Text("Freed \(freed.gb)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.safe)
            case .idle:
                if !model.waitingForAccess.isEmpty {
                    Label("Waiting for permission", systemImage: "hand.raised.fill").font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.review)
                        .help("macOS is asking whether Headroom may look in "
                              + model.waitingForAccess.map { LibraryModel.display($0) }.joined(separator: ", ")
                              + ". Answer the prompt (or turn Headroom on in System Settings → Privacy & Security → Files and Folders), then rescan with ⌘R.")
                }
                if library.scanning {
                    ProgressView().controlSize(.small)
                    Text("Updating library…").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                } else if let r = library.reading, r.total > 0 {
                    Text("Reading text \(r.done)/\(r.total)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        .help("Headroom reads the text in your screenshots and photos on this Mac, so you can search it")
                }
                Button { rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle())
                    .help("Rescan  ⌘R" + (model.lastScan.map { " — last \($0.ago)" } ?? ""))
            }
        }
    }

    func rescan() {
        Task { await library.scan() }
        Task { await model.scan(); await model.buildMap() }
    }

    // MARK: Shortcuts

    var shortcuts: some View {
        ZStack {
            ForEach(Array(Screen.numbered.enumerated()), id: \.offset) { i, s in
                Button("") { screen = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            // ⌃1…⌃9: your workspaces, in sidebar order.
            ForEach(0..<9, id: \.self) { i in
                Button("") { library.openWorkspace(at: i) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .control)
            }
            Button("") { library.workspacePrompt = .create(paths: []) }.keyboardShortcut("n", modifiers: [.option, .command])
            // ⌥⌘T: tidy the folder on screen (Desktop from anywhere else).
            Button("") { Task { await library.planTidy(screen == .folder ? (library.browsePath ?? library.home + "/Desktop") : library.home + "/Desktop") } }
                .keyboardShortcut("t", modifiers: [.option, .command])
            // ⌥⇧⌘T / ⌥⇧⌘E: the folder on screen in your terminal / code editor.
            Button("") { if screen == .folder { DevOpen.open(library.browsePath ?? library.home, in: .terminal, model: model) } }
                .keyboardShortcut("t", modifiers: [.option, .shift, .command])
            Button("") { if screen == .folder { DevOpen.open(library.browsePath ?? library.home, in: .editor, model: model) } }
                .keyboardShortcut("e", modifiers: [.option, .shift, .command])
            Button("") { rescan() }.keyboardShortcut("r", modifiers: .command).disabled(model.isBusy)
            Button("") { library.focusSearch += 1 }.keyboardShortcut("f", modifiers: .command)
            Button("") { library.viewMode = .grid }.keyboardShortcut("1", modifiers: [.control, .command])
            Button("") { library.viewMode = .list }.keyboardShortcut("2", modifiers: [.control, .command])
            Button("") { library.showInspector.toggle() }.keyboardShortcut("i", modifiers: .command)
            Button("") { screen = .downloads }.keyboardShortcut("j", modifiers: [.shift, .command])
            Button("") { screen = .duplicates }.keyboardShortcut("d", modifiers: [.shift, .command])
            Button("") { library.cleanUpFocus = nil; screen = .cleanUp }.keyboardShortcut("k", modifiers: [.shift, .command])
            Button("") { library.bump(24) }.keyboardShortcut("+", modifiers: .command)
            Button("") { library.bump(24) }.keyboardShortcut("=", modifiers: .command)
            Button("") { library.bump(-24) }.keyboardShortcut("-", modifiers: .command)
            Button("") { look = look == .playful ? .minimal : .playful }.keyboardShortcut("t", modifiers: [.control, .command])
            Button("") { sidebarHidden.toggle() }.keyboardShortcut("s", modifiers: [.control, .command])
            Button("") { library.player.toggle() }.keyboardShortcut("p", modifiers: [.option, .command])
            Button("") { library.player.previous() }.keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            Button("") { library.player.next() }.keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            Button("") { screen = .settings }.keyboardShortcut(",", modifiers: .command)
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                GaugeRing(fraction: model.volume.usedFraction, tint: Theme.color(for: model.volume.health), lineWidth: 4)
                    .frame(width: 20, height: 20)
                Text("Headroom").font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Button { sidebarHidden = true } label: { Image(systemName: "sidebar.left") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Hide sidebar  ⌃⌘S")
            }
            .padding(.horizontal, 10).padding(.top, 38).padding(.bottom, 14)

            Scrolling {
                VStack(alignment: .leading, spacing: 1) {
                    navItem(.home)
                    if model.plannerAddOn { navItem(.today, badge: todayBadge) }
                    navItem(.recents)
                    group("Workspaces")
                    ForEach(Array(library.workspaces.enumerated()), id: \.element.id) { i, w in workspaceItem(w, index: i) }
                    Button { library.workspacePrompt = .create(paths: []) } label: {
                        row(title: "New Workspace…", symbol: "plus", on: false)
                    }
                    .buttonStyle(.plain).help("Gather folders and files from anywhere on one page  ⌥⌘N")
                    group("Library")
                    ForEach([Screen.images, .videos, .music, .documents, .archives, .apps]) { s in
                        navItem(s, count: s.kind.map { library.totals($0).count } ?? (s == .apps ? model.apps.count : nil))
                    }
                    group("Smart folders")
                    navItem(.files, badge: model.bigFiles.isEmpty ? nil : SidebarBadge(text: "\(model.bigFiles.count)", color: Theme.critical, whiteText: true))
                    navItem(.screenshots, count: library.screenshotCount)
                    navItem(.duplicates, badge: library.duplicateBytes > 0 ? SidebarBadge(text: ByteFormat.compact(library.duplicateBytes), color: Theme.review) : nil)
                    navItem(.cleanUp, badge: cleanUpBytes > 0 ? SidebarBadge(text: ByteFormat.compact(cleanUpBytes), color: Theme.safe) : nil)
                    navItem(.downloads, count: library.bySource.count)
                    if !library.saved.isEmpty {
                        group("Saved searches")
                        ForEach(library.saved) { s in savedItem(s) }
                    }
                    group("Coding")
                    navItem(.worktrees, badge: codingBadge(.worktrees))
                    navItem(.buildOutput, badge: codingBadge(.buildOutput))
                    navItem(.devCaches, badge: codingBadge(.devCaches))
                    group("Disk")
                    navItem(.overview)
                    navItem(.map)
                    navItem(.reclaim, badge: model.safeReclaimable > 0 ? SidebarBadge(text: ByteFormat.compact(model.safeReclaimable), color: Theme.safe) : nil)
                    if Edition.available(.memory) { navItem(.memory) }
                    if model.showsBattery { navItem(.battery, badge: batteryBadge) }
                    if Edition.available(.ai) { navItem(.ai) }
                    if Edition.available(.drives) { navItem(.drives) }
                    navItem(.activity, badge: model.waitingInTrash.bytes > 0 ? SidebarBadge(text: ByteFormat.compact(model.waitingInTrash.bytes), color: Theme.review) : nil)
                    group("Locations")
                    ForEach(locations, id: \.path) { loc in locationItem(loc.name, loc.path, loc.symbol) }
                    ForEach(library.pinned, id: \.self) { path in
                        locationItem(FileManager.default.displayName(atPath: path), path, "pin", pinned: true)
                    }
                }
                .padding(.bottom, 10)
            }
            navItem(.settings).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.volume.free.gb).font(Theme.number(15, weight: .bold)).foregroundStyle(Theme.color(for: model.volume.health))
                Text("free of \(model.volume.total.gb)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
            .padding(.top, 8)
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(width: 232)
        .background(Theme.sidebar)
    }

    func codingBadge(_ s: Screen) -> SidebarBadge? {
        let items = CodingScreen.items(s, model: model)
        let bytes = s == .worktrees ? Worktrees.total(model.worktrees) : items.reduce(0) { $0 + $1.size.allocated }
        return bytes > 0 ? SidebarBadge(text: ByteFormat.compact(bytes), color: Theme.color(for: CodingScreen.category(s))) : nil
    }

    /// Big ones still open today.
    var todayBadge: SidebarBadge? {
        let open = model.planner.bigToday().filter { !$0.isDone }.count
        return open > 0 ? SidebarBadge(text: "\(open)", color: Theme.review) : nil
    }

    /// Only when something needs attention: heat, or a battery due for service.
    var batteryBadge: SidebarBadge? {
        guard let b = model.battery else { return nil }
        if b.hot { return SidebarBadge(text: String(format: "%.0f°", b.temperature), color: Theme.critical, whiteText: true) }
        if b.failed || b.health < 0.8 { return SidebarBadge(text: "\(b.healthPercent)%", color: Theme.review) }
        return nil
    }

    var cleanUpBytes: Int64 { library.suggestions.reduce(0) { $0 + $1.bytes } }

    var locations: [(name: String, path: String, symbol: String)] {
        let home = library.home
        var out: [(String, String, String)] = [(AppModel.demoMode ? "Home" : NSUserName(), home, "house")]
        for (name, symbol) in [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"),
                               ("Pictures", "photo"), ("Movies", "film"), ("Music", "music.note")] {
            let p = home + "/" + name
            if FileManager.default.fileExists(atPath: p) { out.append((name, p, symbol)) }
        }
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: iCloud) { out.append(("iCloud Drive", iCloud, "icloud")) }
        return out.map { (name: $0.0, path: $0.1, symbol: $0.2) }
    }

    func group(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 4)
    }

    func navItem(_ s: Screen, count: Int? = nil, badge: SidebarBadge? = nil) -> some View {
        let on = screen == s
        return Button {
            if s == .cleanUp { library.cleanUpFocus = nil }
            if s == .downloads { library.sourceID = nil }
            screen = s
        } label: {
            row(title: s.rawValue, symbol: s.symbol, on: on, tint: s.kind.map(Theme.tint(for:)) ?? (s == .apps ? Theme.tint(for: .app) : nil),
                count: count, badge: badge)
        }
        .buttonStyle(.plain)
        .help(s.shortcut.map { "\(s.rawValue)  \($0)" } ?? s.rawValue)
    }

    func row(title: String, symbol: String, on: Bool, tint: Color? = nil, count: Int? = nil, badge: SidebarBadge? = nil) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .semibold)).frame(width: 18)
                .foregroundStyle(tint.map { Theme.minimal ? Theme.textSecondary : $0 } ?? (on ? Theme.textPrimary : Theme.textSecondary))
            Text(title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 4)
            if let badge {
                Text(badge.text).font(Theme.number(10.5, weight: .bold))
                    .foregroundStyle(badge.whiteText ? .white : .black).padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(badge.color))
            } else if let count, count > 0 {
                Text(count.formatted()).font(Theme.number(11, weight: .medium)).foregroundStyle(Theme.textTertiary)
            }
        }
        .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.fill(0.09) : .clear))
        .contentShape(Rectangle())
    }

    func savedItem(_ s: SavedSearch) -> some View {
        Button { library.savedID = s.id; screen = .saved } label: {
            row(title: s.name, symbol: "magnifyingglass", on: screen == .saved && library.savedID == s.id)
        }
        .buttonStyle(.plain)
        .help("“\(s.query)”")
        .contextMenu {
            Button("Edit Search") { library.search(s.query) }
            Button("Remove from Sidebar") { library.saved.removeAll { $0.id == s.id } }
        }
    }

    func workspaceItem(_ w: Workspace, index: Int) -> some View {
        Button { library.openWorkspace(w.id) } label: {
            row(title: w.name, symbol: "rectangle.stack", on: screen == .workspace && library.workspaceID == w.id,
                tint: Theme.minimal ? nil : Theme.accent, count: w.members.count)
        }
        .buttonStyle(.plain)
        .help(index < 9 ? "\(w.name)  ⌃\(index + 1)" : w.name)
        .modifier(WorkspaceDrop(id: w.id))
        .contextMenu {
            Button("Rename…") { library.workspacePrompt = .rename(w.id) }
            Button("Remove Workspace…") { removeWorkspace = w }
        }
    }

    func locationItem(_ name: String, _ path: String, _ symbol: String, pinned: Bool = false) -> some View {
        Button {
            library.browseHistory = []
            library.browse(path)
            screen = .folder
        } label: {
            row(title: name, symbol: symbol, on: screen == .folder && library.browsePath == path, tint: Theme.minimal ? nil : Color(hex: 0x4A9EFF))
        }
        .buttonStyle(.plain)
        .help((path as NSString).abbreviatingWithTildeInPath)
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            if library.canTidy(path) { Button("Tidy \(name)…") { Task { await library.planTidy(path) } } }
            if pinned { Button("Unpin from Sidebar") { library.pinned.removeAll { $0 == path } } }
        }
    }
}

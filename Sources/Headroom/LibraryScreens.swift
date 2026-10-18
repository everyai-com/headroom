import SwiftUI
import AppKit
import HeadroomCore

/// The search box at the top of the window. Plain English works: "pdfs from last week over 5 mb".
struct LibrarySearchBar: View {
    @EnvironmentObject var library: LibraryModel
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            if snapshot {
                Text(library.searchText.isEmpty ? "Search, or try “pdfs from last week”…" : library.searchText)
                    .font(.system(size: 13)).foregroundStyle(library.searchText.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
            } else {
                TextField("", text: $library.searchText, prompt: Text("Search, or try “pdfs from last week”…").foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($focused)
                    .onExitCommand { library.searchText = ""; focused = false }
            }
            if library.searching { ProgressView().controlSize(.mini) }
            if !library.searchText.isEmpty {
                Button { library.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            } else {
                Keycap("⌘F")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface)
            .shadow(color: Theme.shadow, radius: 8, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: focused ? 1.5 : 1))
        .onChange(of: library.focusSearch) { _, _ in focused = true }
    }
}

/// A key, drawn like one: ⌘F, ⇧⌘D…
struct Keycap: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.fill(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// How the search was understood: one chip per filter. ✕ takes that part out of the search.
struct QueryChips: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        let q = library.query
        if !q.chips.isEmpty {
            FlowLayout(spacing: 6) {
                Text("Looking for").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.vertical, 5)
                ForEach(q.chips) { chip in
                    HStack(spacing: 5) {
                        Image(systemName: chip.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(color(chip.kind))
                        Text(chip.label).font(.system(size: 12, weight: .medium))
                        Button { library.searchText = chip.removing } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain).help("Remove")
                    }
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(color(chip.kind).opacity(0.12)))
                    .overlay(Capsule().strokeBorder(color(chip.kind).opacity(0.3)))
                }
            }
        }
    }

    func color(_ kind: LibraryQuery.Chip.Kind) -> Color {
        if Theme.minimal { return Theme.textPrimary }
        switch kind {
        case .type: return Theme.tint(for: .image)
        case .date: return Theme.tint(for: .video)
        case .size: return Theme.tint(for: .audio)
        case .source, .device: return Theme.tint(for: .app)
        case .folder: return Theme.tint(for: .archive)
        case .text: return Theme.tint(for: .document)
        }
    }
}

/// Things to try in the search box.
struct SearchExamples: View {
    @EnvironmentObject var library: LibraryModel
    static let examples = ["pdfs from last week over 5 mb", "videos from my iphone in august", "screenshots with wifi password",
                           "zips bigger than 1gb older than 6 months", "pdfs from gmail", "images from chatgpt", "music under 10 mb",
                           "installers in downloads"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Try asking").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            FlowLayout(spacing: 8) {
                ForEach(Self.examples, id: \.self) { e in
                    Button { library.search(e) } label: {
                        Text("“\(e)”").font(.system(size: 12.5)).padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Capsule().fill(Theme.fill(0.05))).overlay(Capsule().strokeBorder(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Screens

/// One shelf (Images, Videos…), Recents or Screenshots: the files, with type and source filters.
struct KindScreen: View {
    @EnvironmentObject var library: LibraryModel
    @Environment(\.snapshotMode) private var snapshot
    var screen: Screen
    @State private var ext: String?
    @State private var source: String?

    var all: [LibraryItem] {
        switch screen {
        case .recents: library.recents
        case .screenshots: library.screenshots
        default: screen.kind.map(library.items) ?? []
        }
    }

    var body: some View {
        let base = all
        let shown = base.filter { (ext == nil || $0.ext == ext) && (source == nil || DownloadSources.source(of: $0)?.id == source) }
        if !library.hasScanned {
            LoadingLibrary()
        } else if base.isEmpty {
            EmptyState(symbol: screen.symbol, title: "No \(screen.rawValue.lowercased()) yet",
                       detail: "Headroom looks in your own folders — Desktop, Documents, Downloads, Pictures, Movies, Music and iCloud Drive.")
        } else {
            FileGrid(items: shown, header: AnyView(filters(base)))
        }
    }

    func filters(_ base: [LibraryItem]) -> some View {
        let facets = library.facets(screen.rawValue, base)
        let exts = facets.extensions
        let sources = facets.sources
        return HStack(alignment: .top, spacing: 8) {
            if exts.count > 1 {
                FlowLayout(spacing: 8) {
                    Pill(title: "All", on: ext == nil) { ext = nil }
                    ForEach(Array(exts), id: \.0) { e, n in
                        Pill(title: "\(e.uppercased()) · \(n.formatted())", on: ext == e) { ext = ext == e ? nil : e }
                    }
                }
            }
            Spacer(minLength: 0)
            if snapshot, !sources.isEmpty {
                Label("From anywhere", systemImage: "arrow.down.circle").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary).padding(.top, 6)
            } else if !sources.isEmpty {
                Menu {
                    Button("Anywhere") { source = nil }
                    Divider()
                    ForEach(sources.prefix(25), id: \.0.id) { s, n in
                        Button("\(s.name) (\(n))") { source = s.id }
                    }
                } label: {
                    Label(source.flatMap { id in sources.first { $0.0.id == id }?.0.name }.map { "From \($0)" } ?? "From anywhere",
                          systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Show only what you downloaded from one place  ⇧⌘J")
            }
        }
    }
}

/// Search results with the chips that show how the search was read.
struct SearchScreen: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        if library.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            Card { SearchExamples() }
            Spacer()
        } else {
            let results = library.results
            FileGrid(items: results, header: AnyView(VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    QueryChips()
                    Spacer()
                    Button { library.saveSearch() } label: { Label("Save to Sidebar", systemImage: "plus.magnifyingglass") }
                        .buttonStyle(GhostButtonStyle())
                        .disabled(library.saved.contains { $0.query == library.searchText.trimmingCharacters(in: .whitespaces) })
                        .help("Keep this search in the sidebar — it always shows what matches right now")
                }
                if results.isEmpty, !library.searching {
                    EmptyState(symbol: "magnifyingglass", title: "Nothing matches",
                               detail: "Try fewer words, or take a filter off with its ✕. Text inside images appears as Headroom reads them\(library.reading.map { " (\($0.done) of \($0.total) so far)" } ?? "").")
                } else {
                    Text("\(results.count) \(results.count == 1 ? "file" : "files") · \(ByteFormat.string(results.reduce(0) { $0 + $1.bytes }))")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }))
        }
    }
}

/// A saved search: what matches right now.
struct SavedSearchScreen: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        if let saved = library.saved.first(where: { $0.id == library.savedID }) {
            let items = library.matches(for: saved.query)
            FileGrid(items: items, header: AnyView(HStack {
                Label("“\(saved.query)”", systemImage: "magnifyingglass").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                Text("· \(items.count) files").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Edit Search") { library.search(saved.query); NotificationCenter.default.post(name: .headroomShowScreen, object: Screen.search) }
                    .buttonStyle(GhostButtonStyle())
                Button("Remove from Sidebar") {
                    library.saved.removeAll { $0.id == saved.id }
                    NotificationCenter.default.post(name: .headroomShowScreen, object: Screen.home)
                }
                .buttonStyle(GhostButtonStyle())
            }))
        } else {
            EmptyState(symbol: "magnifyingglass", title: "This search is gone", detail: "Pick another one in the sidebar.")
        }
    }
}

/// A folder, like Finder: subfolders first, double-click to go in, the path to go back up.
struct FolderScreen: View {
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshot
    @AppStorage("folderGrouping") private var grouping: FolderGrouping = .none
    @State private var items: [LibraryItem] = []
    @State private var loaded: String?

    var body: some View {
        let path = library.browsePath ?? library.home
        // A render can't wait for the background listing: read the folder now.
        let items = snapshot ? LibraryScanner.list(folder: URL(fileURLWithPath: path)) : self.items
        VStack(alignment: .leading, spacing: 12) {
            breadcrumb(path)
            if loaded != path, !snapshot {
                LoadingLibrary(text: "Opening \((path as NSString).lastPathComponent)…")
            } else if items.isEmpty {
                EmptyState(symbol: "folder", title: "This folder is empty", detail: LibraryModel.display(path))
            } else {
                let groups = grouping.groups(items)
                FileGrid(items: groups.flatMap(\.items), groups: grouping == .none ? nil : groups)
            }
        }
        .task(id: path) { await load(path) }
        .onChange(of: library.index.scannedAt) { _, _ in Task { await load(path, changed: true) } }
        // Something here went to the Trash: show the folder as it is now.
        .onChange(of: library.index.items.count) { _, _ in Task { await load(path, changed: true) } }
        // Undo from the toast (a tidy put back) changes the folder too.
        .onChange(of: model.activity.entries.map(\.restored)) { _, _ in Task { await load(path, changed: true) } }
    }

    /// List the folder; when something in it changed, its subfolders' sizes and git status are read again.
    func load(_ path: String, changed: Bool = false) async {
        let url = URL(fileURLWithPath: path)
        let list = await Task.detached(priority: .userInitiated) { LibraryScanner.list(folder: url) }.value
        items = list
        loaded = path
        if changed {
            FolderInfoStore.shared.invalidate(list.filter(\.isFolder).map(\.path))
            await FolderInfoStore.shared.refreshGit(path)
        }
    }

    func breadcrumb(_ path: String) -> some View {
        let home = library.home
        var parts: [(String, String)] = []
        var p = path
        while true {
            let name = p == home ? (AppModel.demoMode ? "Home" : NSUserName()) : FileManager.default.displayName(atPath: p)
            parts.insert((name, p), at: 0)
            if p == home || p == "/" || !p.hasPrefix(home) && parts.count > 3 { break }
            p = (p as NSString).deletingLastPathComponent
        }
        return HStack(spacing: 4) {
            Button { library.browseBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(GhostButtonStyle()).disabled(library.browseHistory.isEmpty).help("Back")
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textTertiary) }
                Button(part.0) { library.browse(part.1) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: i == parts.count - 1 ? .semibold : .regular))
                    .foregroundStyle(i == parts.count - 1 ? Theme.textPrimary : Theme.textSecondary)
            }
            GitBadge(path: path).padding(.leading, 6)
            Spacer()
            if library.canTidy(path) {
                Button { Task { await library.planTidy(path) } } label: { Label("Tidy…", systemImage: "wand.and.stars") }
                    .buttonStyle(GhostButtonStyle())
                    .help("Put the loose files here into folders by kind — you see the plan first, and Undo puts it back  ⌥⌘T")
            }
            Button { library.reveal([LibraryItem(path: path, kind: .other, bytes: 0, created: .now, modified: .now, isFolder: true)]) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .buttonStyle(GhostButtonStyle())
            OpenInMenu(path: path)
            if !library.pinned.contains(path) {
                Button { library.pin(path) } label: { Label("Pin", systemImage: "pin") }.buttonStyle(GhostButtonStyle())
                    .help("Pin this folder to the sidebar")
            }
            if snapshot {
                // ImageRenderer can't draw a Menu.
                Label("Add to Workspace", systemImage: "rectangle.stack.badge.plus").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Menu {
                    ForEach(library.workspaces) { w in
                        Button(w.name) { library.addToWorkspace(w.id, paths: [path]) }.disabled(w.contains(path))
                    }
                    if !library.workspaces.isEmpty { Divider() }
                    Button("New Workspace…") { library.workspacePrompt = .create(paths: [path]) }
                } label: {
                    Label("Add to Workspace", systemImage: "rectangle.stack.badge.plus").font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Put this folder on a workspace page — it stays where it is")
            }
        }
    }
}

/// While the first library scan runs.
struct LoadingLibrary: View {
    var text = "Looking through your folders…"

    var body: some View {
        Card {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

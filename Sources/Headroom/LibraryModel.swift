import SwiftUI
import AppKit
import HeadroomCore

/// SwiftUI ships a `LibraryItem` of its own (for Xcode's library); in this app the name means ours.
typealias LibraryItem = HeadroomCore.LibraryItem

/// A search you kept in the sidebar. It always shows what matches right now.
struct SavedSearch: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var query: String
}

/// Your files: the library index, search, selection, duplicates, clean-up cards and the view
/// settings for the grid. Shared by the window, the Quick Search panel and the menu bar.
@MainActor
final class LibraryModel: ObservableObject {
    let app: AppModel
    /// Demo runs keep their recognised text apart from yours.
    let text = AppModel.demoMode ? TextIndex(url: AppModel.demoRoot.appendingPathComponent(".headroom-text.plist")) : TextIndex()
    let player = MusicPlayer()

    @Published var index: LibraryIndex { didSet { summarize() } }
    /// Per-kind totals and newest files, worked out once per index (the sidebar and Home redraw often).
    private(set) var kindTotals: [FileKind: LibraryIndex.Totals] = [:]
    private(set) var newest: [FileKind: [LibraryItem]] = [:]
    private(set) var newestOverall: [LibraryItem] = []
    private(set) var shelvedTotals = LibraryIndex.Totals()
    private(set) var screenshotCount = 0
    @Published var scanning = false
    /// Text recognition in the background: done / total.
    @Published var reading: (done: Int, total: Int)?
    /// Recognised text by path (a snapshot of `text`, for search).
    @Published var recognized: [String: String] = [:]

    @Published var duplicates: [DuplicateGroup] = []
    @Published var lookAlikes: [DuplicateGroup] = []
    @Published var duplicatesProgress: Double?
    @Published var duplicatesScanned: Date?
    @Published var suggestions: [CleanUpSuggestion] = []
    /// Spotlight's "last opened" for Downloads and videos (forgotten downloads, big old videos).
    var lastUsed: [String: Date] = [:]
    /// Copies Mail kept of attachments you opened (not in the index: they live in Mail's container).
    var mailAttachments: [LibraryItem] = []

    // MARK: Search

    @Published var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    @Published private(set) var query = LibraryQuery.parse("")
    @Published private(set) var results: [LibraryItem] = []
    @Published private(set) var searching = false
    /// Bumped to put the cursor in the search field (⌘F).
    @Published var focusSearch = 0
    private var searchTask: Task<Void, Never>?
    private var contentHits: Set<String> = []
    private var devices: [String: String] = [:]

    /// What you open from Quick Search, for its ranking (demo runs remember nothing).
    private(set) var quickHistory = AppModel.demoMode ? Frecency() : Frecency.load()
    private var quickHistorySave: Task<Void, Never>?

    /// You picked a file (its path) or a command (`QuickCommand.historyKey`) after typing `query`.
    func recordQuickPick(_ key: String, query: String) {
        quickHistory.record(key, query: query)
        saveQuickHistory()
    }

    /// "Remove from Suggestions": that file, app or command stops counting.
    func forgetQuickPick(_ key: String) {
        quickHistory.forget(key)
        saveQuickHistory()
    }

    func forgetQuickHistory() {
        quickHistory = Frecency()
        saveQuickHistory()
    }

    /// One write at a time, in order, off the main thread.
    private func saveQuickHistory() {
        guard !AppModel.demoMode else { return }
        let snapshot = quickHistory, previous = quickHistorySave
        quickHistorySave = Task.detached(priority: .utility) {
            await previous?.value
            snapshot.save()
        }
    }

    // MARK: Sidebar

    @Published var saved: [SavedSearch] = LibraryModel.load("savedSearches") ?? [] { didSet { Self.store(saved, "savedSearches") } }
    @Published var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? [] {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinnedFolders") }
    }
    /// The folder shown by the folder screen, the saved search shown, the download source shown.
    @Published var browsePath: String?
    @Published var savedID: UUID?
    @Published var sourceID: String?
    @Published var browseHistory: [String] = []
    // MARK: Workspaces

    /// Demo runs keep their workspaces apart from yours; renders don't save theirs at all.
    static var workspaceStore: URL {
        AppModel.demoMode ? AppModel.demoRoot.appendingPathComponent(".headroom-workspaces.json") : Workspaces.storeURL
    }
    var persistWorkspaces = true
    @Published var workspaces: [Workspace] = Workspaces.load(from: LibraryModel.workspaceStore).map(Workspaces.relocated) {
        didSet { if persistWorkspaces { Workspaces.save(workspaces, to: Self.workspaceStore) } }
    }
    @Published var workspaceID: UUID?
    /// What each workspace member is right now (a folder's summary, a file, or gone), by path.
    @Published var members: [String: MemberInfo] = [:]
    /// The new-workspace or rename prompt (the window shows it).
    @Published var workspacePrompt: WorkspacePrompt?

    struct MemberInfo: Hashable {
        var state: Workspaces.State
        var folder: Workspaces.FolderSummary?
        var file: LibraryItem?
    }

    enum WorkspacePrompt: Identifiable {
        case create(paths: [String])
        case rename(UUID)
        var id: String {
            switch self {
            case .create(let p): "new:" + p.joined(separator: "|")
            case .rename(let id): "rename:" + id.uuidString
            }
        }
    }

    /// A screen asked for before the window existed (Quick Search's ⌘↩, the menu bar); the window shows it when it opens.
    var requestedScreen: Screen?
    /// The clean-up card being reviewed (nil = all cards).
    @Published var cleanUpFocus: CleanUpSuggestion.Kind?

    // MARK: View

    enum ViewMode: String { case grid, list }
    enum Sort: String, CaseIterable, Identifiable {
        case date = "Date", name = "Name", size = "Size", kind = "Kind"
        var id: String { rawValue }
    }

    @Published var viewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "libraryView") ?? "") ?? .grid {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "libraryView") }
    }
    @Published var cardSize: Double = UserDefaults.standard.object(forKey: "cardSize") as? Double ?? 168 {
        didSet { UserDefaults.standard.set(cardSize, forKey: "cardSize") }
    }
    @Published var sort = Sort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .date {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "librarySort"); cache.removeAll() }
    }
    @Published var ascending = false { didSet { cache.removeAll() } }
    @Published var showInspector = UserDefaults.standard.bool(forKey: "showInspector") {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }
    @Published var selection: Set<String> = []
    /// Files waiting for the "Move to Trash?" confirm (the window shows it).
    @Published var trashRequest: [LibraryItem]?
    /// The item last clicked: the inspector shows it, Shift-click extends from it.
    @Published var focused: String?
    /// What the grid on screen shows, in order (Quick Look, arrows and Shift-click use it).
    var visible: [LibraryItem] = []
    var columns = 1

    @AppStorage("readTextInImages") var readTextInImages = true

    private var cache: [String: [LibraryItem]] = [:]

    init(app: AppModel) {
        self.app = app
        let cached = AppModel.demoMode ? nil : LibraryIndex.loadCache()
        index = cached ?? LibraryIndex()
        summarize()
        recognized = text.all
        if cached != nil { refreshSuggestions() }
    }

    static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Your home folder — or, with `--demo`, the made-up one scripts/demo-seed.sh fills.
    var home: String { AppModel.demoMode ? Self.demoHome.path : HeadroomPaths.home }
    static var demoHome: URL { AppModel.demoRoot.appendingPathComponent("Home", isDirectory: true) }

    /// "~/Downloads" for display (with `--demo`, the made-up home reads as "~" too).
    static func display(_ path: String) -> String {
        if AppModel.demoMode {
            let demo = demoHome.path
            if path == demo { return "~" }
            if path.hasPrefix(demo + "/") { return "~" + path.dropFirst(demo.count) }
        }
        return (path as NSString).abbreviatingWithTildeInPath
    }
    var hasScanned: Bool { index.scannedAt > .distantPast }

    // MARK: Scanning

    var roots: [URL] { LibraryScanner.defaultRoots(home: URL(fileURLWithPath: home)) }

    /// Walk your folders again (a few seconds), then refresh everything built on the index.
    func scan() async {
        guard !scanning else { return }
        scanning = true
        let all = self.roots
        // Never wait on a permission prompt: a folder macOS is still asking about is skipped until it's answered.
        let roots = await Task.detached(priority: .utility) { Access.readable(all) }.value
        let fresh = await Task.detached(priority: .utility) { await LibraryScanner.scan(roots: roots) }.value
        index = fresh
        cache.removeAll()
        sourceCache = nil
        scanning = false
        if !AppModel.demoMode { Task.detached(priority: .background) { fresh.saveCache() } }
        if app.apps.isEmpty { await app.scanApps() }
        await loadLastUsed()
        refreshSuggestions()
        if !searchText.isEmpty { scheduleSearch(delay: 0) }
        if readTextInImages { readText() }
    }

    /// Rescan if the index is older than `minutes` (opening the window, Quick Search).
    func refreshIfStale(minutes: Double = 10) {
        if !scanning, Date().timeIntervalSince(index.scannedAt) > minutes * 60 { Task { await scan() } }
    }

    private func loadLastUsed() async {
        let downloads = home + "/Downloads/"
        let paths = index.items.filter { $0.path.hasPrefix(downloads) || $0.kind == .video && $0.bytes > 200_000_000 }.map(\.path)
        lastUsed = await Task.detached(priority: .utility) { Spotlight.lastUsed(paths) }.value
        #if !APPSTORE
        let home = self.home
        mailAttachments = await Task.detached(priority: .utility) { CleanUp.mailAttachments(home: home) }.value
        #endif
    }

    func refreshSuggestions() {
        var cards = CleanUp.suggestions(index, apps: app.apps, home: home, lastUsed: lastUsed, mailAttachments: mailAttachments)
        let groups = duplicates + lookAlikes
        if !groups.isEmpty {
            cards.insert(CleanUpSuggestion(kind: .duplicates, items: groups.flatMap { Array($0.items.dropFirst()) }), at: 0)
        }
        suggestions = cards
    }

    /// Read the text in screenshots and recent photos, a batch at a time, in the background.
    func readText() {
        guard reading == nil else { return }
        let todo = TextIndex.candidates(index)
        guard !todo.isEmpty else { return }
        let text = self.text
        reading = (0, 0)
        Task.detached(priority: .background) { [weak self] in
            text.index(todo, limit: 1500, progress: { done, total in
                if done % 20 == 0 || done == total {
                    Task { @MainActor in self?.reading = (done, total) }
                }
            })
            let all = text.all
            await MainActor.run {
                self?.recognized = all
                self?.reading = nil
                if self?.searchText.isEmpty == false { self?.scheduleSearch(delay: 0) }
            }
        }
    }

    /// The text in one image or PDF, read now if needed.
    func recognizedText(_ item: LibraryItem) async -> String {
        let text = self.text
        let result = await Task.detached(priority: .userInitiated) { text.text(for: item) }.value
        recognized[item.path] = result
        Task.detached(priority: .background) { text.save() }
        return result
    }

    // MARK: Duplicates

    func findDuplicates() async {
        guard duplicatesProgress == nil else { return }
        duplicatesProgress = 0
        let items = index.items.filter { $0.kind != .app && !$0.isFolder }
        let exact = await Duplicates.identical(in: items, progress: { p in
            Task { @MainActor [weak self] in self?.duplicatesProgress = p * 0.6 }
        })
        duplicates = exact.compactMap { $0.sparingProjects() }
        let inExact = Set(exact.flatMap { $0.items.map(\.path) })
        let alike = await Duplicates.lookAlikes(in: items.filter { $0.kind == .image }, excluding: inExact, progress: { p in
            Task { @MainActor [weak self] in self?.duplicatesProgress = 0.6 + p * 0.4 }
        })
        lookAlikes = alike.compactMap { $0.sparingProjects() }
        duplicatesProgress = nil
        duplicatesScanned = .now
        refreshSuggestions()
    }

    var duplicateBytes: Int64 { (duplicates + lookAlikes).reduce(0) { $0 + $1.wasted } }

    // MARK: Lists

    /// Sorted per the view settings, cached until the index or the sort changes.
    private func summarize() {
        var totals: [FileKind: LibraryIndex.Totals] = [:]
        var byKind: [FileKind: [LibraryItem]] = [:]
        var shots = 0
        for item in index.items {
            totals[item.kind, default: .init()].count += 1
            totals[item.kind, default: .init()].bytes += item.bytes
            byKind[item.kind, default: []].append(item)
            if item.isScreenshot { shots += 1 }
        }
        kindTotals = totals
        newest = byKind.mapValues { Array($0.sorted { $0.latest > $1.latest }.prefix(40)) }
        newestOverall = Array(index.items.filter { $0.kind != .other }.sorted { $0.latest > $1.latest }.prefix(400))
        shelvedTotals = totals.filter { $0.key != .other }.values.reduce(into: LibraryIndex.Totals()) { $0.count += $1.count; $0.bytes += $1.bytes }
        screenshotCount = shots
        cache.removeAll()
        sourceCache = nil
        pathIndexDate = nil
    }

    func totals(_ kind: FileKind) -> LibraryIndex.Totals { kindTotals[kind] ?? .init() }
    func recent(_ kind: FileKind, limit: Int) -> [LibraryItem] { Array((newest[kind] ?? []).prefix(limit)) }

    func sorted(_ items: @autoclosure () -> [LibraryItem], key: String? = nil) -> [LibraryItem] {
        if let key, let hit = cache[key] { return hit }
        let items = items()
        let asc = ascending
        let out: [LibraryItem]
        switch sort {
        case .date: out = items.sorted { asc ? $0.latest < $1.latest : $0.latest > $1.latest }
        case .name: out = items.sorted { (a, b) in
            let r = a.name.localizedStandardCompare(b.name)
            return asc ? r == .orderedDescending : r == .orderedAscending
        }
        case .size: out = items.sorted { asc ? $0.bytes < $1.bytes : $0.bytes > $1.bytes }
        case .kind: out = items.sorted { $0.ext == $1.ext ? $0.latest > $1.latest : (asc ? $0.ext > $1.ext : $0.ext < $1.ext) }
        }
        if let key { cache[key] = out }
        return out
    }

    func items(_ kind: FileKind) -> [LibraryItem] { sorted(index.items.filter { $0.kind == kind }, key: "kind:" + kind.rawValue) }
    var recents: [LibraryItem] { newestOverall }
    var screenshots: [LibraryItem] { sorted(index.items.filter(\.isScreenshot), key: "screenshots") }
    var largeFiles: [LibraryItem] { index.items.filter { $0.bytes >= 100_000_000 }.sorted { $0.bytes > $1.bytes } }

    func items(from sourceID: String) -> [LibraryItem] {
        sorted(index.items.filter { DownloadSources.source(of: $0)?.id == sourceID }, key: "source:" + sourceID)
    }

    /// Every download, by where it came from.
    var bySource: [(source: DownloadSource, items: [LibraryItem])] {
        if let hit = sourceCache { return hit }
        var groups: [DownloadSource: [LibraryItem]] = [:]
        for item in index.items {
            if let s = DownloadSources.source(of: item) { groups[s, default: []].append(item) }
        }
        var out: [(source: DownloadSource, items: [LibraryItem])] = []
        for (source, items) in groups {
            out.append((source: source, items: items.sorted { (a: LibraryItem, b: LibraryItem) in a.arrived > b.arrived }))
        }
        out.sort { (a, b) -> Bool in
            if a.items.count != b.items.count { return a.items.count > b.items.count }
            return a.source.name < b.source.name
        }
        sourceCache = out
        return out
    }
    private var sourceCache: [(source: DownloadSource, items: [LibraryItem])]?

    func item(_ path: String) -> LibraryItem? {
        if let hit = pathIndex[path] { return hit }
        return visible.first { $0.path == path } ?? results.first { $0.path == path }
    }
    private var pathIndex: [String: LibraryItem] {
        if pathIndexDate != index.scannedAt {
            pathIndexStore = Dictionary(index.items.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            pathIndexDate = index.scannedAt
        }
        return pathIndexStore
    }
    private var pathIndexStore: [String: LibraryItem] = [:]
    private var pathIndexDate: Date?

    // MARK: Search

    func scheduleSearch(delay: Double = 0.12) {
        searchTask?.cancel()
        let text = searchText
        searchTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.runSearch(text)
        }
    }

    private func runSearch(_ text: String) async {
        let q = LibraryQuery.parse(text)
        query = q
        guard !q.isEmpty else { results = []; searching = false; return }
        searching = true
        let home = self.home
        // Spotlight answers the slow parts: words inside documents, and the camera a photo came from.
        if !q.terms.isEmpty {
            let terms = q.terms
            contentHits = await Task.detached(priority: .userInitiated) { Spotlight.paths(containing: terms, in: home) }.value
        } else { contentHits = [] }
        if let device = q.device {
            let found = await Task.detached(priority: .userInitiated) { Spotlight.paths(fromDevice: device, in: home) }.value
            devices = Dictionary(uniqueKeysWithValues: found.map { ($0, device) })
        } else { devices = [:] }
        guard !Task.isCancelled else { return }
        let context = LibraryQuery.MatchContext(home: home, recognizedText: recognized, contentHits: contentHits, devices: devices)
        let items = index.items
        let terms = q.terms
        let found = await Task.detached(priority: .userInitiated) { () -> [LibraryItem] in
            let hits = items.filter { q.matches($0, in: context) }
            // Names that say it come first, then the newest.
            return hits.sorted { a, b in
                let an = terms.allSatisfy { a.name.localizedCaseInsensitiveContains($0) }
                let bn = terms.allSatisfy { b.name.localizedCaseInsensitiveContains($0) }
                return an != bn ? an : a.latest > b.latest
            }
        }.value
        guard !Task.isCancelled, text == searchText else { return }
        results = found
        searching = false
    }

    /// Run a search right away (saved searches, Quick Search, Shortcuts).
    func search(_ text: String) {
        searchText = text
        scheduleSearch(delay: 0)
    }

    /// The matches for a saved search, now.
    func matches(for text: String) -> [LibraryItem] {
        let q = LibraryQuery.parse(text)
        let context = LibraryQuery.MatchContext(home: home, recognizedText: recognized)
        return sorted(self.index.items.filter { q.matches($0, in: context) }, key: "saved:" + text)
    }

    /// The type and source counts above a shelf, cached with it.
    struct Facets {
        var extensions: [(String, Int)]
        var sources: [(DownloadSource, Int)]
    }
    private var facetCache: [String: Facets] = [:]
    private var facetDate: Date?

    func facets(_ key: String, _ items: [LibraryItem]) -> Facets {
        if facetDate != index.scannedAt || facetCache.count > 40 { facetCache = [:]; facetDate = index.scannedAt }
        if let hit = facetCache[key] { return hit }
        var exts: [String: Int] = [:]
        var sources: [DownloadSource: Int] = [:]
        for item in items {
            if !item.ext.isEmpty { exts[item.ext, default: 0] += 1 }
            if let s = DownloadSources.source(of: item) { sources[s, default: 0] += 1 }
        }
        let f = Facets(extensions: exts.sorted { $0.value > $1.value }.prefix(7).map { ($0.key, $0.value) },
                       sources: sources.sorted { $0.value > $1.value }.map { ($0.key, $0.value) })
        facetCache[key] = f
        return f
    }

    func saveSearch(name: String? = nil) {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !saved.contains(where: { $0.query == text }) else { return }
        saved.append(SavedSearch(name: name ?? text, query: text))
        app.show("Saved “\(text)” to the sidebar")
    }

    // MARK: Selection

    func select(_ item: LibraryItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(item.path) { selection.remove(item.path) } else { selection.insert(item.path) }
        } else if modifiers.contains(.shift), let anchor = focused,
                  let a = visible.firstIndex(where: { $0.path == anchor }), let b = visible.firstIndex(where: { $0.path == item.path }) {
            selection.formUnion(visible[min(a, b)...max(a, b)].map(\.path))
        } else {
            selection = [item.path]
        }
        focused = item.path
        QuickLook.shared.follow(self)
    }

    /// Move the selection with the arrow keys: ±1 across, ±columns down a row.
    func moveSelection(by delta: Int, extend: Bool = false) {
        guard !visible.isEmpty else { return }
        let current = focused.flatMap { f in visible.firstIndex { $0.path == f } }
        let next = max(0, min(visible.count - 1, (current ?? (delta > 0 ? -1 : visible.count)) + delta))
        let item = visible[next]
        if extend { selection.insert(item.path) } else { selection = [item.path] }
        focused = item.path
        QuickLook.shared.follow(self)
    }

    var selectedItems: [LibraryItem] {
        let order = visible.isEmpty ? Array(selection) : visible.map(\.path).filter(selection.contains)
        return order.compactMap(item)
    }

    /// What an action applies to: the selection when the clicked item is in it, else just that item.
    func targets(for item: LibraryItem) -> [LibraryItem] {
        selection.contains(item.path) && selection.count > 1 ? selectedItems : [item]
    }

    // MARK: Actions

    func open(_ item: LibraryItem) {
        if item.isFolder {
            browse(item.path)
        } else if item.kind == .audio {
            player.play(item, queue: visible.filter { $0.kind == .audio })
        } else if Notes.canEdit(item.url) {
            NoteWindows.shared.open(item.url)
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// A new empty text file in this folder, opened in Headroom's notepad. Never replaces a file.
    func createNote(_ kind: Notes.Kind, in folder: String) {
        do {
            let url = try Notes.create(kind, in: URL(fileURLWithPath: folder), home: home)
            NotificationCenter.default.post(name: .headroomFolderChanged, object: folder)
            NoteWindows.shared.open(url)
        } catch {
            app.toast = AppModel.Toast(message: "Couldn't make a new file: \(error.localizedDescription)", failed: true)
        }
    }

    func browse(_ path: String) {
        if let current = browsePath, current != path { browseHistory.append(current) }
        browsePath = path
        selection = []
        focused = nil
        requestedScreen = .folder
        NotificationCenter.default.post(name: .headroomShowScreen, object: Screen.folder)
    }

    func browseBack() {
        guard let previous = browseHistory.popLast() else { return }
        browsePath = previous
        selection = []
    }

    /// Bring the window forward with this file selected in its folder.
    func showInApp(_ item: LibraryItem) {
        browsePath = nil
        browse(item.folder)
        selection = [item.path]
        focused = item.path
        NotificationCenter.default.post(name: .headroomOpenWindow, object: nil)
    }

    func reveal(_ items: [LibraryItem]) { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }

    func copyFiles(_ items: [LibraryItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.url as NSURL })
    }

    func copyPaths(_ items: [LibraryItem]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
    }

    func canReadText(_ item: LibraryItem) -> Bool {
        item.kind == .image || item.ext == "pdf"
    }

    /// Copy the words in the images and PDFs (⇧⌘C).
    func copyText(_ items: [LibraryItem]) async {
        let readable = items.filter(canReadText)
        guard !readable.isEmpty else { app.show("Copy Text works on images and PDFs", failed: true); return }
        var parts: [String] = []
        for item in readable {
            let t = await recognizedText(item).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { parts.append(t) }
        }
        guard !parts.isEmpty else { app.show("No text found in \(readable.count == 1 ? "this image" : "these files")"); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(parts.joined(separator: "\n\n"), forType: .string)
        app.show("Copied text from \(parts.count) \(readable.first?.kind == .image && readable.count == parts.count ? (parts.count == 1 ? "image" : "images") : (parts.count == 1 ? "file" : "files"))")
    }

    func pin(_ path: String) {
        guard !pinned.contains(path) else { return }
        pinned.append(path)
    }

    /// Move to the Trash through `Cleaner`, as one Activity entry with Undo. Returns paths that went.
    @discardableResult
    func trash(_ items: [LibraryItem], label: String? = nil) async -> Set<String> {
        // Folders are listed without a size; measure them so the toast and Activity say what went.
        let files = await Task.detached(priority: .userInitiated) {
            items.map { (url: $0.url, bytes: $0.isFolder ? DiskWalker.measure($0.url).allocated : $0.allocated) }
        }.value
        let result = await app.trashFiles(files, label: label)
        app.show(result.message, failed: result.removed.isEmpty, undo: result.undo)
        forget(result.removed)
        return result.removed
    }

    /// Drop removed files from every list without waiting for a rescan.
    func forget(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        index.items.removeAll { paths.contains($0.path) }
        mailAttachments.removeAll { paths.contains($0.path) }
        facetCache = [:]
        results.removeAll { paths.contains($0.path) }
        selection.subtract(paths)
        duplicates = duplicates.compactMap { $0.removing(paths) }
        lookAlikes = lookAlikes.compactMap { $0.removing(paths) }
        cache.removeAll()
        sourceCache = nil
        pathIndexDate = nil
        refreshSuggestions()
        if !AppModel.demoMode { Task.detached(priority: .background) { [index] in index.saveCache() } }
    }

    // MARK: Tidy

    /// The tidy waiting for its go-ahead (the window shows the plan).
    @Published var tidyPlan: AutoRules.TidyPlan?

    func canTidy(_ path: String) -> Bool {
        AutoRules.tidyRefusal(folder: URL(fileURLWithPath: path), home: URL(fileURLWithPath: home)) == nil
    }

    /// Work out what a tidy of this folder would do, and show it. Nothing moves yet.
    func planTidy(_ path: String) async {
        let url = URL(fileURLWithPath: path)
        if let why = AutoRules.tidyRefusal(folder: url, home: URL(fileURLWithPath: home)) { app.show(why, failed: true); return }
        let plan = await Task.detached(priority: .userInitiated) { AutoRules.tidyPlan(folder: url) }.value
        guard !plan.moves.isEmpty else {
            app.show("Nothing loose to tidy in \(FileManager.default.displayName(atPath: path))"
                     + (plan.skipped.isEmpty ? "" : " — \(plan.skipped.count) left for later (still arriving or just changed)"))
            return
        }
        tidyPlan = plan
    }

    /// Carry out a tidy you've seen: guard-checked moves, never overwriting, one Activity entry with Undo.
    func tidy(_ plan: AutoRules.TidyPlan) async {
        let guardrail = app.guardrail
        let result = await Task.detached(priority: .userInitiated) { AutoRules.perform(plan.moves, guardrail: guardrail) }.value
        var undo: ActivityLog.Entry.ID?
        if !result.moved.isEmpty {
            let entry = AutoRules.entry(for: result.moved, automatic: false,
                                        noun: "files tidied in \(FileManager.default.displayName(atPath: plan.folder.path))")
            app.activity.record(entry)
            undo = entry.id
        }
        let moved = result.moved.count
        var message = moved == 0 ? "Nothing was moved" : "Tidied \(moved) \(moved == 1 ? "file" : "files") into folders"
        if !result.failed.isEmpty { message += " · \(result.failed.count) left where \(result.failed.count == 1 ? "it was" : "they were")" }
        app.show(message, failed: moved == 0, undo: undo)
        await scan()
    }

    // MARK: Workspace actions

    var currentWorkspace: Workspace? { workspaces.first { $0.id == workspaceID } }

    func openWorkspace(_ id: UUID) {
        workspaceID = id
        selection = []
        focused = nil
        requestedScreen = .workspace
        NotificationCenter.default.post(name: .headroomShowScreen, object: Screen.workspace)
    }

    /// ⌃1…⌃9.
    func openWorkspace(at index: Int) {
        guard workspaces.indices.contains(index) else { return }
        openWorkspace(workspaces[index].id)
    }

    @discardableResult
    func createWorkspace(name: String, paths: [String] = []) -> Workspace {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        FolderAccess.shared.remember(paths.map { URL(fileURLWithPath: $0) })
        var w = Workspace(name: trimmed.isEmpty ? "New Workspace" : trimmed)
        w.add(paths)
        workspaces.append(w)
        openWorkspace(w.id)
        return w
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].name = trimmed
    }

    func setNote(_ id: UUID, _ note: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }), workspaces[i].note != note else { return }
        workspaces[i].note = note
    }

    /// Forget a workspace. Its folders and files stay exactly where they are.
    func removeWorkspace(_ id: UUID) {
        guard let w = workspaces.first(where: { $0.id == id }) else { return }
        workspaces.removeAll { $0.id == id }
        if workspaceID == id {
            workspaceID = nil
            NotificationCenter.default.post(name: .headroomShowScreen, object: Screen.home)
        }
        app.show("Removed “\(w.name)” — nothing in it was moved or deleted")
    }

    func addToWorkspace(_ id: UUID, paths: [String]) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        FolderAccess.shared.remember(paths.map { URL(fileURLWithPath: $0) })
        let n = workspaces[i].add(paths)
        if n > 0 {
            app.show("Added \(n == 1 ? "1 item" : "\(n) items") to “\(workspaces[i].name)”")
            Task { await refreshWorkspace(id) }
        } else {
            app.show("Already in “\(workspaces[i].name)”")
        }
    }

    func removeFromWorkspace(_ id: UUID, paths: Set<String>) {
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[i].remove(paths)
        selection.subtract(paths)
    }

    /// Look at every member again: folders are summarised in parallel, off the main thread.
    func refreshWorkspace(_ id: UUID) async {
        guard let w = workspaces.first(where: { $0.id == id }).map(Workspaces.relocated) else { return }
        if let i = workspaces.firstIndex(where: { $0.id == id }), workspaces[i] != w { workspaces[i] = w }
        let found = await withTaskGroup(of: (String, MemberInfo).self) { group in
            for path in w.paths {
                group.addTask(priority: .userInitiated) {
                    let state = Workspaces.state(of: path)
                    guard state == .present else { return (path, MemberInfo(state: state)) }
                    if Workspaces.isFolder(path) {
                        return (path, MemberInfo(state: state, folder: Workspaces.summarize(folder: path)))
                    }
                    // nil for an iCloud-only file: shown as a placeholder, never read (that would download it).
                    return (path, MemberInfo(state: state, file: Workspaces.file(at: path)))
                }
            }
            var out: [String: MemberInfo] = [:]
            for await (path, info) in group { out[path] = info }
            return out
        }
        members.merge(found) { _, new in new }
    }

    /// The files changed lately across a workspace (two weeks), newest first.
    func changedLately(_ w: Workspace) -> [LibraryItem] {
        let infos = w.paths.compactMap { members[$0] }
        return Workspaces.changedLately(infos.compactMap(\.folder), files: infos.compactMap(\.file),
                                        since: Date().addingTimeInterval(-14 * 86_400))
    }

    func bump(_ delta: Double) {
        cardSize = max(110, min(320, cardSize + delta))
    }
}

extension DuplicateGroup {
    /// The group without files that are gone; nil when fewer than two copies are left.
    func removing(_ paths: Set<String>) -> DuplicateGroup? {
        var g = self
        g.items.removeAll { paths.contains($0.path) }
        guard g.items.count > 1 else { return nil }
        if paths.contains(g.keep) { g.keep = g.items[0].path }
        g.wasted = g.wasted(keeping: g.keep)
        return g
    }
}

extension Notification.Name {
    /// Show a screen in the window (from Quick Search, the menu bar, Shortcuts).
    static let headroomShowScreen = Notification.Name("headroomShowScreen")
    static let headroomFolderChanged = Notification.Name("headroomFolderChanged")
    /// Open (or bring forward) the main window.
    static let headroomOpenWindow = Notification.Name("headroomOpenWindow")
}

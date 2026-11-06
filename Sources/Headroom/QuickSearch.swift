import SwiftUI
import AppKit
import Carbon.HIToolbox
import Quartz
import HeadroomCore

/// A system-wide hotkey (Carbon's: no Accessibility permission needed).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32
    /// Weak, so dropping a HotKey unregisters it (a changed or turned-off shortcut stops working).
    private struct Entry { weak var hotKey: HotKey? }
    private static var registry: [UInt32: Entry] = [:]
    private static var nextID: UInt32 = 1

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        let id = Self.nextID
        self.id = id
        Self.nextID += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            HotKey.registry[hk.id]?.hotKey?.action()
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4844524D), id: id) // 'HDRM'
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil // deinit still runs for a failed init: don't remove it twice
            return nil
        }
        Self.registry[id] = Entry(hotKey: self)
    }

    deinit {
        Self.registry[id] = nil
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// A panel that can take typing without bringing the whole app forward (like Spotlight).
final class QuickSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    /// ⌘W (the Window menu) closes it, like esc on an empty search.
    override func performClose(_ sender: Any?) { orderOut(nil) }
    override func resignKey() {
        super.resignKey()
        // Clicking anywhere else closes it — unless Quick Look is showing one of its files.
        if !QuickLook.shared.isOpen { orderOut(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLook.shared
        panel.delegate = QuickLook.shared
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

/// Quick Search: find any file, app or command without leaving what you're doing.
@MainActor
final class QuickSearchController {
    static let size = NSSize(width: 800, height: 500)
    private var panel: QuickSearchPanel?
    private let library: LibraryModel
    private let state = QuickSearchState()
    private var flagsMonitor: Any?

    init(library: LibraryModel) {
        self.library = library
        state.library = library
        QuickSearchHotKey.shared.action = { [weak self] in self?.toggle() }
        QuickSearchHotKey.shared.register()
        // Holding ⌘ shows ⌘1…⌘9 on the rows.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let held = event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
            if self?.state.commandHeld != held { self?.state.commandHeld = held }
            return event
        }
    }

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    func show() {
        library.refreshIfStale()
        state.loadApps()
        if panel == nil {
            let p = QuickSearchPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                     styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.animationBehavior = .utilityWindow
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            let root = QuickSearchView(state: state, close: { [weak p] in p?.orderOut(nil) })
                .environmentObject(library)
                .environmentObject(library.app)
            p.contentView = NSHostingView(rootView: root)
            panel = p
        }
        guard let panel else { return }
        state.reset()
        // The screen you're working on (where the pointer is), a little above the middle.
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: (f.midX - panel.frame.width / 2).rounded(),
                                         y: (f.maxY - panel.frame.height - f.height * 0.14).rounded()))
        }
        panel.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class QuickSearchState: ObservableObject {
    @Published var text = "" {
        didSet {
            guard text != oldValue else { return }
            selected = 0
            actionsOpen = false
            refresh()
        }
    }
    @Published var selected = 0
    @Published var focus = 0
    /// The best matches for `query` (at most `limit`) and how many there were in all.
    @Published private(set) var results: [LibraryItem] = []
    @Published private(set) var total = 0
    /// Path → the letters of its name that matched, to bold.
    @Published private(set) var marks: [String: [Range<Int>]] = [:]
    /// Path → how well its name says it (sections and the Top Hit).
    @Published private(set) var tiers: [String: QuickRank.Tier] = [:]
    @Published private(set) var query = LibraryQuery.parse("")
    /// The commands and apps the words find, best first (ranked at once: there are only a few hundred).
    @Published private(set) var commands: [(command: QuickCommand, match: QuickRank.Match)] = []
    @Published private(set) var apps: [(app: QuickApp, match: QuickRank.Match)] = []
    /// Every app in the Applications folders.
    @Published private(set) var allApps: [QuickApp] = []
    /// System Settings pages, and the ones the words find.
    @Published private(set) var allPanes: [SettingsPane] = []
    @Published private(set) var panes: [(pane: SettingsPane, match: QuickRank.Match)] = []
    /// What you open most and lately for what's typed (files and apps by path, commands by history key).
    private(set) var usage: [String: Double] = [:]

    /// ⌘K: the selected row's actions.
    @Published var actionsOpen = false { didSet { if actionsOpen != oldValue { actionQuery = ""; actionSelected = 0 } } }
    @Published var actionQuery = "" { didSet { if actionQuery != oldValue { actionSelected = 0 } } }
    @Published var actionSelected = 0
    /// ⌘I: the details beside the list (remembered).
    @Published var showInfo = UserDefaults.standard.bool(forKey: "quickSearchInfo") {
        didSet { if remembersInfo { UserDefaults.standard.set(showInfo, forKey: "quickSearchInfo") } }
    }
    var remembersInfo = true
    /// ⌘ held: the rows show ⌘1…⌘9.
    @Published var commandHeld = false
    /// Where the pointer last was, so a list scrolling under a still pointer doesn't move the selection.
    var lastMouse = CGPoint.zero

    weak var library: LibraryModel?
    private var task: Task<Void, Never>?
    private var appsLoaded: Date?
    /// The text `results` were found for: ↩ waits until they catch up, so it never opens a stale row.
    private var resultsFor = ""
    static let limit = 40

    var isCurrent: Bool { resultsFor == text }

    /// A fresh start each time the panel opens.
    func reset() {
        actionsOpen = false
        text = ""
        selected = 0
        refresh()
        focus += 1
    }

    /// The Applications folders, listed again when the list is over ten minutes old.
    func loadApps() {
        guard appsLoaded.map({ Date().timeIntervalSince($0) > 600 }) ?? true else { return }
        appsLoaded = Date()
        // Demo runs show Apple's apps only.
        let roots = AppModel.demoMode ? [URL(fileURLWithPath: "/System/Applications")] : QuickApp.defaultRoots()
        Task {
            let (apps, panes) = await Task.detached(priority: .utility) { (QuickApp.list(roots: roots), SettingsPane.list()) }.value
            allPanes = panes
            useApps(apps)
        }
    }

    func useApps(_ list: [QuickApp], panes: [SettingsPane]? = nil) {
        allApps = list
        if let panes { allPanes = panes }
        refresh()
    }

    /// Search again for the current text (typing, a fresh scan). Files are searched off the main
    /// thread; a newer keystroke cancels the older search, so typing never waits on a big library.
    func refresh() {
        task?.cancel()
        let text = self.text
        let q = LibraryQuery.parse(text)
        query = q
        usage = library?.quickHistory.boosts(for: text) ?? [:]
        commands = library.map { QuickCommands.ranked(QuickCommands.all(library: $0), text: text, usage: self.usage) } ?? []
        apps = QuickCommands.rankedApps(allApps, text: text, usage: usage)
        panes = QuickCommands.rankedPanes(allPanes, text: text, usage: usage)
        guard !q.isEmpty, let library else {
            results = []; total = 0; marks = [:]; tiers = [:]; resultsFor = text
            return
        }
        let items = library.index.items
        let context = LibraryQuery.MatchContext(home: library.home, recognizedText: library.recognized)
        let usage = self.usage
        let limit = Self.limit
        task = Task { [weak self] in
            // `search` is @concurrent: it runs off the main thread, and still sees this task's cancel.
            guard let found = await Self.search(q, in: items, context: context, usage: usage, limit: limit),
                  let self, !Task.isCancelled, self.text == text else { return }
            self.results = found.items
            self.marks = found.marks
            self.tiers = found.tiers
            self.total = found.total
            self.resultsFor = text
        }
    }

    /// Wait for the search for what's typed now.
    func settle() async {
        // Only the newest search can catch up; an older one was cancelled by the keystroke after it.
        while !isCurrent, let task {
            await task.value
            if task == self.task { break }
        }
    }

    /// The letters that matched in a row's title, to bold.
    func marks(for row: QuickRow) -> [Range<Int>] {
        switch row {
        case .file(let item): marks[item.path] ?? []
        case .app(let app): apps.first { $0.app.path == app.path }?.match.ranges ?? []
        case .setting(let pane): panes.first { $0.pane.id == pane.id }?.match.ranges ?? []
        case .command(let command): commands.first { $0.command.id == command.id }?.match.ranges ?? []
        case .answer: []
        }
    }

    /// Ranked like Raycast: how well the name says it (`QuickRank.Tier`), then what you open most and
    /// lately for this query (`usage`), then the newest. Names that only hold the letters in order
    /// ("dnld" → Downloads) come last, and only for three letters or more. nil when cancelled.
    @concurrent nonisolated static func search(_ q: LibraryQuery, in items: [LibraryItem], context: LibraryQuery.MatchContext,
                                               usage: [String: Double], limit: Int) async
        -> (items: [LibraryItem], marks: [String: [Range<Int>]], tiers: [String: QuickRank.Tier], total: Int)? {
        let needles = QuickRank.needles(q.terms)
        var filtersOnly = q
        filtersOnly.terms = []
        let loose = needles.joined().count >= 3
        var hits: [(item: LibraryItem, match: QuickRank.Match, usage: Double)] = []
        for (i, item) in items.enumerated() {
            if i % 4096 == 0, Task.isCancelled { return nil }
            if q.matches(item, in: context) {
                var m = QuickRank.match(item.name, needles: needles)
                // Every word was found — not all in the name, so the real match is a folder, tag or text.
                if m.tier == .fuzzy { m.tier = .elsewhere }
                hits.append((item, m, usage[item.path] ?? 0))
            } else if loose, QuickRank.mightMatch(item.name, needles: needles), filtersOnly.matches(item, in: context) {
                let m = QuickRank.match(item.name, needles: needles)
                if m.tier == .fuzzy { hits.append((item, m, usage[item.path] ?? 0)) }
            }
        }
        if Task.isCancelled { return nil }
        hits.sort { a, b in
            if a.match.tier != b.match.tier { return a.match.tier < b.match.tier }
            return a.usage != b.usage ? a.usage > b.usage : a.item.latest > b.item.latest
        }
        let top = hits.prefix(limit)
        let marks = Dictionary(top.map { ($0.item.path, $0.match.ranges) }, uniquingKeysWith: { a, _ in a })
        let tiers = Dictionary(top.map { ($0.item.path, $0.match.tier) }, uniquingKeysWith: { a, _ in a })
        return (top.map(\.item), marks, tiers, hits.count)
    }
}

/// The frosted glass behind floating panels.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

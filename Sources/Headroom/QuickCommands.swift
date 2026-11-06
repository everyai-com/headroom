import SwiftUI
import HeadroomCore

/// Something Quick Search can do besides open a file: show a screen, run a saved search, open a
/// pinned folder, search in the window. Ranked with the same tiers as files, and learned the same way.
struct QuickCommand: Identifiable {
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    /// Other words that find it ("ram" → Memory).
    var keywords: [String] = []
    /// Its key in the window, shown on the row.
    var shortcut: String?
    var run: @MainActor () -> Void

    /// How Quick Search's history (`Frecency`) knows it.
    var historyKey: String { "command:" + id }
}

/// One row of Quick Search.
enum QuickRow: Identifiable {
    case file(LibraryItem)
    case app(QuickApp)
    /// A System Settings page.
    case setting(SettingsPane)
    case command(QuickCommand)
    /// The calculator: what was typed and its answer.
    case answer(sum: String, value: String)

    var id: String {
        switch self {
        case .file(let item): "file:" + item.path
        case .app(let app): "app:" + app.path
        case .setting(let pane): "setting:" + pane.id
        case .command(let command): command.historyKey
        case .answer: "answer"
        }
    }

    /// Its key in Quick Search's history; the calculator isn't remembered.
    var historyKey: String? {
        switch self {
        case .file(let item): item.path
        case .app(let app): app.path
        case .setting(let pane): "settings:" + pane.id
        case .command(let command): command.historyKey
        case .answer: nil
        }
    }

    var file: LibraryItem? { if case .file(let item) = self { item } else { nil } }
}

struct QuickSection: Identifiable {
    var title: String
    var detail: String?
    var rows: [QuickRow]
    var id: String { title }
}

/// A key for an action, shown as a keycap and matched against what you press.
struct QuickKey {
    var key: KeyEquivalent
    var modifiers: EventModifiers
    var label: String

    static func cmd(_ c: Character, _ label: String) -> QuickKey { QuickKey(key: KeyEquivalent(c), modifiers: .command, label: label) }

    static let open = QuickKey(key: .return, modifiers: [], label: "↩")
    static let showInHeadroom = QuickKey(key: .return, modifiers: .command, label: "⌘↩")
    static let reveal = QuickKey(key: .return, modifiers: .option, label: "⌥↩")
    static let quickLook = cmd("y", "⌘Y")
    static let info = cmd("i", "⌘I")
    static let copyFile = QuickKey(key: "c", modifiers: [.command, .shift], label: "⇧⌘C")
    static let copyPath = QuickKey(key: "c", modifiers: [.command, .option], label: "⌥⌘C")
    static let copyName = QuickKey(key: "c", modifiers: [.command, .control], label: "⌃⌘C")
    static let forget = QuickKey(key: "x", modifiers: [.control, .shift], label: "⌃⇧X")
    static let trash = QuickKey(key: "x", modifiers: .control, label: "⌃X")

    /// The modifiers that tell keys apart.
    static let significant: EventModifiers = [.command, .shift, .option, .control]

    func matches(_ press: KeyPress) -> Bool {
        press.modifiers.intersection(Self.significant) == modifiers
            && press.key.character.lowercased() == key.character.lowercased()
    }
}

/// One thing to do with the selected row (the ⌘K list). The first is ↩.
struct QuickAction: Identifiable {
    var id: String
    var title: String
    var symbol: String
    var key: QuickKey?
    var section = ""
    var destructive = false
    var run: @MainActor () -> Void
}

/// What actions need from the panel.
@MainActor
struct QuickContext {
    var library: LibraryModel
    var query: String
    var close: () -> Void
    var quickLook: (LibraryItem) -> Void
    var toggleInfo: () -> Void
}

@MainActor
enum QuickCommands {
    /// Everything Quick Search can do, for this library.
    static func all(library: LibraryModel) -> [QuickCommand] {
        let model = library.app
        var out: [QuickCommand] = []
        let keywords: [Screen: [String]] = [
            .home: ["start"], .recents: ["latest", "new"], .images: ["photos", "pictures", "screenshots"],
            .videos: ["movies", "films"], .music: ["songs", "audio"], .documents: ["pdfs", "docs"],
            .archives: ["zips", "installers", "dmg"], .apps: ["uninstall", "applications"], .overview: ["disk", "storage", "space"],
            .files: ["big", "large", "huge"], .duplicates: ["copies", "same", "dupes"], .cleanUp: ["tidy", "suggestions"],
            .downloads: ["sources", "gmail", "safari"], .map: ["disk", "treemap", "folders"], .reclaim: ["free", "space", "caches", "clean"],
            .memory: ["ram", "processes", "quit"], .ai: ["models", "ollama", "llm"], .drives: ["usb", "external", "rescue"],
            .activity: ["undo", "history", "put back", "trash"], .settings: ["preferences", "options", "shortcut"],
        ]
        let screens: [Screen] = Screen.allCases.filter { ![.search, .saved, .folder, .workspace].contains($0) }
        for screen in screens {
            var subtitle = "Open in Headroom"
            if screen == .reclaim, model.safeReclaimable > 0 { subtitle = "\(ByteFormat.compact(model.safeReclaimable)) safe to reclaim" }
            if screen == .duplicates, !library.duplicates.isEmpty { subtitle = "\(library.duplicates.count) sets of copies" }
            out.append(QuickCommand(id: "screen." + screen.id, title: screen.rawValue, subtitle: subtitle, symbol: screen.symbol,
                                    keywords: keywords[screen] ?? [], shortcut: screen.shortcut) { show(screen, library: library) })
        }
        out.append(QuickCommand(id: "rescan", title: "Rescan", subtitle: "Look at the disk and your files again",
                                symbol: "arrow.clockwise", keywords: ["refresh", "scan", "update"], shortcut: "⌘R") {
            Task { await library.scan() }
            Task { await model.scan(); await model.buildMap() }
            model.show("Rescanning…")
        })
        for saved in library.saved {
            out.append(QuickCommand(id: "saved." + saved.id.uuidString, title: saved.name, subtitle: "Saved search · " + saved.query,
                                    symbol: "magnifyingglass.circle", keywords: [saved.query]) {
                library.savedID = saved.id
                show(.saved, library: library)
            })
        }
        for path in library.pinned {
            out.append(QuickCommand(id: "folder." + path, title: (path as NSString).lastPathComponent,
                                    subtitle: "Pinned folder · " + LibraryModel.display(path), symbol: "folder") {
                library.browse(path)
                NotificationCenter.default.post(name: .headroomOpenWindow, object: nil)
            })
        }
        return out
    }

    /// The last row whenever something is typed: the full search, in the window.
    static func searchInHeadroom(_ text: String) -> QuickCommand {
        let text = text.trimmingCharacters(in: .whitespaces)
        return QuickCommand(id: "search", title: "Search “\(text)” in Headroom", subtitle: "Words inside documents too, with every filter",
                            symbol: "magnifyingglass") {
            NotificationCenter.default.post(name: .headroomSearch, object: text)
        }
    }

    /// Open the window on `screen`.
    static func show(_ screen: Screen, library: LibraryModel) {
        library.requestedScreen = screen
        NotificationCenter.default.post(name: .headroomOpenWindow, object: nil)
        NotificationCenter.default.post(name: .headroomShowScreen, object: screen)
    }

    /// The typed words as needles, matched as typed (not the parsed filters: "images" is a filter for
    /// files, and the Images screen here).
    static func needles(_ text: String) -> [[UInt32]] {
        QuickRank.needles(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// The commands the typed words find, best first. A keyword ranks below a title that says it;
    /// loose letter matches only for three letters or more.
    static func ranked(_ commands: [QuickCommand], text: String, usage: [String: Double])
        -> [(command: QuickCommand, match: QuickRank.Match)] {
        let needles = needles(text)
        guard !needles.isEmpty else { return [] }
        let loose = needles.joined().count >= 3
        var found: [(command: QuickCommand, match: QuickRank.Match)] = []
        for command in commands {
            var best = QuickRank.match(command.title, needles: needles)
            if best.tier == .elsewhere || (best.tier == .fuzzy && !loose) {
                let byKeyword = command.keywords.contains { QuickRank.match($0, needles: needles).tier <= .wordStart }
                guard byKeyword else { continue }
                best = QuickRank.Match(tier: .substring, ranges: [])
            }
            found.append((command, best))
        }
        return found.sorted { a, b in
            if a.match.tier != b.match.tier { return a.match.tier < b.match.tier }
            let ua = usage[a.command.historyKey] ?? 0, ub = usage[b.command.historyKey] ?? 0
            return ua != ub ? ua > ub : a.command.title < b.command.title
        }
    }

    /// The apps the typed words find, best first ("saf" → Safari, "vsc" → Visual Studio Code).
    static func rankedApps(_ apps: [QuickApp], text: String, usage: [String: Double]) -> [(app: QuickApp, match: QuickRank.Match)] {
        let needles = needles(text)
        guard !needles.isEmpty else { return [] }
        let loose = needles.joined().count >= 2
        return apps.compactMap { app -> (app: QuickApp, match: QuickRank.Match)? in
            let m = QuickRank.match(app.name, needles: needles)
            guard m.tier <= .substring || (m.tier == .fuzzy && loose) else { return nil }
            return (app, m)
        }
        .sorted { a, b in
            if a.match.tier != b.match.tier { return a.match.tier < b.match.tier }
            let ua = usage[a.app.path] ?? 0, ub = usage[b.app.path] ?? 0
            return ua != ub ? ua > ub : a.app.name.count < b.app.name.count
        }
    }

    /// The Settings pages the words find, by name or by what people call them ("wifi", "dark mode").
    static func rankedPanes(_ panes: [SettingsPane], text: String, usage: [String: Double]) -> [(pane: SettingsPane, match: QuickRank.Match)] {
        let needles = needles(text)
        guard !needles.isEmpty else { return [] }
        let loose = needles.joined().count >= 3
        return panes.compactMap { pane -> (pane: SettingsPane, match: QuickRank.Match)? in
            let m = QuickRank.match(pane.name, needles: needles)
            if m.tier <= .substring || (m.tier == .fuzzy && loose) { return (pane, m) }
            let byKeyword = pane.keywords.contains { QuickRank.match($0, needles: needles).tier <= .wordStart }
            return byKeyword ? (pane, QuickRank.Match(tier: .substring, ranges: [])) : nil
        }
        .sorted { a, b in
            if a.match.tier != b.match.tier { return a.match.tier < b.match.tier }
            let ua = usage["settings:" + a.pane.id] ?? 0, ub = usage["settings:" + b.pane.id] ?? 0
            return ua != ub ? ua > ub : a.pane.name < b.pane.name
        }
    }

    /// Quick Search's list. With nothing typed: what you use most, recent files, a few commands.
    /// Otherwise: the calculator, the Top Hit (an app, a command or a file), apps, commands, files by
    /// how well the name says it, then "Search in Headroom".
    static func sections(text: String, files: [LibraryItem], tiers: [String: QuickRank.Tier], total: Int,
                         commands: [(command: QuickCommand, match: QuickRank.Match)],
                         apps: [(app: QuickApp, match: QuickRank.Match)], allApps: [QuickApp],
                         panes: [(pane: SettingsPane, match: QuickRank.Match)] = [], allPanes: [SettingsPane] = [],
                         usage: [String: Double], library: LibraryModel) -> [QuickSection] {
        let typed = !text.trimmingCharacters(in: .whitespaces).isEmpty
        guard typed else {
            let history = library.quickHistory.boosts(for: "")
            let everything = all(library: library)
            let byKey = Dictionary(everything.map { ($0.historyKey, $0) }, uniquingKeysWith: { a, _ in a })
            let appsByPath = Dictionary(allApps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let panesByKey = Dictionary(allPanes.map { ("settings:" + $0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let suggested: [QuickRow] = history.sorted { $0.value > $1.value }.lazy.compactMap { key, _ -> QuickRow? in
                if let command = byKey[key] { return .command(command) }
                if let app = appsByPath[key] { return .app(app) }
                if let pane = panesByKey[key] { return .setting(pane) }
                return library.item(key).map(QuickRow.file)
            }.prefix(5).map { $0 }
            let shown = Set(suggested.map(\.id))
            let recent = library.recents.map(QuickRow.file).filter { !shown.contains($0.id) }.prefix(8)
            let everyday = ["screen.Reclaim", "screen.Duplicates", "screen.Clean up", "rescan"]
            // In this order until you use one more than another.
            let common = everything.filter { everyday.contains($0.id) && !shown.contains($0.historyKey) }
                .sorted { a, b in
                    let ua = history[a.historyKey] ?? 0, ub = history[b.historyKey] ?? 0
                    return ua != ub ? ua > ub : everyday.firstIndex(of: a.id)! < everyday.firstIndex(of: b.id)!
                }
            return [
                QuickSection(title: "Suggestions", rows: suggested),
                QuickSection(title: "Recent files", rows: Array(recent)),
                QuickSection(title: "Commands", rows: common.map(QuickRow.command)),
            ].filter { !$0.rows.isEmpty }
        }
        var files = files
        var commands = commands
        var apps = apps
        var panes = panes
        var out: [QuickSection] = []
        if let value = QuickMath.evaluate(text) {
            out.append(QuickSection(title: "Calculator", rows: [.answer(sum: text.trimmingCharacters(in: .whitespaces), value: value)]))
        }
        // The Top Hit: the best first app, Settings page, command or file — if its name really says it.
        // Ties go to what you use more, then to apps, Settings pages, commands.
        struct Candidate { var row: QuickRow; var tier: QuickRank.Tier; var usage: Double; var rank: Int }
        var candidates: [Candidate] = []
        if let a = apps.first { candidates.append(Candidate(row: .app(a.app), tier: a.match.tier, usage: usage[a.app.path] ?? 0, rank: 0)) }
        if let p = panes.first {
            candidates.append(Candidate(row: .setting(p.pane), tier: p.match.tier, usage: usage["settings:" + p.pane.id] ?? 0, rank: 1))
        }
        if let c = commands.first {
            candidates.append(Candidate(row: .command(c.command), tier: c.match.tier, usage: usage[c.command.historyKey] ?? 0, rank: 2))
        }
        if let f = files.first { candidates.append(Candidate(row: .file(f), tier: tiers[f.path] ?? .elsewhere, usage: usage[f.path] ?? 0, rank: 3)) }
        let best = candidates.min { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            return a.usage != b.usage ? a.usage > b.usage : a.rank < b.rank
        }
        if let best, best.tier <= .wordStart {
            out.append(QuickSection(title: "Top Hit", rows: [best.row]))
            switch best.row {
            case .app: apps.removeFirst()
            case .setting: panes.removeFirst()
            case .command: commands.removeFirst()
            case .file: files.removeFirst()
            case .answer: break
            }
        }
        if !apps.isEmpty { out.append(QuickSection(title: "Applications", rows: apps.prefix(4).map { .app($0.app) })) }
        if !panes.isEmpty { out.append(QuickSection(title: "System Settings", rows: panes.prefix(3).map { .setting($0.pane) })) }
        if !commands.isEmpty { out.append(QuickSection(title: "Commands", rows: commands.prefix(3).map { .command($0.command) })) }
        let named = files.filter { (tiers[$0.path] ?? .elsewhere) <= .substring }
        let elsewhere = files.filter { tiers[$0.path] == .elsewhere }
        let close = files.filter { tiers[$0.path] == .fuzzy }
        let found = total == 1 ? "1 file" : "\(total.formatted()) files"
        if !named.isEmpty { out.append(QuickSection(title: "Files", detail: found, rows: named.map(QuickRow.file))) }
        if !elsewhere.isEmpty {
            out.append(QuickSection(title: "In folder names, tags and text", detail: named.isEmpty ? found : nil,
                                    rows: elsewhere.map(QuickRow.file)))
        }
        if !close.isEmpty {
            out.append(QuickSection(title: "Close matches", detail: named.isEmpty && elsewhere.isEmpty ? found : nil,
                                    rows: close.map(QuickRow.file)))
        }
        out.append(QuickSection(title: "Search", rows: [.command(searchInHeadroom(text))]))
        return out
    }

    // MARK: Actions

    /// What ⌘K offers for a row, ↩ first. Each one's key works without opening the list, too.
    static func actions(for row: QuickRow, _ ctx: QuickContext) -> [QuickAction] {
        let library = ctx.library
        /// Using something is what Quick Search learns from.
        func use(_ then: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
            {
                if let key = row.historyKey { library.recordQuickPick(key, query: ctx.query) }
                ctx.close()
                then()
            }
        }
        func copy(_ text: String) -> @MainActor () -> Void {
            { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); ctx.close() }
        }
        var out: [QuickAction] = []
        let forget = QuickAction(id: "forget", title: "Remove from Suggestions", symbol: "eye.slash", key: .forget, section: "Suggestions") {
            if let key = row.historyKey { library.forgetQuickPick(key) }
        }
        let remembered = row.historyKey.map { library.quickHistory.files[$0] != nil } ?? false
        switch row {
        case .file(let item):
            let url = item.url
            let opener = NSWorkspace.shared.urlForApplication(toOpen: url)
            out = [
                QuickAction(id: "open", title: opener.map { "Open in \(FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: ""))" } ?? "Open",
                            symbol: "arrow.up.forward.app", key: .open, run: use { NSWorkspace.shared.open(url) }),
                QuickAction(id: "headroom", title: "Show in Headroom", symbol: "rectangle.stack", key: .showInHeadroom,
                            run: use { library.showInApp(item) }),
                QuickAction(id: "finder", title: "Show in Finder", symbol: "folder", key: .reveal,
                            run: use { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                QuickAction(id: "quicklook", title: "Quick Look", symbol: "eye", key: .quickLook) { ctx.quickLook(item) },
                QuickAction(id: "info", title: "Show Info", symbol: "info.circle", key: .info) { ctx.toggleInfo() },
            ]
            let others = NSWorkspace.shared.urlsForApplications(toOpen: url).filter { $0 != opener }.prefix(5)
            for app in others {
                let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                out.append(QuickAction(id: "with:" + app.path, title: "Open with \(name)", symbol: "app", section: "Open With",
                                       run: use { NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }))
            }
            out += [
                QuickAction(id: "copyfile", title: "Copy File", symbol: "doc.on.doc", key: .copyFile, section: "Copy") {
                    library.copyFiles([item]); ctx.close()
                },
                QuickAction(id: "copypath", title: "Copy Path", symbol: "link", key: .copyPath, section: "Copy", run: copy(item.path)),
                QuickAction(id: "copyname", title: "Copy Name", symbol: "textformat", key: .copyName, section: "Copy", run: copy(item.name)),
            ]
            if remembered { out.append(forget) }
            // Through the window's confirm and the Cleaner — always the Trash, with Undo.
            out.append(QuickAction(id: "trash", title: "Move to Trash…", symbol: "trash", key: .trash, section: "Danger", destructive: true) {
                ctx.close()
                library.trashRequest = [item]
                NotificationCenter.default.post(name: .headroomOpenWindow, object: nil)
            })
        case .app(let app):
            let url = URL(fileURLWithPath: app.path)
            out = [
                QuickAction(id: "open", title: "Open \(app.name)", symbol: "arrow.up.forward.app", key: .open,
                            run: use { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }),
                QuickAction(id: "apps", title: "Show in Headroom’s Apps", symbol: "app.badge", key: .showInHeadroom,
                            run: use { show(.apps, library: library) }),
                QuickAction(id: "finder", title: "Show in Finder", symbol: "folder", key: .reveal,
                            run: use { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                QuickAction(id: "info", title: "Show Info", symbol: "info.circle", key: .info) { ctx.toggleInfo() },
                QuickAction(id: "copypath", title: "Copy Path", symbol: "link", key: .copyPath, section: "Copy", run: copy(app.path)),
                QuickAction(id: "copyname", title: "Copy Name", symbol: "textformat", key: .copyName, section: "Copy", run: copy(app.name)),
            ]
            if remembered { out.append(forget) }
        case .setting(let pane):
            out = [
                QuickAction(id: "open", title: "Open \(pane.name) Settings", symbol: "gearshape", key: .open,
                            run: use { if let url = pane.url { NSWorkspace.shared.open(url) } }),
                QuickAction(id: "info", title: "Show Info", symbol: "info.circle", key: .info) { ctx.toggleInfo() },
            ]
            if remembered { out.append(forget) }
        case .command(let command):
            out = [QuickAction(id: "run", title: command.title.hasPrefix("Search") ? command.title : "Open \(command.title)",
                               symbol: command.symbol, key: .open, run: use(command.run))]
            out.append(QuickAction(id: "info", title: "Show Info", symbol: "info.circle", key: .info) { ctx.toggleInfo() })
            if remembered { out.append(forget) }
        case .answer(let sum, let value):
            out = [
                QuickAction(id: "copy", title: "Copy Answer", symbol: "doc.on.doc", key: .open, run: copy(value.replacingOccurrences(of: ",", with: ""))),
                QuickAction(id: "copysum", title: "Copy “\(sum) = \(value)”", symbol: "equal.square", key: .copyFile, run: copy("\(sum) = \(value)")),
            ]
        }
        return out
    }
}

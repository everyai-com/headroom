import SwiftUI
import AppKit
import HeadroomCore

/// Quick Search's panel, the Raycast way: one field, the list in sections, ⌘K for every action of the
/// selected row (each with its own key), ⌘I for details, ⌘1…⌘9 to pick a row, and a footer that says
/// what ↩ will do.
struct QuickSearchView: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var state: QuickSearchState
    var close: () -> Void
    @FocusState private var field: Field?
    @Environment(\.snapshotMode) private var snapshot

    enum Field: Hashable { case search, actions }

    static let placeholder = "Search files, apps and commands…"
    static let width: CGFloat = 800, height: CGFloat = 500, infoWidth: CGFloat = 340

    var sections: [QuickSection] {
        QuickCommands.sections(text: state.text, files: state.results, tiers: state.tiers, total: state.total,
                               commands: state.commands, apps: state.apps, allApps: state.allApps,
                               panes: state.panes, allPanes: state.allPanes, usage: state.usage, library: library)
    }

    var context: QuickContext {
        QuickContext(library: library, query: state.text, close: close,
                     quickLook: { quickLook($0) }, toggleInfo: { state.showInfo.toggle() })
    }

    /// Typing into an input method (Japanese, Chinese, accents): its keys belong to the text field.
    var composing: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true }

    var body: some View {
        let sections = self.sections
        let rows = sections.flatMap(\.rows)
        let current = rows.indices.contains(state.selected) ? rows[state.selected] : nil
        let actions = current.map { QuickCommands.actions(for: $0, context) } ?? []
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                searchBar(sections: sections, current: current, actions: actions)
                if !filterChips.isEmpty, QuickMath.evaluate(state.text) == nil { chips }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 0) {
                    list(sections)
                    if state.showInfo, let current {
                        Rectangle().fill(Theme.hairline).frame(width: 1)
                        QuickInfo(row: current).frame(width: Self.infoWidth)
                    }
                }
                footer(current: current, actions: actions)
            }
            if state.actionsOpen, !actions.isEmpty {
                actionsPanel(actions)
                    .padding(.trailing, 10).padding(.bottom, 50)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomTrailing)))
            }
        }
        .frame(width: Self.width, height: Self.height)
        .background { if snapshot { Theme.surface } else { VisualEffect().overlay(Theme.surface.opacity(0.78)) } }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .foregroundStyle(Theme.textPrimary)
        .animation(.easeOut(duration: 0.12), value: state.actionsOpen)
        .onChange(of: state.focus) { _, _ in field = .search }
        .onChange(of: state.actionsOpen) { _, open in field = open ? .actions : .search }
        // A scan finished while the panel is open: search the fresh index.
        .onChange(of: library.index.scannedAt) { _, _ in state.refresh() }
        .onAppear { field = .search; state.lastMouse = NSEvent.mouseLocation }
    }

    // MARK: Search field and keys

    func searchBar(sections: [QuickSection], current: QuickRow?, actions: [QuickAction]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.textTertiary)
            if snapshot {
                Text(state.text.isEmpty ? Self.placeholder : state.text).font(.system(size: 19))
                    .foregroundStyle(state.text.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $state.text, prompt: Text(Self.placeholder).foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain).font(.system(size: 19))
                    .focused($field, equals: .search)
                    .onKeyPress(phases: .down) { press in key(press, sections: sections, current: current, actions: actions) }
                if !state.text.isEmpty {
                    Button { state.text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 14)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Clear  esc")
                }
            }
        }
        .padding(.horizontal, 20).frame(height: 58)
    }

    /// What the words were read as — type, date, size, source — not the plain words themselves.
    var filterChips: [LibraryQuery.Chip] { state.query.chips.filter { $0.kind != .text } }

    var chips: some View {
        HStack(spacing: 6) {
            ForEach(filterChips) { chip in
                Label(chip.label, systemImage: chip.symbol).font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Theme.fill(0.07)))
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
    }

    /// Every key the search field handles; anything else is typing.
    func key(_ press: KeyPress, sections: [QuickSection], current: QuickRow?, actions: [QuickAction]) -> KeyPress.Result {
        if composing { return .ignored }
        let mods = press.modifiers.intersection(QuickKey.significant)
        let count = sections.reduce(0) { $0 + $1.rows.count }
        let key = press.key
        if (key == .downArrow && mods.isEmpty) || (key == "n" && mods == .control) { move(1, count); return .handled }
        if (key == .upArrow && mods.isEmpty) || (key == "p" && mods == .control) { move(-1, count); return .handled }
        // ⌘↓ / ⌘↑: the next or previous section.
        if (key == .downArrow || key == .upArrow) && mods == .command {
            let starts = sections.indices.map { i in sections[..<i].reduce(0) { $0 + $1.rows.count } }
            if key == .downArrow { state.selected = starts.first { $0 > state.selected } ?? state.selected }
            else { state.selected = starts.last { $0 < state.selected } ?? 0 }
            return .handled
        }
        if key == .escape {
            // Clears what you typed first, then closes (like Raycast and Spotlight).
            if state.text.isEmpty { close() } else { state.text = "" }
            return .handled
        }
        if key == "k" && mods == .command { state.actionsOpen.toggle(); return .handled }
        if key == .return {
            // ↩ waits for the search to catch up with the last letters typed.
            Task { await state.settle(); performReturn(mods) }
            return .handled
        }
        if key == .space && mods.isEmpty && state.text.isEmpty, let item = current?.file { quickLook(item); return .handled }
        if mods == .command, let n = key.character.wholeNumberValue, (1...9).contains(n), n <= count {
            state.selected = n - 1
            let rows = sections.flatMap(\.rows)
            QuickCommands.actions(for: rows[n - 1], context).first?.run()
            return .handled
        }
        if !mods.isEmpty, let action = actions.first(where: { $0.key.map { $0.key != .return && $0.matches(press) } ?? false }) {
            action.run()
            return .handled
        }
        return .ignored
    }

    func move(_ by: Int, _ count: Int) {
        guard count > 0 else { return }
        state.selected = max(0, min(count - 1, state.selected + by))
    }

    /// ↩, ⌘↩ or ⌥↩ on the selected row: the action with that key, else the first.
    func performReturn(_ mods: EventModifiers) {
        let rows = sections.flatMap(\.rows)
        guard rows.indices.contains(state.selected) else { return }
        let actions = QuickCommands.actions(for: rows[state.selected], context)
        let pick = actions.first { $0.key?.key == .return && $0.key?.modifiers == mods } ?? actions.first
        pick?.run()
    }

    func quickLook(_ item: LibraryItem) {
        let files = sections.flatMap(\.rows).compactMap(\.file)
        QuickLook.shared.show(library: library, items: files.isEmpty ? [item] : files, current: item, followsSelection: false)
    }

    // MARK: List

    @ViewBuilder
    func list(_ sections: [QuickSection]) -> some View {
        if snapshot {
            VStack(spacing: 1) { rows(sections, limit: 8) }
                .padding(8).frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) { rows(sections, limit: nil) }.padding(8)
                }
                .scrollIndicators(.never)
                .onChange(of: state.selected) { _, i in proxy.scrollTo(i) }
            }
        }
    }

    /// Each section's header, then its rows; at most `limit` rows in all (snapshots).
    @ViewBuilder
    func rows(_ sections: [QuickSection], limit: Int?) -> some View {
        let starts = sections.indices.map { i in sections[..<i].reduce(0) { $0 + $1.rows.count } }
        ForEach(Array(sections.enumerated()), id: \.element.id) { s, section in
            if limit.map({ starts[s] < $0 }) ?? true {
                HStack {
                    Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if let detail = section.detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
                }
                .padding(.horizontal, 10).padding(.top, s == 0 ? 4 : 10).padding(.bottom, 4)
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { r, row in
                    let i = starts[s] + r
                    if limit.map({ i < $0 }) ?? true {
                        rowView(row, index: i, on: i == state.selected)
                            .id(i)
                            .onTapGesture {
                                state.selected = i
                                QuickCommands.actions(for: row, context).first?.run()
                            }
                            .onContinuousHover { phase in
                                // The pointer moved onto it (not the list scrolling under a still pointer).
                                guard case .active = phase, !snapshot else { return }
                                let m = NSEvent.mouseLocation
                                if m != state.lastMouse { state.lastMouse = m; if state.selected != i { state.selected = i } }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func rowView(_ row: QuickRow, index: Int, on: Bool) -> some View {
        if case .answer(let sum, let value) = row {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sum).font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(Theme.textSecondary)
                    Text("Calculator").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "equal").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
            }
            .padding(.horizontal, 16).frame(height: 76)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.fill(0.10) : Theme.fill(0.04)))
            .contentShape(Rectangle())
        } else {
            HStack(spacing: 10) {
                icon(row).frame(width: 28, height: 28)
                HStack(spacing: 8) {
                    Text(Self.highlighted(title(row), state.marks(for: row), size: 13.5))
                        .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    if let subtitle = subtitle(row) {
                        // A folder keeps its end ("…/Projects/Site"); a sentence its start.
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            .truncationMode(row.file == nil ? .tail : .head)
                    }
                }
                Spacer(minLength: 8)
                if state.commandHeld, index < 9 {
                    Keycap("⌘\(index + 1)")
                } else {
                    accessory(row)
                }
            }
            .padding(.horizontal, 10).frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.fill(0.10) : .clear))
            .contentShape(Rectangle())
            .onDrag { row.file.flatMap { NSItemProvider(contentsOf: $0.url) } ?? NSItemProvider() }
        }
    }

    func title(_ row: QuickRow) -> String {
        switch row {
        case .file(let item): item.name
        case .app(let app): app.name
        case .setting(let pane): pane.name
        case .command(let command): command.title
        case .answer(_, let value): value
        }
    }

    func subtitle(_ row: QuickRow) -> String? {
        switch row {
        case .file(let item): LibraryModel.display(item.folder)
        case .command(let command): command.subtitle
        case .setting: "System Settings"
        case .app, .answer: nil
        }
    }

    @ViewBuilder
    func icon(_ row: QuickRow) -> some View {
        switch row {
        case .file(let item):
            Thumbnail(item: item, size: 28, fill: item.kind == .image || item.kind == .video)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .app(let app):
            Image(nsImage: AppIcons.icon(app.path)).resizable().interpolation(.high)
        case .setting:
            Image(nsImage: AppIcons.icon(AppIcons.systemSettings)).resizable().interpolation(.high)
        case .command(let command):
            Image(systemName: command.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.fill(0.07)))
        case .answer:
            EmptyView()
        }
    }

    @ViewBuilder
    func accessory(_ row: QuickRow) -> some View {
        switch row {
        case .file(let item):
            HStack(spacing: 10) {
                Text(item.latest.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                Text(ByteFormat.compact(item.bytes)).font(Theme.number(11.5, weight: .medium)).frame(minWidth: 44, alignment: .trailing)
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
        case .app:
            Text("Application").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
        case .setting:
            Text("Settings").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
        case .command(let command):
            if let shortcut = command.shortcut { Keycap(shortcut) } else { Text("Command").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary) }
        case .answer:
            EmptyView()
        }
    }

    /// The name with the letters you typed in bold (and the rest lighter, so they stand out).
    static func highlighted(_ name: String, _ ranges: [Range<Int>], size: CGFloat) -> AttributedString {
        guard !ranges.isEmpty else {
            var plain = AttributedString(name)
            plain.font = .system(size: size, weight: .medium)
            return plain
        }
        var out = AttributedString()
        for part in QuickRank.segments(name, ranges: ranges) {
            var run = AttributedString(part.text)
            run.font = .system(size: size, weight: part.matched ? .bold : .regular)
            if !part.matched { run.foregroundColor = Theme.textSecondary }
            out += run
        }
        return out
    }

    // MARK: Footer

    func footer(current: QuickRow?, actions: [QuickAction]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.onAccent)
                .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.accent))
            Text(kind(current)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            Spacer()
            if let primary = actions.first {
                Button { primary.run() } label: {
                    HStack(spacing: 6) {
                        Text(primary.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Keycap("↩")
                    }
                }
                .buttonStyle(.plain)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 16)
            }
            Button { state.actionsOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Text("Actions").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    Keycap("⌘K")
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).frame(height: 42)
        .background(Theme.fill(0.035))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    func kind(_ row: QuickRow?) -> String {
        switch row {
        case .file(let item)?: item.isFolder ? "Folder" : item.kind == .other ? "File" : String(item.kind.title.dropLast())
        case .app?: "Application"
        case .setting?: "System Settings"
        case .command?: "Command"
        case .answer?: "Calculator"
        case nil: "Quick Search"
        }
    }

    // MARK: ⌘K

    func filtered(_ actions: [QuickAction]) -> [QuickAction] {
        let needles = QuickCommands.needles(state.actionQuery)
        guard !needles.isEmpty else { return actions }
        return actions.filter { QuickRank.match($0.title, needles: needles).tier != .elsewhere }
    }

    func actionsPanel(_ all: [QuickAction]) -> some View {
        let shown = filtered(all)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, action in
                    if action.section != (i > 0 ? shown[i - 1].section : "") && !action.section.isEmpty {
                        Text(action.section).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 10).padding(.top, i == 0 ? 2 : 8).padding(.bottom, 2)
                    }
                    HStack(spacing: 9) {
                        Image(systemName: action.symbol).font(.system(size: 12, weight: .medium)).frame(width: 18)
                            .foregroundStyle(action.destructive ? Theme.critical : Theme.textSecondary)
                        Text(action.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            .foregroundStyle(action.destructive ? Theme.critical : Theme.textPrimary)
                        Spacer(minLength: 8)
                        if let key = action.key { Keycap(key.label) }
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(i == state.actionSelected ? Theme.fill(0.10) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { action.run() }
                    .onHover { if $0 { state.actionSelected = i } }
                }
                if shown.isEmpty {
                    Text("No actions match").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(10)
                }
            }
            .padding(6)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Group {
                if snapshot {
                    Text("Search for actions…").foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: $state.actionQuery, prompt: Text("Search for actions…").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain)
                        .focused($field, equals: .actions)
                        .onKeyPress(phases: .down) { press in actionKey(press, shown: shown) }
                }
            }
            .font(.system(size: 12.5)).padding(.horizontal, 14).frame(height: 38)
        }
        .frame(width: 330)
        .background { if snapshot { Theme.surfaceRaised } else { VisualEffect(material: .menu).overlay(Theme.surfaceRaised.opacity(0.7)) } }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }

    func actionKey(_ press: KeyPress, shown: [QuickAction]) -> KeyPress.Result {
        if composing { return .ignored }
        let mods = press.modifiers.intersection(QuickKey.significant)
        let key = press.key
        if (key == .downArrow && mods.isEmpty) || (key == "n" && mods == .control) {
            state.actionSelected = min(max(shown.count - 1, 0), state.actionSelected + 1); return .handled
        }
        if (key == .upArrow && mods.isEmpty) || (key == "p" && mods == .control) {
            state.actionSelected = max(0, state.actionSelected - 1); return .handled
        }
        if key == .escape || (key == "k" && mods == .command) { state.actionsOpen = false; return .handled }
        if key == .return && mods.isEmpty {
            if shown.indices.contains(state.actionSelected) { shown[state.actionSelected].run() }
            return .handled
        }
        if !mods.isEmpty, let action = shown.first(where: { $0.key?.matches(press) ?? false }) { action.run(); return .handled }
        return .ignored
    }
}

/// ⌘I: what the selected row is, beside the list.
struct QuickInfo: View {
    var row: QuickRow
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 14) {
                preview.frame(maxWidth: .infinity).frame(height: 180)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(facts, id: \.0) { label, value in
                        HStack(alignment: .firstTextBaseline) {
                            Text(label).foregroundStyle(Theme.textTertiary).frame(width: 82, alignment: .leading)
                            Text(value).foregroundStyle(Theme.textSecondary).lineLimit(3).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11.5))
                    }
                }
                if case .file(let item) = row, let text = library.recognized[item.path]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Text in it").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        Text(String(text.prefix(400))).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(8).textSelection(.enabled)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder var preview: some View {
        switch row {
        case .file(let item):
            Thumbnail(item: item, size: 300, fill: item.kind == .image || item.kind == .video)
        case .app(let app):
            Image(nsImage: AppIcons.icon(app.path)).resizable().interpolation(.high).frame(width: 96, height: 96)
        case .setting:
            Image(nsImage: AppIcons.icon(AppIcons.systemSettings)).resizable().interpolation(.high).frame(width: 96, height: 96)
        case .command(let command):
            Image(systemName: command.symbol).font(.system(size: 40, weight: .medium)).foregroundStyle(Theme.accent)
        case .answer(_, let value):
            Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)).minimumScaleFactor(0.4).padding()
        }
    }

    var title: String {
        switch row {
        case .file(let item): item.name
        case .app(let app): app.name
        case .setting(let pane): pane.name
        case .command(let command): command.title
        case .answer(let sum, _): sum
        }
    }

    var facts: [(String, String)] {
        let when: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
        switch row {
        case .file(let item):
            var out: [(String, String)] = [
                ("Kind", item.isFolder ? "Folder" : item.ext.isEmpty ? "File" : "\(item.ext.uppercased()) \(String(item.kind.title.dropLast()).lowercased())"),
                ("Size", ByteFormat.compact(item.bytes)),
                ("Where", LibraryModel.display(item.folder)),
                ("Modified", when(item.modified)),
                ("Created", when(item.created)),
            ]
            if let received = item.received { out.append(("Downloaded", when(received))) }
            if let source = DownloadSources.source(of: item) { out.append(("From", source.name)) }
            return out
        case .app(let app):
            let info = Bundle(path: app.path)?.infoDictionary
            var out: [(String, String)] = [("Where", LibraryModel.display((app.path as NSString).deletingLastPathComponent))]
            if let version = info?["CFBundleShortVersionString"] as? String { out.append(("Version", version)) }
            if let id = info?["CFBundleIdentifier"] as? String { out.append(("Bundle ID", id)) }
            return out
        case .setting(let pane):
            var out: [(String, String)] = [("Opens", "System Settings → \(pane.name)")]
            if !pane.keywords.isEmpty { out.append(("Also finds", pane.keywords.prefix(4).joined(separator: ", "))) }
            return out
        case .command(let command):
            var out: [(String, String)] = [("What", command.subtitle)]
            if let shortcut = command.shortcut { out.append(("In the window", shortcut)) }
            return out
        case .answer(let sum, let value):
            return [("Sum", sum), ("Answer", value)]
        }
    }
}

/// App icons, read once each.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]
    static let systemSettings = "/System/Applications/System Settings.app"

    static func icon(_ path: String) -> NSImage {
        if let icon = cache[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache[path] = icon
        return icon
    }
}

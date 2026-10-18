import SwiftUI
import AppKit
import HeadroomCore

/// Files as big cards or a tidy list. Click to select (⌘ and ⇧ like Finder), double-click to
/// open, Space for Quick Look, arrows to move, drag to carry files out, right-click for actions.
struct FileGrid: View {
    @EnvironmentObject var library: LibraryModel
    var items: [LibraryItem]
    /// Shown above the files, inside the scroll view.
    var header: AnyView? = nil
    var limit = 3000
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let shown = Array(items.prefix(snapshot ? (library.viewMode == .grid ? 24 : 16) : limit))
        Scrolling {
            VStack(alignment: .leading, spacing: 14) {
                if let header { header }
                if library.viewMode == .grid { grid(shown) } else { list(shown) }
                if items.count > shown.count, !snapshot {
                    Text("Showing the first \(shown.count) of \(items.count). Search to narrow it down.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 24)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) { QuickLook.shared.toggle(library); return .handled }
        .onKeyPress(.leftArrow) { library.moveSelection(by: -1); return .handled }
        .onKeyPress(.rightArrow) { library.moveSelection(by: 1); return .handled }
        .onKeyPress(.upArrow) { library.moveSelection(by: library.viewMode == .grid ? -library.columns : -1); return .handled }
        .onKeyPress(.downArrow) { library.moveSelection(by: library.viewMode == .grid ? library.columns : 1); return .handled }
        .onKeyPress(.return) {
            if let f = library.focused.flatMap(library.item) { library.open(f) }
            return .handled
        }
        .onKeyPress(.escape) {
            if library.selection.isEmpty { return .ignored }
            library.selection = []
            return .handled
        }
        // Finder's keys, while the files have focus (so they never steal copy from a text field).
        // ⌘C and ⌘A are the Edit menu's: they arrive as commands for whatever has focus.
        .onCommand(#selector(NSText.copy(_:))) {
            let picked = library.selectedItems
            if !picked.isEmpty { library.copyFiles(picked) }
        }
        .onCommand(#selector(NSText.selectAll(_:))) { library.selection = Set(items.map(\.path)) }
        // ⇧⌘C arrives as "C" (Shift is kept in the key).
        .onKeyPress(keys: ["C", .delete]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let picked = library.selectedItems
            switch press.key {
            case "C": Task { await library.copyText(picked) }
            case .delete: if !picked.isEmpty { library.trashRequest = picked }
            default: return .ignored
            }
            return .handled
        }
        .onAppear { library.visible = items }
        .onChange(of: items) { _, new in
            library.visible = new
            let live = Set(new.map(\.path))
            library.selection = library.selection.filter(live.contains)
        }
        .onChange(of: library.focused) { _, f in if f != nil { focused = true } }
    }

    // MARK: Grid

    func grid(_ shown: [LibraryItem]) -> some View {
        let size = library.cardSize
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size * 1.35), spacing: 14)], alignment: .leading, spacing: 14) {
            ForEach(shown) { item in
                FileCard(item: item, size: size)
            }
        }
        .background(GeometryReader { geo in
            Color.clear.onAppear { library.columns = max(1, Int((geo.size.width + 14) / (size + 14))) }
                .onChange(of: geo.size.width) { _, w in library.columns = max(1, Int((w + 14) / (size + 14))) }
        })
    }

    // MARK: List

    func list(_ shown: [LibraryItem]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                sortHeader("Name", .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 44)
                sortHeader("Kind", .kind).frame(width: 90, alignment: .leading)
                sortHeader("Size", .size).frame(width: 80, alignment: .trailing)
                sortHeader("Date", .date).frame(width: 130, alignment: .trailing)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider().overlay(Theme.hairline)
            LazyVStack(spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                    FileRow(item: item, striped: i % 2 == 1)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    func sortHeader(_ title: String, _ sort: LibraryModel.Sort) -> some View {
        Button {
            if library.sort == sort { library.ascending.toggle() } else { library.sort = sort; library.ascending = sort == .name || sort == .kind }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if library.sort == sort { Image(systemName: library.ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(library.sort == sort ? Theme.textPrimary : Theme.textTertiary)
        }
        .buttonStyle(.plain)
    }
}

/// How a card or row reacts to the mouse — shared so cards on the Home screen behave the same.
struct FileMouse: ViewModifier {
    @EnvironmentObject var library: LibraryModel
    var item: LibraryItem
    /// The list this item belongs to (Quick Look, Shift-click); nil keeps the current one.
    var siblings: [LibraryItem]?
    @Binding var hovering: Bool
    @Environment(\.snapshotMode) private var snapshot

    @ViewBuilder func body(content: Content) -> some View {
        // ImageRenderer can't draw an AppKit view: renders show the card alone.
        if snapshot { content } else { interactive(content) }
    }

    func interactive(_ content: Content) -> some View {
        content.overlay(
            FileInteraction(
                onClick: { modifiers, count in
                    if let siblings { library.visible = siblings }
                    if count >= 2 { library.open(item) } else { library.select(item, modifiers: modifiers) }
                },
                isInMultiSelection: { library.selection.count > 1 && library.selection.contains(item.path) },
                dragURLs: { library.targets(for: item).map(\.url) },
                menu: { FileMenu.make(for: item, library: library) },
                onHover: { hovering = $0 }
            )
        )
    }
}

/// A file as a card: big thumbnail, type and size, name and date.
struct FileCard: View {
    @EnvironmentObject var library: LibraryModel
    var item: LibraryItem
    var size: CGFloat
    var siblings: [LibraryItem]? = nil
    @State private var hovering = false

    var selected: Bool { library.selection.contains(item.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.045))
                Thumbnail(item: item, size: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 4) {
                    Circle().fill(Theme.tint(for: item.kind)).frame(width: 6, height: 6)
                    Text(item.isFolder ? "Folder" : "\(item.typeLabel) · \(ByteFormat.compact(item.bytes))")
                }
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.black.opacity(0.75))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(0.88)))
                .padding(7)
                .opacity(item.isFolder ? 0 : 1)
            }
            .frame(height: size * 0.78)
            .overlay(alignment: .bottomLeading) {
                if item.kind == .audio, library.player.current?.path == item.path {
                    NowPlayingBadge().padding(8)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.latest.listDate)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, 3)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.16) : hovering ? Theme.fill(0.05) : Theme.surface)
                .shadow(color: selected || hovering ? .clear : Theme.shadow, radius: 6, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(selected ? Theme.accent.opacity(0.85) : Theme.hairline, lineWidth: selected ? 2 : 1))
        .modifier(FileMouse(item: item, siblings: siblings, hovering: $hovering))
        // Above the mouse layer, so the buttons get their clicks.
        .overlay(alignment: .topTrailing) { hoverActions.padding(7) }
        .help(item.url.tildePath)
    }

    /// Hover a picture for Copy Text; hover a song or video for play.
    @ViewBuilder var hoverActions: some View {
        if hovering, !item.isFolder {
            HStack(spacing: 6) {
                if library.canReadText(item) {
                    HoverButton(symbol: "text.viewfinder", help: "Copy Text  ⇧⌘C") { Task { await library.copyText(library.targets(for: item)) } }
                }
                if item.kind == .audio {
                    HoverButton(symbol: library.player.current?.path == item.path && library.player.playing ? "pause.fill" : "play.fill",
                                help: "Play") {
                        if library.player.current?.path == item.path { library.player.toggle() } else { library.open(item) }
                    }
                }
                HoverButton(symbol: "eye", help: "Quick Look  Space") {
                    QuickLook.shared.show(library: library, items: library.visible.isEmpty ? [item] : library.visible, current: item)
                }
            }
            .padding(7)
            .transition(.opacity)
        }
    }
}

/// A small round button over a thumbnail. Drawn above the card's mouse layer, so it gets the click.
struct HoverButton: View {
    var symbol: String
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.black.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(0.92)).shadow(color: .black.opacity(0.18), radius: 3, y: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A file as a row: icon, name and folder, kind, size, date.
struct FileRow: View {
    @EnvironmentObject var library: LibraryModel
    var item: LibraryItem
    var striped = false
    var siblings: [LibraryItem]? = nil
    @State private var hovering = false

    var selected: Bool { library.selection.contains(item.path) }

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(item: item, size: 30, fill: item.kind == .image || item.kind == .video)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(LibraryModel.display(item.folder)).font(.system(size: 10.5))
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary).lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                Circle().fill(Theme.tint(for: item.kind)).frame(width: 6, height: 6)
                Text(item.typeLabel)
            }
            .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
            Text(item.isFolder ? "—" : ByteFormat.string(item.bytes)).font(Theme.number(11.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary).frame(width: 80, alignment: .trailing)
            Text(item.latest.listDate).font(.system(size: 11.5)).lineLimit(1)
                .foregroundStyle(Theme.textTertiary).frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(selected ? Theme.accent.opacity(0.18) : hovering ? Theme.fill(0.05) : striped ? Theme.fill(0.02) : .clear)
        .modifier(FileMouse(item: item, siblings: siblings, hovering: $hovering))
    }
}

extension Date {
    /// "Today 14:05", "Oct 16, 14:05" this year, "Mar 3, 2024" before.
    var listDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today, " + formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(self) { return "Yesterday, " + formatted(date: .omitted, time: .shortened) }
        if cal.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day()) + ", " + formatted(date: .omitted, time: .shortened)
        }
        return formatted(date: .abbreviated, time: .omitted)
    }
}

/// Little equaliser bars on the song that's playing.
struct NowPlayingBadge: View {
    var body: some View {
        Image(systemName: "waveform").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            .padding(5).background(Circle().fill(Theme.tint(for: .audio)))
    }
}

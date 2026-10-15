import SwiftUI
import HeadroomCore

/// The heatmap: every GB on the disk as squares sized by space, coloured by area.
/// Safe-to-reclaim folders glow mint with hatching; review items get an amber dash.
/// Click a square to select it, double-click to look inside, right-click for everything you can do.
struct MapView: View {
    @EnvironmentObject var model: AppModel
    @State private var path: [DiskNode] = []
    @State private var loading = false
    @State private var hovered: DiskNode?
    @State private var selected: DiskNode?
    @State private var highlightSafe = true
    @State private var pending: PendingAction?
    @State private var working = false
    @State private var outcome: AppModel.MapOutcome?
    @Environment(\.snapshotMode) private var snapshot

    init(path: [DiskNode] = [], selected: DiskNode? = nil) {
        _path = State(initialValue: path)
        _selected = State(initialValue: selected)
    }

    var current: DiskNode? { path.last ?? model.map }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let node = current {
                GeometryReader { geo in
                    TreemapTiles(node: node, size: geo.size, highlightSafe: highlightSafe, hovered: $hovered,
                                 selectedID: selected?.id,
                                 onSelect: { tile in
                                     // Summary groups have nothing to act on: one click opens them, as before.
                                     if tile.url == nil, canLookInside(tile) { Task { await drill(into: tile) } }
                                     else { selected = tile }
                                 },
                                 onOpen: { tile in Task { await drill(into: tile) } },
                                 menu: { tile in menu(for: tile) })
                }
                .overlay(alignment: .center) {
                    if loading || working { ProgressView().controlSize(.large).tint(.white) }
                }
                .overlay(alignment: .top) { toast }
                footer
            } else if let p = model.mapProgress {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Mapping every folder on your Mac…").font(.system(size: 15, weight: .semibold))
                        ProgressLine(done: p.done, total: p.total, label: p.current)
                    }
                }
                Spacer()
            } else {
                Card { Text("The map builds after the first scan.").foregroundStyle(Theme.textSecondary) }
                Spacer()
            }
        }
        .confirmingAction($pending) { p in await run(p) }
        .background {
            // ⌘⌫ moves the selection to the Trash, as in Finder (after the usual confirm).
            Button("") { if let s = selected { ask(.trash, s) } }
                .keyboardShortcut(.delete, modifiers: .command).hidden()
        }
    }

    var header: some View {
        HStack(spacing: 6) {
            Button { go(to: 0) } label: { Text(model.map?.name ?? "Macintosh HD") }
                .buttonStyle(.plain).font(.system(size: 13, weight: path.isEmpty ? .semibold : .regular))
            ForEach(Array(path.enumerated()), id: \.element.id) { i, n in
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Button { go(to: i + 1) } label: { Text(n.name).lineLimit(1) }
                    .buttonStyle(.plain).font(.system(size: 13, weight: i == path.count - 1 ? .semibold : .regular))
            }
            Spacer()
            if let node = current { Text(node.bytes.gb).font(Theme.number(13, weight: .semibold)).foregroundStyle(Theme.textSecondary) }
            Button { highlightSafe.toggle() } label: {
                HStack(spacing: 6) {
                    CheckCircle(on: highlightSafe)
                    Text("Highlight safe to delete").font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.textPrimary)
    }

    /// The selected square and what you can do with it; otherwise whatever is under the pointer.
    var footer: some View {
        HStack(spacing: 10) {
            if let h = selected ?? hovered {
                Image(systemName: h.safety == .safe ? "sparkles" : h.url?.pathExtension == "app" ? "app.fill" : "folder.fill")
                    .foregroundStyle(h.safety.map(Theme.color(for:)) ?? Theme.color(for: h.area))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(h.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(h.bytes.gb).font(Theme.number(12, weight: .semibold))
                        if let s = h.safety { Badge(text: s.label, color: Theme.color(for: s)) }
                    }
                    Text(h.url?.tildePath ?? (selected == nil ? "Click to select" : "Look inside to act on these"))
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let s = selected { actions(for: s) }
            } else {
                HStack(spacing: 14) {
                    LegendDot(color: Theme.safe, label: "Safe to reclaim")
                    LegendDot(color: Theme.review, label: "Review first")
                    Text("Click a folder to select it · double-click to look inside · right-click for options")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
        }
        .frame(height: 34)
        .foregroundStyle(Theme.textPrimary)
    }

    @ViewBuilder func actions(for node: DiskNode) -> some View {
        if canLookInside(node) {
            Button("Look inside") { Task { await drill(into: node) } }.buttonStyle(GhostButtonStyle())
        }
        if let url = node.url {
            Button("Reveal") { model.reveal([url]) }.buttonStyle(GhostButtonStyle())
        }
        // The one action that fits best, up front; everything else in the menu.
        if let primary = primaryAction(for: node) {
            Button(ActionText.label(primary) + (primary == .reclaim ? "" : "…")) { ask(primary, node) }
                .buttonStyle(PrimaryButtonStyle(tint: primary == .reclaim ? Theme.safe : Theme.critical))
                .disabled(working)
        }
        if snapshot {
            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.textSecondary)
        } else {
            Menu { menu(for: node) } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        Button { selected = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Deselect")
    }

    /// Every option for a square: the right-click menu and the ⋯ button.
    @ViewBuilder func menu(for node: DiskNode) -> some View {
        if canLookInside(node) { Button("Look Inside") { Task { await drill(into: node) } } }
        if let url = node.url {
            Button("Reveal in Finder") { model.reveal([url]) }
            Button("Open") { model.open(url) }
            if model.isDirectory(url) { Button("Open in Terminal") { model.openInTerminal(url) } }
            Button("Copy Path") { model.copyPath(url) }
            Divider()
            if let known = model.knownFinding(for: url), known.method != .none, known.safety != .keep {
                actionItem(.reclaim, "Reclaim — \(known.title)", node)
            }
            if url.pathExtension == "app" { actionItem(.uninstall, "Uninstall App…", node) }
            actionItem(.trash, "Move to Trash…", node)
            if model.isDirectory(url) { actionItem(.emptyContents, "Empty Folder (keep the folder)…", node) }
            actionItem(.delete, "Delete Permanently…", node)
            Divider()
            Button("Never Touch This") { model.exclude([url]); selected = nil }
        } else {
            Text("Look inside to act on what's in it")
        }
    }

    @ViewBuilder func actionItem(_ action: AppModel.MapAction, _ title: String, _ node: DiskNode) -> some View {
        if let why = model.refusal(action, for: node) {
            Button("\(title.replacingOccurrences(of: "…", with: "")) — \(why)") {}.disabled(true)
        } else {
            Button(title) { ask(action, node) }.disabled(working)
        }
    }

    @ViewBuilder var toast: some View {
        if let o = outcome {
            HStack(spacing: 8) {
                Image(systemName: o.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(o.failed ? Theme.review : Theme.safe)
                Text(o.message).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Theme.surfaceRaised).shadow(color: .black.opacity(0.4), radius: 12, y: 4))
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Actions

    func primaryAction(for node: DiskNode) -> AppModel.MapAction? {
        [.reclaim, .uninstall, .trash].first { action in
            if action == .reclaim, node.url.flatMap(model.knownFinding(for:)) == nil { return false }
            if action == .uninstall, node.url?.pathExtension != "app" { return false }
            return model.refusal(action, for: node) == nil
        }
    }

    func ask(_ action: AppModel.MapAction, _ node: DiskNode) {
        guard !working, model.refusal(action, for: node) == nil else { return }
        pending = PendingAction(action: action, node: node)
    }

    func run(_ p: PendingAction) async {
        working = true
        let result = await model.perform(p.action, on: p.node)
        // Update the map in place: the square shrinks or goes, and so do its parents.
        let ancestors = Set(path.map(\.id) + [model.map?.id ?? "root"])
        model.reflect(result, ancestors: ancestors)
        var updated: [DiskNode] = []
        for node in path {
            guard let n = node.reflecting(removalOf: result.nodeID, remaining: result.remaining,
                                          freed: result.freedFromMap, ancestors: ancestors) else { break }
            updated.append(n)
        }
        path = updated
        if selected?.id == result.nodeID { selected = nil }
        working = false
        // Trashed and uninstalled things can be put back straight from the toast.
        let undoable = !result.failed && (p.action == .trash || p.action == .uninstall)
        model.show(result.message, failed: result.failed, undo: undoable ? model.activity.entries.first?.id : nil)
    }

    // MARK: Navigation

    func canLookInside(_ node: DiskNode) -> Bool {
        !node.children.isEmpty || (node.expandable && node.url != nil && model.isDirectory(node.url!))
    }

    func go(to depth: Int) {
        path = Array(path.prefix(depth))
        selected = nil
    }

    func drill(into tile: DiskNode) async {
        if !tile.children.isEmpty {
            path.append(tile)
            selected = nil
            return
        }
        guard canLookInside(tile) else { return }
        loading = true
        var expanded = tile
        expanded.children = await DiskMap.expand(tile, safetyByPath: model.safetyByPath)
        loading = false
        if !expanded.children.isEmpty {
            path.append(expanded)
            selected = nil
        }
    }
}

struct TreemapTiles<Menu: View>: View {
    var node: DiskNode
    var size: CGSize
    var highlightSafe: Bool
    @Binding var hovered: DiskNode?
    var selectedID: String?
    var onSelect: (DiskNode) -> Void
    var onOpen: (DiskNode) -> Void
    @ViewBuilder var menu: (DiskNode) -> Menu

    /// Tiny tiles are merged into one "N smaller items" square so the map stays legible.
    var tiles: [DiskNode] {
        let kids = node.children.sorted { $0.bytes > $1.bytes }
        let total = Double(kids.reduce(0) { $0 + $1.bytes })
        guard total > 0 else { return [] }
        var shown: [DiskNode] = []
        var rest: Int64 = 0
        var restCount = 0
        for k in kids {
            if Double(k.bytes) / total >= 0.004 || shown.count < 6 { shown.append(k) } else { rest += k.bytes; restCount += 1 }
        }
        if rest > 0 {
            shown.append(DiskNode(id: node.id + ":rest", name: "\(restCount) smaller items", bytes: rest, area: node.children.first?.area ?? .other))
        }
        return shown
    }

    var body: some View {
        let items = tiles
        let rects = Treemap.layout(items.map { Double($0.bytes) }, in: .init(x: 0, y: 0, width: size.width, height: size.height))
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(items, rects)), id: \.0.id) { item, rect in
                Tile(node: item, rect: rect, highlightSafe: highlightSafe, isHovered: hovered?.id == item.id,
                     isSelected: selectedID == item.id)
                    .onHover { inside in if inside { hovered = item } else if hovered?.id == item.id { hovered = nil } }
                    .onTapGesture(count: 2) { onOpen(item) }
                    .onTapGesture { onSelect(item) }
                    .contextMenu { menu(item) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: node.id)
    }
}

struct Tile: View {
    var node: DiskNode
    var rect: Treemap.Rect
    var highlightSafe: Bool
    var isHovered: Bool
    var isSelected = false

    var body: some View {
        let base = Theme.color(for: node.area)
        let w = max(0, rect.width - 3), h = max(0, rect.height - 3)
        let safety = highlightSafe ? node.safety : nil
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [base.opacity(isHovered ? 0.95 : 0.78), base.opacity(isHovered ? 0.75 : 0.52)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if safety == .safe {
                Hatch().stroke(Theme.safe.opacity(0.35), lineWidth: 1).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if w > 70, h > 34 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if safety == .safe { Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)) }
                        Text(node.name).font(.system(size: min(14, max(10, h / 6)), weight: .semibold)).lineLimit(1)
                    }
                    Text(node.bytes.gb).font(Theme.number(min(13, max(9.5, h / 7)), weight: .medium)).opacity(0.85)
                }
                .foregroundStyle(Color.black.opacity(0.82))
                .padding(8)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white, lineWidth: 2.5)
                    .shadow(color: .white.opacity(0.5), radius: 6)
            } else if safety == .safe {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.safe, lineWidth: 2)
                    .shadow(color: Theme.safe.opacity(0.6), radius: 6)
            } else if safety == .review {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.review, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
            }
        }
        .frame(width: w, height: h)
        .offset(x: rect.x + 1.5, y: rect.y + 1.5)
        .help("\(node.name) — \(node.bytes.gb)")
    }
}

/// Diagonal hatching for "safe to reclaim" tiles.
struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 9
        var x = -rect.height
        while x < rect.width {
            p.move(to: CGPoint(x: x, y: rect.height))
            p.addLine(to: CGPoint(x: x + rect.height, y: 0))
            x += step
        }
        return p
    }
}

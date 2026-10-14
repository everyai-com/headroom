import SwiftUI
import HeadroomCore

/// The heatmap: every GB on the disk as squares sized by space, coloured by area.
/// Safe-to-reclaim folders glow mint with hatching; review items get an amber dash.
struct MapView: View {
    @EnvironmentObject var model: AppModel
    @State private var path: [DiskNode] = []
    @State private var loading = false
    @State private var hovered: DiskNode?
    @State private var highlightSafe = true

    var current: DiskNode? { path.last ?? model.map }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let node = current {
                GeometryReader { geo in
                    TreemapTiles(node: node, size: geo.size, highlightSafe: highlightSafe, hovered: $hovered) { tile in
                        Task { await drill(into: tile) }
                    }
                }
                .overlay(alignment: .center) {
                    if loading { ProgressView().controlSize(.large).tint(.white) }
                }
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
    }

    var header: some View {
        HStack(spacing: 6) {
            Button { path = [] } label: { Text(model.map?.name ?? "Macintosh HD") }
                .buttonStyle(.plain).font(.system(size: 13, weight: path.isEmpty ? .semibold : .regular))
            ForEach(Array(path.enumerated()), id: \.element.id) { i, n in
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Button { path = Array(path.prefix(i + 1)) } label: { Text(n.name).lineLimit(1) }
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

    var footer: some View {
        HStack(spacing: 14) {
            if let h = hovered {
                Image(systemName: h.safety == .safe ? "sparkles" : "folder.fill")
                    .foregroundStyle(h.safety.map(Theme.color(for:)) ?? Theme.color(for: h.area))
                Text(h.url?.tildePath ?? h.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(h.bytes.gb).font(Theme.number(12, weight: .semibold))
                if let s = h.safety { Badge(text: s.label, color: Theme.color(for: s)) }
                Spacer()
                if let url = h.url { Button("Reveal") { model.reveal([url]) }.buttonStyle(GhostButtonStyle()) }
            } else {
                HStack(spacing: 14) {
                    LegendDot(color: Theme.safe, label: "Safe to reclaim")
                    LegendDot(color: Theme.review, label: "Review first")
                    Text("Click a square to look inside").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
        }
        .frame(height: 28)
        .foregroundStyle(Theme.textPrimary)
    }

    func drill(into tile: DiskNode) async {
        if !tile.children.isEmpty {
            path.append(tile)
            return
        }
        guard tile.expandable, tile.url != nil else { return }
        loading = true
        var expanded = tile
        expanded.children = await DiskMap.expand(tile, safetyByPath: model.safetyByPath)
        loading = false
        if !expanded.children.isEmpty { path.append(expanded) }
    }
}

struct TreemapTiles: View {
    var node: DiskNode
    var size: CGSize
    var highlightSafe: Bool
    @Binding var hovered: DiskNode?
    var onOpen: (DiskNode) -> Void

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
                Tile(node: item, rect: rect, highlightSafe: highlightSafe, isHovered: hovered?.id == item.id)
                    .onHover { inside in if inside { hovered = item } else if hovered?.id == item.id { hovered = nil } }
                    .onTapGesture { onOpen(item) }
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
            if safety == .safe {
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

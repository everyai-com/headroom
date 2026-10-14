import SwiftUI
import HeadroomCore

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    var openReclaim: () -> Void = {}
    var openMap: () -> Void = {}

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 18) {
                hero
                HStack(alignment: .top, spacing: 18) {
                    reclaimCard.frame(maxWidth: .infinity)
                    whereCard.frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Hero — the number that matters, big (WhatsApp "Manage storage")

    var hero: some View {
        let v = model.volume
        let tint = Theme.color(for: v.health)
        return Card(padding: 26) {
            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Badge(text: healthTitle(v.health), color: tint)
                        if let lost = model.history.lost(overHours: 24, now: v), lost > 1_000_000_000 {
                            Badge(text: "−\(lost.gb) in 24 h", color: Theme.review)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(v.free.gb).font(Theme.number(56, weight: .bold)).foregroundStyle(Theme.textPrimary)
                        Text("free of \(v.total.gb)").font(.system(size: 17, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(healthLine(v)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    capacityBar.padding(.top, 6)
                }
                Spacer(minLength: 0)
                ZStack {
                    GaugeRing(fraction: v.usedFraction, tint: tint, lineWidth: 16)
                    VStack(spacing: 2) {
                        Text("\(Int((v.usedFraction * 100).rounded()))%").font(Theme.number(34, weight: .bold))
                        Text("used").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(width: 150, height: 150)
            }
        }
    }

    var capacityBar: some View {
        let groups = model.map?.children ?? []
        let total = Double(model.volume.total)
        return VStack(alignment: .leading, spacing: 10) {
            if groups.isEmpty {
                SegmentedBar(segments: [.init(id: "used", value: Double(model.volume.used), color: Theme.color(for: .apps).opacity(0.7))], total: total)
            } else {
                SegmentedBar(segments: groups.map { .init(id: $0.id, value: Double($0.bytes), color: Theme.color(for: $0.area)) }, total: total)
                FlowLegend(items: groups.prefix(8).map { ($0.name, Theme.color(for: $0.area), $0.bytes.gb) })
            }
        }
    }

    func healthTitle(_ h: VolumeStatus.Health) -> String {
        switch h {
        case .good: "Healthy"
        case .tight: "Getting tight"
        case .critical: "Critically low"
        }
    }

    func healthLine(_ v: VolumeStatus) -> String {
        switch v.health {
        case .critical: "macOS needs about 10 GB free for updates, swap and apps to run smoothly. Reclaim below — nothing you made is touched."
        case .tight: "You're under 10 GB. Agentic coding refills this fast — every repo an agent touches grows its own dependencies."
        case .good: "Plenty of room. Headroom keeps watching and tells you before it gets tight."
        }
    }

    // MARK: Reclaim card (Telegram "Storage Usage")

    var reclaimCard: some View {
        let safe = model.safeFindings
        let byCategory = Dictionary(grouping: safe, by: \.category)
            .map { (cat: $0.key, bytes: $0.value.reduce(0) { $0 + $1.reclaimable }) }
            .sorted { $0.bytes > $1.bytes }
        let total = model.safeReclaimable
        return Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(title: "Reclaim safely", trailing: model.lastScan.map { "scanned \($0.ago)" })
                HStack(spacing: 18) {
                    ZStack {
                        Donut(slices: byCategory.map { (Double($0.bytes), Theme.color(for: $0.cat)) })
                        VStack(spacing: 0) {
                            Text(total.gb).font(Theme.number(17, weight: .bold))
                            Text("safe").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(width: 118, height: 118)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(byCategory.prefix(5), id: \.cat) { row in
                            HStack {
                                Circle().fill(Theme.color(for: row.cat)).frame(width: 8, height: 8)
                                Text(row.cat.title).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(row.bytes.gb).font(Theme.number(12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        if byCategory.isEmpty {
                            Text(model.lastScan == nil ? "Scanning…" : "Nothing safe left to reclaim.")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Button {
                    Task { await model.reclaim(safeOnly: true) }
                } label: {
                    Label(reclaimLabel(total), systemImage: "sparkles")
                }
                .buttonStyle(PrimaryButtonStyle(large: true))
                .disabled(total == 0 || model.isBusy)
                Text("Only caches and build output your tools recreate on their own. Your files, chats, apps and projects stay exactly as they are.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                if model.reviewReclaimable > 0 {
                    Button { openReclaim() } label: {
                        HStack {
                            Text("\(model.reviewReclaimable.gb) more to review").font(.system(size: 12.5, weight: .medium))
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Theme.review)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    func reclaimLabel(_ total: Int64) -> String {
        switch model.phase {
        case .reclaiming: "Reclaiming…"
        case .done(let freed): "Freed \(freed.gb)"
        case .scanning: "Scanning…"
        case .idle: total > 0 ? "Reclaim \(total.gb) safely" : "All clean"
        }
    }

    // MARK: Where it's going (Google One "usage details")

    var whereCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Where your space goes", trailing: model.map == nil ? nil : "every GB")
                if let groups = model.map?.children {
                    let maxBytes = Double(groups.first?.bytes ?? 1)
                    ForEach(groups.prefix(9)) { g in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(g.name).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                                Text(g.bytes.gb).font(Theme.number(12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            }
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 3).fill(Theme.color(for: g.area))
                                    .frame(width: max(3, geo.size.width * Double(g.bytes) / maxBytes))
                            }
                            .frame(height: 5)
                        }
                    }
                    Button("Open the map") { openMap() }.buttonStyle(GhostButtonStyle())
                } else if let p = model.mapProgress {
                    ProgressLine(done: p.done, total: p.total, label: "Measuring every folder… \(p.current)")
                } else {
                    Text("Measuring…").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}

struct Donut: View {
    var slices: [(Double, Color)]

    var body: some View {
        let total = max(slices.reduce(0) { $0 + $1.0 }, 1)
        ZStack {
            Circle().stroke(Color.white.opacity(0.06), lineWidth: 16)
            ForEach(Array(slices.enumerated()), id: \.offset) { i, s in
                let start = slices.prefix(i).reduce(0) { $0 + $1.0 } / total
                Circle()
                    .trim(from: start + 0.004, to: max(start + 0.004, start + s.0 / total - 0.004))
                    .stroke(s.1, style: StrokeStyle(lineWidth: 16, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

struct FlowLegend: View {
    var items: [(String, Color, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.0) { LegendDot(color: $0.1, label: $0.0, value: $0.2) }
        }
    }
}

struct ProgressLine: View {
    var done: Int
    var total: Int
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.07))
                    Capsule().fill(Theme.safe).frame(width: geo.size.width * Double(done) / Double(max(total, 1)))
                }
            }
            .frame(height: 6)
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
        }
    }
}

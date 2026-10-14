import SwiftUI
import HeadroomCore

/// Everything reclaimable, grouped by how safe it is (Telegram checklist + PlayStation's
/// sticky "Selected 11.98 GB" bar).
struct ReclaimView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: StorageCategory?
    @State private var showKeep = true
    @State private var byProject: Bool

    init(byProject: Bool = false) {
        _byProject = State(initialValue: byProject)
    }
    @Environment(\.snapshotMode) private var snapshot

    var visible: [Finding] {
        model.findings.filter { filter == nil || $0.category == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            Scrolling {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        chips
                        Spacer(minLength: 12)
                        HStack(spacing: 6) {
                            chip("By safety", color: Theme.safe, on: !byProject) { byProject = false }
                            chip("By project", color: Theme.color(for: .projectArtifacts), on: byProject) { byProject = true }
                        }
                        .fixedSize()
                    }
                    if byProject {
                        projects
                    } else {
                        ForEach(Safety.allCases, id: \.self) { safety in
                            let group = visible.filter { $0.safety == safety }
                            if !group.isEmpty && (safety != .keep || showKeep) {
                                section(safety, group)
                            }
                        }
                    }
                    if model.findings.isEmpty {
                        Card { Text("Scanning your Mac…").foregroundStyle(Theme.textSecondary) }
                    }
                }
                .padding(.bottom, 90)
            }
        }
        .overlay(alignment: .bottom) { selectionBar }
    }

    var chips: some View {
        let present = StorageCategory.allCases.filter { c in model.findings.contains { $0.category == c } }
        return FlowLayout(spacing: 8) {
            Group {
                chip("Everything", color: Theme.textPrimary, on: filter == nil) { filter = nil }
                ForEach(present, id: \.self) { c in
                    let bytes = model.findings.filter { $0.category == c }.reduce(0) { $0 + $1.size.allocated }
                    chip("\(c.title) · \(bytes.gb)", color: Theme.color(for: c), on: filter == c) { filter = filter == c ? nil : c }
                }
            }
        }
    }

    func chip(_ title: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(on ? Color.black : Theme.textPrimary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    func section(_ safety: Safety, _ items: [Finding]) -> some View {
        let total = items.reduce(0) { $0 + (safety == .keep ? $1.size.allocated : $1.reclaimable) }
        let allOn = items.allSatisfy { model.selected.contains($0.id) }
        return Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Circle().fill(Theme.color(for: safety)).frame(width: 9, height: 9)
                    Text(safety.label).font(.system(size: 14, weight: .semibold))
                    Text(subtitle(safety)).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text(total.gb).font(Theme.number(14, weight: .semibold)).foregroundStyle(Theme.color(for: safety))
                    if safety != .keep {
                        Button(allOn ? "Deselect all" : "Select all") {
                            for f in items where f.reclaimable > 0 {
                                if allOn { model.selected.remove(f.id) } else { model.selected.insert(f.id) }
                            }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                Divider().overlay(Theme.hairline)
                ForEach(items.prefix(snapshot ? 4 : (safety == .keep ? 12 : 200))) { f in
                    FindingRow(finding: f)
                    if f.id != items.last?.id { Divider().overlay(Theme.hairline).padding(.leading, 58) }
                }
            }
        }
    }

    // MARK: By project — agents make many repos; this is how you think about them

    struct ProjectGroup: Identifiable {
        var id: String
        var items: [Finding]
        var bytes: Int64 { items.reduce(0) { $0 + $1.reclaimable } }
        var lastUsed: Date? { items.compactMap(\.lastUsed).max() }
        var folder: URL? { items.first?.paths.first?.deletingLastPathComponent() }
    }

    var projectGroups: [ProjectGroup] {
        Dictionary(grouping: model.findings.filter { $0.category == .projectArtifacts }) { $0.project ?? "?" }
            .map { ProjectGroup(id: $0.key, items: $0.value) }
            .sorted { $0.bytes > $1.bytes }
    }

    @ViewBuilder var projects: some View {
        let groups = projectGroups
        let idle = groups.filter { ($0.lastUsed ?? .distantPast) < Date().addingTimeInterval(-30 * 86_400) }
        Card {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(groups.count) projects with build output · \(groups.reduce(0) { $0 + $1.bytes }.gb)")
                        .font(.system(size: 14, weight: .semibold))
                    Text("\(idle.count) untouched for 30+ days hold \(idle.reduce(0) { $0 + $1.bytes }.gb)")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("Select every project idle 30+ days") {
                    for g in idle { for f in g.items where f.reclaimable > 0 { model.selected.insert(f.id) } }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(idle.isEmpty)
            }
        }
        ForEach(groups.prefix(snapshot ? 4 : 300)) { g in
            let allOn = g.items.allSatisfy { model.selected.contains($0.id) || $0.reclaimable == 0 }
            Card(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.color(for: .projectArtifacts))
                        Text(g.id).font(.system(size: 14, weight: .semibold))
                        if let used = g.lastUsed {
                            Text("touched \(used.ago)").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Text(g.bytes.gb).font(Theme.number(14, weight: .semibold))
                        Button(allOn ? "Deselect" : "Select all") {
                            for f in g.items where f.reclaimable > 0 {
                                if allOn { model.selected.remove(f.id) } else { model.selected.insert(f.id) }
                            }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .contextMenu {
                        if let folder = g.folder {
                            Button("Reveal Project") { model.reveal([folder]) }
                            Button("Never Touch This Project") { model.exclude([folder]) }
                        }
                    }
                    Divider().overlay(Theme.hairline)
                    ForEach(g.items) { f in FindingRow(finding: f) }
                }
            }
        }
        if groups.isEmpty {
            Card { Text("No build output found in your code folders.").foregroundStyle(Theme.textSecondary) }
        }
    }

    func subtitle(_ s: Safety) -> String {
        switch s {
        case .safe: "recreated automatically — nothing is lost"
        case .review: "recreatable, but check first"
        case .keep: "shown so you know — never deleted"
        }
    }

    @ViewBuilder var selectionBar: some View {
        let count = model.selectedFindings.count
        if count > 0 || model.isBusy {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text("\(count) items · \(model.selectedBytes.gb)").font(Theme.number(15, weight: .semibold))
                }
                Spacer()
                let review = model.selectedFindings.filter { $0.safety == .review }.count
                if review > 0 {
                    Text("includes \(review) to review").font(.system(size: 12)).foregroundStyle(Theme.review)
                }
                Button {
                    Task { await model.reclaim() }
                } label: {
                    Label(barLabel, systemImage: "arrow.uturn.backward.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surfaceRaised.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            )
            .padding(.horizontal, 4).padding(.bottom, 4)
        }
    }

    var barLabel: String {
        switch model.phase {
        case .reclaiming: "Reclaiming…"
        case .done(let freed): "Freed \(freed.gb)"
        default: "Reclaim \(model.selectedBytes.gb)"
        }
    }
}

struct FindingRow: View {
    @EnvironmentObject var model: AppModel
    var finding: Finding

    var body: some View {
        let on = model.selected.contains(finding.id)
        let reclaimable = finding.safety != .keep && finding.reclaimable > 0
        HStack(alignment: .top, spacing: 14) {
            Button { model.toggle(finding) } label: {
                CheckCircle(on: on, tint: Theme.color(for: finding.safety), disabled: !reclaimable)
            }
            .buttonStyle(.plain)
            .disabled(!reclaimable)
            .padding(.top, 9)

            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.color(for: finding.category).opacity(0.16))
                Image(systemName: finding.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.color(for: finding.category))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(finding.project.map { "\($0) · \(finding.title)" } ?? finding.title)
                        .font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if let rebuild = finding.rebuild {
                        Text(rebuild).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                    }
                }
                Text(finding.subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                Text(finding.detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(finding.size.allocated > 0 ? finding.size.allocated.gb : "—").font(Theme.number(14, weight: .semibold))
                if reclaimable, finding.reclaimable < finding.size.allocated * 9 / 10 {
                    Text("frees \(finding.reclaimable.gb)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        .help("Shared with other projects through hard links — only this much is actually freed.")
                }
                if let used = finding.lastUsed {
                    Text(used.ago).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Button("Reveal") { model.reveal(finding.paths) }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            if !finding.paths.isEmpty {
                Button("Reveal in Finder") { model.reveal(finding.paths) }
                Button("Never Suggest This") { model.exclude(finding.paths) }
                if finding.category == .projectArtifacts, let project = finding.paths.first?.deletingLastPathComponent() {
                    Button("Never Touch This Project") { model.exclude([project]) }
                }
            }
        }
    }
}

import SwiftUI
import HeadroomCore

/// Coding: where an agent-heavy Mac's space goes. Worktrees (every task's extra checkout), build output
/// (node_modules, .next, Pods, venvs…) and developer caches, grouped so you can clear them at a glance.
/// Everything goes through `Cleaner` like the rest of the app: worktrees with `git worktree remove`
/// (never with uncommitted changes), build output deleted (it rebuilds), and one Activity entry each.
struct CodingScreen: View {
    @EnvironmentObject var model: AppModel
    var screen: Screen
    @State private var confirm: [Finding]?
    @Environment(\.snapshotMode) private var snapshot

    static func category(_ s: Screen) -> StorageCategory {
        switch s {
        case .worktrees: .worktrees
        case .buildOutput: .projectArtifacts
        default: .packageCaches
        }
    }

    static func items(_ s: Screen, model: AppModel) -> [Finding] {
        switch s {
        case .worktrees: return model.findings.filter { $0.category == .worktrees }
        case .buildOutput: return model.findings.filter { $0.category == .projectArtifacts }
        case .devCaches: return model.findings.filter { [.packageCaches, .developerTools, .aiAgents].contains($0.category) }
        default: return []
        }
    }

    var items: [Finding] { Self.items(screen, model: model) }

    /// The folder you'd call the project: the first one under Desktop, Documents, Projects… ("connector saas"),
    /// so many `deploy/worker`s from different repos don't land in one group.
    static func topProject(_ f: Finding) -> String? {
        guard let path = f.paths.first?.path, path.hasPrefix(HeadroomPaths.home + "/") else { return nil }
        let parts = path.dropFirst(HeadroomPaths.home.count + 1).split(separator: "/").map(String.init)
        guard parts.count > 2 else { return nil }
        return parts[1]
    }

    /// What removing these frees, counting a worktree nested inside another chosen one once.
    static func bytes(_ list: [Finding]) -> Int64 {
        let paths = list.compactMap { $0.paths.first?.path }
        return list.filter { f in
            guard let p = f.paths.first?.path else { return true }
            return !paths.contains { p.hasPrefix($0 + "/") }
        }.reduce(0) { $0 + $1.reclaimable }
    }
    var removable: [Finding] { items.filter { $0.safety != .keep && $0.reclaimable > 0 && $0.method != .none } }
    var chosen: [Finding] { removable.filter { model.selected.contains($0.id) } }

    /// Worktrees by repository, build output by project, caches by kind — biggest first.
    var groups: [(name: String, items: [Finding])] {
        Dictionary(grouping: items) { f -> String in
            switch screen {
            case .worktrees: (f.project ?? "Other").components(separatedBy: " · ").first ?? "Other"
            case .buildOutput: Self.topProject(f) ?? f.project ?? "Other"
            default: f.category.title
            }
        }
        .map { (name: $0.key, items: $0.value.sorted { $0.size.allocated > $1.size.allocated }) }
        .sorted { $0.items.reduce(0) { $0 + $1.size.allocated } > $1.items.reduce(0) { $0 + $1.size.allocated } }
    }

    var body: some View {
        VStack(spacing: 0) {
            Scrolling {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    if items.isEmpty {
                        if model.findings.isEmpty {
                            Card { HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Looking through your projects…").foregroundStyle(Theme.textSecondary) } }
                        } else {
                            EmptyState(symbol: screen.symbol, title: emptyTitle, detail: "Headroom looks in Desktop, Documents, Developer, Projects and the folders agents use (~/.codex, ~/conductor, ~/.cursor…).")
                        }
                    }
                    ForEach(groups.prefix(snapshot ? 5 : 200), id: \.name) { g in group(g.name, g.items) }
                }
                .padding(.bottom, 90)
            }
        }
        .overlay(alignment: .bottom) { removeBar }
        .confirmSheet(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { plan in
            Button(screen == .worktrees ? "Remove" : "Delete", role: .destructive) {
                Task {
                    await model.reclaim(only: plan)
                    model.selected.subtract(plan.map(\.id))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(confirmMessage(plan))
        }
    }

    var emptyTitle: String {
        switch screen {
        case .worktrees: "No worktrees"
        case .buildOutput: "No build output to clear"
        default: "No developer caches to clear"
        }
    }

    // MARK: Summary

    var summary: some View {
        let total = screen == .worktrees ? Worktrees.total(model.worktrees) : items.reduce(0) { $0 + $1.size.allocated }
        let free = Self.bytes(removable)
        let idle = removable.filter { ($0.lastUsed ?? .distantPast) < Date().addingTimeInterval(-14 * 86_400) }
        return Card {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ByteFormat.string(total)).font(Theme.number(28, weight: .bold))
                    Text(blurb(free: free)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    Button { select(removable) } label: { Label("Select all removable (\(removable.count))", systemImage: "checkmark.circle") }
                        .buttonStyle(GhostButtonStyle()).disabled(removable.isEmpty)
                    Button { select(idle) } label: { Label("Select idle 2+ weeks (\(idle.count))", systemImage: "moon.zzz") }
                        .buttonStyle(GhostButtonStyle()).disabled(idle.isEmpty)
                }
            }
        }
    }

    func blurb(free: Int64) -> String {
        switch screen {
        case .worktrees:
            let kept = items.count - removable.count
            return "Extra checkouts agents made for each task. \(ByteFormat.string(free)) can go with `git worktree remove` — commits stay on their branches."
                + (kept > 0 ? " \(kept) with uncommitted changes stay." : "")
        case .buildOutput:
            return "node_modules, Pods, virtualenvs and build caches inside your projects. \(ByteFormat.string(free)) can go; each comes back with its install command."
        default:
            return "Package manager, Xcode, simulator and agent caches. \(ByteFormat.string(free)) can go; tools rebuild what they need."
        }
    }

    func select(_ list: [Finding]) {
        let ids = Set(list.map(\.id))
        let mine = Set(items.map(\.id))
        model.selected.subtract(mine)
        model.selected.formUnion(ids)
    }

    // MARK: Groups

    func group(_ name: String, _ list: [Finding]) -> some View {
        let removableHere = list.filter { $0.safety != .keep && $0.reclaimable > 0 && $0.method != .none }
        let allOn = !removableHere.isEmpty && removableHere.allSatisfy { model.selected.contains($0.id) }
        let bytes = list.reduce(0) { $0 + $1.size.allocated }
        return Card(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: screen.symbol).font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.color(for: Self.category(screen)))
                    Text(name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(list.count)").font(Theme.number(11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.fill(0.07)))
                    Spacer()
                    Text(ByteFormat.string(bytes)).font(Theme.number(15, weight: .semibold))
                    if !removableHere.isEmpty {
                        Button(allOn ? "Deselect" : "Select all") {
                            for f in removableHere { if allOn { model.selected.remove(f.id) } else { model.selected.insert(f.id) } }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                Divider().overlay(Theme.hairline)
                ForEach(list.prefix(snapshot ? 3 : 100)) { f in
                    FindingRow(finding: f)
                    if f.id != list.last?.id { Divider().overlay(Theme.hairline).padding(.leading, 58) }
                }
            }
        }
    }

    // MARK: Remove

    @ViewBuilder var removeBar: some View {
        let plan = chosen
        if !plan.isEmpty || model.isBusy {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text("\(plan.count) \(noun(plan.count)) · \(ByteFormat.string(Self.bytes(plan)))")
                        .font(Theme.number(15, weight: .semibold))
                }
                Spacer()
                Button("Clear") { model.selected.subtract(items.map(\.id)) }.buttonStyle(GhostButtonStyle())
                Button { confirm = plan } label: {
                    Label(model.isBusy ? "Working…" : (screen == .worktrees ? "Remove" : "Delete") + " \(plan.count)", systemImage: "trash")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isBusy || plan.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surfaceRaised.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            )
            .padding(.horizontal, 4).padding(.bottom, 4)
        }
    }

    func noun(_ n: Int) -> String {
        switch screen {
        case .worktrees: n == 1 ? "worktree" : "worktrees"
        case .buildOutput: n == 1 ? "folder" : "folders"
        default: n == 1 ? "cache" : "caches"
        }
    }

    var confirmTitle: String {
        guard let plan = confirm else { return "" }
        let size = ByteFormat.string(Self.bytes(plan))
        return screen == .worktrees ? "Remove \(plan.count) \(noun(plan.count)) (\(size))?" : "Delete \(plan.count) \(noun(plan.count)) (\(size))?"
    }

    func confirmMessage(_ plan: [Finding]) -> String {
        switch screen {
        case .worktrees:
            let orphans = plan.filter { $0.method == .trash }.count
            return "Each goes with `git worktree remove`, which refuses anything with uncommitted changes. Commits stay on their branches in the main repository; ignored files in the worktree (node_modules, .env, build output) go with it."
                + (orphans > 0 ? " \(orphans) whose repository is gone go to the Trash." : "")
        case .buildOutput:
            return "Deleted for good — they're rebuilt by each project's install command (npm install, pod install…), shown on each row."
        default:
            return "Deleted for good — the tools that made them rebuild what they need, a little slower the first time."
        }
    }
}

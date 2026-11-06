import SwiftUI
import HeadroomCore

/// Clean up: the stuff you forgot about and what it's worth. Each card opens a review page —
/// you pick, and everything goes to the Trash, so it can always come back.
struct CleanUpView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: LibraryModel
    var openReclaim: () -> Void = {}
    var openDuplicates: () -> Void = {}

    var body: some View {
        if let kind = library.cleanUpFocus {
            CleanUpReview(kind: kind, back: { library.cleanUpFocus = nil }, openDuplicates: openDuplicates)
        } else {
            overview
        }
    }

    var overview: some View {
        let cards = library.suggestions
        let total = cards.reduce(0) { $0 + $1.bytes }
        return Scrolling {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    HStack(alignment: .center, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Free up \(ByteFormat.string(total + model.safeReclaimable))")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Text("Headroom finds the stuff you forgot about and shows you what it's worth. You review it, you decide. Files go to the Trash, so you can always put them back.")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 10)
                        if library.duplicatesScanned == nil {
                            Button { Task { await library.findDuplicates() } } label: {
                                Label(library.duplicatesProgress == nil ? "Find duplicates" : "Looking…", systemImage: "square.on.square")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(library.duplicatesProgress != nil)
                        }
                    }
                }
                if !library.hasScanned { LoadingLibrary() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(cards) { s in
                        Button { library.cleanUpFocus = s.kind } label: { SuggestionCard(suggestion: s, large: true) }
                            .buttonStyle(PressableStyle())
                    }
                    if model.safeReclaimable > 0 {
                        Button(action: openReclaim) { cachesCard }.buttonStyle(PressableStyle())
                    }
                }
                if cards.isEmpty, library.hasScanned, model.safeReclaimable == 0 {
                    EmptyState(symbol: "checkmark.seal", title: "Nothing to clean up",
                               detail: "No old installers, forgotten downloads, old screenshots or unused apps. Nice and tidy.")
                }
                Text("Example rules: installers untouched for 30 days or already installed · downloads not opened in 3 months · screenshots and screen recordings older than a month · videos over 500 MB untouched for 6 months · Mail attachments you opened over a week ago · apps not opened in 3 months.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 24)
        }
    }

    /// The caches and build output Reclaim handles — one click, nothing of yours.
    var cachesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.safe)
                    .frame(width: 30, height: 30).background(Circle().fill(Theme.safe.opacity(0.14)))
                Spacer()
                Badge(text: "One click", color: Theme.safe)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Caches & build output").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Text(ByteFormat.string(model.safeReclaimable)).font(Theme.number(28, weight: .bold))
            }
            Text("Temporary files your apps and tools make again on their own. Nothing of yours.")
                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Text("Reclaim").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface).shadow(color: Theme.shadow, radius: 8, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// One card's files: pick some, or take them all — to the Trash.
struct CleanUpReview: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: LibraryModel
    var kind: CleanUpSuggestion.Kind
    var back: () -> Void
    var openDuplicates: () -> Void
    @State private var confirm: [LibraryItem]?
    @State private var uninstalling: InstalledApp?

    var suggestion: CleanUpSuggestion? { library.suggestions.first { $0.kind == kind } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button(action: back) { Image(systemName: "chevron.left") }.buttonStyle(GhostButtonStyle()).help("All cards")
                Image(systemName: kind.symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title).font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(kind.detail).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if kind == .duplicates {
                    Button("Review duplicates", action: openDuplicates).buttonStyle(PrimaryButtonStyle())
                } else if kind != .unusedApps, let s = suggestion {
                    let picked = s.items.filter { library.selection.contains($0.path) }
                    Button("Trash Selected (\(picked.count))") { confirm = picked }
                        .buttonStyle(GhostButtonStyle()).disabled(picked.isEmpty)
                    Button("Trash All · \(ByteFormat.string(s.bytes))") { confirm = s.items }
                        .buttonStyle(PrimaryButtonStyle(tint: Theme.review))
                }
            }
            if let s = suggestion {
                if kind == .unusedApps {
                    apps(s.apps)
                } else {
                    FileGrid(items: s.items, header: s.installed.isEmpty ? nil : AnyView(
                        Text("\(s.installed.count) of these are for apps you already have in Applications.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)))
                }
            } else {
                EmptyState(symbol: "checkmark.seal", title: "All cleaned up", detail: "Nothing left on this card.")
            }
        }
        .confirmSheet(confirm.map { $0.count == 1 ? "Move “\($0[0].name)” to the Trash?" : "Move \($0.count) files to the Trash?" } ?? "",
                      isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { items in
            Button("Move to Trash", role: .destructive) { Task { await library.trash(items, label: kind.title.lowercased()) } }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            Text("\(ByteFormat.string(items.reduce(0) { $0 + $1.allocated })). Put them back any time from Activity — the space comes back when you empty the Trash.")
        }
        .confirmSheet(uninstalling.map { "Uninstall \($0.name)?" } ?? "", isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
                      presenting: uninstalling) { app in
            Button("Uninstall", role: .destructive) {
                Task {
                    let r = await model.uninstallApp(app)
                    model.show(r.message, failed: r.failed, undo: r.failed ? nil : model.activity.entries.first?.id)
                    library.refreshSuggestions()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { app in
            Text("\(app.name) and the \(ByteFormat.string(app.dataSize)) of data it keeps move to the Trash (\(ByteFormat.string(app.totalSize)) in all). Quit it first.")
        }
    }

    func apps(_ apps: [InstalledApp]) -> some View {
        Card(padding: 0) {
            Scrolling {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 34, height: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name).font(.system(size: 13, weight: .semibold))
                                Text("Last opened \(app.lastUsed?.ago ?? "never")").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                            }
                            Spacer()
                            Text(ByteFormat.string(app.totalSize)).font(Theme.number(13))
                            Button("Uninstall…") { uninstalling = app }.buttonStyle(GhostButtonStyle())
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        Divider().overlay(Theme.hairline).padding(.leading, 62)
                    }
                }
            }
        }
    }
}

import SwiftUI
import HeadroomCore

/// Duplicates: identical files (by SHA-256 fingerprint) and look-alike photos (bursts, edits,
/// HEIC/JPEG pairs). Headroom picks a copy to keep — click another to keep that one instead —
/// and the rest go to the Trash. Files that live only in iCloud are never read.
struct DuplicatesView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var tab: DuplicateGroup.Kind = .identical
    /// Your choice of copy to keep, by group.
    @State private var keep: [String: String] = [:]
    @State private var skipped: Set<String> = []
    @State private var confirm = false
    @Environment(\.snapshotMode) private var snapshot

    var groups: [DuplicateGroup] { tab == .identical ? library.duplicates : library.lookAlikes }

    func keeper(_ g: DuplicateGroup) -> String { keep[g.id] ?? g.keep }
    var chosen: [DuplicateGroup] { (library.duplicates + library.lookAlikes).filter { !skipped.contains($0.id) } }
    var extras: [LibraryItem] { chosen.flatMap { g in g.items.filter { $0.path != keeper(g) } } }
    var extraBytes: Int64 { chosen.reduce(0) { $0 + $1.wasted(keeping: keeper($1)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let p = library.duplicatesProgress {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Comparing your files…").font(.system(size: 14, weight: .semibold))
                        ProgressView(value: p).tint(Theme.accent)
                        Text("Same-size files are fingerprinted with SHA-256, then photos taken close together are compared with Vision. Nothing leaves your Mac.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                }
            } else if library.duplicatesScanned == nil {
                start
            } else if library.duplicates.isEmpty, library.lookAlikes.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: "No duplicates", detail: "Every file in your folders is the only copy of itself.")
                Button("Look again") { Task { await library.findDuplicates() } }.buttonStyle(GhostButtonStyle())
            } else {
                summary
                HStack(spacing: 8) {
                    Pill(title: "Identical · \(library.duplicates.count)", on: tab == .identical) { tab = .identical }
                    Pill(title: "Look-alike photos · \(library.lookAlikes.count)", on: tab == .lookAlike) { tab = .lookAlike }
                    Spacer()
                    Text("Click a copy to keep it instead").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
                Scrolling {
                    LazyVStack(spacing: 12) {
                        ForEach(groups.prefix(snapshot ? 4 : 400)) { g in group(g) }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .confirmSheet("Move \(extras.count) extra \(extras.count == 1 ? "copy" : "copies") to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                let list = extras
                Task {
                    await library.trash(list, label: "duplicates")
                    keep = [:]
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(ByteFormat.string(extraBytes)) once the Trash is emptied. One copy of each stays where it is, and anything trashed can be put back from Activity.")
        }
    }

    var start: some View {
        Card {
            HStack(spacing: 18) {
                Image(systemName: "square.on.square").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 56).background(Circle().fill(Theme.accent.opacity(0.12)))
                VStack(alignment: .leading, spacing: 5) {
                    Text("One copy is plenty").font(.system(size: 16, weight: .semibold))
                    Text("Headroom finds identical files by their content and look-alike photos — bursts, edits and HEIC/JPEG pairs. You see exactly how much you'd free, and pick what stays.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { Task { await library.findDuplicates() } } label: { Label("Find duplicates", systemImage: "magnifyingglass") }
                    .buttonStyle(PrimaryButtonStyle()).disabled(!library.hasScanned)
            }
        }
    }

    var summary: some View {
        Card {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Free up \(ByteFormat.string(extraBytes))").font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("\(extras.count) extra copies in \(chosen.count) groups · scanned \(library.duplicatesScanned?.ago ?? "")")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button { Task { await library.findDuplicates() } } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle())
                Button { confirm = true } label: { Label("Trash \(extras.count) extra copies", systemImage: "trash") }
                    .buttonStyle(PrimaryButtonStyle(tint: Theme.review)).disabled(extras.isEmpty)
            }
        }
    }

    func group(_ g: DuplicateGroup) -> some View {
        let on = !skipped.contains(g.id)
        return Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { if on { skipped.insert(g.id) } else { skipped.remove(g.id) } } label: { CheckCircle(on: on) }
                        .buttonStyle(.plain).help(on ? "Leave this group alone" : "Include this group")
                    Text(g.items.first?.name ?? "").font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text("\(g.items.count) \(g.kind == .identical ? "copies" : "look-alikes") · \(ByteFormat.string(g.items.first?.bytes ?? 0)) each")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Text("frees \(ByteFormat.string(g.wasted(keeping: keeper(g))))").font(Theme.number(12.5)).foregroundStyle(on ? Theme.review : Theme.textTertiary)
                }
                HScrolling {
                    HStack(spacing: 10) {
                        ForEach(g.items) { item in copy(item, group: g) }
                    }
                }
            }
            .opacity(on ? 1 : 0.55)
        }
    }

    func copy(_ item: LibraryItem, group g: DuplicateGroup) -> some View {
        let kept = keeper(g) == item.path
        return Button { keep[g.id] = item.path } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.045))
                    Thumbnail(item: item, size: 120).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(kept ? "Keep" : "Trash")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(kept ? (Theme.minimal ? Theme.onAccent : .black) : .white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(kept ? Theme.accent : Color.black.opacity(0.55)))
                        .padding(6)
                }
                .frame(width: 150, height: 104)
                Text(LibraryModel.display(item.folder)).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.head).frame(width: 150, alignment: .leading)
                Text(item.created.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(kept ? Theme.accent : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Quick Look") { QuickLook.shared.show(library: library, items: g.items, current: item) }
            Button("Show in Finder") { library.reveal([item]) }
            Button("Keep This Copy") { keep[g.id] = item.path }
        }
        .help(item.url.tildePath)
    }
}

/// Downloaded From: every download grouped by where you got it.
struct DownloadedFromView: View {
    @EnvironmentObject var library: LibraryModel

    var body: some View {
        if let id = library.sourceID, let group = library.bySource.first(where: { $0.source.id == id }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Button { library.sourceID = nil } label: { Image(systemName: "chevron.left") }.buttonStyle(GhostButtonStyle()).help("All sources")
                    SourceIcon(source: group.source, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(group.source.name).font(.system(size: 17, weight: .bold, design: .rounded))
                        Text("\(group.items.count) files · \(ByteFormat.string(group.items.reduce(0) { $0 + $1.bytes }))")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                FileGrid(items: library.sorted(group.items, key: "source:" + id))
            }
        } else if !library.hasScanned {
            LoadingLibrary()
        } else {
            let groups = library.bySource
            let known = groups.filter(\.source.isKnown)
            let sites = groups.filter { !$0.source.isKnown }
            Scrolling {
                VStack(alignment: .leading, spacing: 20) {
                    Text("\(groups.reduce(0) { $0 + $1.items.count }) files · \(groups.count) sources — read from the “where from” macOS saves with every download.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    if groups.isEmpty {
                        EmptyState(symbol: "arrow.down.circle", title: "No downloads found", detail: "Files you download keep a note of where they came from. None here yet.")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(known, id: \.source.id) { g in
                            Button { library.sourceID = g.source.id } label: { SourceCard(source: g.source, items: g.items) }.buttonStyle(PressableStyle())
                        }
                    }
                    if !sites.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HomeSection(title: "Any website", count: sites.count)
                            Card(padding: 0) {
                                LazyVStack(spacing: 0) {
                                    ForEach(sites.prefix(200), id: \.source.id) { g in
                                        Button { library.sourceID = g.source.id } label: {
                                            HStack(spacing: 10) {
                                                SourceIcon(source: g.source, size: 22)
                                                Text(g.source.name).font(.system(size: 12.5, weight: .medium))
                                                Spacer()
                                                Text("\(g.items.count) files").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                                                Text(ByteFormat.string(g.items.reduce(0) { $0 + $1.bytes })).font(Theme.number(12)).frame(width: 80, alignment: .trailing)
                                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                                            }
                                            .padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        Divider().overlay(Theme.hairline).padding(.leading, 46)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

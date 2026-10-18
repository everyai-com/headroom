import SwiftUI
import HeadroomCore

/// Home: a greeting, a shelf for each kind of file, what you could clean up, where your
/// downloads came from, and your newest photos, videos, documents and music.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: LibraryModel
    var go: (Screen) -> Void = { _ in }

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 28) {
                if !library.hasScanned {
                    LoadingLibrary()
                } else {
                    shelves
                    cleanUp
                    downloads
                    recent(.image, "Recent photos")
                    recent(.video, "Recent videos")
                    recent(.document, "Recent documents")
                    recent(.audio, "Recent music")
                }
            }
            .padding(.bottom, 28)
        }
    }

    static func greeting(_ date: Date = .now) -> String {
        let h = Calendar.current.component(.hour, from: date)
        return h < 5 ? "Good evening" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    // MARK: Shelves

    var shelves: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSection(title: "Library", count: FileKind.shelves.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 16)], spacing: 16) {
                ForEach(FileKind.shelves) { kind in
                    let screen = Screen.forKind(kind)
                    Button { go(screen) } label: { FolderCard(kind: kind) }
                        .buttonStyle(PressableStyle())
                        .help("\(kind.title)  \(screen.shortcut ?? "")")
                }
            }
        }
    }

    // MARK: Clean up

    @ViewBuilder var cleanUp: some View {
        let cards = library.suggestions
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HomeSection(title: "Clean up", badge: "Free up to \(ByteFormat.string(cards.reduce(0) { $0 + $1.bytes }))",
                            seeAll: { go(.cleanUp) })
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    ForEach(cards.prefix(4)) { s in
                        Button { library.cleanUpFocus = s.kind; go(.cleanUp) } label: { SuggestionCard(suggestion: s) }
                            .buttonStyle(PressableStyle())
                    }
                }
            }
        }
    }

    // MARK: Downloaded from

    @ViewBuilder var downloads: some View {
        let groups = library.bySource
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HomeSection(title: "Downloaded from", count: groups.count, seeAll: { library.sourceID = nil; go(.downloads) })
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    ForEach(groups.prefix(8), id: \.source.id) { g in
                        Button { library.sourceID = g.source.id; go(.downloads) } label: { SourceCard(source: g.source, items: g.items) }
                            .buttonStyle(PressableStyle())
                    }
                }
            }
        }
    }

    // MARK: Recent shelves

    @ViewBuilder func recent(_ kind: FileKind, _ title: String) -> some View {
        let items = library.recent(kind, limit: 12)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HomeSection(title: title, seeAll: { go(Screen.forKind(kind)) })
                HScrolling {
                    HStack(spacing: 12) {
                        ForEach(items) { item in
                            FileCard(item: item, size: 148, siblings: items).frame(width: 148)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

/// A section title on Home: name, a count or badge, and "See all".
struct HomeSection: View {
    var title: String
    var count: Int? = nil
    var badge: String? = nil
    var seeAll: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 17, weight: .bold, design: .rounded))
            if let count {
                Text("\(count)").font(Theme.number(11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(Theme.fill(0.07)))
            }
            if let badge {
                Text(badge).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.minimal ? Theme.onAccent : .black.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Theme.accent))
            }
            Spacer()
            if let seeAll {
                Button(action: seeAll) {
                    HStack(spacing: 3) { Text("See all"); Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)) }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A folder with a tab: the shape of every shelf on Home.
struct FolderShape: Shape {
    var tabWidth: CGFloat = 0.4
    var tabHeight: CGFloat = 13
    var radius: CGFloat = 16

    func path(in r: CGRect) -> Path {
        var p = Path()
        let tw = max(min(60, r.width * 0.5), r.width * tabWidth), th = tabHeight, cr = min(radius, r.height / 3)
        p.move(to: CGPoint(x: r.minX, y: r.minY + cr))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + cr, y: r.minY), radius: cr)
        p.addLine(to: CGPoint(x: r.minX + tw - th, y: r.minY))
        p.addCurve(to: CGPoint(x: r.minX + tw + th * 0.6, y: r.minY + th),
                   control1: CGPoint(x: r.minX + tw - th * 0.1, y: r.minY), control2: CGPoint(x: r.minX + tw, y: r.minY + th))
        p.addLine(to: CGPoint(x: r.maxX - cr, y: r.minY + th))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY + th), tangent2End: CGPoint(x: r.maxX, y: r.minY + th + cr), radius: cr)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cr))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - cr, y: r.maxY), radius: cr)
        p.addLine(to: CGPoint(x: r.minX + cr, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - cr), radius: cr)
        p.closeSubpath()
        return p
    }
}

/// One kind of file as a pastel folder: its name, the newest few, and how many and how big.
struct FolderCard: View {
    @EnvironmentObject var library: LibraryModel
    var kind: FileKind

    var body: some View {
        let (top, bottom) = Theme.shelf(for: kind)
        let totals = kind == .app ? appTotals : library.totals(kind)
        let recent = kind == .app ? [] : library.recent(kind, limit: 3)
        ZStack(alignment: .topLeading) {
            // The back of the folder (its tab shows), then the front panel.
            FolderShape().fill(bottom)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                .padding(.top, 20)
                .shadow(color: .black.opacity(0.06), radius: 3, y: -1)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: kind.symbol + (kind == .app ? "" : ".fill"))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.tint(for: kind))
                    Spacer()
                    if kind == .app {
                        AppIconStack(apps: Array(library.app.apps.prefix(3)), total: library.app.apps.count)
                    } else {
                        ThumbStack(items: recent, total: totals.count, size: 26)
                    }
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
                Text(kind.title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text("\(totals.count.formatted()) items · \(ByteFormat.string(totals.bytes))")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 30)
        }
        .frame(height: 138)
        .contentShape(Rectangle())
    }

    var appTotals: LibraryIndex.Totals {
        LibraryIndex.Totals(count: library.app.apps.count, bytes: library.app.apps.reduce(0) { $0 + $1.appSize.allocated })
    }
}

/// App icons fanned out (Apps shelf).
struct AppIconStack: View {
    var apps: [InstalledApp]
    var total: Int

    var body: some View {
        HStack(spacing: -7) {
            ForEach(apps) { app in
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 26, height: 26)
            }
            if total > apps.count, !apps.isEmpty {
                Text("+\(total - apps.count)").font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).padding(.vertical, 5).background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(Theme.hairline)).padding(.leading, 9)
            }
        }
    }
}

/// A clean-up card: what it is, how much it frees, how many files.
struct SuggestionCard: View {
    var suggestion: CleanUpSuggestion
    var large = false

    var tint: Color {
        if Theme.minimal { return Theme.textPrimary }
        switch suggestion.kind {
        case .duplicates: return Theme.tint(for: .app)
        case .oldInstallers: return Theme.tint(for: .archive)
        case .forgottenDownloads: return Theme.tint(for: .video)
        case .oldScreenshots: return Theme.tint(for: .image)
        case .bigOldVideos: return Theme.tint(for: .audio)
        case .unusedApps: return Theme.tint(for: .document)
        }
    }

    var countLabel: String {
        let n = suggestion.count
        switch suggestion.kind {
        case .duplicates: return "\(n) extra \(n == 1 ? "copy" : "copies")"
        case .unusedApps: return "\(n) \(n == 1 ? "app" : "apps")"
        default: return "\(n) \(n == 1 ? "file" : "files")"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: suggestion.kind.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(tint)
                    .frame(width: 30, height: 30).background(Circle().fill(tint.opacity(0.14)))
                Spacer()
                if suggestion.kind == .unusedApps {
                    AppIconStack(apps: Array(suggestion.apps.prefix(3)), total: suggestion.apps.count)
                } else {
                    ThumbStack(items: Array(suggestion.items.prefix(3)), total: suggestion.items.count, size: 24)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.kind.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                Text(ByteFormat.string(suggestion.bytes)).font(Theme.number(large ? 26 : 22, weight: .bold))
            }
            if large {
                Text(suggestion.kind.detail).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            }
            HStack {
                Spacer()
                Text(countLabel).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(
            LinearGradient(colors: [tint.opacity(Theme.minimal ? 0.03 : 0.10), tint.opacity(0.02)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
            .shadow(color: Theme.shadow, radius: 8, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Where downloads came from: Gmail, ChatGPT, a website…
struct SourceCard: View {
    var source: DownloadSource
    var items: [LibraryItem]

    var body: some View {
        HStack(spacing: 10) {
            SourceIcon(source: source, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(items.count) \(items.count == 1 ? "file" : "files") · \(ByteFormat.string(items.reduce(0) { $0 + $1.bytes }))")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            // The thumbnails give way first when the card is narrow.
            ViewThatFits(in: .horizontal) {
                ThumbStack(items: Array(items.prefix(2)), total: min(items.count, 2), size: 22)
                Color.clear.frame(width: 0)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface).shadow(color: Theme.shadow, radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// A gentle press: cards dip a little under the finger.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Sideways scrolling (shelves); laid out flat in snapshots, like `Scrolling`.
struct HScrolling<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    @ViewBuilder var content: Content

    var body: some View {
        if snapshot {
            content.fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).clipped()
        } else {
            ScrollView(.horizontal) { content }.scrollIndicators(.never)
        }
    }
}

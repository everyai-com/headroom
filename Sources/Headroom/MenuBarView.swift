import SwiftUI
import AppKit
import HeadroomCore

/// The menu bar popover: free space, the safe one-click reclaim, and the last ten files that
/// landed in Downloads — drag one straight into Mail, Slack or Figma, or click to open it.
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: LibraryModel
    @AppStorage("menuBarDownloads") private var showDownloads = true
    @State private var downloads: [LibraryItem] = []
    /// Renders can't run `.task`: they pass the list in.
    var preloaded: [LibraryItem]? = nil
    var openWindow: () -> Void
    var quickSearch: () -> Void
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                GaugeRing(fraction: model.volume.usedFraction, tint: Theme.color(for: model.volume.health), lineWidth: 5)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(model.volume.free.gb) free").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("of \(model.volume.total.gb) · \(model.volume.health == .good ? "plenty of room" : model.volume.health == .tight ? "getting tight" : "almost full")")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if model.safeReclaimable > 0 {
                    Button { Task { await model.reclaim(safeOnly: true) } } label: {
                        Text("Free \(ByteFormat.compact(model.safeReclaimable))").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isBusy)
                    .help("Remove only caches and build output that come back on their own")
                }
            }
            if showDownloads {
                Divider().overlay(Theme.hairline)
                HStack {
                    Text("Recent downloads").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Downloads") {
                        close()
                        library.browseHistory = []
                        library.browse(library.home + "/Downloads")
                        openWindow()
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
                let downloads = preloaded ?? self.downloads
                if downloads.isEmpty {
                    Text("Nothing in Downloads yet.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary).padding(.vertical, 6)
                } else {
                    VStack(spacing: 2) {
                        ForEach(downloads) { item in DownloadRow(item: item, close: close, openWindow: openWindow) }
                    }
                }
            }
            Divider().overlay(Theme.hairline)
            HStack(spacing: 8) {
                Button { close(); openWindow() } label: { Label("Open Headroom", systemImage: "macwindow") }
                Button { close(); quickSearch() } label: { Label("Quick Search", systemImage: "magnifyingglass") }
                    .help(QuickSearchHotKey.shared.combo.map { "Quick Search  \($0.title)" } ?? "Quick Search")
                Spacer()
                if let release = model.update {
                    Button { NSWorkspace.shared.open(release.url) } label: { Label("Update", systemImage: "arrow.down.app") }
                        .help("Headroom \(release.version) is available")
                }
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit Headroom")
            }
            .buttonStyle(GhostButtonStyle())
        }
        .padding(14)
        .frame(width: 360)
        .foregroundStyle(Theme.textPrimary)
        .task { downloads = await Self.recentDownloads(home: library.home) }
    }

    /// The newest arrivals in Downloads, by when they arrived (not when they last changed).
    static func recentDownloads(home: String = NSHomeDirectory(), limit: Int = 10) async -> [LibraryItem] {
        let folder = URL(fileURLWithPath: home + "/Downloads")
        return await Task.detached(priority: .userInitiated) {
            Array(LibraryScanner.list(folder: folder)
                .filter { !$0.name.hasSuffix(".download") && !$0.name.hasSuffix(".crdownload") && !$0.name.hasSuffix(".part") }
                .sorted { $0.arrived > $1.arrived }
                .prefix(limit))
        }.value
    }
}

/// One download: thumbnail, name, when it arrived. Drag it out; hover for Headroom / Finder.
struct DownloadRow: View {
    @EnvironmentObject var library: LibraryModel
    var item: LibraryItem
    var close: () -> Void
    var openWindow: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(item: item, size: 34, fill: item.kind == .image || item.kind == .video)
                .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.arrived.ago + (item.isFolder ? "" : " · " + ByteFormat.compact(item.bytes)))
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            if hovering {
                Button { close(); library.showInApp(item); openWindow() } label: { Image(systemName: "sidebar.left") }
                    .help("Show in Headroom")
                Button { close(); NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
            }
        }
        .buttonStyle(GhostButtonStyle())
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.fill(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { close(); NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help(item.url.tildePath)
    }
}

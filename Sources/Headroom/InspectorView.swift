import SwiftUI
import AppKit
import Quartz
import HeadroomCore

/// ⌘I: a live preview of the selected file plus the details — size, dates, dimensions,
/// duration, camera, where it was downloaded from, and the text inside it.
struct InspectorView: View {
    @EnvironmentObject var library: LibraryModel
    @State private var details = Spotlight.Details()
    @State private var text: String?
    @State private var reading = false
    @Environment(\.snapshotMode) private var snapshot

    var item: LibraryItem? { library.focused.flatMap(library.item) ?? library.selectedItems.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Info").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { library.showInspector = false } label: { Image(systemName: "sidebar.right") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Hide  ⌘I")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
            if library.selection.count > 1 {
                many(library.selectedItems)
            } else if let item {
                one(item)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cursorarrow.click.2").font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
                    Text("Select a file to see its details").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 290)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }

    func one(_ item: LibraryItem) -> some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 14) {
                preview(item)
                    .frame(height: 210)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.045)))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                    Text(item.isFolder ? "Folder" : "\(item.typeLabel) · \(ByteFormat.string(item.bytes))")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                actions(item)
                section("Details") {
                    if let w = details.pixelWidth, let h = details.pixelHeight { row("Dimensions", "\(w) × \(h)") }
                    if let d = details.duration, d > 0 { row("Duration", Duration.seconds(d).formatted(.time(pattern: d >= 3600 ? .hourMinuteSecond : .minuteSecond))) }
                    if let p = details.pages { row("Pages", "\(p)") }
                    if let device = details.device { row("Taken with", device) }
                    if let artist = details.artist, item.kind == .audio { row("Artist", artist) }
                    if let album = details.album { row("Album", album) }
                    row("Created", item.created.formatted(date: .abbreviated, time: .shortened))
                    row("Modified", item.modified.formatted(date: .abbreviated, time: .shortened))
                    if let added = item.added { row("Added", added.formatted(date: .abbreviated, time: .shortened)) }
                    if let used = details.lastUsed { row("Last opened", used.formatted(date: .abbreviated, time: .shortened)) }
                    if item.allocated != item.bytes, !item.isFolder { row("On disk", ByteFormat.string(item.allocated)) }
                }
                if let source = DownloadSources.source(of: item) { downloaded(item, source) }
                section("Where") {
                    Button { library.browse(item.folder) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.fill").foregroundStyle(Theme.tint(for: .document))
                            Text(LibraryModel.display(item.folder)).lineLimit(2).truncationMode(.head)
                        }
                        .font(.system(size: 11.5))
                    }
                    .buttonStyle(.plain)
                    .help("Open this folder in Headroom")
                }
                if !item.tags.isEmpty {
                    section("Tags") { FlowLayout(spacing: 6) { ForEach(item.tags, id: \.self) { Badge(text: $0, color: Theme.keep) } } }
                }
                if library.canReadText(item) { textSection(item) }
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .task(id: item.path) {
            text = library.recognized[item.path]
            details = await Task.detached { Spotlight.details(item.path) }.value
            if details.pixelWidth == nil, item.kind == .image { details = Self.imageSize(item.url, into: details) }
        }
    }

    @ViewBuilder func preview(_ item: LibraryItem) -> some View {
        if snapshot || item.isFolder || item.kind == .app {
            Thumbnail(item: item, size: 240, fill: false)
        } else {
            LivePreview(url: item.url)
        }
    }

    func actions(_ item: LibraryItem) -> some View {
        HStack(spacing: 6) {
            Button { library.open(item) } label: { Label(item.kind == .audio ? "Play" : "Open", systemImage: item.kind == .audio ? "play.fill" : "arrow.up.forward.app") }
            Button { library.reveal([item]) } label: { Image(systemName: "folder") }.help("Show in Finder")
            Button { QuickLook.shared.show(library: library, items: library.visible, current: item) } label: { Image(systemName: "eye") }
                .help("Quick Look  Space")
            Button { library.copyFiles([item]) } label: { Image(systemName: "doc.on.doc") }.help("Copy  ⌘C")
            Spacer()
            Button { library.trashRequest = [item] } label: { Image(systemName: "trash") }.help("Move to Trash  ⌘⌫")
        }
        .buttonStyle(GhostButtonStyle())
    }

    func downloaded(_ item: LibraryItem, _ source: DownloadSource) -> some View {
        section("Downloaded from") {
            Button { library.sourceID = source.id; NotificationCenter.default.post(name: .headroomShowScreen, object: Screen.downloads) } label: {
                HStack(spacing: 8) {
                    SourceIcon(source: source, size: 22)
                    Text(source.name).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .help("Everything you downloaded from \(source.name)")
            if let url = (item.whereFrom ?? []).last(where: { $0.hasPrefix("http") }) ?? item.whereFrom?.first, let link = URL(string: url) {
                Button { NSWorkspace.shared.open(link) } label: {
                    Text(url).font(.system(size: 11)).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .help("Open the page it came from")
            }
            if let by = item.downloadedBy, !DownloadSources.isBrowser(by) || source.isKnown == false { row("Saved by", by) }
        }
    }

    func textSection(_ item: LibraryItem) -> some View {
        section("Text in \(item.kind == .image ? "image" : "file")") {
            if let text, !text.isEmpty {
                Text(text.prefix(1200)).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled).lineLimit(14)
                Button { Task { await library.copyText([item]) } } label: { Label("Copy Text", systemImage: "doc.on.clipboard") }
                    .buttonStyle(GhostButtonStyle())
            } else if text != nil {
                Text("No text found.").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            } else {
                Button {
                    reading = true
                    Task { text = await library.recognizedText(item); reading = false }
                } label: { Label(reading ? "Reading…" : "Read text", systemImage: "text.viewfinder") }
                    .buttonStyle(GhostButtonStyle()).disabled(reading)
            }
        }
    }

    func many(_ items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ThumbStack(items: items, total: items.count, size: 54).frame(maxWidth: .infinity).padding(.vertical, 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(items.count) items").font(.system(size: 15, weight: .semibold))
                Text(ByteFormat.string(items.reduce(0) { $0 + $1.bytes })).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 6) {
                Button { library.reveal(items) } label: { Label("Show in Finder", systemImage: "folder") }
                Button { library.copyFiles(items) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
                if items.contains(where: library.canReadText) {
                    Button { Task { await library.copyText(items) } } label: { Image(systemName: "text.viewfinder") }.help("Copy Text  ⇧⌘C")
                }
                Spacer()
                Button { library.trashRequest = items } label: { Image(systemName: "trash") }.help("Move to Trash")
            }
            .buttonStyle(GhostButtonStyle())
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary).textCase(.uppercase).kerning(0.5)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 11.5))
    }

    static func imageSize(_ url: URL, into d: Spotlight.Details) -> Spotlight.Details {
        var d = d
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return d }
        d.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        d.pixelHeight = props[kCGImagePropertyPixelHeight] as? Int
        if d.device == nil, let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            d.device = (tiff[kCGImagePropertyTIFFModel] as? String) ?? (tiff[kCGImagePropertyTIFFMake] as? String)
        }
        return d
    }
}

/// Quick Look's live preview inside the inspector: videos play, PDFs scroll.
struct LivePreview: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .compact)!
        v.autostarts = false
        v.shouldCloseWithWindow = true
        v.previewItem = url as NSURL
        return v
    }

    func updateNSView(_ v: QLPreviewView, context: Context) {
        if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
    }
}

/// A download source's badge: its symbol on its own colour.
struct SourceIcon: View {
    var source: DownloadSource
    var size: CGFloat = 28

    var color: Color {
        if Theme.minimal { return Theme.textPrimary }
        switch source.id {
        case "gmail": return Color(hex: 0xEA4335)
        case "drive": return Color(hex: 0x1FA463)
        case "chatgpt": return Color(hex: 0x10A37F)
        case "claude": return Color(hex: 0xD97757)
        case "canva": return Color(hex: 0x00C4CC)
        case "x": return Color(hex: 0x111111)
        case "slack": return Color(hex: 0x611F69)
        case "whatsapp": return Color(hex: 0x25D366)
        case "telegram": return Color(hex: 0x2AABEE)
        case "discord": return Color(hex: 0x5865F2)
        case "github": return Color(hex: 0x24292F)
        case "dropbox": return Color(hex: 0x0061FE)
        case "airdrop": return Color(hex: 0x1E90FF)
        case "messages": return Color(hex: 0x34C759)
        case "youtube": return Color(hex: 0xFF0000)
        case "linkedin": return Color(hex: 0x0A66C2)
        case "figma": return Color(hex: 0xA259FF)
        case "notion": return Color(hex: 0x2F3437)
        case "extensions": return Color(hex: 0x8E8E93)
        default: return source.isKnown ? Color(hex: 0x6E7BFF) : Color(hex: 0x8A93A6)
        }
    }

    var body: some View {
        Image(systemName: source.symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(Theme.minimal ? Theme.inverseText : .white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(color.gradient))
    }
}

import SwiftUI
import AppKit
import QuickLookThumbnailing
import HeadroomCore

/// Big, clear thumbnails for everything (Quick Look's own renderer), cached in memory.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() { cache.countLimit = 1500 }

    /// Pixel sizes come in a few steps so a slider drag doesn't re-render every card.
    static func bucket(_ points: CGFloat) -> CGFloat {
        points <= 64 ? 64 : points <= 160 ? 160 : points <= 320 ? 320 : 640
    }

    private func key(_ path: String, _ size: CGFloat) -> String { "\(Self.bucket(size))|\(path)" }

    func cached(_ path: String, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(path, size) as NSString)
            // A bigger one already made is fine too.
            ?? [640, 320, 160].lazy.compactMap { self.cache.object(forKey: "\($0)|\(path)" as NSString) }.first
    }

    func load(_ url: URL, size: CGFloat) async -> NSImage? {
        let k = key(url.path, size)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        if let running = inFlight[k] { return await running.value }
        let px = Self.bucket(size)
        let task = Task<NSImage?, Never> {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: px, height: px), scale: 2,
                                                       representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                return rep.nsImage
            }
            return nil
        }
        inFlight[k] = task
        let image = await task.value
        inFlight[k] = nil
        if let image { cache.setObject(image, forKey: k as NSString) }
        return image
    }

    /// Make thumbnails before a snapshot renders (ImageRenderer can't wait for async loads).
    func preload(_ urls: [URL], size: CGFloat) {
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for url in urls { group.addTask { _ = await self.load(url, size: size) } }
            }
            done.signal()
        }
        let deadline = Date().addingTimeInterval(30)
        while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    static func icon(_ path: String) -> NSImage { NSWorkspace.shared.icon(forFile: path) }
}

/// A file's picture: its thumbnail when Quick Look can draw one, else its icon.
struct Thumbnail: View {
    var item: LibraryItem
    var size: CGFloat
    /// Photos and videos fill their frame; documents and icons sit inside it.
    var fill: Bool? = nil
    @State private var image: NSImage?

    var fills: Bool { fill ?? (item.kind == .image || item.kind == .video) }

    var body: some View {
        let shown = image ?? Thumbnails.shared.cached(item.path, size: size)
        Group {
            if let shown {
                if fills {
                    Color.clear.overlay(Image(nsImage: shown).resizable().interpolation(.high).aspectRatio(contentMode: .fill)).clipped()
                } else {
                    Image(nsImage: shown).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(item.kind == .document ? 0.12 : 0), radius: 3, y: 1)
                        .padding(item.kind == .document ? size * 0.08 : size * 0.12)
                }
            } else {
                Image(nsImage: Thumbnails.icon(item.path)).resizable().aspectRatio(contentMode: .fit).padding(size * 0.16)
            }
        }
        .task(id: "\(item.path)|\(Thumbnails.bucket(size))") {
            // Folders and archives: the Finder icon says it best.
            guard !item.isFolder, item.kind != .archive else { return }
            if let loaded = await Thumbnails.shared.load(item.url, size: size) { image = loaded }
        }
    }
}

/// Up to three thumbnails fanned out, with "+N" — the little stacks on shelves and cards.
struct ThumbStack: View {
    /// 1234 → "1.2K".
    static func count(_ n: Int) -> String {
        n < 1000 ? "\(n)" : n < 10_000 ? String(format: "%.1fK", Double(n) / 1000) : "\(n / 1000)K"
    }

    var items: [LibraryItem]
    var total: Int
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: -size * 0.32) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { i, item in
                    Thumbnail(item: item, size: size * 2, fill: item.kind == .image || item.kind == .video)
                        .frame(width: size, height: size)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Theme.surface, lineWidth: 2))
                        .zIndex(Double(3 - i))
                }
            }
            if total > 3 {
                Text("+" + Self.count(total - 3)).font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                    .padding(.horizontal, 6).frame(minHeight: size * 0.8)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(Theme.hairline))
            }
        }
    }
}

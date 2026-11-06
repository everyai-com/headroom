import SwiftUI
import AVFoundation
import HeadroomCore

/// Double-click a song and it plays right in the toolbar. ⌥⌘P plays or pauses, ⌥⌘← and ⌥⌘→ skip.
@MainActor
final class MusicPlayer: ObservableObject {
    @Published private(set) var current: LibraryItem?
    @Published private(set) var playing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var title = ""
    @Published private(set) var artist: String?
    private var queue: [LibraryItem] = []
    private var player: AVPlayer?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?

    func play(_ item: LibraryItem, queue: [LibraryItem]) {
        self.queue = queue.isEmpty ? [item] : queue
        load(item)
    }

    private func load(_ item: LibraryItem) {
        stopObserving()
        current = item
        title = (item.name as NSString).deletingPathExtension
        artist = nil
        progress = 0
        duration = 0
        let playerItem = AVPlayerItem(url: item.url)
        let p = AVPlayer(playerItem: playerItem)
        player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let item = self.player?.currentItem else { return }
                let d = item.duration.seconds
                if d.isFinite, d > 0 { self.duration = d; self.progress = t.seconds / d }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
        }
        p.play()
        playing = true
        Task {
            let details = await Task.detached { Spotlight.details(item.path) }.value
            if self.current?.path == item.path {
                if let t = details.title, !t.isEmpty { self.title = t }
                self.artist = details.artist
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if playing { player.pause() } else { player.play() }
        playing.toggle()
    }

    func next() { step(1) }
    func previous() {
        // Like every player: back to the start first, then the song before.
        if progress * duration > 3 { seek(to: 0); return }
        step(-1)
    }

    private func step(_ delta: Int) {
        guard let current, let i = queue.firstIndex(where: { $0.path == current.path }) else { return }
        let j = i + delta
        guard queue.indices.contains(j) else { if delta > 0 { stop() }; return }
        load(queue[j])
    }

    func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        player.seek(to: CMTime(seconds: fraction * duration, preferredTimescale: 600))
        progress = fraction
    }

    func stop() {
        player?.pause()
        stopObserving()
        player = nil
        current = nil
        playing = false
    }

    private func stopObserving() {
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

/// The toolbar player: artwork, title, play/pause, skip, a thin progress line.
struct MiniPlayer: View {
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var player: MusicPlayer

    var body: some View {
        if let item = player.current {
            HStack(spacing: 10) {
                Thumbnail(item: item, size: 30, fill: true)
                    .frame(width: 30, height: 30)
                    .background(Theme.tint(for: .audio).opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.fill(0.1))
                            Capsule().fill(Theme.tint(for: .audio)).frame(width: max(2, geo.size.width * player.progress))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { location in player.seek(to: max(0, min(1, location.x / geo.size.width))) }
                    }
                    .frame(height: 3)
                }
                .frame(width: 130)
                Button { player.previous() } label: { Image(systemName: "backward.fill") }.help("Previous  ⌥⌘←")
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 14) }
                    .help("Play / Pause  ⌥⌘P")
                Button { player.next() } label: { Image(systemName: "forward.fill") }.help("Next  ⌥⌘→")
                Button { player.stop() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .foregroundStyle(Theme.textTertiary).help("Stop")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .padding(.leading, 5).padding(.trailing, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.fill(0.06)))
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

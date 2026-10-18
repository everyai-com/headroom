import SwiftUI
import AppKit
import HeadroomCore

/// Which Headroom this is. The Mac App Store edition (built with `-DAPPSTORE` by scripts/appstore.sh)
/// runs in the App Sandbox: it can't run other tools (xcrun, docker, lsof, ps), stop other apps'
/// processes, mount drives or update itself, so those parts are off and point to the full download.
enum Edition {
    #if APPSTORE
    static let appStore = true
    #else
    static let appStore = false
    #endif

    /// Screens that need what the sandbox doesn't allow.
    static let fullOnly: Set<Screen> = appStore ? [.memory, .ai, .drives] : []

    static func available(_ screen: Screen) -> Bool { !fullOnly.contains(screen) }

}

/// Folders you've let the App Store edition open, kept as security-scoped bookmarks so access lasts
/// across launches. Outside the sandbox every folder is already open and this does nothing.
@MainActor
final class FolderAccess: ObservableObject {
    static let shared = FolderAccess()
    private static let key = "securityScopedBookmarks"

    /// Folders open right now (bookmarks resolved and started).
    @Published private(set) var granted: [URL] = []

    /// The sandboxed edition can't see your files until you give it your home folder once.
    var needsHome: Bool { Edition.appStore && !covers(HeadroomPaths.home) }

    func covers(_ path: String) -> Bool {
        !Edition.appStore || granted.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    /// At launch, before any scan: reopen every folder you granted before.
    func restore() {
        guard Edition.appStore else { return }
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [Data] ?? []
        var keep: [Data] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            granted.append(url)
            keep.append(stale ? ((try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data) : data)
        }
        UserDefaults.standard.set(keep, forKey: Self.key)
    }

    /// Keep access to folders or files you picked or dropped (an open panel or a drop grants it for
    /// this run only; the bookmark makes it last).
    func remember(_ urls: [URL]) {
        guard Edition.appStore else { return }
        var stored = UserDefaults.standard.array(forKey: Self.key) as? [Data] ?? []
        for url in urls where !covers(url.path) {
            guard let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
                  url.startAccessingSecurityScopedResource() else { continue }
            stored.append(data)
            granted.append(url)
        }
        UserDefaults.standard.set(stored, forKey: Self.key)
    }

    /// Ask for a folder with an open panel that starts there. Returns true when it's open now.
    @discardableResult
    func request(_ path: String, message: String) -> Bool {
        guard Edition.appStore else { return true }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.message = message
        panel.prompt = "Give Access"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        remember([url])
        return covers(path)
    }
}

/// Shown on top of Home in the App Store edition until it can see your files.
struct HomeAccessCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: LibraryModel
    @ObservedObject var access = FolderAccess.shared
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if access.needsHome, !snapshot {
            Card {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "house.lodge").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44).background(Circle().fill(Theme.accent.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Let Headroom see your files").font(.system(size: 15, weight: .semibold))
                        Text("macOS keeps App Store apps out of your folders until you choose one. Pick your home folder once and Headroom can show your files by kind, find duplicates, tidy the Desktop and say what takes the space. Nothing leaves your Mac.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        Button("Choose Home Folder…") {
                            if access.request(HeadroomPaths.home, message: "Choose your home folder (\(NSUserName())) so Headroom can see your files.") {
                                Task { await library.scan() }
                                Task { await model.scan(); await model.buildMap() }
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
                    }
                }
            }
        }
    }
}

/// A screen the App Store edition leaves out, if something links to it.
struct FullVersionOnly: View {
    var screen: Screen

    var body: some View {
        EmptyState(symbol: screen.symbol, title: "\(screen.rawValue) isn't in this edition",
                   detail: "This edition runs in Apple's App Sandbox, which doesn't let apps look at other apps' processes, run developer tools or mount drives.")
    }
}

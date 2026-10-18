import SwiftUI
import AppKit
import HeadroomCore

/// Folder sizes and git status, measured in the background and kept per path. Cards ask for a
/// folder when they appear; the newest asks go first, a few at a time, and results land in batches
/// so a screen of folders doesn't redraw once per folder.
@MainActor
final class FolderInfoStore: ObservableObject {
    static let shared = FolderInfoStore()

    @Published private(set) var sizes: [String: FolderSize] = [:]
    @Published private(set) var git: [String: GitStatus] = [:]

    private var measured: [String: Date] = [:]
    private var queue: [String] = []
    private var inFlight: Set<String> = []
    private var pending: [String: FolderSize] = [:]
    private var flushing = false
    private var gitChecked: [String: Date] = [:]
    /// A size is trusted this long; Trash and Undo in the folder on screen re-measure sooner.
    private let freshFor: TimeInterval = 300

    /// Measure this folder soon, unless a fresh size is known.
    func request(_ path: String) {
        if let t = measured[path], Date().timeIntervalSince(t) < freshFor { return }
        guard !inFlight.contains(path) else { return }
        queue.removeAll { $0 == path }
        queue.append(path)
        pump()
    }

    /// Scrolled away before its turn: don't measure it.
    func cancel(_ path: String) { queue.removeAll { $0 == path } }

    /// Something changed inside these folders: measure them again (the old size shows meanwhile).
    func invalidate(_ paths: [String]) {
        for p in paths where sizes[p] != nil {
            measured[p] = nil
            request(p)
        }
    }

    private func pump() {
        while inFlight.count < 3, let path = queue.popLast() {
            inFlight.insert(path)
            Task.detached(priority: .utility) {
                let size = FolderSizes.measure(path)
                await self.finish(path, size)
            }
        }
    }

    private func finish(_ path: String, _ size: FolderSize) {
        inFlight.remove(path)
        measured[path] = .now
        pending[path] = size
        if !flushing {
            flushing = true
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                sizes.merge(pending) { _, new in new }
                pending = [:]
                flushing = false
            }
        }
        pump()
    }

    /// Read the branch and change count of the repo this folder is in (at most every few seconds).
    func refreshGit(_ path: String) async {
        if let t = gitChecked[path], Date().timeIntervalSince(t) < 5 { return }
        gitChecked[path] = .now
        let status = await Task.detached(priority: .utility) { Git.status(of: path) }.value
        if git[path] != status { git[path] = status }
    }

    /// For renders: measure a folder's subfolders and read its git status now, on this thread.
    func prewarm(folder: String) {
        for item in LibraryScanner.list(folder: URL(fileURLWithPath: folder)) where item.isFolder {
            sizes[item.path] = FolderSizes.measure(item.path)
            measured[item.path] = .now
        }
        git[folder] = Git.status(of: folder)
        gitChecked[folder] = .now
    }
}

/// "12 items · 3.4 GB" for a folder, "—" until it's measured.
struct FolderSizeText: View {
    @ObservedObject private var store = FolderInfoStore.shared
    var path: String
    var format: Format = .full

    enum Format { case full, bytes, items }

    var body: some View {
        Text(text)
            .onAppear { store.request(path) }
            .onDisappear { store.cancel(path) }
    }

    var text: String {
        guard let s = store.sizes[path] else { return format == .items ? "Folder" : "—" }
        switch format {
        case .full: return s.label
        case .bytes: return s.items == 0 ? "—" : ByteFormat.string(s.bytes) + (s.partial ? "+" : "")
        case .items: return "\(s.items.formatted()) \(s.items == 1 ? "item" : "items")"
        }
    }
}

/// The branch and uncommitted changes of the repo a folder is in. Nothing when it isn't one.
struct GitBadge: View {
    @ObservedObject private var store = FolderInfoStore.shared
    @Environment(\.snapshotMode) private var snapshot
    var path: String
    var compact = false

    var body: some View {
        Group {
            if let status = store.git[path] {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: compact ? 9 : 10, weight: .bold))
                    Text(status.branch).lineLimit(1).truncationMode(.middle)
                    if let n = status.changes {
                        Text(n == 0 ? "clean" : "\(n) changed")
                            .foregroundStyle(n == 0 ? Theme.safe : Theme.review)
                    }
                }
                .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 2 : 3)
                .background(Capsule().fill(Theme.fill(0.06)))
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .help(gitHelp(status))
            }
        }
        .task(id: path) { if !snapshot { await store.refreshGit(path) } }
    }

    func gitHelp(_ s: GitStatus) -> String {
        let changes = s.changes.map { $0 == 0 ? "No uncommitted changes" : "\($0) \($0 == 1 ? "file has" : "files have") uncommitted changes" }
        return "Git branch \(s.branch) in \(LibraryModel.display(s.root))" + (changes.map { " — \($0)" } ?? "")
    }
}

// MARK: - Grouping

/// Group the folder on screen by kind or by when things arrived — next to Sort. Nothing moves.
struct GroupMenu: View {
    @AppStorage("folderGrouping") private var grouping: FolderGrouping = .none
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            Label("Group: \(grouping.rawValue)", systemImage: "square.stack.3d.up").font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        } else {
            Menu {
                ForEach(FolderGrouping.allCases) { g in
                    Button { grouping = g } label: { if grouping == g { Label(g.rawValue, systemImage: "checkmark") } else { Text(g.rawValue) } }
                }
            } label: {
                Label(grouping == .none ? "Group" : "Group: \(grouping.rawValue)", systemImage: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Group this folder by kind or by when things arrived — nothing moves")
        }
    }
}

/// A group's heading inside a grid or list: "Yesterday · 4".
struct GroupHeader: View {
    var group: ItemGroup

    var body: some View {
        HStack(spacing: 6) {
            Text(group.title).font(.system(size: 13, weight: .bold, design: .rounded))
            Text("\(group.items.count)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 4)
        }
        .padding(.top, 4)
    }
}

// MARK: - Terminal and editor

/// Open a folder in the first installed terminal (Ghostty, Warp, iTerm, Terminal) or in the editor
/// picked in Settings — with NSWorkspace, never a shell command.
@MainActor
enum DevOpen {
    static func installed(_ id: String) -> Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil }

    static var terminal: DevApp? { DevApps.terminal(has: installed) }
    static var editor: DevApp? { DevApps.editor(preferred: UserDefaults.standard.string(forKey: "folderEditor"), has: installed) }
    static var editors: [DevApp] { DevApps.installed(DevApps.editors, has: installed) }

    enum Target { case terminal, editor }

    /// Opens the folder; returns what went wrong, if anything.
    @discardableResult
    static func open(_ path: String, in target: Target) -> String? {
        guard Workspaces.isFolder(path) else { return "Not a folder" }
        let app = target == .terminal ? terminal : editor
        guard let app, let id = app.bundleIDs.first, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return target == .terminal ? "No terminal found" : "No code editor found — install one, or pick one in Settings"
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)], withApplicationAt: appURL, configuration: config)
        return nil
    }

    /// Open, and say so in the window's toast if it didn't work.
    static func open(_ path: String, in target: Target, model: AppModel) {
        if let problem = open(path, in: target) { model.show(problem, failed: true) }
    }

    /// The two menu items for a folder's right-click menu.
    static func menuItems(for path: String, model: AppModel) -> [NSMenuItem] {
        var out: [NSMenuItem] = []
        if let t = terminal {
            out.append(ActionMenuItem("Open in \(t.name)", symbol: "terminal", key: "t", modifiers: [.command, .option, .shift]) {
                open(path, in: .terminal, model: model)
            })
        }
        if let e = editor {
            out.append(ActionMenuItem("Open in \(e.name)", symbol: "chevron.left.forwardslash.chevron.right", key: "e",
                                      modifiers: [.command, .option, .shift]) {
                open(path, in: .editor, model: model)
            })
        }
        return out
    }
}

/// "Open in iTerm  ⌥⇧⌘T" / "Open in Zed  ⌥⇧⌘E" for the folder on screen.
struct OpenInMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshot
    var path: String

    var body: some View {
        if snapshot {
            Label("Open in", systemImage: "terminal").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
        } else {
            Menu {
                Button("Open in \(DevOpen.terminal?.name ?? "Terminal")  ⌥⇧⌘T") { DevOpen.open(path, in: .terminal, model: model) }
                    .disabled(DevOpen.terminal == nil)
                Button("Open in \(DevOpen.editor?.name ?? "Editor")  ⌥⇧⌘E") { DevOpen.open(path, in: .editor, model: model) }
                    .disabled(DevOpen.editor == nil)
            } label: {
                Label("Open in", systemImage: "terminal").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Open this folder in your terminal  ⌥⇧⌘T, or your code editor  ⌥⇧⌘E")
        }
    }
}

/// Settings: which editor "Open in editor" uses.
struct EditorSettingRow: View {
    @AppStorage("folderEditor") private var chosen = ""
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let editors = DevOpen.editors
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Open folders in").font(.system(size: 13, weight: .medium))
                Text("⌥⇧⌘E opens the folder on screen in this editor; ⌥⇧⌘T opens it in \(DevOpen.terminal?.name ?? "your terminal").")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if editors.isEmpty {
                Text("No code editor installed").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            } else if snapshot {
                Text(DevOpen.editor?.name ?? "").font(.system(size: 12.5, weight: .medium))
            } else {
                Picker("", selection: Binding(get: { DevOpen.editor?.name ?? "" }, set: { chosen = $0 })) {
                    ForEach(editors) { Text($0.name).tag($0.name) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }
}


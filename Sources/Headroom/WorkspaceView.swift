import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HeadroomCore

/// One project on one page: its folders (from anywhere — home, iCloud, Dropbox, a drive), its loose
/// files, and what changed lately. Nothing is copied or moved; drop things on the page to add them.
struct WorkspaceScreen: View {
    @EnvironmentObject var library: LibraryModel
    @AppStorage("workspaceChangedLately") private var showChanges = true
    @State private var dropping = false
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if let w = library.currentWorkspace {
            page(w)
                .task(id: w.paths) { await library.refreshWorkspace(w.id) }
                .onChange(of: library.index.scannedAt) { _, _ in Task { await library.refreshWorkspace(w.id) } }
                .modifier(WorkspaceDrop(id: w.id, targeted: $dropping))
                .overlay {
                    if dropping {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.accent.opacity(0.06)))
                            .overlay(Label("Add to “\(w.name)”", systemImage: "plus.circle.fill")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent))
                            .allowsHitTesting(false)
                    }
                }
        } else {
            EmptyState(symbol: "rectangle.stack", title: "No workspace open",
                       detail: "Pick one in the sidebar, or make one with ⌥⌘N.")
        }
    }

    func page(_ w: Workspace) -> some View {
        let infos = w.paths.map { (path: $0, info: library.members[$0]) }
        let folders = infos.filter { $0.info?.folder != nil || $0.info.map { $0.state != .present } == true }
        let files = library.sorted(infos.compactMap { $0.info?.file })
        let placeholders = infos.filter { i in i.info.map { $0.state == .present && $0.folder == nil && $0.file == nil } == true }
        let loading = infos.contains { $0.info == nil }
        let changes = library.changedLately(w)
        // The note sits above the grid, not in its header: the grid's keys (Space, Return, arrows) would
        // otherwise catch keys typed into the field — Space opened Quick Look, Return opened a file.
        return VStack(alignment: .leading, spacing: 18) {
            noteRow(w)
            FileGrid(items: files, header: AnyView(
            VStack(alignment: .leading, spacing: 24) {
                if w.members.isEmpty {
                    addCard(w, big: true)
                } else {
                    if showChanges, !changes.isEmpty { changedLately(changes) }
                    if !folders.isEmpty || loading {
                        VStack(alignment: .leading, spacing: 12) {
                            HomeSection(title: "Folders", count: folders.count)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                                ForEach(folders, id: \.path) { f in WorkspaceFolderCard(workspace: w, path: f.path, info: f.info) }
                                if loading { LoadingFolderCard() }
                                addCard(w, big: false)
                            }
                        }
                    }
                    if !files.isEmpty || !placeholders.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HomeSection(title: "Files", count: files.count + placeholders.count)
                            ForEach(placeholders, id: \.path) { p in cloudOnlyRow(w, p.path) }
                        }
                    }
                }
            }
            ))
        }
    }

    func noteRow(_ w: Workspace) -> some View {
        HStack(spacing: 10) {
            // ImageRenderer can't draw a text field: renders show the note as text.
            if snapshot {
                Text(w.note.isEmpty ? "Add a note — what this workspace is for" : w.note).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            } else {
                TextField("Add a note — what this workspace is for", text: Binding(get: { w.note }, set: { library.setNote(w.id, $0) }))
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if !showChanges {
                Button { showChanges = true } label: { Label("Changed lately", systemImage: "clock") }
                    .buttonStyle(GhostButtonStyle()).help("Show what changed in this workspace in the last two weeks")
            }
            Button { add(to: w) } label: { Label("Add…", systemImage: "plus") }
                .buttonStyle(GhostButtonStyle()).help("Add folders or files — or drag them onto this page")
        }
    }

    /// The newest changes anywhere in the workspace, in one strip.
    func changedLately(_ items: [LibraryItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Changed lately").font(.system(size: 17, weight: .bold, design: .rounded))
                Text("last two weeks").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Hide") { showChanges = false }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            }
            HScrolling {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            FileCard(item: item, size: 148, siblings: items).frame(width: 148)
                            Text(Workspaces.place(of: item.path, home: library.home))
                                .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                                .frame(width: 140, alignment: .leading).padding(.leading, 8)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    func addCard(_ w: Workspace, big: Bool) -> some View {
        Button { add(to: w) } label: {
            VStack(spacing: big ? 10 : 6) {
                Image(systemName: "plus").font(.system(size: big ? 20 : 15, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text("Add folders or files").font(.system(size: big ? 15 : 12.5, weight: .semibold))
                Text("Drag them here, or right-click a file › Add to Workspace. Nothing is copied or moved.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: big ? 200 : 112)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.textTertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    /// An iCloud-only file: listed by name, never opened or previewed (that would download it).
    func cloudOnlyRow(_ w: Workspace, _ path: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "icloud.and.arrow.down").foregroundStyle(Theme.textTertiary)
            Text((path as NSString).lastPathComponent).font(.system(size: 12.5, weight: .medium))
            Text("In iCloud only — open it in Finder to download it").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                .buttonStyle(GhostButtonStyle())
            Button("Remove") { library.removeFromWorkspace(w.id, paths: [path]) }.buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
    }

    func add(to w: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Workspace"
        panel.message = "Pick folders or files for “\(w.name)”. They stay where they are."
        guard panel.runModal() == .OK else { return }
        library.addToWorkspace(w.id, paths: panel.urls.map(\.path))
    }
}

/// Drop folders or files from Finder (or Headroom's own grid) to add them to a workspace.
/// Skipped in renders: ImageRenderer can't draw a drop target.
struct WorkspaceDrop: ViewModifier {
    @EnvironmentObject var library: LibraryModel
    var id: UUID
    var targeted: Binding<Bool> = .constant(false)
    @Environment(\.snapshotMode) private var snapshot

    @ViewBuilder func body(content: Content) -> some View {
        if snapshot {
            content
        } else {
            content.dropDestination(for: URL.self) { urls, _ in
                let paths = urls.filter(\.isFileURL).map(\.path)
                guard !paths.isEmpty else { return false }
                library.addToWorkspace(id, paths: paths)
                return true
            } isTargeted: { targeted.wrappedValue = $0 }
        }
    }
}

/// A folder in a workspace: where it lives, how many files and how big, when it last changed.
struct WorkspaceFolderCard: View {
    @EnvironmentObject var library: LibraryModel
    var workspace: Workspace
    var path: String
    var info: LibraryModel.MemberInfo?
    @State private var hovering = false

    var summary: Workspaces.FolderSummary? { info?.folder }
    var present: Bool { info?.state == .present }

    /// The kind most of its newest files are — the folder takes that colour and symbol.
    var dominant: FileKind? {
        let kinds = (summary?.recent ?? []).map(\.kind).filter { $0 != .other && $0 != .app }
        return Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count).max { $0.value < $1.value }?.key
    }
    /// Plain folders are Finder blue.
    var kind: FileKind { dominant ?? .video }

    var symbol: String {
        if !present { return info?.state == .missing ? "questionmark.folder" : "externaldrive.badge.xmark" }
        if summary?.isRepo == true { return "chevron.left.forwardslash.chevron.right" }
        return dominant.map { $0.symbol + ".fill" } ?? "folder.fill"
    }

    var body: some View {
        let (top, bottom) = Theme.shelf(for: present ? kind : .other)
        Button { if present { library.browse(path) } } label: {
            ZStack(alignment: .topLeading) {
                FolderShape().fill(bottom.opacity(0.9))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [top.opacity(0.92), bottom.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.fill(hovering ? 0.16 : 0.08)))
                    .padding(.top, 20)
                    .shadow(color: .black.opacity(0.06), radius: 3, y: -1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Image(systemName: symbol).font(.system(size: 12, weight: .bold))
                            .foregroundStyle(present ? Theme.tint(for: kind) : Theme.textTertiary)
                        Spacer()
                        if present, let recent = summary?.recent, !recent.isEmpty {
                            ThumbStack(items: Array(recent.filter { $0.kind == .image || $0.kind == .video || $0.kind == .document }.prefix(3)),
                                       total: summary?.files ?? 0, size: 24)
                        }
                    }
                    .padding(.top, 2)
                    Spacer(minLength: 0)
                    Text(FileManager.default.displayName(atPath: path)).font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(present ? Theme.textPrimary : Theme.textSecondary).lineLimit(1)
                    Text(Workspaces.place(of: path, home: library.home)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    Text(detail).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1).padding(.top, 3)
                    if present, let changed = summary?.changed {
                        Text("Changed \(changed.ago)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 13).padding(.top, 30)
            }
            .frame(height: 164)
            .opacity(present ? 1 : 0.7)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .help(LibraryModel.display(path))
        .contextMenu {
            if present {
                Button("Open") { library.browse(path) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Divider()
            }
            Button("Remove from Workspace") { library.removeFromWorkspace(workspace.id, paths: [path]) }
        }
    }

    var detail: String {
        switch info?.state {
        case .notConnected(let drive)?: return "On “\(drive)” — not connected"
        case .missing?: return "Moved or deleted — right-click to remove"
        default: break
        }
        guard let s = summary else { return "Looking…" }
        let items = s.partial ? "\(s.files.formatted())+ files" : "\(s.files.formatted()) \(s.files == 1 ? "file" : "files")"
        return "\(items) · \(ByteFormat.compact(s.bytes))"
    }
}

/// While a workspace's folders are being looked at.
struct LoadingFolderCard: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Looking through folders…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 164)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.fill(0.04)))
    }
}

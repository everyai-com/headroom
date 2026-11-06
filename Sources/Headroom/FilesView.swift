import SwiftUI
import HeadroomCore

/// Single big files anywhere in your folders — the forgotten 8 GB video the folder map hides.
/// Pick several and trash them in one go; everything trashed can be put back from Activity.
struct FilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var minimumMB: Int64 = 500
    @State private var oldestFirst = false
    @State private var kind: Kind = .all
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var pending: PendingAction?
    @State private var bulk: Bulk?
    @State private var working = false
    @Environment(\.snapshotMode) private var snapshot

    enum Bulk: Identifiable { case trash, delete; var id: Self { self } }

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", video = "Videos", archive = "Archives", installer = "Installers", model = "AI models", other = "Other"
        var id: String { rawValue }
        static func of(_ url: URL) -> Kind {
            switch url.pathExtension.lowercased() {
            case "mov", "mp4", "m4v", "mkv", "avi", "webm": .video
            case "zip", "tar", "gz", "7z", "rar", "tgz", "xz", "bz2": .archive
            case "dmg", "iso", "img", "pkg", "xip": .installer
            case "gguf", "safetensors", "bin", "pt", "pth", "onnx", "ckpt", "mlmodel": .model
            default: url.path.contains("/huggingface/") || url.path.contains("/.ollama/") ? .model : .other
            }
        }
    }

    var files: [BigFile] {
        let min = minimumMB * 1_000_000
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = model.bigFiles.filter { $0.bytes >= min && FileManager.default.fileExists(atPath: $0.url.path) }
            .filter { !Exclusions.touches($0.url.path, model.excluded) }
            .filter { kind == .all || Kind.of($0.url) == kind }
            .filter { q.isEmpty || $0.url.path.lowercased().contains(q) }
        return oldestFirst ? list.sorted { $0.modified < $1.modified } : list
    }

    var selectedFiles: [BigFile] { files.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Bigger than").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                ForEach([Int64(100), 250, 500, 1000, 5000], id: \.self) { mb in
                    Pill(title: mb < 1000 ? "\(mb) MB" : "\(mb / 1000) GB", on: minimumMB == mb) { minimumMB = mb }
                }
                Spacer()
                SearchField(text: $query, prompt: "Filter by name or folder")
                    .frame(width: 220)
                Pill(title: "Largest", on: !oldestFirst) { oldestFirst = false }
                Pill(title: "Oldest", on: oldestFirst) { oldestFirst = true }
            }
            HStack(spacing: 8) {
                ForEach(Kind.allCases) { k in
                    let count = k == .all ? nil : model.bigFiles.filter { Kind.of($0.url) == k && $0.bytes >= minimumMB * 1_000_000 }.count
                    if count != 0 {
                        Pill(title: count.map { "\(k.rawValue) · \($0)" } ?? k.rawValue, on: kind == k) { kind = k }
                    }
                }
            }
            let list = files
            if model.map == nil {
                Card {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Large files are found while the map measures your disk…").foregroundStyle(Theme.textSecondary)
                    }
                }
            } else if list.isEmpty {
                EmptyState(symbol: "checkmark.seal", title: query.isEmpty ? "No file that big here" : "Nothing matches “\(query)”",
                           detail: query.isEmpty ? "Try a smaller size or another type." : "Clear the filter to see everything.")
            } else {
                HStack(spacing: 12) {
                    let all = !list.isEmpty && list.allSatisfy { selected.contains($0.id) }
                    Button {
                        if all { selected.subtract(list.map(\.id)) } else { selected.formUnion(list.filter(canTrash).map(\.id)) }
                    } label: {
                        HStack(spacing: 8) {
                            CheckCircle(on: all)
                            Text(all ? "Deselect all" : "Select all").font(.system(size: 12, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("a", modifiers: .command)
                    Spacer()
                    Text("\(list.count) files · \(list.reduce(0) { $0 + $1.bytes }.gb) — your own folders only; app data in Library is never listed.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 18)
                Card(padding: 0) {
                    Scrolling {
                        LazyVStack(spacing: 0) {
                            ForEach(list.prefix(snapshot ? 8 : 500)) { f in
                                row(f)
                                Divider().overlay(Theme.hairline).padding(.leading, 90)
                            }
                        }
                        .padding(.bottom, selected.isEmpty ? 0 : 80)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { selectionBar }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selected.isEmpty)
        .onChange(of: model.bigFiles) { _, files in
            let live = Set(files.map(\.id))
            selected = selected.filter(live.contains)
        }
        .confirmingAction($pending) { p in
            let outcome = await model.perform(p.action, on: p.node)
            let entry = outcome.failed || p.action != .trash ? nil : model.activity.entries.first?.id
            model.show(outcome.message, failed: outcome.failed, undo: entry)
            if !outcome.failed {
                model.bigFiles.removeAll { $0.url.path == p.node.id }
                selected.remove(p.node.id)
            }
        }
        .confirmSheet(bulkTitle, isPresented: Binding(get: { bulk != nil }, set: { if !$0 { bulk = nil } }), presenting: bulk) { b in
            Button(b == .trash ? "Move to Trash" : "Delete Permanently", role: .destructive) { Task { await run(b) } }
            Button("Cancel", role: .cancel) {}
        } message: { b in
            Text(b == .trash
                 ? "\(selectedBytes.gb). Put them back any time from Activity — the space comes back when you empty the Trash (one click in Activity)."
                 : "Frees \(selectedBytes.gb) right away. This can't be undone.")
        }
    }

    var selectedBytes: Int64 { selectedFiles.reduce(0) { $0 + $1.bytes } }
    var bulkTitle: String {
        let n = selectedFiles.count
        let what = n == 1 ? "“\(selectedFiles.first?.url.lastPathComponent ?? "")”" : "\(n) files"
        return bulk == .delete ? "Delete \(what) permanently?" : "Move \(what) to the Trash?"
    }

    func run(_ b: Bulk) async {
        working = true
        let r = await model.remove(selectedFiles, permanently: b == .delete)
        working = false
        model.bigFiles.removeAll { r.removed.contains($0.url.path) }
        selected.subtract(r.removed)
        model.show(r.message, failed: r.removed.isEmpty, undo: r.undo)
    }

    @ViewBuilder var selectionBar: some View {
        let picked = selectedFiles
        if !picked.isEmpty {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text("\(picked.count) \(picked.count == 1 ? "file" : "files") · \(selectedBytes.gb)").font(Theme.number(15, weight: .semibold))
                }
                Spacer()
                Button("Clear") { selected = [] }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.escape, modifiers: [])
                Button("Reveal") { model.reveal(picked.map(\.url)) }.buttonStyle(GhostButtonStyle())
                Button { bulk = .delete } label: { Label("Delete Permanently…", systemImage: "xmark.bin") }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.delete, modifiers: [.command, .option])
                Button { bulk = .trash } label: {
                    Label(working ? "Working…" : "Move \(selectedBytes.gb) to Trash", systemImage: "trash.fill")
                }
                .buttonStyle(PrimaryButtonStyle(tint: Theme.review))
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(working)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(FloatingBarBackground())
            .padding(.horizontal, 4).padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    func canTrash(_ f: BigFile) -> Bool { model.refusal(.trash, for: node(f)) == nil }

    func node(_ f: BigFile) -> DiskNode {
        DiskNode(id: f.url.path, name: f.url.lastPathComponent, url: f.url, bytes: f.bytes, area: .documents)
    }

    func row(_ f: BigFile) -> some View {
        let node = node(f)
        let refusal = model.refusal(.trash, for: node)
        let on = selected.contains(f.id)
        return HStack(spacing: 14) {
            CheckCircle(on: on, tint: Theme.review, disabled: refusal != nil)
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.color(for: .documents).opacity(0.16))
                Image(systemName: symbol(f.url)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.color(for: .documents))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(f.url.deletingLastPathComponent().tildePath).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(f.bytes.gb).font(Theme.number(15, weight: .semibold))
                Text("changed \(f.modified.ago)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .frame(minWidth: 110, alignment: .trailing)
            Button { model.reveal([f.url]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(GhostButtonStyle()).help("Reveal in Finder")
            Button { pending = PendingAction(action: .trash, node: node) } label: { Image(systemName: "trash") }
                .buttonStyle(GhostButtonStyle())
                .disabled(refusal != nil)
                .help(refusal ?? "Move to Trash — put it back from Activity")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(on ? Theme.review.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            guard refusal == nil else { return }
            if on { selected.remove(f.id) } else { selected.insert(f.id) }
        }
        .contextMenu {
            Button("Open") { model.open(f.url) }
            Button("Reveal in Finder") { model.reveal([f.url]) }
            Button("Copy Path") { model.copyPath(f.url) }
            Divider()
            Button("Move to Trash…") { pending = PendingAction(action: .trash, node: node) }
                .disabled(refusal != nil)
            Button("Delete Permanently…") { pending = PendingAction(action: .delete, node: node) }
                .disabled(model.refusal(.delete, for: node) != nil)
            Divider()
            Button("Never Touch This") { model.exclude([f.url]) }
        }
    }

    func symbol(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "mkv", "avi", "webm": "film.fill"
        case "dmg", "iso", "img", "pkg", "xip": "opticaldiscdrive.fill"
        case "zip", "tar", "gz", "7z", "rar", "tgz", "xz", "bz2": "doc.zipper"
        case "gguf", "safetensors", "bin", "pt", "pth", "onnx", "ckpt": "brain"
        case "wav", "aif", "aiff", "flac", "mp3": "waveform"
        case "sqlite", "db", "raw", "qcow2", "vmdk", "vdi": "externaldrive.fill"
        case "log", "jsonl", "txt": "doc.text.fill"
        default: "doc.fill"
        }
    }
}

/// Everything Headroom removed, newest first — Put Back anything still in the Trash, or
/// delete it for good so the space actually comes back.
struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var confirmPurge: [ActivityLog.Entry]?
    @State private var confirmClear = false
    @State private var working = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "Everything", inTrash = "In the Trash", gone = "Freed for good"
        var id: String { rawValue }
    }

    var entries: [ActivityLog.Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.activity.entries.filter { e in
            switch filter {
            case .all: true
            case .inTrash: e.canDeleteFromTrash
            case .gone: !e.canDeleteFromTrash && !e.restored && e.kind != .filed
            }
        }
        .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.items.contains { $0.original.lowercased().contains(q) } }
    }

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 14) {
                if model.activity.entries.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "Nothing removed yet",
                               detail: "Everything Headroom cleans up, trashes or uninstalls is listed here. Trashed items can be put back — or deleted for good to get the space.")
                } else {
                    trashBanner
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { f in Pill(title: f.rawValue, on: filter == f) { filter = f } }
                        Spacer()
                        SearchField(text: $query, prompt: "Filter").frame(width: 200)
                    }
                    let freed = model.activity.entries.filter { $0.kind != .filed && (($0.kind != .trashed && $0.kind != .uninstalled) || $0.purgedAt != nil) }
                        .reduce(0) { $0 + $1.bytes }
                    Text("\(model.activity.entries.count) actions · \(freed.gb) freed for good")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    let list = entries
                    if list.isEmpty {
                        EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "Nothing here", detail: "No action matches this filter.")
                    } else {
                        Card(padding: 0) {
                            LazyVStack(spacing: 0) {
                                ForEach(list.prefix(300)) { e in
                                    row(e)
                                    Divider().overlay(Theme.hairline).padding(.leading, 58)
                                }
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Clear this list…") { confirmClear = true }.buttonStyle(GhostButtonStyle())
                            .help("Forget the history. Nothing on disk changes.")
                    }
                }
            }
        }
        .confirmSheet(purgeTitle, isPresented: Binding(get: { confirmPurge != nil }, set: { if !$0 { confirmPurge = nil } }),
                            presenting: confirmPurge) { list in
            Button("Delete Permanently", role: .destructive) {
                Task {
                    working = true
                    let message = await model.deleteFromTrash(list)
                    working = false
                    model.show(message, failed: message.contains("couldn't"))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { list in
            Text("Frees about \(list.reduce(0) { $0 + $1.bytes }.gb). Only what Headroom put in the Trash is removed — anything else in your Trash stays. This can't be undone.")
        }
        .confirmSheet("Clear the activity list?", isPresented: $confirmClear) {
            Button("Clear List", role: .destructive) { model.clearActivityLog(); model.show("Activity cleared") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Headroom forgets what it removed. Nothing on disk changes — trashed items stay in the Trash, but Put Back won't be offered for them any more.")
        }
    }

    var purgeTitle: String {
        guard let list = confirmPurge else { return "" }
        return list.count == 1 ? "Delete “\(list[0].title)” for good?" : "Delete \(list.count) items from the Trash for good?"
    }

    @ViewBuilder var trashBanner: some View {
        let waiting = model.waitingInTrash
        if !waiting.entries.isEmpty {
            Card {
                HStack(spacing: 16) {
                    Image(systemName: "trash.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.review)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Theme.review.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(waiting.bytes.gb) is still in the Trash").font(.system(size: 15, weight: .semibold))
                        Text("\(waiting.entries.count) \(waiting.entries.count == 1 ? "thing" : "things") Headroom moved there. The space comes back once they're deleted for good.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button { confirmPurge = waiting.entries } label: {
                        Label(working ? "Deleting…" : "Delete for good", systemImage: "xmark.bin.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(tint: Theme.review))
                    .disabled(working)
                }
            }
        }
    }

    func row(_ e: ActivityLog.Entry) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color(e).opacity(0.16))
                Image(systemName: symbol(e)).font(.system(size: 15, weight: .semibold)).foregroundStyle(color(e))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(e.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if e.automatic { Badge(text: "Automatic", color: Theme.keep) }
                    if e.restored { Badge(text: "Put back", color: Theme.safe) }
                    if e.purgedAt != nil, !e.canDeleteFromTrash { Badge(text: "Deleted for good", color: Theme.critical) }
                }
                Text(verb(e) + " · " + (e.items.first.map { URL(fileURLWithPath: $0.original).tildePath } ?? "")
                     + (e.items.count > 1 ? " +\(e.items.count - 1) more" : ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                if let rebuild = e.rebuild {
                    Text("bring it back: \(rebuild)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(e.bytes.gb).font(Theme.number(15, weight: .semibold))
                Text(e.date.ago).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            if e.canPutBack {
                Button("Put Back") { model.show(model.putBack(e)) }.buttonStyle(GhostButtonStyle())
            }
            if e.canDeleteFromTrash {
                Button { confirmPurge = [e] } label: { Image(systemName: "xmark.bin") }
                    .buttonStyle(GhostButtonStyle())
                    .help("Delete for good — frees the space now")
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .contextMenu {
            if e.canPutBack { Button("Put Back") { model.show(model.putBack(e)) } }
            if !e.stillInTrash.isEmpty { Button("Show in Trash") { model.reveal(e.stillInTrash) } }
            if let first = e.items.first { Button("Copy Original Path") { model.copyPath(URL(fileURLWithPath: first.original)) } }
            if e.canDeleteFromTrash {
                Divider()
                Button("Delete for Good…") { confirmPurge = [e] }
            }
        }
    }

    func verb(_ e: ActivityLog.Entry) -> String {
        switch e.kind {
        case .reclaimed: "Removed (comes back on its own)"
        case .trashed: "Moved to the Trash"
        case .emptied: "Emptied"
        case .deleted: "Deleted permanently"
        case .uninstalled: "Uninstalled to the Trash"
        case .ranTool: "Cleaned by its own tool"
        case .filed: "Filed into a folder"
        }
    }

    func symbol(_ e: ActivityLog.Entry) -> String {
        switch e.kind {
        case .trashed, .uninstalled: "trash"
        case .deleted: "xmark.bin.fill"
        case .ranTool: "terminal.fill"
        case .filed: "folder.fill"
        default: "sparkles"
        }
    }

    func color(_ e: ActivityLog.Entry) -> Color {
        switch e.kind {
        case .deleted: Theme.critical
        case .trashed, .uninstalled: Theme.review
        case .filed: Theme.keep
        default: Theme.safe
        }
    }
}

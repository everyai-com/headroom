import SwiftUI
import HeadroomCore

/// Single big files anywhere in your folders — the forgotten 8 GB video the folder map hides.
struct FilesView: View {
    @EnvironmentObject var model: AppModel
    @State private var minimumGB: Double = 0.5
    @State private var oldestFirst = false
    @State private var pending: PendingAction?
    @State private var message: String?
    @Environment(\.snapshotMode) private var snapshot

    var files: [BigFile] {
        let min = Int64(minimumGB * 1_000_000_000)
        let list = model.bigFiles.filter { $0.bytes >= min && FileManager.default.fileExists(atPath: $0.url.path) }
            .filter { !Exclusions.touches($0.url.path, model.excluded) }
        return oldestFirst ? list.sorted { $0.modified < $1.modified } : list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text("Files bigger than").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                ForEach([0.5, 1, 5], id: \.self) { gb in
                    pill(gb < 1 ? "500 MB" : "\(Int(gb)) GB", on: minimumGB == gb) { minimumGB = gb }
                }
                Spacer()
                pill("Largest", on: !oldestFirst) { oldestFirst = false }
                pill("Oldest", on: oldestFirst) { oldestFirst = true }
            }
            if let message {
                Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.safe)
            }
            let list = files
            if model.map == nil {
                Card { Text("Large files are found while the map measures your disk…").foregroundStyle(Theme.textSecondary) }
            } else if list.isEmpty {
                Card { Text("No single file that big in your folders.").foregroundStyle(Theme.textSecondary) }
            } else {
                Card(padding: 0) {
                    Scrolling {
                        VStack(spacing: 0) {
                            ForEach(list.prefix(snapshot ? 8 : 300)) { f in
                                row(f)
                                Divider().overlay(Theme.hairline).padding(.leading, 58)
                            }
                        }
                    }
                }
                Text("\(list.count) files · \(list.reduce(0) { $0 + $1.bytes }.gb) — your own folders only; app data in Library is never listed.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .confirmingAction($pending) { p in
            let outcome = await model.perform(p.action, on: p.node)
            message = outcome.message
            if !outcome.failed { model.bigFiles.removeAll { $0.url.path == p.node.id } }
        }
    }

    func row(_ f: BigFile) -> some View {
        let node = DiskNode(id: f.url.path, name: f.url.lastPathComponent, url: f.url, bytes: f.bytes, area: .documents)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.color(for: .documents).opacity(0.16))
                Image(systemName: symbol(f.url)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.color(for: .documents))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(f.url.lastPathComponent).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(f.url.deletingLastPathComponent().tildePath).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(f.bytes.gb).font(Theme.number(14, weight: .semibold))
                Text("changed \(f.modified.ago)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            Button("Reveal") { model.reveal([f.url]) }.buttonStyle(GhostButtonStyle())
            Button("Move to Trash…") { pending = PendingAction(action: .trash, node: node) }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.refusal(.trash, for: node) != nil)
                .help(model.refusal(.trash, for: node) ?? "Goes to the Trash — put it back from Activity")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .contextMenu {
            Button("Open") { model.open(f.url) }
            Button("Reveal in Finder") { model.reveal([f.url]) }
            Button("Copy Path") { model.copyPath(f.url) }
            Divider()
            Button("Move to Trash…") { pending = PendingAction(action: .trash, node: node) }
                .disabled(model.refusal(.trash, for: node) != nil)
            Button("Delete Permanently…") { pending = PendingAction(action: .delete, node: node) }
                .disabled(model.refusal(.delete, for: node) != nil)
            Divider()
            Button("Never Touch This") { model.exclude([f.url]) }
        }
    }

    func symbol(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "mkv", "avi": "film.fill"
        case "dmg", "iso", "img", "pkg", "xip": "opticaldiscdrive.fill"
        case "zip", "tar", "gz", "7z", "rar", "tgz": "doc.zipper"
        case "gguf", "safetensors", "bin", "pt", "onnx": "brain"
        case "wav", "aif", "aiff", "flac", "mp3": "waveform"
        case "sqlite", "db", "raw", "qcow2", "vmdk", "vdi": "externaldrive.fill"
        default: "doc.fill"
        }
    }

    func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.black : Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// Everything Headroom removed, newest first — with Put Back for anything still in the Trash.
struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    @State private var message: String?

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 14) {
                if let message {
                    Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.safe)
                }
                if model.activity.entries.isEmpty {
                    Card {
                        Text("Nothing removed yet. Everything Headroom reclaims, trashes or uninstalls is listed here — trashed items can be put back.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    let freed = model.activity.entries.filter { $0.kind != .trashed && $0.kind != .uninstalled }.reduce(0) { $0 + $1.bytes }
                    Text("\(model.activity.entries.count) actions · \(freed.gb) freed for good")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(model.activity.entries.prefix(200)) { e in
                                row(e)
                                Divider().overlay(Theme.hairline).padding(.leading, 58)
                            }
                        }
                    }
                }
            }
        }
    }

    func row(_ e: ActivityLog.Entry) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color(e).opacity(0.16))
                Image(systemName: symbol(e)).font(.system(size: 14, weight: .semibold)).foregroundStyle(color(e))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(e.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if e.automatic { Badge(text: "Automatic", color: Theme.keep) }
                    if e.restored { Badge(text: "Put back", color: Theme.safe) }
                }
                Text(verb(e) + " · " + (e.items.first.map { URL(fileURLWithPath: $0.original).tildePath } ?? "")
                     + (e.items.count > 1 ? " +\(e.items.count - 1) more" : ""))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                if let rebuild = e.rebuild {
                    Text("bring it back: \(rebuild)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(e.bytes.gb).font(Theme.number(14, weight: .semibold))
                Text(e.date.ago).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            if e.canPutBack {
                Button("Put Back") { message = model.putBack(e) }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    func verb(_ e: ActivityLog.Entry) -> String {
        switch e.kind {
        case .reclaimed: "Removed (regenerable)"
        case .trashed: "Moved to the Trash"
        case .emptied: "Emptied"
        case .deleted: "Deleted permanently"
        case .uninstalled: "Uninstalled to the Trash"
        case .ranTool: "Cleaned by its own tool"
        }
    }

    func symbol(_ e: ActivityLog.Entry) -> String {
        switch e.kind {
        case .trashed, .uninstalled: "trash"
        case .deleted: "xmark.bin.fill"
        case .ranTool: "terminal.fill"
        default: "sparkles"
        }
    }

    func color(_ e: ActivityLog.Entry) -> Color {
        switch e.kind {
        case .deleted: Theme.critical
        case .trashed, .uninstalled: Theme.review
        default: Theme.safe
        }
    }
}

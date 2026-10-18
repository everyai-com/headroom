import SwiftUI
import HeadroomCore

/// USB drives: see one even while macOS is still checking it, open it read-only, browse it,
/// and copy what matters to the Mac. The drive is only ever read.
@MainActor
final class DrivesModel: ObservableObject {
    struct Entry: Identifiable, Hashable {
        var id: String { url.path }
        var url: URL
        var isFolder: Bool
        var bytes: Int64
        var modified: Date?
    }

    struct Job: Identifiable {
        let id = UUID()
        var name: String
        var destination: URL
        var copier: DriveCopier
        var progress: DriveCopier.Progress?
    }

    @Published var drives: [ExternalDrive] = []
    @Published var selected: String?
    @Published var folder: URL?
    @Published var entries: [Entry] = []
    @Published var loading = false
    @Published var query = ""
    @Published var results: [Entry]?
    @Published var jobs: [Job] = []
    @Published var message: String?
    @Published var mounting = false

    static let rescueRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Drive Rescue")

    var drive: ExternalDrive? { drives.first { $0.id == selected } ?? drives.first }

    func refresh() async {
        let found = await Task.detached { ExternalDrive.current() }.value
        let wasMounted = drive?.mountPoint
        drives = found
        if selected == nil || !found.contains(where: { $0.id == selected }) { selected = found.first?.id }
        // Just mounted (or switched drive): start at its root.
        if let root = drive?.mountPoint, root != wasMounted || folder == nil || !(folder!.path.hasPrefix(root.path)) {
            await open(root)
        } else if drive?.mountPoint == nil {
            folder = nil; entries = []
        }
    }

    func open(_ url: URL) async {
        folder = url
        results = nil
        loading = true
        entries = await Task.detached { Self.list(url) }.value
        loading = false
    }

    nonisolated static func list(_ url: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)) ?? []
        return items.filter { !hidden($0.lastPathComponent) }.map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            return Entry(url: u, isFolder: v?.isDirectory ?? false, bytes: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate)
        }.sorted { ($0.isFolder ? 0 : 1, $0.url.lastPathComponent.lowercased()) < ($1.isFolder ? 0 : 1, $1.url.lastPathComponent.lowercased()) }
    }

    nonisolated static func hidden(_ name: String) -> Bool {
        name.hasPrefix("._") || name == ".DS_Store" || name.hasPrefix(".Spotlight") || name == ".fseventsd"
            || name == ".Trashes" || name == ".TemporaryItems" || name == "System Volume Information"
    }

    func search() async {
        guard let root = drive?.mountPoint, !query.trimmingCharacters(in: .whitespaces).isEmpty else { results = nil; return }
        loading = true
        let q = query.lowercased()
        results = await Task.detached {
            var hits: [Entry] = []
            let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                                        options: [.skipsHiddenFiles]) { _, _ in true }
            var scanned = 0
            while let u = walker?.nextObject() as? URL, hits.count < 300, scanned < 300_000 {
                scanned += 1
                guard u.lastPathComponent.lowercased().contains(q) else { continue }
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                hits.append(Entry(url: u, isFolder: v?.isDirectory ?? false, bytes: Int64(v?.fileSize ?? 0), modified: nil))
            }
            return hits
        }.value
        loading = false
    }

    /// Ask macOS for the admin password and mount read-only, skipping the slow check.
    func mountReadOnly() async {
        guard let script = drive?.readOnlyMountScript else { return }
        mounting = true
        message = nil
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let ok = await Task.detached {
            Shell.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 120) != nil
        }.value
        mounting = false
        await refresh()
        message = ok && drive?.mounted == true ? "Opened read-only. Nothing on the drive can change."
            : "Couldn't open it (cancelled, or the drive didn't respond). Try another port or cable."
    }

    func eject() {
        guard let point = drive?.mountPoint else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: point)
            message = "Ejected. Safe to unplug."
        } catch {
            message = "Couldn't eject: \(error.localizedDescription). Close files that are open from it."
        }
        Task { await refresh() }
    }

    func copy(_ url: URL) {
        guard let drive else { return }
        let destination = Self.rescueRoot.appendingPathComponent(drive.title)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let copier = DriveCopier(source: url, into: destination)
        let job = Job(name: url.lastPathComponent, destination: destination.appendingPathComponent(url.lastPathComponent), copier: copier)
        jobs.insert(job, at: 0)
        let id = job.id
        Task.detached {
            copier.run { p in
                Task { @MainActor in
                    if let i = self.jobs.firstIndex(where: { $0.id == id }) { self.jobs[i].progress = p }
                }
            }
        }
    }
}

struct DrivesView: View {
    @StateObject private var model: DrivesModel

    /// Snapshots pass a model already filled in (ImageRenderer never runs `.task`).
    @MainActor init(model: DrivesModel? = nil) { _model = StateObject(wrappedValue: model ?? DrivesModel()) }
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.drives.isEmpty {
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No USB drive plugged in").font(.system(size: 15, weight: .semibold))
                            Text("Plug one in — it shows up here even before Finder sees it.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            } else {
                if model.drives.count > 1 {
                    HStack { ForEach(model.drives) { d in pill(d.title, on: d.id == model.drive?.id) { model.selected = d.id; Task { await model.refresh() } } } }
                }
                if let drive = model.drive { header(drive) }
                if let message = model.message {
                    Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.safe)
                }
                if !model.jobs.isEmpty { jobs }
                if model.drive?.mounted == true { browser }
            }
        }
        .task {
            await model.refresh()
            guard !snapshot else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await model.refresh()
            }
        }
    }

    // MARK: Drive

    func header(_ d: ExternalDrive) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.color(for: .documents).opacity(0.16))
                        Image(systemName: "externaldrive.fill").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.color(for: .documents))
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(d.title).font(.system(size: 17, weight: .bold, design: .rounded))
                        HStack(spacing: 8) {
                            Text(d.bytes.gb).font(Theme.number(12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            Badge(text: d.link.label, color: d.link.isBottleneck ? Theme.review : Theme.safe)
                            stateBadge(d)
                        }
                    }
                    Spacer()
                    actions(d)
                }
                if d.link.isBottleneck {
                    Text("Connected at USB 2.0 speed — about 30 MB/s, roughly 2 minutes per GB. This drive can do far more: try a 10 Gb/s USB-C cable, the other port, or clean the drive's USB-C socket.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if !d.mounted, d.macOSChecking {
                    Text("macOS is checking the drive before it shows in Finder. Over a slow link that can take a long time. Open it read-only now to skip the wait — nothing on the drive can be changed that way.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder func stateBadge(_ d: ExternalDrive) -> some View {
        if d.mounted {
            Badge(text: d.readOnly ? "Open · read-only" : "Open", color: Theme.safe)
        } else if d.macOSChecking {
            Badge(text: "macOS is checking it…", color: Theme.review)
        } else {
            Badge(text: "Not open", color: Theme.keep)
        }
    }

    @ViewBuilder func actions(_ d: ExternalDrive) -> some View {
        if d.mounted {
            HStack(spacing: 8) {
                Button("Show in Finder") { if let p = d.mountPoint { NSWorkspace.shared.open(p) } }.buttonStyle(GhostButtonStyle())
                Button("Eject") { model.eject() }.buttonStyle(GhostButtonStyle())
            }
        } else {
            Button {
                Task { await model.mountReadOnly() }
            } label: {
                HStack(spacing: 6) {
                    if model.mounting { ProgressView().controlSize(.small) }
                    Text(model.mounting ? "Opening…" : "Open now (read-only)")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.mounting || d.readOnlyMountScript == nil)
        }
    }

    // MARK: Browser

    var browser: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                breadcrumbs
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    TextField("Search the drive", text: $model.query)
                        .textFieldStyle(.plain).font(.system(size: 12.5)).frame(width: 180)
                        .onSubmit { Task { await model.search() } }
                    if model.results != nil {
                        Button { model.query = ""; model.results = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(0.06)))
                if let folder = model.folder, model.results == nil {
                    Button("Copy this folder to Mac") { model.copy(folder) }.buttonStyle(PrimaryButtonStyle())
                }
            }
            let list = model.results ?? model.entries
            Card(padding: 0) {
                if model.loading {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Reading the drive…").foregroundStyle(Theme.textSecondary) }
                        .padding(20)
                } else if list.isEmpty {
                    Text(model.results == nil ? "This folder is empty." : "Nothing matches.").foregroundStyle(Theme.textSecondary).padding(20)
                } else {
                    Scrolling {
                        VStack(spacing: 0) {
                            ForEach(list.prefix(snapshot ? 10 : 2000)) { e in
                                row(e)
                                Divider().overlay(Theme.hairline).padding(.leading, 58)
                            }
                        }
                    }
                }
            }
            Text("Copies go to ~/Drive Rescue. Re-copying skips files already copied whole, so an interrupted copy just picks up where it stopped.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
        }
    }

    var breadcrumbs: some View {
        HStack(spacing: 4) {
            if let root = model.drive?.mountPoint, let folder = model.folder {
                let parts = [root] + crumbs(from: root, to: folder)
                ForEach(Array(parts.enumerated()), id: \.offset) { i, url in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary) }
                    Button(i == 0 ? (model.drive?.name ?? "Drive") : url.lastPathComponent) { Task { await model.open(url) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: i == parts.count - 1 ? .semibold : .regular))
                        .foregroundStyle(i == parts.count - 1 ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    func crumbs(from root: URL, to folder: URL) -> [URL] {
        var out: [URL] = []
        var u = folder.standardizedFileURL
        let r = root.standardizedFileURL.path
        while u.path.count > r.count, u.path.hasPrefix(r) {
            out.insert(u, at: 0)
            u = u.deletingLastPathComponent()
        }
        return out
    }

    func row(_ e: DrivesModel.Entry) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill((e.isFolder ? Theme.color(for: .documents) : Theme.keep).opacity(0.16))
                Image(systemName: e.isFolder ? "folder.fill" : symbol(e.url)).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(e.isFolder ? Theme.color(for: .documents) : Theme.textSecondary)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.url.lastPathComponent).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                if model.results != nil, let root = model.drive?.mountPoint {
                    Text(String(e.url.deletingLastPathComponent().path.dropFirst(root.path.count)).ifEmpty("/"))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                } else if let m = e.modified {
                    Text("changed \(m.ago)").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 12)
            if !e.isFolder { Text(e.bytes.gb).font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.textSecondary) }
            if e.isFolder {
                Button("Open") { Task { await model.open(e.url) } }.buttonStyle(GhostButtonStyle())
            } else {
                Button("Preview") { NSWorkspace.shared.open(e.url) }.buttonStyle(GhostButtonStyle())
            }
            Button("Copy to Mac") { model.copy(e.url) }.buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if e.isFolder { Task { await model.open(e.url) } } }
    }

    func symbol(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "avi", "m4v": "film"
        case "jpg", "jpeg", "png", "heic", "gif", "raw", "cr2", "arw", "dng": "photo"
        case "mp3", "wav", "aac", "m4a", "flac": "waveform"
        case "zip", "rar", "7z", "gz", "tar", "dmg": "doc.zipper"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }

    // MARK: Copies

    var jobs: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Copying to your Mac")
                ForEach(model.jobs) { job in
                    let p = job.progress
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Spacer()
                            if let p {
                                Text(p.finished ? (p.failed.isEmpty ? "Done · \(p.total.gb)" : "Done · \(p.failed.count) failed")
                                     : "\(p.copied.gb) of \(p.total.gb)")
                                    .font(Theme.number(12, weight: .medium))
                                    .foregroundStyle(p.finished ? (p.failed.isEmpty ? Theme.safe : Theme.review) : Theme.textSecondary)
                            } else {
                                Text("Measuring…").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                            }
                            if p?.finished == true {
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([job.destination]) }.buttonStyle(GhostButtonStyle())
                            } else {
                                Button("Stop") { job.copier.cancel() }.buttonStyle(GhostButtonStyle())
                            }
                        }
                        SegmentedBar(segments: [.init(id: "c", value: p?.fraction ?? 0, color: p?.failed.isEmpty == false ? Theme.review : Theme.safe)],
                                     total: 1, height: 6)
                        if let p, !p.finished, !p.current.isEmpty {
                            Text(p.current).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }

    func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? Color.black : Theme.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(on ? Theme.safe : Theme.fill(0.06)))
        }
        .buttonStyle(.plain)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

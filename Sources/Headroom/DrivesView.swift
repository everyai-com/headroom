import SwiftUI
import HeadroomCore

/// USB drives: see one even while macOS is still checking it (with the check's live progress),
/// let macOS check and open it normally, browse it, and copy what matters to the Mac.
/// Headroom itself only ever reads the drive.
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
    /// Drives whose check + normal mount we started (`diskutil mount`, which waits for the check).
    @Published var opening: Set<String> = []
    /// Bytes per second read from each unmounted drive — macOS's check at work.
    @Published var readRate: [String: Double] = [:]
    private var lastRead: [String: (bytes: Int64, at: Date)] = [:]
    /// Drives seen being checked, so the moment one opens we can say so.
    private var sawChecking: Set<String> = []
    /// When we first saw macOS checking each drive.
    @Published var checkingSince: [String: Date] = [:]

    static let rescueRoot = URL(fileURLWithPath: HeadroomPaths.home).appendingPathComponent("Drive Rescue")

    var drive: ExternalDrive? { drives.first { $0.id == selected } ?? drives.first }

    func refresh() async {
        let found = await Task.detached { ExternalDrive.current() }.value
        let wasMounted = drive?.mountPoint
        let now = Date()
        for d in found {
            if let last = lastRead[d.id], now.timeIntervalSince(last.at) > 0.5 {
                readRate[d.id] = max(0, Double(d.bytesRead - last.bytes) / now.timeIntervalSince(last.at))
            }
            lastRead[d.id] = (d.bytesRead, now)
            if !d.mounted, isChecking(d) {
                sawChecking.insert(d.id)
                if checkingSince[d.id] == nil { checkingSince[d.id] = now }
            }
            if d.mounted { checkingSince[d.id] = nil }
            if d.mounted, sawChecking.remove(d.id) != nil, !d.readOnly {
                message = "\(d.title) passed the check and is open — use it normally."
            }
        }
        drives = found
        if selected == nil || !found.contains(where: { $0.id == selected }) { selected = found.first?.id }
        // Just mounted (or switched drive): start at its root.
        if let root = drive?.mountPoint, root != wasMounted || folder == nil || !(folder!.path.hasPrefix(root.path)) {
            await open(root)
        } else if drive?.mountPoint == nil {
            folder = nil; entries = []
        }
    }

    /// Reading steadily while unmounted: that's macOS checking it.
    func isChecking(_ d: ExternalDrive) -> Bool {
        !d.mounted && (readRate[d.id] ?? 0) > 200_000
    }

    /// Let macOS check the drive and mount it the normal way (read-write, in Finder). `diskutil
    /// mount` returns once the check is done, however long that takes; the drive itself is
    /// only touched by macOS's own checker.
    func checkAndOpen() {
        guard let d = drive, let partition = d.partition, partition.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
        opening.insert(d.id)
        sawChecking.insert(d.id)
        message = nil
        Task {
            let ok = await Task.detached {
                Shell.run("/usr/sbin/diskutil", ["mount", partition], timeout: 24 * 3600) != nil
            }.value
            opening.remove(d.id)
            await refresh()
            if !ok, self.drives.first(where: { $0.id == d.id })?.mounted != true {
                message = "macOS couldn't open it. Unplug it, plug it straight into the Mac (no hub), and try again."
            }
        }
    }

    func open(_ url: URL) async {
        folder = url
        results = nil
        loading = true
        entries = await Task.detached { Self.list(url) }.value
        loading = false
    }

    /// New File, Add Files and the notepad work only on a drive macOS opened normally (read-write) —
    /// never on one opened read-only to rescue files.
    var canWrite: Bool { drive?.mounted == true && drive?.readOnly == false && folder != nil }

    func newFile(_ kind: Notes.Kind) {
        guard canWrite, let folder else { return }
        do {
            let url = try Notes.create(kind, in: folder)
            Task { await open(folder) }
            NoteWindows.shared.open(url)
        } catch {
            message = "Couldn't make a new file: \(error.localizedDescription)"
        }
    }

    /// Copy files from the Mac onto the drive, into the folder you're looking at. Nothing is replaced.
    func add(_ files: [URL]) {
        guard canWrite, let folder, !files.isEmpty else { return }
        message = "Copying \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) items") to the drive…"
        Task {
            let result = await Task.detached { Notes.add(files, into: folder) }.value
            message = result.skipped.isEmpty ? "Copied \(result.copied) to \(folder.lastPathComponent)."
                : "Copied \(result.copied). Skipped \(result.skipped.count) already there or unreadable: \(result.skipped.prefix(3).joined(separator: ", "))"
            await open(folder)
        }
    }

    func pickFilesToAdd() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Copy to Drive"
        panel.message = "These are copied onto the drive. The originals stay on your Mac."
        if panel.runModal() == .OK { add(panel.urls) }
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
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.drives.isEmpty {
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.questionmark").font(.system(size: 28)).foregroundStyle(Theme.textTertiary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No USB drive plugged in").font(.system(size: 15, weight: .semibold))
                            Text("Plug one in — it shows up here even before Finder sees it.")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
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
                        Image(systemName: "externaldrive.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.color(for: .documents))
                    }
                    .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(d.title).font(.system(size: 17, weight: .bold, design: .rounded))
                        HStack(spacing: 8) {
                            Text(d.bytes.gb).font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            Badge(text: d.link.label, color: d.link.isBottleneck ? Theme.review : Theme.safe)
                            stateBadge(d)
                        }
                    }
                    Spacer()
                    actions(d)
                }
                if d.link.isBottleneck, !model.isChecking(d) {
                    Text("Connected at USB 2.0 speed — about 30 MB/s, roughly 2 minutes per GB. This drive can do far more: try a 10 Gb/s USB-C cable, the other port, or clean the drive's USB-C socket.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if !d.mounted { checkStatus(d) }
                if d.mounted, !d.readOnly, d.format == .windows {
                    note("Eject before unplugging. exFAT keeps no journal, so a drive pulled out without Eject gets checked in full next time — that's the long wait. Used only with Macs? APFS recovers in seconds: copy your files off, then reformat it in Disk Utility.")
                }
            }
        }
    }

    /// Not open yet: what macOS is doing, how far it got, and what helps.
    @ViewBuilder func checkStatus(_ d: ExternalDrive) -> some View {
        let checking = model.isChecking(d)
        if checking {
            HStack(spacing: 8) {
                // A symbol, not ProgressView: renders (ImageRenderer) can't draw a spinner.
                Image(systemName: "checkmark.shield").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.review)
                    .symbolEffect(.pulse, isActive: !snapshot)
                Text(checkLine(d))
                    .font(Theme.number(13, weight: .semibold))
            }
            if d.canSkipCheck {
                note("macOS is checking the drive before it shows in Finder. Over a slow link that can take a long time. Open it read-only now to skip the wait — nothing on the drive can be changed that way.")
            } else {
                note("It was unplugged without Eject, so macOS checks the whole drive before opening it — this macOS won't open it before that, not even read-only. The fuller the drive, the longer it takes. When the check ends it opens by itself, ready to use normally. Keep it plugged in: unplugging starts the check over.")
            }
            if d.link.isBottleneck {
                note("The check is slow because the cable or port runs at USB 2.0. With the drive's own USB-C cable straight into the Mac it runs about 10× faster — swapping restarts the check, so it's worth doing early.")
            }
        } else if model.opening.contains(d.id) {
            note("Asking macOS to check and open it…")
        } else if d.partition != nil {
            note("Not open. Check & open lets macOS check it and open it normally — read-write, in Finder.")
        }
    }

    func checkLine(_ d: ExternalDrive) -> String {
        var line = "Checked \(d.bytesRead.gb) so far · \(Int((model.readRate[d.id] ?? 0) / 1_000_000)) MB/s"
        if let since = model.checkingSince[d.id], Date().timeIntervalSince(since) >= 60 {
            line += " · for \(Self.duration(since: since))"
        }
        return line
    }

    static func duration(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : "\(s / 60) min"
    }

    func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder func stateBadge(_ d: ExternalDrive) -> some View {
        if d.mounted {
            Badge(text: d.readOnly ? "Open · read-only" : "Open", color: Theme.safe)
        } else if model.isChecking(d) || (d.macOSChecking && model.readRate[d.id] == nil) {
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
            HStack(spacing: 8) {
                if d.canSkipCheck, model.isChecking(d) || d.macOSChecking {
                    Button {
                        Task { await model.mountReadOnly() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.mounting { ProgressView().controlSize(.small) }
                            Text(model.mounting ? "Opening…" : "Open now (read-only)")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.mounting)
                }
                if !model.isChecking(d), d.partition != nil {
                    Button {
                        model.checkAndOpen()
                    } label: {
                        HStack(spacing: 6) {
                            if model.opening.contains(d.id) { ProgressView().controlSize(.small) }
                            Text(model.opening.contains(d.id) ? "Opening…" : "Check & open")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.opening.contains(d.id))
                }
            }
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
                        .textFieldStyle(.plain).font(.system(size: 13)).frame(width: 180)
                        .onSubmit { Task { await model.search() } }
                    if model.results != nil {
                        Button { model.query = ""; model.results = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(0.06)))
                if model.canWrite, model.results == nil {
                    if snapshot {
                        Label("New File", systemImage: "doc.badge.plus").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    } else {
                        Menu {
                            ForEach(Notes.Kind.allCases) { kind in
                                Button("\(kind.title) (.\(kind.rawValue))") { model.newFile(kind) }
                            }
                        } label: {
                            Label("New File", systemImage: "doc.badge.plus").font(.system(size: 12, weight: .medium))
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Make a new text file on the drive and write in it in Headroom")
                    }
                    Button { model.pickFilesToAdd() } label: { Label("Add Files…", systemImage: "plus") }
                        .buttonStyle(GhostButtonStyle())
                        .help("Copy files from your Mac onto the drive, here. Or drop them on the list")
                }
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
                    Text(model.results != nil ? "Nothing matches." : model.canWrite ? "This folder is empty. Drop files here to copy them onto the drive, or make a New File."
                         : "This folder is empty.").foregroundStyle(Theme.textSecondary).padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            .modifier(DriveDrop(model: model, targeted: $dropping))
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accent.opacity(0.06)))
                        .overlay(Label("Copy onto \(model.folder?.lastPathComponent ?? "the drive")", systemImage: "plus.circle.fill")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent))
                        .allowsHitTesting(false)
                }
            }
            Text("Copies go to ~/Drive Rescue. Re-copying skips files already copied whole, so an interrupted copy just picks up where it stopped.")
                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
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
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill((e.isFolder ? Theme.color(for: .documents) : Theme.keep).opacity(0.16))
                Image(systemName: e.isFolder ? "folder.fill" : symbol(e.url)).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(e.isFolder ? Theme.color(for: .documents) : Theme.textSecondary)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if model.results != nil, let root = model.drive?.mountPoint {
                    Text(String(e.url.deletingLastPathComponent().path.dropFirst(root.path.count)).ifEmpty("/"))
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                } else if let m = e.modified {
                    Text("changed \(m.ago)").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 12)
            if !e.isFolder { Text(e.bytes.gb).font(Theme.number(13, weight: .medium)).foregroundStyle(Theme.textSecondary) }
            if e.isFolder {
                Button("Open") { Task { await model.open(e.url) } }.buttonStyle(GhostButtonStyle())
            } else if model.canWrite, Notes.canEdit(e.url) {
                Button("Edit") { NoteWindows.shared.open(e.url) }.buttonStyle(GhostButtonStyle())
            } else {
                Button("Preview") { NSWorkspace.shared.open(e.url) }.buttonStyle(GhostButtonStyle())
            }
            Button("Copy to Mac") { model.copy(e.url) }.buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if e.isFolder { Task { await model.open(e.url) } }
            else if model.canWrite, Notes.canEdit(e.url) { NoteWindows.shared.open(e.url) }
        }
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

/// Files dropped on a drive's folder list are copied onto it (renders skip drop targets).
struct DriveDrop: ViewModifier {
    @ObservedObject var model: DrivesModel
    var targeted: Binding<Bool>
    @Environment(\.snapshotMode) private var snapshot

    @ViewBuilder func body(content: Content) -> some View {
        if snapshot || !model.canWrite || model.results != nil {
            content
        } else {
            content.dropDestination(for: URL.self) { urls, _ in
                model.add(urls.filter(\.isFileURL))
                return true
            } isTargeted: { targeted.wrappedValue = $0 }
        }
    }
}

import SwiftUI
import AppKit
import HeadroomCore

/// Every app with everything it keeps on disk. Uninstall moves the app AND its leftovers to
/// the Trash — recoverable until you empty it.
struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @State private var sort: Sort = .size
    @State private var expanded: String?
    @State private var query = ""
    @State private var confirming = false
    @State private var working = false

    enum Sort: String, CaseIterable { case size = "Size", unused = "Least used", name = "Name" }

    var sorted: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let apps = q.isEmpty ? model.apps : model.apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        switch sort {
        case .size: return apps
        case .unused: return apps.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    var chosen: [InstalledApp] { model.apps.filter { model.selectedApps.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                let total = model.apps.reduce(0) { $0 + $1.totalSize }
                let data = model.apps.reduce(0) { $0 + $1.dataSize }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.apps.count) apps · \(total.gb)").font(Theme.number(20, weight: .bold))
                    Text("\(data.gb) of that is data apps keep in your Library").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                let selectable = sorted.filter { !$0.isApple }
                let allOn = !selectable.isEmpty && selectable.allSatisfy { model.selectedApps.contains($0.id) }
                Button(allOn ? "Deselect all" : "Select all") {
                    if allOn { model.selectedApps.subtract(selectable.map(\.id)) } else { model.selectedApps.formUnion(selectable.map(\.id)) }
                }
                .buttonStyle(GhostButtonStyle())
                .keyboardShortcut("a", modifiers: .command)
                .disabled(selectable.isEmpty)
                SearchField(text: $query, prompt: "Find an app").frame(width: 200)
                HStack(spacing: 4) {
                    ForEach(Sort.allCases, id: \.self) { s in
                        Button(s.rawValue) { sort = s }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(sort == s ? Theme.inverseText : Theme.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(sort == s ? Theme.textPrimary : Color.clear))
                    }
                }
                .padding(3)
                .background(Capsule().fill(Theme.fill(0.06)))
            }
            if case .scanning(let label) = model.appsPhase, model.apps.isEmpty {
                Card { Text(label).foregroundStyle(Theme.textSecondary) }
                Spacer()
            } else {
                Scrolling {
                    Card(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(sorted) { app in
                                AppRow(app: app, expanded: expanded == app.id) {
                                    withAnimation(.spring(response: 0.35)) { expanded = expanded == app.id ? nil : app.id }
                                }
                                if app.id != sorted.last?.id { Divider().overlay(Theme.hairline).padding(.leading, 66) }
                            }
                        }
                    }
                    .padding(.bottom, 90)
                }
            }
        }
        .overlay(alignment: .bottom) { bar }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.selectedApps.isEmpty)
        .confirmSheet(chosen.count == 1 ? "Uninstall \(chosen.first?.name ?? "")?" : "Uninstall \(chosen.count) apps?",
                            isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    working = true
                    let r = await model.uninstallSelectedApps()
                    working = false
                    model.show("Moved \(r.trashed.count) items (\(r.bytes.gb)) to the Trash — put them back from Activity"
                               + (r.failed.isEmpty ? "" : " · \(r.failed.count) skipped: \(r.failed[0].1)"),
                               failed: r.trashed.isEmpty)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(chosen.map(\.name).prefix(6).joined(separator: ", ") + (chosen.count > 6 ? " and \(chosen.count - 6) more" : "")
                 + " — \(chosen.reduce(0) { $0 + $1.totalSize }.gb) with their data, moved to the Trash. Quit them first; running apps are skipped.")
        }
    }

    @ViewBuilder var bar: some View {
        let chosen = self.chosen
        if !chosen.isEmpty {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text("\(chosen.count) \(chosen.count == 1 ? "app" : "apps") · \(chosen.reduce(0) { $0 + $1.totalSize }.gb)").font(Theme.number(15, weight: .semibold))
                }
                Spacer()
                Text("Recoverable from the Trash until you empty it").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                Button("Clear") { model.selectedApps = [] }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.escape, modifiers: [])
                Button { confirming = true } label: { Label(working ? "Uninstalling…" : "Uninstall…", systemImage: "trash") }
                    .buttonStyle(PrimaryButtonStyle(tint: Theme.critical))
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(working)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surfaceRaised.opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
            )
            .padding(4)
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var model: AppModel
    var app: InstalledApp
    var expanded: Bool
    var onExpand: () -> Void

    var body: some View {
        let on = model.selectedApps.contains(app.id)
        let stale = app.lastUsed.map { $0 < Date().addingTimeInterval(-60 * 86_400) } ?? false
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    if on { model.selectedApps.remove(app.id) } else { model.selectedApps.insert(app.id) }
                } label: { CheckCircle(on: on, tint: Theme.critical, disabled: app.isApple) }
                    .buttonStyle(.plain).disabled(app.isApple)
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.name).font(.system(size: 13.5, weight: .semibold))
                        if let v = app.version { Text(v).font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
                        if app.isApple { Badge(text: "macOS", color: Theme.keep) }
                    }
                    HStack(spacing: 10) {
                        Text("App \(app.appSize.allocated.gb)")
                        if app.dataSize > 0 { Text("Data \(app.dataSize.gb)").foregroundStyle(Theme.color(for: .appData)) }
                        Text(app.lastUsed.map { app.lastUsedIsExact ? "opened \($0.ago)" : "active \($0.ago)" } ?? "usage unknown")
                            .foregroundStyle(app.lastUsed != nil && stale ? Theme.review : Theme.textTertiary)
                            .help(app.lastUsedIsExact ? "From Spotlight" : "Inferred from when the app last changed its own data")
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(app.totalSize.gb).font(Theme.number(14, weight: .semibold))
                Button(action: onExpand) {
                    Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                        .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .opacity(app.leftovers.isEmpty ? 0.2 : 1)
                .disabled(app.leftovers.isEmpty)
            }
            // A click anywhere on the row selects it, like a list — not only the little circle.
            .contentShape(Rectangle())
            .onTapGesture {
                guard !app.isApple else { return }
                if on { model.selectedApps.remove(app.id) } else { model.selectedApps.insert(app.id) }
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(app.leftovers) { l in
                        HStack {
                            Text(l.kind).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary).frame(width: 130, alignment: .leading)
                            Text(l.url.tildePath).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(l.size.allocated.gb).font(Theme.number(11.5, weight: .medium))
                            Button { model.reveal([l.url]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .padding(.leading, 84).padding(.trailing, 18).padding(.bottom, 12)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: LibraryModel
    @Environment(\.snapshotMode) private var snapshot
    var launchAtLogin: Binding<Bool>
    @State private var clearing: Clearing?
    @AppStorage("look") private var look: Look = .playful
    @AppStorage("appearance") private var appearance: Appearance = .system
    @AppStorage("menuBarDownloads") private var menuBarDownloads = true
    @AppStorage("readTextInImages") private var readText = true
    @AppStorage("autoTrashInstallers") private var autoTrashInstallers = false
    @AppStorage("autoFileScreenshots") private var autoFileScreenshots = false

    enum Clearing: String, Identifiable {
        case activity, history, neverTouch
        var id: String { rawValue }
        var title: String {
            switch self {
            case .activity: "Clear the activity list?"
            case .history: "Clear space history?"
            case .neverTouch: "Reset the never-touch list?"
            }
        }
        var done: String {
            switch self {
            case .activity: "Activity list cleared"
            case .history: "Space history cleared"
            case .neverTouch: "Never-touch list reset"
            }
        }
        var message: String {
            switch self {
            case .activity: "Headroom forgets what it removed. Trashed items stay in the Trash, but Put Back won't be offered for them any more."
            case .history: "The free-space chart, the growth alerts and “what grew” start over from the next scan."
            case .neverTouch: "Every folder on the list becomes eligible again. Nothing is deleted — scans just see them again."
            }
        }
    }

    var body: some View {
        settingsBody
            .confirmSheet(clearing?.title ?? "", isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), presenting: clearing) { c in
                Button("Clear", role: .destructive) {
                    switch c {
                    case .activity: model.clearActivityLog()
                    case .history: model.clearHistory()
                    case .neverTouch: model.clearNeverTouch()
                    }
                    model.show(c.done)
                }
                Button("Cancel", role: .cancel) {}
            } message: { c in Text(c.message) }
    }

    var settingsBody: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle(title: "Look", trailing: "⌃⌘T switches")
                        HStack(spacing: 12) {
                            ForEach(Look.allCases) { l in lookChoice(l) }
                        }
                        HStack(spacing: 8) {
                            Text("Appearance").font(.system(size: 13, weight: .medium))
                            Spacer()
                            ForEach(Appearance.allCases) { a in Pill(title: a.title, on: appearance == a) { appearance = a } }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle(title: "Your files")
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Quick Search").font(.system(size: 13, weight: .medium))
                                Text("Files, apps, commands and sums in one panel over any app. ↩ opens, ⌘K shows every action, ⌘I the details, ⌘1–9 picks a row.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            ShortcutRecorder()
                        }
                        toggleRow("Recent downloads in the menu bar", "The last ten files that landed in Downloads, with thumbnails — drag one straight into another app.",
                                  on: $menuBarDownloads)
                        toggleRow("Read the text in screenshots and photos",
                                  "So you can search for the words in them (that Wi-Fi password, a tracking number). Done on this Mac with Apple's Vision — nothing is uploaded. \(library.recognized.count) read so far.",
                                  on: $readText)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle(title: "Automatic clean up", trailing: "off until you turn it on")
                        toggleRow("Move old installers to the Trash",
                                  "Disk images and packages in Downloads you haven't touched for 30 days. At most every 6 hours; each run is in Activity, with Put Back.",
                                  on: $autoTrashInstallers)
                        toggleRow("File screenshots into a folder per month",
                                  "Screenshots older than a day move from \(AutoRules.screenshotFolder().tildePath) into Screenshots/2026-10 and so on. Nothing is deleted; Put Back moves them home.",
                                  on: $autoFileScreenshots)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle(title: "Watching")
                        toggleRow("Tell me before space runs out", "A notification when free space drops below the threshold, or falls fast.",
                                  on: $model.notificationsEnabled)
                        sliderRow("Warn below", value: $model.lowSpaceThresholdGB, range: 5...60, unit: "GB")
                        toggleRow("Show in the notch", "The live readout around your camera notch. Hover it for details.", on: $model.showNotch)
                        toggleRow("Open at login", "Headroom runs quietly in the notch and menu bar.", on: launchAtLogin)
                        toggleRow("Free up space automatically when it runs low",
                                  "When free space drops below this, Headroom removes only the safe items on its own (at most every 6 hours) and tells you exactly what went. Never anything you should check first.",
                                  on: $model.autoReclaim)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SectionTitle(title: "Never touch")
                            Spacer()
                            Button("Add folder…") { addExclusion() }.buttonStyle(GhostButtonStyle())
                        }
                        Text("Headroom never suggests, cleans or deletes anything at, inside or containing these — even from the map. Right-click any item to add it.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        if model.excluded.isEmpty {
                            Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        }
                        ForEach(model.excluded, id: \.self) { path in
                            HStack {
                                Image(systemName: "hand.raised.fill").foregroundStyle(Theme.review).font(.system(size: 11))
                                Text(URL(fileURLWithPath: path).tildePath).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Remove") { model.unexclude(path) }.buttonStyle(GhostButtonStyle())
                            }
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle(title: "Projects")
                        let days = Binding(get: { Double(model.staleDays) }, set: { model.staleDays = Int($0) })
                        sliderRow("Idle projects after", value: days, range: 1...60, unit: "days")
                        Text("Build output of projects you haven't touched for this long is marked safe. Active projects always ask first.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Text("Searching: " + ProjectScanner.defaultRoots().map(\.tildePath).joined(separator: ", "))
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Full Disk Access", trailing: model.hasFullDiskAccess ? "granted" : "not granted")
                        Text("Without it macOS hides a few folders (Mail, Safari, some app data), shown as “Other” on the map, and blocks emptying the Trash and removing some app data.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        if !model.hasFullDiskAccess {
                            Button("Open Privacy & Security") { AppModel.openFullDiskAccessSettings() }
                                .buttonStyle(GhostButtonStyle())
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Headroom's data", trailing: model.ownDataBytes.gb)
                        Text("What Headroom remembers on this Mac: the activity list, free-space history, folder growth, the file index, the text read from images and what you open from Quick Search. Clearing it never touches your files.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button("Clear activity list…") { clearing = .activity }.buttonStyle(GhostButtonStyle())
                                .disabled(model.activity.entries.isEmpty)
                            Button("Clear space history…") { clearing = .history }.buttonStyle(GhostButtonStyle())
                            Button("Reset never-touch list…") { clearing = .neverTouch }.buttonStyle(GhostButtonStyle())
                                .disabled(model.excluded.isEmpty)
                            Button("Forget text read from images") { library.text.clear(); library.recognized = [:]; model.show("Recognised text forgotten") }
                                .buttonStyle(GhostButtonStyle()).disabled(library.recognized.isEmpty)
                            Button("Reset Quick Search ranking") { library.forgetQuickHistory(); model.show("Quick Search forgot what you open") }
                                .buttonStyle(GhostButtonStyle())
                            Spacer()
                            Button("Show in Finder") { model.reveal([HeadroomPaths.support]) }.buttonStyle(GhostButtonStyle())
                        }
                    }
                }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionTitle(title: "Updates", trailing: "version \(Updates.currentVersion)")
                        HStack(spacing: 10) {
                            Button("Check for updates") { Task { await model.checkForUpdates(manual: true) } }
                                .buttonStyle(GhostButtonStyle())
                            if let release = model.update {
                                Button("Get Headroom \(release.version)") { NSWorkspace.shared.open(release.url) }
                                    .buttonStyle(PrimaryButtonStyle())
                            }
                            if let status = model.updateStatus {
                                Text(status).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                        }
                        if let notes = model.update?.notes {
                            Text(notes).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if model.history.totalFreed > 0 {
                    Card {
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(Theme.safe)
                            Text("Headroom has freed up \(model.history.totalFreed.gb) for you so far.").font(.system(size: 13))
                        }
                    }
                }
            }
        }
    }

    func lookChoice(_ l: Look) -> some View {
        Button { look = l } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach([FileKind.image, .video, .audio, .document], id: \.self) { k in
                        let saved = Theme.look
                        let _ = { Theme.look = l }()
                        let (top, bottom) = Theme.shelf(for: k)
                        let _ = { Theme.look = saved }()
                        FolderShape(tabHeight: 6, radius: 6).fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                            .frame(width: 34, height: 26)
                    }
                }
                Text(l.title).font(.system(size: 13, weight: .semibold))
                Text(l == .playful ? "Colourful and friendly" : "Quiet black, white and grey").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(look == l ? Theme.accent : Theme.hairline, lineWidth: look == l ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Never Touch"
        if panel.runModal() == .OK { model.exclude(panel.urls) }
    }

    func toggleRow(_ title: String, _ detail: String, on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Capsule().fill(on.wrappedValue ? Theme.safe : Theme.fill(0.15))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: on.wrappedValue ? .trailing : .leading) {
                        Circle().fill(.white).padding(2.5)
                    }
                    .animation(.spring(response: 0.25), value: on.wrappedValue)
            }
        }
        .buttonStyle(.plain)
    }

    func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13.5, weight: .medium))
            if snapshot {
                // ImageRenderer can't draw a Slider: the same track, drawn by hand.
                GeometryReader { geo in
                    let f = (value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill(0.12)).frame(height: 4)
                        Capsule().fill(Theme.safe).frame(width: geo.size.width * f, height: 4)
                        Circle().fill(.white).frame(width: 18, height: 18).shadow(radius: 2).offset(x: geo.size.width * f - 9)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 20)
            } else {
                Slider(value: value, in: range, step: 1).tint(Theme.safe)
            }
            Text("\(Int(value.wrappedValue)) \(unit)").font(Theme.number(13, weight: .medium)).frame(width: 64, alignment: .trailing)
        }
    }
}

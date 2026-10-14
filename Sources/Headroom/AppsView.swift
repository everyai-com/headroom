import SwiftUI
import AppKit
import HeadroomCore

/// Every app with everything it keeps on disk. Uninstall moves the app AND its leftovers to
/// the Trash — recoverable until you empty it.
struct AppsView: View {
    @EnvironmentObject var model: AppModel
    @State private var sort: Sort = .size
    @State private var expanded: String?
    @State private var result: String?

    enum Sort: String, CaseIterable { case size = "Size", unused = "Least used", name = "Name" }

    var sorted: [InstalledApp] {
        switch sort {
        case .size: model.apps
        case .unused: model.apps.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: model.apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

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
                HStack(spacing: 4) {
                    ForEach(Sort.allCases, id: \.self) { s in
                        Button(s.rawValue) { sort = s }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(sort == s ? Color.black : Theme.textSecondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(sort == s ? Color.white : Color.clear))
                    }
                }
                .padding(3)
                .background(Capsule().fill(Color.white.opacity(0.06)))
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
    }

    @ViewBuilder var bar: some View {
        let chosen = model.apps.filter { model.selectedApps.contains($0.id) }
        if !chosen.isEmpty || result != nil {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result == nil ? "Selected" : "Done").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text(result ?? "\(chosen.count) apps · \(chosen.reduce(0) { $0 + $1.totalSize }.gb)").font(Theme.number(15, weight: .semibold))
                }
                Spacer()
                if result == nil {
                    Text("Recoverable from the Trash until you empty it").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    Button {
                        Task {
                            let r = await model.uninstallSelectedApps()
                            result = "Moved \(r.trashed.count) items (\(r.bytes.gb)) to the Trash"
                                + (r.failed.isEmpty ? "" : " · \(r.failed.count) skipped")
                        }
                    } label: { Label("Move to Trash", systemImage: "trash") }
                        .buttonStyle(PrimaryButtonStyle(tint: Theme.critical))
                } else {
                    Button("OK") { result = nil }.buttonStyle(GhostButtonStyle())
                }
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
    @Environment(\.snapshotMode) private var snapshot
    var launchAtLogin: Binding<Bool>

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 18) {
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionTitle(title: "Watching")
                        toggleRow("Tell me before space runs out", "A notification when free space drops below the threshold, or falls fast.",
                                  on: $model.notificationsEnabled)
                        sliderRow("Warn below", value: $model.lowSpaceThresholdGB, range: 5...60, unit: "GB")
                        toggleRow("Show in the notch", "The live readout around your camera notch. Hover it for details.", on: $model.showNotch)
                        toggleRow("Open at login", "Headroom runs quietly in the notch and menu bar.", on: launchAtLogin)
                        toggleRow("Reclaim automatically when space is low",
                                  "Below the threshold, Headroom reclaims the safe set on its own (at most every 6 hours) and tells you exactly what went. Never anything marked review.",
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
                        Text("Headroom never suggests, reclaims or deletes anything at, inside or containing these — even from the map. Right-click any item to add it.")
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
                        Text("Without it macOS hides a few folders (Mail, Safari, some app containers), shown as “Other” on the map. Headroom never needs it to reclaim safely.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        if !model.hasFullDiskAccess {
                            Button("Open Privacy & Security") { AppModel.openFullDiskAccessSettings() }
                                .buttonStyle(GhostButtonStyle())
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
                            Text("Headroom has reclaimed \(model.history.totalFreed.gb) for you so far.").font(.system(size: 13))
                        }
                    }
                }
            }
        }
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
                Capsule().fill(on.wrappedValue ? Theme.safe : Color.white.opacity(0.15))
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
                        Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
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

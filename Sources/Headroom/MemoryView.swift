import SwiftUI
import AppKit
import HeadroomCore

/// What's holding your RAM, in plain words — and quitting it, safely. Headroom never "purges"
/// memory: macOS keeps spare RAM full of cache on purpose, and forcing it out only slows things down.
struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: Filter = .yours
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var confirm: (groups: [MemoryGroup], force: Bool)?
    @State private var expanded: String?
    @State private var working = false
    @Environment(\.snapshotMode) private var snapshot

    enum Filter: String, CaseIterable, Identifiable {
        case yours = "Everything", apps = "Apps", developer = "Dev servers & tools", system = "macOS"
        var id: String { rawValue }
    }

    var groups: [MemoryGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.memoryGroups.filter { g in
            switch filter {
            case .yours: g.kind != .system
            case .apps: g.kind == .app
            case .developer: g.kind == .developer
            case .system: g.kind == .system
            }
        }
        .filter { $0.footprint >= 20_000_000 }
        .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.processes.contains { $0.arguments.joined(separator: " ").lowercased().contains(q) } }
    }

    var selectedGroups: [MemoryGroup] { model.memoryGroups.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            advice
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { f in Pill(title: f.rawValue, on: filter == f) { filter = f } }
                Spacer()
                SearchField(text: $query, prompt: "Find an app").frame(width: 220)
            }
            let list = groups
            if model.memoryGroups.isEmpty {
                Card { HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Reading memory…").foregroundStyle(Theme.textSecondary) } }
            } else if list.isEmpty {
                EmptyState(symbol: "memorychip", title: "Nothing here", detail: "Nothing here is using much memory.")
            } else {
                Card(padding: 0) {
                    Scrolling {
                        LazyVStack(spacing: 0) {
                            ForEach(list.prefix(snapshot ? 9 : 200)) { g in
                                row(g)
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
        .task {
            // Live while the screen is open.
            while !Task.isCancelled {
                await model.refreshMemory()
                let live = Set(model.memoryGroups.map(\.id))
                selected = selected.filter(live.contains)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmSheet(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { c in
            Button(c.force ? "Force Quit" : "Quit", role: c.force ? .destructive : nil) {
                Task {
                    working = true
                    let message = await model.quit(c.groups, force: c.force)
                    working = false
                    selected.subtract(c.groups.map(\.id))
                    model.show(message, failed: message.hasPrefix("Couldn't"))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.force
                 ? "Ends them immediately. Anything unsaved in them is lost."
                 : "They close the normal way — apps ask you to save first. Frees about \(c.groups.reduce(0) { $0 + $1.footprint }.gb).")
        }
    }

    var confirmTitle: String {
        guard let c = confirm else { return "" }
        let what = c.groups.count == 1 ? c.groups[0].name : "\(c.groups.count) apps"
        return c.force ? "Force quit \(what)?" : "Quit \(what)?"
    }

    // MARK: Summary

    var pressureColor: Color {
        switch model.memory.pressure {
        case .normal: Theme.safe
        case .warning: Theme.review
        case .critical: Theme.critical
        }
    }

    var summary: some View {
        let m = model.memory
        return Card {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Badge(text: "Memory: \(m.pressure.label.lowercased())", color: pressureColor)
                        if m.swapUsed > 500_000_000 {
                            Badge(text: "\(m.swapUsed.gb) of disk used as extra memory", color: m.swapUsed > 4_000_000_000 ? Theme.review : Theme.keep)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(m.used.gb).font(Theme.number(40, weight: .bold))
                        Text("used of \(m.total.gb)").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                    Text(headline(m)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    SegmentedBar(segments: [
                        .init(id: "Apps", value: Double(m.app), color: Color(hex: 0x7C83FF)),
                        .init(id: "macOS", value: Double(m.wired), color: Color(hex: 0xFF8A65)),
                        .init(id: "Squeezed", value: Double(m.compressed), color: Color(hex: 0xFFC94D)),
                        .init(id: "Spare", value: Double(m.cached), color: Color(hex: 0x4FC3F7).opacity(0.55)),
                    ], total: Double(m.total))
                    .frame(height: 12)
                    HStack(spacing: 16) {
                        legend("Apps", m.app, Color(hex: 0x7C83FF), "Memory apps are using right now")
                        legend("macOS", m.wired, Color(hex: 0xFF8A65), "macOS itself — can't be freed")
                        legend("Squeezed", m.compressed, Color(hex: 0xFFC94D), "Squeezed by macOS so more fits")
                        legend("Spare", m.cached, Color(hex: 0x4FC3F7), "Kept ready to reuse — given back instantly when an app needs it")
                    }
                }
                Spacer(minLength: 0)
                ZStack {
                    GaugeRing(fraction: m.usedFraction, tint: pressureColor, lineWidth: 12)
                    VStack(spacing: 0) {
                        Text("\(Int(m.usedFraction * 100))%").font(Theme.number(28, weight: .bold))
                        Text("in use").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 130, height: 130)
            }
        }
    }

    func headline(_ m: MemoryStatus) -> String {
        switch m.pressure {
        case .normal:
            return "Your Mac has enough memory. macOS keeps spare memory busy on purpose — there's nothing to clean."
        case .warning:
            return "Memory is getting tight, so macOS is squeezing apps and borrowing disk space. Quitting an app you aren't using helps right away."
        case .critical:
            return "Your Mac is out of memory — apps will feel slow and may freeze. Quit something big below."
        }
    }

    func legend(_ label: String, _ bytes: Int64, _ color: Color, _ help: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Text(bytes.gb).font(Theme.number(12, weight: .semibold))
        }
        .help(help)
    }

    /// The biggest things you could quit, when it would actually help.
    @ViewBuilder var advice: some View {
        let m = model.memory
        let candidates = model.memoryGroups.filter { $0.kind != .system && model.quitRefusal($0) == nil && $0.footprint > 300_000_000 }
            .prefix(3)
        if (m.pressure > .normal || m.swapUsed > 3_000_000_000), !candidates.isEmpty {
            let list = Array(candidates)
            Card {
                HStack(spacing: 14) {
                    Image(systemName: "bolt.fill").foregroundStyle(pressureColor)
                        .frame(width: 36, height: 36).background(Circle().fill(pressureColor.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quitting \(list.map(\.name).joined(separator: ", ")) frees about \(list.reduce(0) { $0 + $1.footprint }.gb)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("The biggest things you're running that are safe to quit.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Quit them…") { confirm = (list, false) }.buttonStyle(PrimaryButtonStyle(tint: pressureColor))
                }
            }
        }
    }

    // MARK: Rows

    func row(_ g: MemoryGroup) -> some View {
        let refusal = model.quitRefusal(g)
        let on = selected.contains(g.id)
        let isOpen = expanded == g.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                CheckCircle(on: on, tint: Theme.review, disabled: refusal != nil)
                icon(g).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(g.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if g.processes.count > 1 {
                            Text("\(g.processes.count) parts").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        }
                        if g.kind == .developer { Badge(text: "Dev", color: Color(hex: 0xB388FF)) }
                    }
                    Text(ProcessExplainer.explain(g)).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(g.footprint.gb).font(Theme.number(15, weight: .semibold))
                        .foregroundStyle(g.footprint > 2_000_000_000 ? Theme.review : Theme.textPrimary)
                    if let start = g.oldestStart {
                        Text("running \(start.ago.replacingOccurrences(of: " ago", with: ""))").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(minWidth: 100, alignment: .trailing)
                if refusal == nil {
                    Button("Quit") { confirm = ([g], false) }.buttonStyle(GhostButtonStyle()).disabled(working)
                } else {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        .frame(width: 44).help(refusal ?? "")
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                guard refusal == nil else { expanded = isOpen ? nil : g.id; return }
                if on { selected.remove(g.id) } else { selected.insert(g.id) }
            }
            if isOpen { processes(g) }
        }
        .background(on ? Theme.review.opacity(0.06) : .clear)
        .contextMenu {
            if refusal == nil {
                Button("Quit") { confirm = ([g], false) }
                Button("Force Quit…") { confirm = ([g], true) }
                Divider()
            }
            Button(isOpen ? "Hide parts" : "Show parts") { expanded = isOpen ? nil : g.id }
            if let bundle = g.bundlePath { Button("Reveal App in Finder") { model.reveal([URL(fileURLWithPath: bundle)]) } }
            else if let path = g.processes.first?.path { Button("Reveal in Finder") { model.reveal([URL(fileURLWithPath: path)]) } }
            if let args = g.processes.first?.arguments, !args.isEmpty {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(args.joined(separator: " "), forType: .string)
                }
            }
            if let why = refusal { Divider(); Text(why) }
        }
    }

    func processes(_ g: MemoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(g.processes.prefix(30)) { p in
                HStack(spacing: 8) {
                    Text("\(p.pid)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary).frame(width: 52, alignment: .leading)
                    Text(p.arguments.isEmpty ? p.name : p.arguments.joined(separator: " ")).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(p.footprint.gb).font(Theme.number(11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.leading, 90).padding(.trailing, 18).padding(.bottom, 10)
    }

    @ViewBuilder func icon(_ g: MemoryGroup) -> some View {
        if let bundle = g.bundlePath, !snapshot {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundle)).resizable()
        } else {
            let (symbol, color): (String, Color) = switch g.kind {
            case .app: ("app.fill", Color(hex: 0x7C83FF))
            case .developer: ("terminal.fill", Color(hex: 0xB388FF))
            case .system: ("gearshape.fill", Theme.keep)
            case .background: ("gearshape.2.fill", Theme.textSecondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.16))
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
            }
        }
    }

    @ViewBuilder var selectionBar: some View {
        let picked = selectedGroups
        if !picked.isEmpty {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Text("\(picked.count) · \(picked.reduce(0) { $0 + $1.footprint }.gb) of memory").font(Theme.number(15, weight: .semibold))
                }
                Spacer()
                Button("Clear") { selected = [] }.buttonStyle(GhostButtonStyle()).keyboardShortcut(.escape, modifiers: [])
                Button("Force Quit…") { confirm = (picked, true) }.buttonStyle(GhostButtonStyle())
                    .keyboardShortcut("q", modifiers: [.command, .option])
                Button { confirm = (picked, false) } label: { Label(working ? "Quitting…" : "Quit \(picked.count == 1 ? picked[0].name : "\(picked.count)")", systemImage: "xmark.circle.fill") }
                    .buttonStyle(PrimaryButtonStyle(tint: Theme.review))
                    .disabled(working)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .background(FloatingBarBackground())
            .padding(.horizontal, 4).padding(.bottom, 4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

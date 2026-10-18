import SwiftUI
import AppKit
import HeadroomCore

/// AI tools: their models, caches and history on disk, what's running and which local servers are open.
@MainActor
final class AIModel: ObservableObject {
    @Published var tools: [AITool] = []
    @Published var loaded = false

    func refresh() async {
        tools = await Task.detached(priority: .userInitiated) { await AIUsage.scan() }.value
        loaded = true
    }

    var bytes: Int64 { tools.reduce(0) { $0 + $1.bytes } }
    var modelBytes: Int64 { tools.flatMap(\.items).filter { $0.symbol == "cube.box.fill" }.reduce(0) { $0 + $1.size.allocated } }
    var servers: [AIServer] { tools.flatMap(\.servers) }
}

extension AppModel {
    /// Remove AI items (models, caches) through `Cleaner`; one Activity entry each, Undo for what was trashed.
    func removeAI(_ plan: [Finding]) async -> (message: String, failed: Bool, undo: ActivityLog.Entry.ID?) {
        guard !plan.isEmpty else { return ("Nothing selected", true, nil) }
        let guardrail = self.guardrail
        let report = await Task.detached(priority: .userInitiated) { Cleaner(guardrail: guardrail).reclaim(plan) }.value
        let entries = ActivityLog.entries(for: plan, report: report)
        for e in entries { activity.record(e) }
        refreshVolume()
        let done = plan.filter { report.reclaimed.contains($0.id) }
        let bytes = done.reduce(0) { $0 + $1.size.allocated }
        let undo = entries.first { $0.kind == .trashed }?.id
        let what = done.count == 1 ? "“\(done[0].title)”" : "\(done.count) items"
        if let skip = report.skipped.first {
            let name = plan.first { $0.id == skip.id }?.title ?? skip.id
            return (done.isEmpty ? "Couldn't remove \(name): \(skip.reason)" : "Removed \(what) · couldn't remove \(name): \(skip.reason)",
                    done.isEmpty, undo)
        }
        return (undo != nil ? "Moved \(what) to the Trash (\(bytes.gb))" : "Removed \(what) — freed \(bytes.gb)", false, undo)
    }
}

struct AIView: View {
    @EnvironmentObject var model: AppModel
    @StateObject var ai: AIModel
    @State private var confirm: [Finding]?
    @State private var stopping: (tool: AITool, server: AIServer?)?
    @State private var working: Set<String> = []
    @Environment(\.snapshotMode) private var snapshot

    init(ai: AIModel? = nil) { _ai = StateObject(wrappedValue: ai ?? AIModel()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            summary
            if !ai.loaded {
                Card { HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Looking for AI tools…").foregroundStyle(Theme.textSecondary) } }
            } else if ai.tools.isEmpty {
                EmptyState(symbol: "sparkles", title: "No AI tools found",
                           detail: "Models from Ollama, LM Studio and Hugging Face, and data from Claude, Codex, Cursor and ChatGPT show up here.")
            } else {
                Scrolling {
                    VStack(spacing: 12) {
                        ForEach(ai.tools) { toolCard($0) }
                    }
                }
            }
        }
        .task { if !ai.loaded { await ai.refresh() } }
        .confirmSheet(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { items in
            Button(items.contains { $0.method == .trash } ? "Move to Trash" : "Remove", role: .destructive) { remove(items) }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            Text(items.map(\.detail).uniqued().joined(separator: "\n\n"))
        }
        .confirmSheet(stopTitle, isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            presenting: stopping) { s in
            Button("Stop") { stop(s.tool, server: s.server) }
            Button("Cancel", role: .cancel) {}
        } message: { s in
            Text(s.server.map { "Stops \($0.process), the local server at localhost:\($0.port). Anything using it stops working until it starts again." }
                 ?? "Quits \(s.tool.name) the normal way, so it can save first — everything of it that's running, including sessions open in Terminal.")
        }
    }

    // MARK: Summary

    var summary: some View {
        Card {
            HStack(alignment: .top, spacing: 28) {
                stat(ai.bytes.gb, "on disk across \(ai.tools.count) AI tools")
                stat(ai.modelBytes.gb, "in downloaded models")
                stat("\(ai.tools.filter(\.isRunning).count)", "running now")
                stat("\(ai.servers.count)", ai.servers.contains(where: \.exposed) ? "local servers · some open to your network" : "local servers listening")
                Spacer()
                Button { Task { ai.loaded = false; await ai.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }

    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(Theme.number(26, weight: .bold))
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Tools

    func toolCard(_ tool: AITool) -> some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: tool.symbol).font(.system(size: 18)).frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surfaceRaised))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(tool.name).font(.system(size: 15, weight: .semibold))
                            if tool.isRunning { Badge(text: "Running", color: Theme.safe) }
                        }
                        Text(subtitle(tool)).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Text(tool.bytes.gb).font(Theme.number(17, weight: .semibold))
                    if tool.isRunning, tool.processes.contains(where: { ProcessGuard.check($0) == .allowed }) {
                        Button("Quit") { stopping = (tool, nil) }.buttonStyle(GhostButtonStyle())
                    }
                }
                .padding(16)
                ForEach(tool.servers) { s in
                    Divider().overlay(Theme.hairline)
                    serverRow(tool, s)
                }
                ForEach(tool.items.prefix(snapshot ? 4 : 50)) { item in
                    Divider().overlay(Theme.hairline)
                    itemRow(item)
                }
            }
        }
    }

    func subtitle(_ tool: AITool) -> String {
        let models = tool.items.filter { $0.symbol == "cube.box.fill" }.count
        var parts: [String] = []
        if models > 0 { parts.append("\(models) model\(models == 1 ? "" : "s")") }
        let others = tool.items.count - models
        if others > 0 { parts.append("\(others) folder\(others == 1 ? "" : "s")") }
        if !tool.processes.isEmpty { parts.append("\(tool.processes.count) part\(tool.processes.count == 1 ? "" : "s") running") }
        return parts.joined(separator: " · ")
    }

    func serverRow(_ tool: AITool, _ s: AIServer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "network").foregroundStyle(s.exposed ? Theme.review : Theme.textSecondary).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("localhost:\(s.port)").font(.system(size: 13, weight: .medium, design: .monospaced))
                Text(s.exposed ? "\(s.process) · open to other devices on your network" : "\(s.process) · only this Mac can reach it")
                    .font(.system(size: 11.5)).foregroundStyle(s.exposed ? Theme.review : Theme.textTertiary)
            }
            Spacer()
            Button("Open") { NSWorkspace.shared.open(URL(string: "http://localhost:\(s.port)")!) }.buttonStyle(GhostButtonStyle())
            if let p = tool.processes.first(where: { $0.pid == s.pid }), ProcessGuard.check(p) == .allowed {
                Button("Stop") { stopping = (tool, s) }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    func itemRow(_ f: Finding) -> some View {
        HStack(spacing: 12) {
            Image(systemName: f.symbol == "cube.box.fill" ? "cube.box.fill" : roleSymbol(f))
                .foregroundStyle(Theme.color(for: f.safety)).frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(f.subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let used = f.lastUsed { Text(used.ago).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary) }
            Text(f.size.allocated.gb).font(Theme.number(13, weight: .semibold)).frame(width: 80, alignment: .trailing)
            Button { NSWorkspace.shared.activateFileViewerSelecting([f.paths[0]]) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(GhostButtonStyle()).help("Show in Finder")
            if working.contains(f.id) {
                ProgressView().controlSize(.small).frame(width: 96)
            } else if f.safety != .keep, f.method != .none {
                Button(actionLabel(f)) { confirm = [f] }.buttonStyle(GhostButtonStyle()).frame(width: 96)
            } else {
                Text(f.safety == .keep ? "Your data" : "Can't remove").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 96).help(f.detail)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    func roleSymbol(_ f: Finding) -> String {
        switch f.safety {
        case .safe: "arrow.triangle.2.circlepath"
        case .keep: "text.bubble.fill"
        default: "folder.fill"
        }
    }

    func actionLabel(_ f: Finding) -> String {
        switch f.method {
        case .deleteContents: "Empty"
        case .command: "Remove"
        default: "Trash"
        }
    }

    var confirmTitle: String {
        guard let items = confirm, let f = items.first else { return "" }
        switch f.method {
        case .deleteContents: return "Empty \(f.title) (\(f.size.allocated.gb))?"
        case .command: return "Remove \(f.title) (\(f.size.allocated.gb))?"
        default: return "Move \(f.title) to the Trash (\(f.size.allocated.gb))?"
        }
    }

    var stopTitle: String {
        guard let s = stopping else { return "" }
        return s.server.map { "Stop the server on port \($0.port)?" } ?? "Quit \(s.tool.name)?"
    }

    // MARK: Actions

    func remove(_ items: [Finding]) {
        working.formUnion(items.map(\.id))
        Task {
            let r = await model.removeAI(items)
            working.subtract(items.map(\.id))
            model.show(r.message, failed: r.failed, undo: r.undo)
            await ai.refresh()
        }
    }

    func stop(_ tool: AITool, server: AIServer?) {
        let targets = server.map { s in tool.processes.filter { $0.pid == s.pid } } ?? tool.processes.sorted { $0.pid > $1.pid }
        var failed: [String] = []
        for p in targets {
            if server == nil, let app = NSRunningApplication(processIdentifier: p.pid), app.bundleURL != nil {
                if !app.terminate() { failed.append(p.name) }
            } else if case .refused(let why) = ProcessGuard.stop(p, force: false) {
                failed.append("\(p.name): \(why)")
            }
        }
        model.show(failed.isEmpty ? (server.map { "Stopped the server on port \($0.port)" } ?? "Quit \(tool.name)")
                                  : "Couldn't stop \(failed[0])", failed: !failed.isEmpty)
        Task { try? await Task.sleep(for: .seconds(1)); await ai.refresh() }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

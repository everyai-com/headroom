import SwiftUI
import HeadroomCore

/// Keep awake in the menu bar: a session menu, a green dot while it holds the Mac awake.
struct KeepAwakeRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.awake == nil ? "moon.zzz" : "cup.and.saucer.fill")
                .foregroundStyle(model.awakeState == .awake && model.awake != nil ? Theme.safe : Theme.textSecondary).frame(width: 20)
            Text("Keep awake").font(.system(size: 13, weight: .medium))
            Spacer(minLength: 4)
            Text(model.awakeLabel).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Menu {
                Button("30 minutes") { model.startAwake(.timed, minutes: 30) }
                Button("1 hour") { model.startAwake(.timed, minutes: 60) }
                Button("2 hours") { model.startAwake(.timed, minutes: 120) }
                Button("Until I stop it") { model.startAwake(.untilStopped) }
                Button("While agents work") { model.startAwake(.whileAgents) }
                    .help("Claude Code, Codex, builds… — stays awake only while one runs")
                Divider()
                Toggle("Keep the display on", isOn: model.$awakeKeepDisplay)
                Toggle("Only on the charger", isOn: model.$awakeRequireCharger)
                Picker("Stop at battery", selection: model.$awakeBatteryCutoff) {
                    Text("Never").tag(0)
                    ForEach([10, 20, 30, 50], id: \.self) { Text("\($0)%").tag($0) }
                }
                if model.awake != nil { Divider(); Button("Stop") { model.stopAwake() } }
            } label: { Text(model.awake == nil ? "Start" : "Change") }
            .menuStyle(.borderlessButton).fixedSize()
        }
    }
}

/// Battery screen: which apps use the most energy, and what's stopping the Mac from sleeping.
struct EnergyCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshot
    @State private var quitting: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Using energy now", trailing: "CPU and wake-ups, last few seconds")
                if model.energy.isEmpty {
                    Text("Nothing is working hard right now.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(model.energy) { u in
                    HStack(spacing: 10) {
                        Text(u.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(String(format: "%.0f%% CPU · %.0f wake-ups/s", u.cpuPercent, u.wakeupsPerSecond))
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(u.impact > 50 ? Theme.critical : Theme.textTertiary)
                        if u.bundlePath != nil, u.name != "Headroom" {
                            Button("Quit") { quit(u) }.buttonStyle(.borderless).disabled(quitting != nil)
                        }
                    }
                }
                if !model.sleepBlockers.isEmpty {
                    Divider().overlay(Theme.hairline)
                    SectionTitle(title: "Keeping your Mac awake")
                    ForEach(model.sleepBlockers) { b in
                        HStack(spacing: 10) {
                            Image(systemName: b.display ? "display" : "moon.zzz").foregroundStyle(Theme.textSecondary).frame(width: 18)
                            Text(b.process).font(.system(size: 13, weight: .medium))
                            Text(b.name).font(.system(size: 12)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                            Spacer(minLength: 6)
                            if let since = b.since {
                                Text("for \(since.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)).replacingOccurrences(of: " ago", with: ""))")
                                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    Text("While these hold on, your Mac won't sleep when idle — quit or pause them when you leave it on battery.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .task {
            guard !snapshot else { return }
            while !Task.isCancelled {
                await model.measureEnergy()
                try? await Task.sleep(for: .seconds(7))
            }
        }
    }

    /// Quit through ProcessGuard like the Memory screen (apps get to save).
    func quit(_ u: Energy.Use) {
        let procs = ProcessScanner.snapshot(includeArguments: false)
        guard let g = ProcessScanner.groups(procs).first(where: { $0.id == u.id }) else { return }
        quitting = u.id
        Task { _ = await model.quit([g], force: false); quitting = nil; await model.measureEnergy() }
    }
}

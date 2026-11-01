import SwiftUI
import AppKit
import Charts
import HeadroomCore

/// The battery add-on: charge, health, heat and where the watts go — live — plus the health trend and a
/// monthly recap card to share. Read-only: Headroom never changes charging (macOS has its own limit in
/// System Settings › Battery › Charging, which the tips point to).
struct BatteryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshot
    @State private var lastMonth = false

    var body: some View {
        if let b = model.battery {
            Scrolling {
                VStack(alignment: .leading, spacing: 14) {
                    summary(b)
                    HStack(alignment: .top, spacing: 14) {
                        PowerFlowCard(b: b)
                        tips(b)
                    }
                    EnergyCard()
                    trend
                    recap
                }
            }
            .task {
                // Live while the screen is open; the 30 s tick keeps the record.
                while !Task.isCancelled, !snapshot {
                    model.refreshBattery()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } else {
            EmptyState(symbol: "powerplug", title: "No battery", detail: "This Mac runs from the wall — there's no battery to look after.")
        }
    }

    // MARK: Summary

    func summary(_ b: BatteryStatus) -> some View {
        Card {
            HStack(alignment: .center, spacing: 24) {
                ZStack {
                    GaugeRing(fraction: Double(b.percent) / 100, tint: chargeColor(b), lineWidth: 12)
                    VStack(spacing: 0) {
                        Text("\(b.percent)%").font(Theme.number(26, weight: .bold))
                        Image(systemName: b.pluggedIn ? "bolt.fill" : "battery.75percent")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Badge(text: stateText(b), color: chargeColor(b))
                        if b.hot { Badge(text: "Hot", color: Theme.critical) }
                    }
                    Text(headline(b)).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 28) {
                        stat("Health", "\(b.healthPercent)%", b.health < 0.8 ? Theme.critical : b.health < 0.85 ? Theme.review : Theme.safe,
                             "Holds \(b.maxCapacity.formatted()) of \(b.designCapacity.formatted()) mAh when full")
                        stat("Cycles", "\(b.cycles)", Theme.textPrimary, "of \(b.designCycles) Apple rates it for")
                        stat("Temperature", String(format: "%.1f °C", b.temperature), b.hot ? Theme.critical : Theme.textPrimary,
                             b.hot ? "Hot — heat wears it fastest" : "Comfortable")
                        if let w = b.adapterWatts {
                            stat("Charger", "\(w) W", w < 30 ? Theme.review : Theme.textPrimary, b.adapterName ?? "Plugged in")
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    func stat(_ title: String, _ value: String, _ color: Color, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
            Text(value).font(Theme.number(20, weight: .bold)).foregroundStyle(color)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .help(detail)
    }

    func chargeColor(_ b: BatteryStatus) -> Color {
        b.percent <= 10 && !b.pluggedIn ? Theme.critical : b.percent <= 20 && !b.pluggedIn ? Theme.review : Theme.safe
    }

    func stateText(_ b: BatteryStatus) -> String {
        switch b.flow {
        case .charging: "Charging"
        case .held: b.percent >= 99 ? "Full, on the charger" : "Not charging"
        case .onBattery: "On battery"
        case .slowCharger: "Charger can't keep up"
        }
    }

    func headline(_ b: BatteryStatus) -> String {
        switch b.flow {
        case .charging: b.minutesToFull.map { "Full in about \(duration($0))." } ?? "Charging."
        case .held: b.percent >= 99 ? "The charger is running the Mac and the battery is resting full." : "The charger is running the Mac; macOS is holding the charge here."
        case .onBattery: b.minutesToEmpty.map { "About \(duration($0)) left at this pace." } ?? "Running on battery."
        case .slowCharger: "Plugged in, but the Mac uses more than this charger gives, so the battery is draining slowly."
        }
    }

    func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    // MARK: Tips

    func tips(_ b: BatteryStatus) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Worth knowing")
                ForEach(BatteryTip.tips(b, month: model.batteryLog.month(containing: .now))) { tip in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: tip.level == .good ? "checkmark.circle.fill" : tip.level == .note ? "info.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(tip.level == .good ? Theme.safe : tip.level == .note ? Theme.review : Theme.critical)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tip.title).font(.system(size: 13, weight: .semibold))
                            Text(tip.detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            if tip.opensSettings {
                                Button("Open Battery Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                                }
                                .buttonStyle(GhostButtonStyle()).padding(.top, 2)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 380)
    }

    // MARK: Trend

    var trend: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Health over time", trailing: model.batteryLog.samples.isEmpty ? nil : "recorded on this Mac")
                if let t = model.batteryLog.trend() {
                    Chart {
                        RuleMark(y: .value("Service", 80)).foregroundStyle(Theme.critical.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("80% · Apple suggests service").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                            }
                        ForEach(t.daily, id: \.date) { d in
                            LineMark(x: .value("Day", d.date), y: .value("Health", d.health * 100))
                                .foregroundStyle(Theme.safe).interpolationMethod(.monotone)
                        }
                    }
                    // Tight around the readings, but always showing the 80% line.
                    .chartYScale(domain: min(78, ((t.daily.map(\.health).min() ?? 0.8) * 100 - 2).rounded(.down))
                                 ... min(100, ((t.daily.map(\.health).max() ?? 1) * 100 + 3).rounded(.up)))
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Double.self).map { Int($0) } ?? 0)%") } } }
                    .frame(height: 160)
                    Text(trendLine(t)).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Headroom notes the battery's capacity while it runs. The trend appears after two weeks of readings — capacity estimates wobble a little day to day, so fewer would mislead.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    func trendLine(_ t: BatteryLog.Trend) -> String {
        var parts = [String(format: "Losing %.1f%% a year", t.wearPerYear * 100), String(format: "%.0f cycles a month", t.cyclesPerMonth)]
        if let y = t.yearsTo80 { parts.append(y < 1 ? "under a year until 80%" : String(format: "about %.1f years until 80%%", y)) }
        return parts.joined(separator: " · ") + " — since " + t.since.formatted(.dateTime.month(.wide).year()) + "."
    }

    // MARK: Recap

    var month: BatteryLog.Month? {
        let date = lastMonth ? Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now : .now
        return model.batteryLog.month(containing: date)
    }

    var recap: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionTitle(title: "Your battery's month")
                    Pill(title: "This month", on: !lastMonth) { lastMonth = false }
                    Pill(title: "Last month", on: lastMonth) { lastMonth = true }
                }
                if let m = month {
                    HStack(alignment: .top, spacing: 20) {
                        BatteryRecapCard(month: m, model: "My MacBook")
                            .environment(\.colorScheme, .dark)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Everything on the card was measured on this Mac. Nothing is uploaded — share it yourself if you like.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            if !snapshot, let image = render(m) {
                                ShareLink(item: Image(nsImage: image), subject: Text("My battery's month"), message: Text(shareText(m)),
                                          preview: SharePreview("My battery's month", image: Image(nsImage: image))) {
                                    Label("Share…", systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(PrimaryButtonStyle())
                                HStack(spacing: 8) {
                                    Button("Copy Image") { copy(image) }.buttonStyle(GhostButtonStyle())
                                    Button("Save Image…") { save(image, m) }.buttonStyle(GhostButtonStyle())
                                }
                            }
                        }
                        .frame(maxWidth: 260, alignment: .leading)
                    }
                } else {
                    Text(lastMonth ? "No readings from last month — Headroom wasn't keeping track yet."
                         : "The card fills in as Headroom notes the battery through the month. Check back tomorrow.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    func shareText(_ m: BatteryLog.Month) -> String {
        let mood = BatteryMood.of(m)
        return "My MacBook's battery in \(m.start.formatted(.dateTime.month(.wide))): \(Int((m.healthEnd * 100).rounded()))% health after \(m.cyclesTotal) cycles. Mood: \(mood.rawValue)."
    }

    @MainActor
    func render(_ m: BatteryLog.Month) -> NSImage? {
        let renderer = ImageRenderer(content: BatteryRecapCard(month: m, model: "My MacBook")
            .environment(\.colorScheme, .dark))
        renderer.scale = 2
        return renderer.nsImage
    }

    func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        model.show("Card copied — paste it anywhere")
    }

    func save(_ image: NSImage, _ m: BatteryLog.Month) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Battery \(m.start.formatted(.dateTime.year().month(.twoDigits))).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        do { try png.write(to: url); model.show("Saved \(url.lastPathComponent)") }
        catch { model.show("Couldn't save: \(error.localizedDescription)", failed: true) }
    }
}

/// Charger → Mac and battery, with the watts on each arrow.
struct PowerFlowCard: View {
    var b: BatteryStatus

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "Power right now")
                HStack(spacing: 0) {
                    node("powerplug.fill", "Charger", b.pluggedIn ? b.adapterDelivering.map(watts) ?? "On" : "Unplugged", on: b.pluggedIn)
                    arrow(b.pluggedIn ? b.adapterDelivering : nil)
                    node("laptopcomputer", "Mac", b.systemWatts.map(watts) ?? "—", on: true)
                    // Into the battery while charging; out of it (pointing at the Mac) on battery.
                    arrow(b.batteryWatts.magnitude > 0.3 ? b.batteryWatts.magnitude : nil, reversed: b.batteryWatts < 0)
                    node(b.batteryWatts > 0.3 ? "battery.100percent.bolt" : "battery.75percent", "Battery \(b.percent)%",
                         b.batteryWatts.magnitude < 0.3 ? "Resting" : String(format: "%+.1f W", b.batteryWatts), on: true)
                }
                Text(sentence).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var sentence: String {
        let rated = b.adapterWatts.map { " of its \($0) W" } ?? ""
        switch b.flow {
        case .charging: return "The charger runs the Mac and charges the battery" + (b.adapterDelivering.map { String(format: ", delivering %.1f W", $0) + rated } ?? "") + "."
        case .held: return "The charger runs the Mac; nothing goes in or out of the battery."
        case .onBattery: return "The battery runs the Mac."
        case .slowCharger: return "The charger can't keep up: the battery makes up the difference."
        }
    }

    func watts(_ w: Double) -> String { String(format: "%.1f W", w) }

    func node(_ symbol: String, _ title: String, _ value: String, on: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 52, height: 52)
                .background(Circle().fill(Theme.fill(on ? 0.07 : 0.03)))
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
            Text(value).font(Theme.number(13, weight: .semibold))
        }
        .frame(minWidth: 86)
    }

    /// A flow, left to right (reversed: from the battery back to the Mac).
    func arrow(_ w: Double?, reversed: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: reversed ? "arrow.left" : "arrow.right").font(.system(size: 14, weight: .bold))
                .foregroundStyle(w != nil ? Theme.safe : Theme.fill(0.15))
            Rectangle().fill(w != nil ? Theme.safe.opacity(0.5) : Theme.fill(0.08)).frame(height: 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 34)
    }
}

/// The shareable card. Fixed size and always dark, so the saved image looks the same everywhere.
struct BatteryRecapCard: View {
    var month: BatteryLog.Month
    var model: String

    var body: some View {
        let mood = BatteryMood.of(month)
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BATTERY MONTH").font(.system(size: 11, weight: .bold)).kerning(1.2).foregroundStyle(.white.opacity(0.55))
                    Text(model).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    Text(month.start.formatted(.dateTime.month(.wide).year())).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Image(systemName: mood.symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(Color(hex: 0x3DF5A7))
            }
            Text(mood.rawValue).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(.white)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 14) {
                tile("\(Int((month.healthEnd * 100).rounded()))%", "battery health",
                     month.healthChange == 0 ? "no change" : "\(month.healthChange > 0 ? "+" : "−")\(abs(month.healthChange)) this month")
                tile("\(Int(month.hoursHeldFull.rounded())) h", "held at 100%", "of \(Int(month.hoursPlugged.rounded())) h on the charger")
                tile(String(format: "%.1f °C", month.hottest), "hottest moment", month.hottestAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                tile("+\(month.cyclesUsed)", "charge cycles", "\(month.cyclesTotal) in total")
            }
            Text(mood.line).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            Text("Measured by Headroom").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(22)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x15302A), Color(hex: 0x0B0C10)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
    }

    func tile(_ value: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            Text(detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// Seeded readings for `--demo` renders and the reel: a MacBook Air that lives on its charger.
enum BatteryDemo {
    static var status: BatteryStatus {
        BatteryStatus(percent: 73, pluggedIn: true, charging: true, fullyCharged: false, cycles: 349, designCycles: 1000,
                      maxCapacity: 3842, designCapacity: 4629, temperature: 32.5, volts: 12.6, batteryWatts: 23.0,
                      systemWatts: 5.2, adapterWatts: 30, adapterName: "30W USB-C Power Adapter",
                      minutesToFull: 38, minutesToEmpty: nil, failed: false)
    }

    static func log(now: Date = .now) -> BatteryLog {
        var log = BatteryLog()
        var rng = SystemRandomNumberGenerator()
        let start = now.addingTimeInterval(-200 * 86_400)
        var t = start
        while t < now {
            let days = t.timeIntervalSince(start) / 86_400
            let hour = Calendar.current.component(.hour, from: t)
            let plugged = hour >= 9 && hour < 19
            var s = status
            s.date = t
            s.pluggedIn = plugged
            s.percent = plugged ? (hour >= 11 ? 100 : 60 + (hour - 9) * 20) : max(20, 100 - (hour + 5) % 24 * 6)
            s.temperature = 29 + Double.random(in: 0...6, using: &rng) + (hour == 15 ? 4 : 0)
            s.maxCapacity = Int(4000 - days * 0.85 + Double.random(in: -12...12, using: &rng))
            s.cycles = 300 + Int(days / 4)
            log.samples.append(.init(s))
            // Every 10 minutes for the last two months, every 6 hours before.
            t.addTimeInterval(now.timeIntervalSince(t) < 62 * 86_400 ? 600 : 6 * 3600)
        }
        return log
    }
}

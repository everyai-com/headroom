import Foundation
import IOKit

/// The MacBook's battery, read from the battery controller (`AppleSmartBattery` in IOKit). Read-only:
/// Headroom never changes how the Mac charges — that needs a root helper writing SMC keys, and macOS 26.4+
/// has its own charge limit in System Settings › Battery. Desktops have no battery: `current()` is nil.
public struct BatteryStatus: Sendable, Equatable, Codable {
    /// 0–100, as the menu bar shows it.
    public var percent: Int
    public var pluggedIn: Bool
    public var charging: Bool
    public var fullyCharged: Bool
    public var cycles: Int
    /// Apple's rated cycle count for this battery (1000 on every Apple silicon MacBook).
    public var designCycles: Int
    /// What the battery holds when full today, and when new (mAh).
    public var maxCapacity: Int
    public var designCapacity: Int
    public var temperature: Double
    public var volts: Double
    /// Into the battery while charging (positive), out of it on battery (negative).
    public var batteryWatts: Double
    /// What the Mac itself is drawing, from the power telemetry (nil on older controllers).
    public var systemWatts: Double?
    /// The charger's rating and name ("30W USB-C Power Adapter").
    public var adapterWatts: Int?
    public var adapterName: String?
    public var minutesToFull: Int?
    public var minutesToEmpty: Int?
    /// The controller reports a permanent fault: Apple says to service it.
    public var failed: Bool
    public var date = Date()

    public init(percent: Int, pluggedIn: Bool, charging: Bool, fullyCharged: Bool, cycles: Int, designCycles: Int,
                maxCapacity: Int, designCapacity: Int, temperature: Double, volts: Double, batteryWatts: Double,
                systemWatts: Double?, adapterWatts: Int?, adapterName: String?, minutesToFull: Int?, minutesToEmpty: Int?,
                failed: Bool, date: Date = .now) {
        self.percent = percent; self.pluggedIn = pluggedIn; self.charging = charging; self.fullyCharged = fullyCharged
        self.cycles = cycles; self.designCycles = designCycles; self.maxCapacity = maxCapacity; self.designCapacity = designCapacity
        self.temperature = temperature; self.volts = volts; self.batteryWatts = batteryWatts; self.systemWatts = systemWatts
        self.adapterWatts = adapterWatts; self.adapterName = adapterName; self.minutesToFull = minutesToFull
        self.minutesToEmpty = minutesToEmpty; self.failed = failed; self.date = date
    }

    /// Full charge today against new, 0–1. Apple suggests service below 80%.
    public var health: Double { designCapacity > 0 ? min(1, Double(maxCapacity) / Double(designCapacity)) : 0 }
    public var healthPercent: Int { Int((health * 100).rounded()) }
    public var hot: Bool { temperature >= 40 }

    /// The charger's watts going into the Mac and battery right now.
    public var adapterDelivering: Double? {
        guard pluggedIn, let systemWatts else { return nil }
        return systemWatts + max(0, batteryWatts)
    }

    public enum Flow: String, Sendable { case charging, held, onBattery, slowCharger }

    /// What the watts are doing, in one word.
    public var flow: Flow {
        if !pluggedIn { return .onBattery }
        if batteryWatts < -0.5 { return .slowCharger } // plugged in and still draining: the charger can't keep up
        if charging, batteryWatts > 0.3 { return .charging }
        return .held
    }

    public static func current() -> BatteryStatus? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        return parse(dict)
    }

    /// The controller's properties → a status. Separate from IOKit so tests can feed it.
    public static func parse(_ d: [String: Any], at date: Date = .now) -> BatteryStatus? {
        func int(_ key: String, in dict: [String: Any] = d) -> Int? {
            // Signed values (amperage) arrive as unsigned 64-bit; reinterpret the bits.
            (dict[key] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
        }
        func bool(_ key: String) -> Bool { (d[key] as? NSNumber)?.boolValue ?? false }
        guard (d["BatteryInstalled"] as? NSNumber)?.boolValue ?? true,
              let design = int("DesignCapacity"), design > 0 else { return nil }
        // AppleRawMaxCapacity is mAh on Apple silicon; MaxCapacity is a percentage there (and mAh on Intel).
        let rawMax = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity") ?? int("MaxCapacity") ?? 0
        let millivolts = int("Voltage") ?? int("AppleRawBatteryVoltage") ?? 0
        let milliamps = int("InstantAmperage").flatMap { $0 == 0 ? nil : $0 } ?? int("Amperage") ?? 0
        let telemetry = d["PowerTelemetryData"] as? [String: Any]
        let adapter = d["AdapterDetails"] as? [String: Any]
        let plugged = bool("ExternalConnected")
        func minutes(_ key: String) -> Int? { int(key).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil } }
        let percent: Int = {
            let current = int("CurrentCapacity") ?? 0, max = int("MaxCapacity") ?? 100
            // Intel reports both in mAh.
            return max > 100 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        }()
        return BatteryStatus(
            percent: Swift.max(0, Swift.min(100, percent)),
            pluggedIn: plugged,
            charging: bool("IsCharging"),
            fullyCharged: bool("FullyCharged"),
            cycles: int("CycleCount") ?? 0,
            designCycles: int("DesignCycleCount9C") ?? 1000,
            maxCapacity: rawMax,
            designCapacity: design,
            temperature: Double(int("Temperature") ?? 0) / 100,
            volts: Double(millivolts) / 1000,
            batteryWatts: Double(millivolts) * Double(milliamps) / 1_000_000,
            systemWatts: telemetry.flatMap { int("SystemLoad", in: $0) }.map { Double($0) / 1000 },
            adapterWatts: plugged ? adapter.flatMap { int("Watts", in: $0) } : nil,
            adapterName: plugged ? adapter?["Name"] as? String : nil,
            minutesToFull: plugged ? minutes("AvgTimeToFull") : nil,
            minutesToEmpty: plugged ? nil : minutes("AvgTimeToEmpty"),
            failed: (int("PermanentFailureStatus") ?? 0) != 0,
            date: date)
    }
}

/// What Headroom remembers about the battery: a sample every few minutes while it runs, thinned to one a
/// day after two months, so the health trend and the monthly recap come from this Mac's own readings.
public struct BatteryLog: Codable, Sendable {
    public struct Sample: Codable, Sendable, Equatable {
        public var date: Date
        public var percent: Int
        public var pluggedIn: Bool
        public var temperature: Double
        public var maxCapacity: Int
        public var designCapacity: Int
        public var cycles: Int
        public var health: Double { designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) : 0 }

        public init(_ s: BatteryStatus) {
            date = s.date; percent = s.percent; pluggedIn = s.pluggedIn; temperature = s.temperature
            maxCapacity = s.maxCapacity; designCapacity = s.designCapacity; cycles = s.cycles
        }
    }

    public var samples: [Sample] = []

    public init() {}

    /// Samples further apart than this mean Headroom wasn't running (or the Mac slept): the gap isn't counted.
    public static let gap: TimeInterval = 20 * 60
    public static var defaultURL: URL { HeadroomPaths.support.appendingPathComponent("battery.json") }

    public static func load(from url: URL = defaultURL) -> BatteryLog {
        guard let data = try? Data(contentsOf: url) else { return BatteryLog() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(BatteryLog.self, from: data)) ?? BatteryLog()
    }

    public func save(to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// Every sample for 62 days (enough for this month and last), then one a day for three years.
    public mutating func record(_ status: BatteryStatus, to url: URL? = defaultURL) {
        if let last = samples.last, status.date.timeIntervalSince(last.date) < 4 * 60 { return }
        samples.append(Sample(status))
        let now = status.date
        var seen = Set<Int>()
        samples = samples.filter { s in
            let age = now.timeIntervalSince(s.date)
            if age < 62 * 86_400 { return true }
            return age < 3 * 365 * 86_400 && seen.insert(Int(s.date.timeIntervalSince1970 / 86_400)).inserted
        }
        if let url { save(to: url) }
    }

    // MARK: Health trend

    public struct Trend: Sendable, Equatable {
        /// Health points lost per year (0.023 = 2.3%), from a straight line through the daily readings.
        public var wearPerYear: Double
        public var cyclesPerMonth: Double
        /// Years until the line crosses 80%; nil when it isn't falling or it's already there.
        public var yearsTo80: Double?
        public var since: Date
        /// One health reading per day, for the chart.
        public var daily: [(date: Date, health: Double)]

        public static func == (a: Trend, b: Trend) -> Bool {
            a.wearPerYear == b.wearPerYear && a.cyclesPerMonth == b.cyclesPerMonth && a.since == b.since
        }
    }

    /// Needs two weeks of readings: day-to-day capacity estimates wobble by a percent or two.
    public func trend(now: Date = .now) -> Trend? {
        var byDay: [Int: Sample] = [:]
        for s in samples where s.designCapacity > 0 {
            let day = Int(s.date.timeIntervalSince1970 / 86_400)
            if byDay[day] == nil || s.maxCapacity > byDay[day]!.maxCapacity { byDay[day] = s }
        }
        let days = byDay.values.sorted { $0.date < $1.date }
        guard let first = days.first, let last = days.last,
              last.date.timeIntervalSince(first.date) >= 14 * 86_400 else { return nil }
        // Least squares: health against years.
        let xs = days.map { $0.date.timeIntervalSince(first.date) / (365.25 * 86_400) }, ys = days.map(\.health)
        let n = Double(days.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        let slope = sxx > 0 ? zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / sxx : 0
        let nowHealth = my + slope * ((xs.last ?? 0) - mx)
        let months = last.date.timeIntervalSince(first.date) / (30.44 * 86_400)
        return Trend(wearPerYear: max(0, -slope),
                     cyclesPerMonth: months > 0 ? Double(last.cycles - first.cycles) / months : 0,
                     yearsTo80: slope < 0 && nowHealth > 0.8 ? (nowHealth - 0.8) / -slope : nil,
                     since: first.date,
                     daily: days.map { ($0.date, $0.health) })
    }

    // MARK: Monthly recap

    /// One calendar month, measured: what the recap card shows.
    public struct Month: Sendable, Equatable {
        public var start: Date
        public var healthStart: Double
        public var healthEnd: Double
        public var cyclesUsed: Int
        public var cyclesTotal: Int
        public var hottest: Double
        public var hottestAt: Date
        /// Hours on the charger in all, and how many of them sitting at 99–100% (what ages a battery).
        public var hoursPlugged: Double
        public var hoursHeldFull: Double
        public var hoursOnBattery: Double
        public var hoursMeasured: Double { hoursPlugged + hoursOnBattery }
        public var healthChange: Int { Int(((healthEnd - healthStart) * 100).rounded()) }
    }

    /// The month containing `date`; nil until there's a day of readings in it.
    public func month(containing date: Date, calendar: Calendar = .current) -> Month? {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return nil }
        let inMonth = samples.filter { interval.contains($0.date) }
        guard let first = inMonth.first, let last = inMonth.last,
              let hottest = inMonth.max(by: { $0.temperature < $1.temperature }) else { return nil }
        var plugged = 0.0, full = 0.0, battery = 0.0
        for (a, b) in zip(inMonth, inMonth.dropFirst()) {
            let dt = b.date.timeIntervalSince(a.date)
            guard dt <= Self.gap else { continue }
            let hours = dt / 3600
            if a.pluggedIn {
                plugged += hours
                if a.percent >= 99 { full += hours }
            } else {
                battery += hours
            }
        }
        guard plugged + battery >= 1 else { return nil }
        return Month(start: interval.start, healthStart: first.health, healthEnd: last.health,
                     cyclesUsed: max(0, last.cycles - first.cycles), cyclesTotal: last.cycles,
                     hottest: hottest.temperature, hottestAt: hottest.date,
                     hoursPlugged: plugged, hoursHeldFull: full, hoursOnBattery: battery)
    }
}

/// The month's character, in one word: the recap card's headline.
public enum BatteryMood: String, Sendable, CaseIterable {
    case restful = "Well rested"
    case overfull = "Kept too full"
    case warm = "Running warm"
    case traveller = "On the go"
    case new = "Fresh out of the box"

    public var symbol: String {
        switch self {
        case .restful: "leaf.fill"
        case .overfull: "battery.100percent.bolt"
        case .warm: "thermometer.sun.fill"
        case .traveller: "airplane"
        case .new: "sparkles"
        }
    }

    public var line: String {
        switch self {
        case .restful: "Spent the month away from 100% and cool — the gentlest life a battery can have."
        case .overfull: "Sat at 100% on the charger most of the month. A charge limit would keep it fresher."
        case .warm: "Got hot this month. Heat is what wears a battery fastest."
        case .traveller: "Mostly ran on battery, away from the charger."
        case .new: "A new battery, barely used yet."
        }
    }

    public static func of(_ m: BatteryLog.Month) -> BatteryMood {
        // The habit you can change wins over the weather: sitting full comes before heat.
        if m.cyclesTotal < 20 { return .new }
        if m.hoursPlugged >= 24, m.hoursHeldFull / m.hoursPlugged >= 0.5 { return .overfull }
        if m.hottest >= 40 { return .warm }
        if m.hoursMeasured > 0, m.hoursOnBattery / m.hoursMeasured >= 0.6 { return .traveller }
        return .restful
    }
}

/// Things worth knowing about the battery, each with what to do. Headroom only reads, so the fixes are
/// macOS's own settings (or the charger).
public struct BatteryTip: Sendable, Identifiable, Equatable {
    public enum Level: Sendable { case good, note, warning }
    public var id: String
    public var level: Level
    public var title: String
    public var detail: String
    /// Opens System Settings › Battery.
    public var opensSettings = false

    public static func tips(_ s: BatteryStatus, month: BatteryLog.Month?) -> [BatteryTip] {
        var out: [BatteryTip] = []
        if s.failed || s.health < 0.8 {
            out.append(.init(id: "service", level: .warning, title: "Apple suggests service",
                             detail: "The battery holds \(s.healthPercent)% of what it did new. An Apple Store or authorised provider can replace it; System Settings › Battery shows its condition.",
                             opensSettings: true))
        }
        if s.hot {
            out.append(.init(id: "hot", level: .warning, title: String(format: "The battery is hot (%.0f °C)", s.temperature),
                             detail: "Heat wears a battery fastest. Give the Mac air — off a bed or lap — and let heavy work finish before charging."))
        }
        if let m = month, m.hoursPlugged >= 24, m.hoursHeldFull / m.hoursPlugged >= 0.5 {
            out.append(.init(id: "full", level: .note, title: "Held at 100% for \(Int(m.hoursHeldFull)) hours this month",
                             detail: "A battery ages fastest sitting full. Turn on Optimized Battery Charging, or set a charge limit, in System Settings › Battery › Charging.",
                             opensSettings: true))
        }
        if let w = s.adapterWatts, w > 0, w < 30 {
            out.append(.init(id: "slow", level: .note, title: "This \(w) W charger is slow",
                             detail: "MacBooks come with 30 W or more. This one charges slowly and may not keep up while the Mac works hard."))
        }
        if s.flow == .slowCharger {
            out.append(.init(id: "draining", level: .note, title: "Plugged in, but still draining",
                             detail: "The charger gives less than the Mac is using. A stronger charger or cable fixes it."))
        }
        if out.isEmpty {
            out.append(.init(id: "fine", level: .good, title: "Nothing to worry about",
                             detail: "Healthy, cool and charging normally."))
        }
        return out
    }
}

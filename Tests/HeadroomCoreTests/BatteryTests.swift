import XCTest
@testable import HeadroomCore

/// The battery add-on: reading the controller, the record, the trend and the monthly recap.
final class BatteryTests: XCTestCase {
    /// Properties as an Apple silicon MacBook Air reports them (trimmed).
    let air: [String: Any] = [
        "BatteryInstalled": true, "CurrentCapacity": 73, "MaxCapacity": 100, "AppleRawMaxCapacity": 3958,
        "DesignCapacity": 4629, "CycleCount": 468, "DesignCycleCount9C": 1000, "Temperature": 3072,
        "Voltage": 12600, "InstantAmperage": 1825, "IsCharging": true, "ExternalConnected": true,
        "AvgTimeToFull": 38, "AvgTimeToEmpty": 65535,
        "PowerTelemetryData": ["SystemLoad": 5057],
        "AdapterDetails": ["Watts": 30, "Name": "30W USB-C Power Adapter"],
    ]

    func testReadsAppleSiliconBattery() throws {
        let b = try XCTUnwrap(BatteryStatus.parse(air))
        XCTAssertEqual(b.percent, 73)
        XCTAssertEqual(b.healthPercent, 86, "raw mAh against design, not MaxCapacity (a percentage on Apple silicon)")
        XCTAssertEqual(b.temperature, 30.72, accuracy: 0.001)
        XCTAssertEqual(b.batteryWatts, 23.0, accuracy: 0.01)
        XCTAssertEqual(b.systemWatts ?? 0, 5.057, accuracy: 0.001)
        XCTAssertEqual(b.adapterDelivering ?? 0, 28.06, accuracy: 0.01)
        XCTAssertEqual(b.flow, .charging)
        XCTAssertEqual(b.minutesToFull, 38)
        XCTAssertNil(b.minutesToEmpty, "65535 means unknown, and it's plugged in")
    }

    func testDischargingAmperageIsNegative() throws {
        var d = air
        d["ExternalConnected"] = false
        d["IsCharging"] = false
        d["InstantAmperage"] = NSNumber(value: UInt64(bitPattern: -800)) // how IOKit hands back a negative current
        let b = try XCTUnwrap(BatteryStatus.parse(d))
        XCTAssertEqual(b.batteryWatts, -10.08, accuracy: 0.01)
        XCTAssertEqual(b.flow, .onBattery)
        XCTAssertNil(b.adapterWatts, "the adapter's details linger after unplugging")
    }

    func testPluggedInButDrainingIsASlowCharger() throws {
        var d = air
        d["IsCharging"] = false
        d["InstantAmperage"] = NSNumber(value: UInt64(bitPattern: -300))
        d["AdapterDetails"] = ["Watts": 20]
        let b = try XCTUnwrap(BatteryStatus.parse(d))
        XCTAssertEqual(b.flow, .slowCharger)
        let ids = BatteryTip.tips(b, month: nil).map(\.id)
        XCTAssertTrue(ids.contains("slow"))
        XCTAssertTrue(ids.contains("draining"))
    }

    func testNoBatteryOnADesktop() {
        XCTAssertNil(BatteryStatus.parse(["BatteryInstalled": false, "DesignCapacity": 4629]))
        XCTAssertNil(BatteryStatus.parse([:]))
    }

    func testIntelReportsCapacityInMilliampHours() throws {
        var d = air
        d["AppleRawMaxCapacity"] = nil
        d["MaxCapacity"] = 4000
        d["CurrentCapacity"] = 2000
        let b = try XCTUnwrap(BatteryStatus.parse(d))
        XCTAssertEqual(b.percent, 50)
        XCTAssertEqual(b.maxCapacity, 4000)
    }

    func status(_ date: Date, percent: Int = 80, plugged: Bool = true, temp: Double = 30, max: Int = 4000, cycles: Int = 100) -> BatteryStatus {
        BatteryStatus(percent: percent, pluggedIn: plugged, charging: false, fullyCharged: false, cycles: cycles, designCycles: 1000,
                      maxCapacity: max, designCapacity: 5000, temperature: temp, volts: 12, batteryWatts: 0, systemWatts: 5,
                      adapterWatts: 30, adapterName: nil, minutesToFull: nil, minutesToEmpty: nil, failed: false, date: date)
    }

    func testRecordThinsOldReadingsToOneADay() {
        var log = BatteryLog()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 100 days, every 6 hours.
        for i in stride(from: 400, through: 0, by: -1) { log.record(status(now.addingTimeInterval(-Double(i) * 6 * 3600)), to: nil) }
        let old = log.samples.filter { now.timeIntervalSince($0.date) >= 62 * 86_400 }
        XCTAssertEqual(Set(old.map { Int($0.date.timeIntervalSince1970 / 86_400) }).count, old.count, "one a day past two months")
        XCTAssertEqual(log.samples.filter { now.timeIntervalSince($0.date) < 62 * 86_400 }.count, 248, "every reading for two months")
        log.record(status(now.addingTimeInterval(60)), to: nil)
        XCTAssertEqual(log.samples.last?.date, now, "at most one reading every 4 minutes")
    }

    func testTrendFitsWearAndYearsTo80() throws {
        var log = BatteryLog()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        // 90% falling 5 points a year → 2 years to 80%.
        for day in 0...365 {
            let health = 0.90 - 0.05 * Double(day) / 365.25
            log.samples.append(.init(status(start.addingTimeInterval(Double(day) * 86_400), max: Int(health * 5000), cycles: 100 + day / 3)))
        }
        let t = try XCTUnwrap(log.trend())
        XCTAssertEqual(t.wearPerYear, 0.05, accuracy: 0.002)
        XCTAssertEqual(t.yearsTo80 ?? 0, 1.0, accuracy: 0.05, "85% now, five points a year")
        XCTAssertEqual(t.cyclesPerMonth, 10, accuracy: 0.3)
        XCTAssertNil(BatteryLog(samples: Array(log.samples.prefix(10))).trend(), "under two weeks is too little to say")
    }

    func testMonthCountsHoursAndSkipsGaps() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        var log = BatteryLog()
        // 10 h at 100% on the charger, then 5 h on battery at 60%, every 10 minutes.
        for i in 0...60 { log.samples.append(.init(status(start.addingTimeInterval(Double(i) * 600), percent: 100))) }
        for i in 61...90 { log.samples.append(.init(status(start.addingTimeInterval(Double(i) * 600), percent: 60, plugged: false, temp: i == 70 ? 41 : 30, cycles: 101))) }
        // A gap of a day (Headroom wasn't running) isn't counted.
        log.samples.append(.init(status(start.addingTimeInterval(91 * 600 + 86_400), percent: 60, cycles: 102)))
        let m = try XCTUnwrap(log.month(containing: start, calendar: cal))
        XCTAssertEqual(m.hoursHeldFull, 10 + 1.0 / 6, accuracy: 0.01, "the 10 minutes from the last full reading to unplugging count too")
        XCTAssertEqual(m.hoursPlugged, m.hoursHeldFull, accuracy: 0.01)
        XCTAssertEqual(m.hoursOnBattery, 5 - 1.0 / 6, accuracy: 0.01)
        XCTAssertEqual(m.hottest, 41)
        XCTAssertEqual(m.cyclesUsed, 2)
        XCTAssertNil(log.month(containing: start.addingTimeInterval(40 * 86_400), calendar: cal))
    }
}

extension BatteryLog {
    init(samples: [Sample]) { self.init(); self.samples = samples }
}

final class BatteryMoodTests: XCTestCase {
    func month(plugged: Double = 100, full: Double = 10, battery: Double = 20, hottest: Double = 33, cycles: Int = 300) -> BatteryLog.Month {
        .init(start: .now, healthStart: 0.9, healthEnd: 0.9, cyclesUsed: 5, cyclesTotal: cycles, hottest: hottest, hottestAt: .now,
              hoursPlugged: plugged, hoursHeldFull: full, hoursOnBattery: battery)
    }

    func testMoods() {
        XCTAssertEqual(BatteryMood.of(month()), .restful)
        XCTAssertEqual(BatteryMood.of(month(cycles: 5)), .new)
        XCTAssertEqual(BatteryMood.of(month(full: 80, hottest: 44)), .overfull, "sitting full beats heat: it's the habit to change")
        XCTAssertEqual(BatteryMood.of(month(hottest: 41)), .warm)
        XCTAssertEqual(BatteryMood.of(month(plugged: 20, full: 2, battery: 80)), .traveller)
        XCTAssertEqual(BatteryMood.of(month(plugged: 10, full: 10, battery: 1)), .restful, "under a day on the charger says too little")
    }
}

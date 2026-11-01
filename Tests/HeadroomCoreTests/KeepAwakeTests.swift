import XCTest
@testable import HeadroomCore

/// Keep-awake rules and the energy readings.
final class KeepAwakeTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func battery(_ percent: Int, plugged: Bool) -> BatteryStatus {
        BatteryStatus(percent: percent, pluggedIn: plugged, charging: false, fullyCharged: false, cycles: 1, designCycles: 1000,
                      maxCapacity: 4000, designCapacity: 4000, temperature: 30, volts: 12, batteryWatts: 0, systemWatts: 5,
                      adapterWatts: nil, adapterName: nil, minutesToFull: nil, minutesToEmpty: nil, failed: false)
    }

    func testTimedSessionEnds() {
        let s = AwakeSession.timed(3600, from: now)
        XCTAssertEqual(KeepAwake.decide(s, battery: nil, agentsWorking: [], now: now.addingTimeInterval(60)), .awake)
        XCTAssertEqual(KeepAwake.decide(s, battery: nil, agentsWorking: [], now: now.addingTimeInterval(3600)), .ended("Time's up"))
    }

    func testBatteryCutoffOnlyOnBattery() {
        var s = AwakeSession(mode: .untilStopped, started: now)
        s.batteryCutoff = 30
        XCTAssertEqual(KeepAwake.decide(s, battery: battery(30, plugged: false), agentsWorking: [], now: now), .ended("Battery reached 30%"))
        XCTAssertEqual(KeepAwake.decide(s, battery: battery(20, plugged: true), agentsWorking: [], now: now), .awake, "charging: no cutoff")
        XCTAssertEqual(KeepAwake.decide(s, battery: nil, agentsWorking: [], now: now), .awake, "desktops have no battery")
    }

    func testChargerRequiredPausesUnplugged() {
        var s = AwakeSession(mode: .untilStopped, started: now)
        s.requireCharger = true
        XCTAssertEqual(KeepAwake.decide(s, battery: battery(80, plugged: false), agentsWorking: [], now: now), .paused("Waiting for the charger"))
        XCTAssertEqual(KeepAwake.decide(s, battery: battery(80, plugged: true), agentsWorking: [], now: now), .awake)
    }

    func testWhileAgentsFollowsThem() {
        let s = AwakeSession(mode: .whileAgents, started: now)
        XCTAssertEqual(KeepAwake.decide(s, battery: nil, agentsWorking: [], now: now), .paused("No agent is working"))
        XCTAssertEqual(KeepAwake.decide(s, battery: nil, agentsWorking: ["claude"], now: now), .awake)
    }

    func testAgentsAreYoursOnly() {
        func p(_ name: String, uid: uid_t) -> ProcessInfoSnapshot {
            ProcessInfoSnapshot(pid: 10, parent: 1, name: name, path: nil, uid: uid, footprint: 1, started: nil)
        }
        XCTAssertEqual(KeepAwake.agentsWorking([p("claude", uid: 501), p("claude", uid: 501), p("Safari", uid: 501), p("codex", uid: 0)], me: 501), ["claude"])
    }

    func testEnergyPerAppAndReusedPids() {
        let g = MemoryGroup(id: "/Applications/Busy.app", name: "Busy", bundlePath: "/Applications/Busy.app", kind: .app,
                            processes: [ProcessInfoSnapshot(pid: 1, parent: 0, name: "Busy", path: nil, uid: 501, footprint: 1, started: nil),
                                        ProcessInfoSnapshot(pid: 2, parent: 1, name: "Busy Helper", path: nil, uid: 501, footprint: 1, started: nil)])
        let before: [Int32: Energy.Counters] = [1: .init(cpuNanos: 0, wakeups: 0), 2: .init(cpuNanos: 5_000_000_000, wakeups: 100)]
        let after: [Int32: Energy.Counters] = [1: .init(cpuNanos: 1_000_000_000, wakeups: 50), 2: .init(cpuNanos: 1, wakeups: 0)]
        let use = Energy.use(groups: [g], before: before, after: after, seconds: 2)
        XCTAssertEqual(use.first?.cpuPercent ?? 0, 50, accuracy: 0.01, "1 s of CPU in 2 s; pid 2 went backwards (reused) and counts nothing")
        XCTAssertEqual(use.first?.wakeupsPerSecond ?? 0, 25, accuracy: 0.01)
    }

    func testBlockersSkipBookkeepingAndHeadroom() {
        let dict: [NSNumber: [[String: Any]]] = [
            42: [["AssertType": "NoIdleSleepAssertion", "AssertName": "Electron", "Process Name": "Claude", "AssertLevel": 255]],
            7: [["AssertType": "UserIsActive", "AssertName": "tickle", "Process Name": "WindowServer", "AssertLevel": 255]],
            9: [["AssertType": "PreventUserIdleSystemSleep", "AssertName": "keep", "Process Name": "Headroom", "AssertLevel": 255]],
        ]
        let b = Energy.parse(dict)
        XCTAssertEqual(b.map(\.process), ["Claude"])
        XCTAssertEqual(b.first?.name, "Electron")
    }
}

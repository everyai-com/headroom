import Foundation
import IOKit.pwr_mgt

/// What's using the battery: CPU time and wake-ups per app between two samples (what Activity Monitor's
/// Energy tab weighs), and what's stopping the Mac from sleeping. Read-only — quitting goes through
/// `ProcessGuard` like the Memory screen.
public enum Energy {
    /// One process's counters at a moment.
    public struct Counters: Sendable, Equatable {
        public var cpuNanos: UInt64
        public var wakeups: UInt64
    }

    public static func counters(pid: Int32) -> Counters? {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard ok == 0 else { return nil }
        return Counters(cpuNanos: usage.ri_user_time + usage.ri_system_time,
                        wakeups: usage.ri_pkg_idle_wkups + usage.ri_interrupt_wkups)
    }

    public static func sample(_ pids: [Int32]) -> [Int32: Counters] {
        var out: [Int32: Counters] = [:]
        for pid in pids { if let c = counters(pid: pid) { out[pid] = c } }
        return out
    }

    public struct Use: Sendable, Identifiable, Equatable {
        public var id: String
        public var name: String
        public var bundlePath: String?
        /// Percent of one core, averaged over the interval.
        public var cpuPercent: Double
        public var wakeupsPerSecond: Double
        /// Activity Monitor's rough weighting: CPU dominates, idle wake-ups cost too.
        public var impact: Double { cpuPercent + wakeupsPerSecond * 0.02 }
    }

    /// Per app (processes grouped like the Memory screen), heaviest first.
    public static func use(groups: [MemoryGroup], before: [Int32: Counters], after: [Int32: Counters], seconds: Double) -> [Use] {
        guard seconds > 0 else { return [] }
        return groups.compactMap { g -> Use? in
            var cpu: UInt64 = 0, wake: UInt64 = 0
            for p in g.processes {
                guard let a = before[p.pid], let b = after[p.pid] else { continue }
                // A reused pid can go backwards: count nothing for it.
                cpu += b.cpuNanos >= a.cpuNanos ? b.cpuNanos - a.cpuNanos : 0
                wake += b.wakeups >= a.wakeups ? b.wakeups - a.wakeups : 0
            }
            let u = Use(id: g.id, name: g.name, bundlePath: g.bundlePath,
                        cpuPercent: Double(cpu) / 1e9 / seconds * 100, wakeupsPerSecond: Double(wake) / seconds)
            return u.impact >= 0.5 ? u : nil
        }
        .sorted { $0.impact > $1.impact }
    }

    // MARK: Sleep blockers

    public struct Blocker: Sendable, Identifiable, Equatable {
        public var id: String { "\(pid):\(name)" }
        public var pid: Int32
        public var process: String
        /// What the app called it ("Electron", "Playing audio"…).
        public var name: String
        public var type: String
        public var since: Date?
        /// Keeps the screen on, not just the Mac.
        public var display: Bool { type.contains("Display") }
    }

    /// Assertion types that actually stop idle sleep (others, like UserIsActive, are macOS bookkeeping).
    static let blocking: Set<String> = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
                                        "NoIdleSleepAssertion", "NoDisplaySleepAssertion"]

    public static func blockers(now: Date = .now) -> [Blocker] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return parse(dict.mapValues { $0 }, now: now)
    }

    /// `IOPMCopyAssertionsByProcess`'s dictionary → blockers. Separate so tests can feed it.
    public static func parse(_ dict: [NSNumber: [[String: Any]]], now: Date = .now) -> [Blocker] {
        var out: [Blocker] = []
        for (pid, list) in dict {
            for a in list {
                guard let type = a["AssertType"] as? String, blocking.contains(type),
                      (a["AssertLevel"] as? NSNumber)?.intValue ?? 255 > 0 else { continue }
                let process = a["Process Name"] as? String ?? "pid \(pid)"
                // Headroom's own keep-awake isn't a problem to report.
                guard process != "Headroom" else { continue }
                let since = (a["AssertTimeStarted"] as? Date)
                out.append(Blocker(pid: pid.int32Value, process: process, name: a["AssertName"] as? String ?? type,
                                   type: type, since: since))
            }
        }
        return out.sorted { ($0.since ?? now) < ($1.since ?? now) }
    }
}

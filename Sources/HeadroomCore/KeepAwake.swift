import Foundation
import IOKit.pwr_mgt

/// Keeping the Mac awake: a timed session, or "while agents work". Uses macOS's own sleep assertion
/// (the same thing `caffeinate` does) — no admin rights, released the moment the session ends or Headroom
/// quits. The rules (charger required, battery cutoff) are a pure function so they can be tested.
public struct AwakeSession: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case timed, untilStopped, whileAgents }

    public var mode: Mode
    public var started: Date
    /// When a timed session ends.
    public var ends: Date?
    /// Keep the display on too (otherwise only the system stays awake and the screen may dim).
    public var keepDisplay = false
    public var requireCharger = false
    /// End when the battery falls to this percent on battery power (nil = no cutoff).
    public var batteryCutoff: Int?

    public init(mode: Mode, started: Date = .now, ends: Date? = nil, keepDisplay: Bool = false,
                requireCharger: Bool = false, batteryCutoff: Int? = nil) {
        self.mode = mode; self.started = started; self.ends = ends; self.keepDisplay = keepDisplay
        self.requireCharger = requireCharger; self.batteryCutoff = batteryCutoff
    }

    public static func timed(_ duration: TimeInterval, from now: Date = .now) -> AwakeSession {
        AwakeSession(mode: .timed, started: now, ends: now.addingTimeInterval(duration))
    }
}

public enum KeepAwake {
    public enum Decision: Equatable, Sendable {
        /// Hold the assertion.
        case awake
        /// Running, but not holding it right now (no agent at work, or unplugged while the charger is required).
        case paused(String)
        /// The session is over; why, for the notification.
        case ended(String)
    }

    /// What the session should do right now.
    public static func decide(_ s: AwakeSession, battery: BatteryStatus?, agentsWorking: [String], now: Date = .now) -> Decision {
        if let ends = s.ends, now >= ends { return .ended("Time's up") }
        if let b = battery, let cutoff = s.batteryCutoff, !b.pluggedIn, b.percent <= cutoff {
            return .ended("Battery reached \(b.percent)%")
        }
        if s.requireCharger, let b = battery, !b.pluggedIn { return .paused("Waiting for the charger") }
        if s.mode == .whileAgents, agentsWorking.isEmpty { return .paused("No agent is working") }
        return .awake
    }

    /// Coding agents and long jobs that deserve an awake Mac. Matched on the process name, yours only.
    static let agentNames: Set<String> = ["claude", "codex", "aider", "cursor-agent", "gemini", "opencode", "goose",
                                          "xcodebuild", "swift-build", "cargo", "make", "ninja", "gradle", "docker-build"]

    /// Names of agents running right now (deduplicated, sorted).
    public static func agentsWorking(_ processes: [ProcessInfoSnapshot], me: uid_t = getuid()) -> [String] {
        Array(Set(processes.filter { $0.uid == me && agentNames.contains($0.name.lowercased()) }.map(\.name))).sorted()
    }

    /// The assertion itself. One at a time; `hold(false)` (or deinit) lets the Mac sleep again.
    public final class Assertion: @unchecked Sendable {
        private var id: IOPMAssertionID = 0
        private var held = false
        private var display = false
        private let lock = NSLock()

        public init() {}
        deinit { release() }

        public var isHeld: Bool { lock.withLock { held } }

        public func hold(_ on: Bool, display: Bool = false, reason: String = "Headroom is keeping your Mac awake") {
            lock.withLock {
                if held, on, display == self.display { return }
                if held { IOPMAssertionRelease(id); held = false }
                guard on else { return }
                let type = (display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString
                held = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id) == kIOReturnSuccess
                self.display = display
            }
        }

        public func release() { hold(false) }
    }
}

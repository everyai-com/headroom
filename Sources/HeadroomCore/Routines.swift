import Foundation

/// A routine: a nudge at the time you set to plan the morning, sync the evening or review the week.
/// The nudge only reminds — the coach still runs only when you press its button.
public struct Routine: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case morning, evening, week, vision

        public var title: String {
            switch self {
            case .morning: "Morning plan"
            case .evening: "Evening sync"
            case .week: "Weekly review"
            case .vision: "Your vision"
            }
        }
        /// What the notification says, and its button.
        public var body: String {
            switch self {
            case .morning: "Pick today's big three and block the time before the day picks for you."
            case .evening: "Rate the day, set tomorrow's top thing, and close the loop."
            case .week: "See how the season's week went and block the hours still needed."
            case .vision: "Read what you want to have, do and become — and give thanks as if it's already yours."
            }
        }
        public var action: String {
            switch self {
            case .morning: "Plan My Day"
            case .evening: "Review & Plan Tomorrow"
            case .week: "Review My Week"
            case .vision: "Read My Vision"
            }
        }
    }

    public var kind: Kind
    /// Minutes after midnight.
    public var at: Int
    /// The weekly review's day (1 = Sunday); the others run every day.
    public var weekday: Int?
    public var on: Bool
    public var id: Kind { kind }

    public init(_ kind: Kind, at: Int, weekday: Int? = nil, on: Bool = true) {
        self.kind = kind; self.at = at; self.weekday = weekday; self.on = on
    }
}

public enum Routines {
    public static let defaults = [Routine(.morning, at: 8 * 60 + 30), Routine(.evening, at: 17 * 60 + 30),
                                  Routine(.week, at: 18 * 60, weekday: 1), Routine(.vision, at: 21 * 60 + 30)]

    /// Pure: the routines to nudge now — on, their day, within two hours after their time, not nudged today
    /// (`nudged`: kind → day), and not already done (`done`, e.g. the evening sync once the day is rated).
    public static func due(_ routines: [Routine], now: Date, nudged: [String: String], done: Set<Routine.Kind> = [],
                           calendar: Calendar = .current) -> [Routine] {
        let today = Planner.key(now, calendar: calendar)
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let weekday = calendar.component(.weekday, from: now)
        return routines.filter { r in
            r.on && !done.contains(r.kind) && nudged[r.kind.rawValue] != today
                && (r.weekday.map { $0 == weekday } ?? true) && minute >= r.at && minute < r.at + 120
        }
    }
}

/// Meeting prep: a heads-up shortly before an event, and (on a button) the coach's agenda for it.
public enum MeetingPrep {
    /// The event to give a heads-up for: starting within `lead`, not all-day, not yet nudged.
    public static func upcoming(_ events: [CalendarEvent], now: Date, lead: TimeInterval = 10 * 60, nudged: Set<String>) -> CalendarEvent? {
        events.filter { !$0.allDay && $0.start > now && $0.start.timeIntervalSince(now) <= lead && !nudged.contains(key($0)) }
            .min { $0.start < $1.start }
    }

    /// The next timed event that hasn't ended, today only — what the Prep button is for.
    public static func next(_ events: [CalendarEvent], now: Date, calendar: Calendar = .current) -> CalendarEvent? {
        events.filter { !$0.allDay && $0.end > now && calendar.isDate($0.start, inSameDayAs: now) }.min { $0.start < $1.start }
    }

    public static func key(_ e: CalendarEvent) -> String { "\(e.title)@\(Int(e.start.timeIntervalSince1970))" }
}

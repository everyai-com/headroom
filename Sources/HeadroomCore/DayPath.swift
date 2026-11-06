import Foundation

/// The day as one path: morning (vision, plan, the top thing, time for it), the day (focus on it) and the evening
/// ritual (gratitude, value given, a rating, a few lines, tomorrow's top thing). Every step is read from what's
/// already in planner.json, so there's nothing to tick twice — and there's always exactly one next step.
public enum DayPath {
    public enum Phase: String, Sendable, CaseIterable {
        case morning, day, evening
        public var title: String { rawValue.capitalized }
    }

    public enum Step: String, Sendable, CaseIterable, Identifiable {
        case vision, plan, top, block, focus, gratitude, gave, rate, journal, tomorrow
        public var id: String { rawValue }

        public var phase: Phase {
            switch self {
            case .vision, .plan, .top, .block: .morning
            case .focus: .day
            case .gratitude, .gave, .rate, .journal, .tomorrow: .evening
            }
        }
        public var title: String {
            switch self {
            case .vision: "Read your vision"
            case .plan: "Pick the Big 3"
            case .top: "Choose the top thing"
            case .block: "Give it time"
            case .focus: "Focus on it"
            case .gratitude: "Three thanks"
            case .gave: "Value given"
            case .rate: "Rate the day"
            case .journal: "A few lines"
            case .tomorrow: "Tomorrow's top thing"
            }
        }
        /// Why this step, in one line — shown when it's the next one.
        public var why: String {
            switch self {
            case .vision: "Two minutes with what you want, as if it's already yours. Everything else today is for this."
            case .plan: "At most three things that move your season. Choosing is the point."
            case .top: "If only one thing gets done today, which one makes it a good day?"
            case .block: "A task without a time is a wish. Put today's tasks into your free time."
            case .focus: "One thing, done well, without hurry. Start a session on your top thing."
            case .gratitude: "Three good things from today, however small."
            case .gave: "Who got more from you today than they paid for?"
            case .rate: "How much did today move? Honest, not harsh."
            case .journal: "What went well, what didn't, what you noticed."
            case .tomorrow: "Decide tomorrow's one thing tonight, so the morning starts already moving."
            }
        }
        public var symbol: String {
            switch self {
            case .vision: "eye"
            case .plan: "star"
            case .top: "scope"
            case .block: "calendar.badge.clock"
            case .focus: "timer"
            case .gratitude: "heart"
            case .gave: "gift"
            case .rate: "chart.bar"
            case .journal: "text.book.closed"
            case .tomorrow: "sunrise"
            }
        }
    }

    /// Morning until noon, the day until 5 pm, then the evening.
    public static func phase(_ now: Date, calendar: Calendar = .current) -> Phase {
        let h = calendar.component(.hour, from: now)
        return h < 12 ? .morning : h < 17 ? .day : .evening
    }

    /// The steps the day has already met.
    public static func done(_ p: Planner, now: Date, calendar: Calendar = .current) -> Set<Step> {
        let today = Planner.key(now, calendar: calendar), tomorrow = Planner.key(daysFrom: now, 1, calendar: calendar)
        let log = p.log(on: today)
        var out: Set<Step> = []
        if log?.visioned == true { out.insert(.vision) }
        if p.today(now, calendar: calendar).contains(where: \.big) { out.insert(.plan) }
        if log?.top != nil { out.insert(.top) }
        if p.blocks.contains(where: { $0.day == today }) { out.insert(.block) }
        if p.focusMinutes(on: now, calendar: calendar) >= 25 || p.topThing(on: today)?.isDone == true { out.insert(.focus) }
        if log?.isGrateful == true { out.insert(.gratitude) }
        if log?.gaveValue == true { out.insert(.gave) }
        if log?.isSynced == true { out.insert(.rate) }
        if log?.isJournal == true { out.insert(.journal) }
        if p.log(on: tomorrow)?.top != nil { out.insert(.tomorrow) }
        return out
    }

    /// Steps that still make sense now: nothing from a later phase, and in the evening no morning planning or
    /// focus (it's tomorrow's turn) — the vision always counts.
    public static func open(_ done: Set<Step>, now: Date, calendar: Calendar = .current) -> [Step] {
        let phase = phase(now, calendar: calendar)
        let order = Phase.allCases
        return Step.allCases.filter { s in
            guard !done.contains(s), order.firstIndex(of: s.phase)! <= order.firstIndex(of: phase)! else { return false }
            return phase != .evening || s.phase == .evening || s == .vision
        }
    }

    /// The one thing to do next, or nil when the day's path is walked.
    public static func next(_ p: Planner, now: Date, calendar: Calendar = .current) -> Step? {
        open(done(p, now: now, calendar: calendar), now: now, calendar: calendar).first
    }
}

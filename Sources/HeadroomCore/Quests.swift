import Foundation

// Daily quests that fill themselves: a habit with a time target ("Marketing · Product X — 4 h a day") is
// measured from the timeline and focus sessions, and checked off the moment it's met. And seasons: two
// weeks with one main quest and at most two side quests, so many projects don't mean no progress on any.

/// What counts toward a time target. Every field set must match; nil means "any".
public struct QuotaTrack: Codable, Sendable, Equatable, Hashable {
    public var project: String?
    public var area: String?
    public var category: ActivityCategory?

    public init(project: String? = nil, area: String? = nil, category: ActivityCategory? = nil) {
        self.project = project; self.area = area; self.category = category
    }

    public var isEmpty: Bool { project == nil && area == nil && category == nil }

    func matches(_ c: Classification) -> Bool {
        if let p = project, c.project?.caseInsensitiveCompare(p) != .orderedSame { return false }
        if let a = area, c.area?.caseInsensitiveCompare(a) != .orderedSame { return false }
        if let k = category, c.category != k { return false }
        return true
    }

    public var label: String {
        [project, area, category?.title].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Up to 12 weeks, one main quest, up to two side quests, each with the hours a week you mean to give it.
public struct Season: Codable, Sendable, Equatable, Identifiable {
    public struct Quest: Codable, Sendable, Equatable, Hashable, Identifiable {
        public var project: String
        public var hoursPerWeek: Int
        public var id: String { project }
        public init(project: String, hoursPerWeek: Int) { self.project = project; self.hoursPerWeek = max(1, hoursPerWeek) }
    }

    public static let maxSideQuests = 2
    public var start: String
    public var end: String
    public var main: Quest
    public var sides: [Quest]
    /// Minutes per quest (project, lowercased) for each season week, keyed by the week's first day.
    public var log: [String: [String: Int]]?
    /// Areas that still need doing but don't move the season (admin, gym): named so the coach plans around them.
    public var support: [String]?
    /// Checkpoints per quest, and the weekly hours you protect for each (SeasonPlan.swift).
    public var milestones: [Milestone]?
    public var protected: [ProtectedTime]?
    /// What you commit to this season, in your words, and when you signed it.
    public var manifesto: String?
    public var signed: Date?
    /// Set when the season was ended (early or on time) and moved to `Planner.pastSeasons`.
    public var ended: String?

    public init(start: String, end: String, main: Quest, sides: [Quest] = []) {
        self.start = start; self.end = end; self.main = main; self.sides = Array(sides.prefix(Self.maxSideQuests))
    }

    public var quests: [Quest] { [main] + sides }
    public var id: String { start }

    public func isActive(on day: String) -> Bool { day >= start && day <= end }
}

public enum Quests {
    /// Minutes that count toward `track`: timeline spans that match, plus focus sessions whose area (or task's
    /// project) matches — overlapping time counts once.
    public static func minutes(_ track: QuotaTrack, spans: [ActivitySpan], sessions: [FocusSession] = [], tasks: [PlannerTask] = [],
                               classifier: Classifier, now: Date = .now) -> Int {
        let tracked = spans.filter { track.matches(classifier.classify($0)) }
        // A focus session has no category, so it only counts toward project/area targets.
        let focus: [ActivitySpan] = track.category != nil ? [] : sessions.compactMap { s in
            let project = s.taskID.flatMap { id in tasks.first { $0.id == id }?.project }
            guard track.matches(Classification(category: .other, project: project, area: s.area)) else { return nil }
            return ActivitySpan(start: s.start, end: s.end ?? now, app: "headroom.focus", appName: "Focus", title: s.title, project: project)
        }
        return Int(TimelineMath.covered(tracked + focus) / 60)
    }

    /// Minutes per project, for the season card.
    public static func minutesByProject(spans: [ActivitySpan], classifier: Classifier) -> [String: Int] {
        var groups: [String: [ActivitySpan]] = [:]
        for s in spans { if let p = classifier.classify(s).project { groups[p.lowercased(), default: []].append(s) } }
        return groups.mapValues { Int(TimelineMath.covered($0) / 60) }
    }
}

extension Habit {
    /// Minutes a day that check this habit off on their own (nil = checked by hand).
    public var isTimed: Bool { (minutes ?? 0) > 0 && track.map { !$0.isEmpty } == true }
}

extension Planner {
    /// Checks off timed habits whose target is met today. Returns the ones it checked (to celebrate once).
    /// Never unchecks: a habit you ticked yourself stays ticked.
    @discardableResult
    public mutating func applyQuotas(_ minutes: [UUID: Int], on date: Date = .now, calendar: Calendar = .current) -> [Habit] {
        let key = Self.key(date, calendar: calendar)
        var met: [Habit] = []
        for i in habits.indices where habits[i].isTimed && !habits[i].archived && habits[i].kind == .build {
            guard let target = habits[i].minutes, (minutes[habits[i].id] ?? 0) >= target, !habits[i].done.contains(key) else { continue }
            habits[i].done.insert(key)
            met.append(habits[i])
        }
        return met
    }

    /// The Monday-to-Sunday week holding `date`, as day keys.
    public static func week(of date: Date, calendar: Calendar = .current) -> [String] {
        var cal = calendar
        cal.firstWeekday = 2
        guard let start = cal.dateInterval(of: .weekOfYear, for: date)?.start else { return [key(date, calendar: calendar)] }
        return (0..<7).map { key(daysFrom: start, $0, calendar: calendar) }
    }
}

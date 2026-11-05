import Foundation

// Goals to hours, after Superfocus (Ali Abdaal's GPS method) but kept local and white-hat: seasons up to
// 12 weeks with an honest weekly read on each quest, time blocks that give the work a place in the day,
// a plan-strength score (how much of what's left this week has a block), and focus mode — how well a
// session actually went, and a gentle shield against distractions while it runs.

// MARK: - Time blocks

/// A slot in a day for one piece of work. Lives in planner.json — your calendar is never written.
public struct TimeBlock: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public var title: String
    public var day: String
    /// Minutes after midnight.
    public var start: Int
    public var end: Int
    public var project: String?
    public var taskID: UUID?
    public var fromCoach: Bool?

    public init(title: String, day: String, start: Int, end: Int, project: String? = nil, taskID: UUID? = nil) {
        self.title = title; self.day = day
        self.start = min(max(start, 0), 24 * 60 - 5); self.end = min(max(end, self.start + 5), 24 * 60)
        self.project = project; self.taskID = taskID
    }

    public var minutes: Int { end - start }

    public func interval(calendar: Calendar = .current) -> DateInterval? {
        guard let d = Planner.date(day, calendar: calendar) else { return nil }
        return DateInterval(start: d.addingTimeInterval(TimeInterval(start * 60)), end: d.addingTimeInterval(TimeInterval(end * 60)))
    }

    /// "09:30" ↔ 570.
    public static func minute(_ text: String) -> Int? {
        let p = text.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0...24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return min(p[0] * 60 + p[1], 24 * 60)
    }

    public static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
}

extension Planner {
    public func blocks(on day: String) -> [TimeBlock] { blocks.filter { $0.day == day }.sorted { $0.start < $1.start } }

    /// Adds a block. Returns nil when it would overlap another block that day (two things can't have the same hour).
    @discardableResult
    public mutating func addBlock(_ b: TimeBlock) -> TimeBlock? {
        guard !blocks.contains(where: { $0.day == b.day && $0.start < b.end && $0.end > b.start }) else { return nil }
        blocks.append(b)
        return b
    }

    /// The block happening now, if any.
    public func currentBlock(_ now: Date = .now, calendar: Calendar = .current) -> TimeBlock? {
        let day = Self.key(now, calendar: calendar)
        let m = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return blocks.first { $0.day == day && $0.start <= m && m < $0.end }
    }

    /// The first free slot of `minutes` on a day at or after `from`, around blocks and calendar events (busy).
    public func firstFree(on day: String, from: Int, minutes: Int, busy: [DateInterval] = [], until: Int = 22 * 60,
                          calendar: Calendar = .current) -> Int? {
        guard let midnight = Self.date(day, calendar: calendar) else { return nil }
        var taken = blocks(on: day).map { ($0.start, $0.end) }
        for b in busy {
            let s = Int(b.start.timeIntervalSince(midnight) / 60), e = Int(b.end.timeIntervalSince(midnight) / 60)
            if e > 0 && s < 24 * 60 { taken.append((max(0, s), min(24 * 60, e))) }
        }
        var t = from
        for (s, e) in taken.sorted(by: { $0.0 < $1.0 }) {
            if s - t >= minutes { break }
            t = max(t, e)
        }
        return t + minutes <= until ? t : nil
    }
}

// MARK: - Seasons, week by week

public enum GoalStatus: String, Codable, Sendable { case onTrack, adjust, offTrack, upcoming }

extension Season {
    public var days: Int {
        guard let s = Planner.date(start), let e = Planner.date(end) else { return 14 }
        return (Calendar.current.dateComponents([.day], from: s, to: e).day ?? 13) + 1
    }
    public var weekCount: Int { (days + 6) / 7 }

    /// 1-based day of the season, nil outside it.
    public func dayNumber(on day: String, calendar: Calendar = .current) -> Int? {
        guard isActive(on: day), let s = Planner.date(start, calendar: calendar), let d = Planner.date(day, calendar: calendar) else { return nil }
        return (calendar.dateComponents([.day], from: s, to: d).day ?? 0) + 1
    }

    /// Season weeks are 7-day stretches from its first day (w1, w2…), not calendar weeks.
    public func weekIndex(on day: String, calendar: Calendar = .current) -> Int? {
        dayNumber(on: day, calendar: calendar).map { ($0 - 1) / 7 }
    }

    /// The days of week `index` (the last week may be short).
    public func weekDays(_ index: Int, calendar: Calendar = .current) -> [String] {
        guard let s = Planner.date(start, calendar: calendar) else { return [] }
        return (0..<7).map { Planner.key(daysFrom: s, index * 7 + $0, calendar: calendar) }.filter { $0 <= end }
    }

    /// How a quest stands in one week. `elapsed` is how much of the week has gone (1 for a finished week):
    /// the current week is judged on pace, not on the full target.
    public static func status(minutes: Int, hoursPerWeek: Int, elapsed: Double) -> GoalStatus {
        guard elapsed > 0 else { return .upcoming }
        let expected = Double(hoursPerWeek * 60) * min(1, elapsed)
        guard expected > 0 else { return .onTrack }
        let pace = Double(minutes) / expected
        // TODO(human): where "on track" ends. Default: 90% of the pace or better is on track, 60% needs adjusting.
        if pace >= 0.9 { return .onTrack }
        if pace >= 0.6 { return .adjust }
        return .offTrack
    }

    /// Every quest's status, week by week, from the season's recorded minutes. Weeks to come are `.upcoming`.
    public func grid(now: Date = .now, calendar: Calendar = .current) -> [(quest: Quest, weeks: [GoalStatus])] {
        let today = Planner.key(now, calendar: calendar)
        let current = weekIndex(on: today, calendar: calendar) ?? (today > end ? weekCount : -1)
        return quests.map { q in
            (q, (0..<weekCount).map { i -> GoalStatus in
                if i > current { return .upcoming }
                let minutes = log?[weekDays(i, calendar: calendar).first ?? ""]?[q.project.lowercased()] ?? 0
                var elapsed = 1.0
                if i == current {
                    let days = weekDays(i, calendar: calendar)
                    let done = Double(days.filter { $0 < today }.count)
                    let hour = Double(calendar.component(.hour, from: now)) / 24
                    elapsed = (done + hour) / Double(max(1, days.count))
                }
                return Self.status(minutes: minutes, hoursPerWeek: q.hoursPerWeek, elapsed: elapsed)
            })
        }
    }
}

extension Planner {
    /// Saves this season-week's minutes per project (lowercased) so the weekly grid outlives the timeline's 30 days.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func recordSeasonWeek(_ minutes: [String: Int], on date: Date = .now, calendar: Calendar = .current) -> Bool {
        guard var s = season, let i = s.weekIndex(on: Self.key(date, calendar: calendar), calendar: calendar),
              let key = s.weekDays(i, calendar: calendar).first else { return false }
        let wanted = minutes.filter { k, _ in s.quests.contains { $0.project.lowercased() == k } }
        guard s.log?[key] != wanted else { return false }
        var log = s.log ?? [:]
        log[key] = wanted
        s.log = log
        season = s
        return true
    }
}

// MARK: - Plan strength

public struct PlanStrength: Sendable, Equatable {
    /// 0…1: how much of the hours still needed this season-week already have a block.
    public var score: Double
    /// Minutes per quest still needed with no block for them.
    public var gaps: [String: Int]

    /// Done + blocked ahead, against each quest's weekly hours. Blocks count toward the quest whose project
    /// (or title) names it; blocks already past count only through the time actually tracked.
    public static func of(_ planner: Planner, done: [String: Int], now: Date = .now, calendar: Calendar = .current) -> PlanStrength? {
        guard let s = planner.season, let i = s.weekIndex(on: Planner.key(now, calendar: calendar), calendar: calendar) else { return nil }
        let days = Set(s.weekDays(i, calendar: calendar))
        let ahead = planner.blocks.filter { days.contains($0.day) && ($0.interval(calendar: calendar)?.end ?? .distantPast) > now }
        var needed = 0, covered = 0
        var gaps: [String: Int] = [:]
        for q in s.quests {
            let left = max(0, q.hoursPerWeek * 60 - (done[q.project.lowercased()] ?? 0))
            let blocked = ahead.filter { b in
                (b.project ?? b.title).range(of: q.project, options: .caseInsensitive) != nil
            }.reduce(0) { total, b in
                // A block under way counts only for what's left of it.
                let iv = b.interval(calendar: calendar)
                return total + (iv.map { Int(max(0, $0.end.timeIntervalSince(max(now, $0.start))) / 60) } ?? b.minutes)
            }
            needed += left
            covered += min(left, blocked)
            if left > blocked { gaps[q.project] = left - blocked }
        }
        return PlanStrength(score: needed == 0 ? 1 : Double(covered) / Double(needed), gaps: gaps)
    }
}

// MARK: - Focus mode

public enum FocusMode {
    /// Share of a session not spent on distractions (from the timeline), nil without timeline data in it.
    public static func quality(_ session: FocusSession, spans: [ActivitySpan], classifier: Classifier, now: Date = .now) -> Double? {
        let window = DateInterval(start: session.start, end: max(session.start, session.end ?? now))
        guard window.duration >= 60 else { return nil }
        let inside = spans.compactMap { s -> ActivitySpan? in
            guard s.end > s.start, let i = DateInterval(start: s.start, end: s.end).intersection(with: window) else { return nil }
            var c = s; c.start = i.start; c.end = i.end
            return c
        }
        guard !inside.isEmpty else { return nil }
        let distracted = TimelineMath.covered(inside.filter { classifier.classify($0).category.isDistraction })
        return max(0, 1 - distracted / window.duration)
    }

    /// What the shield does when a distraction comes to the front during a focus session.
    public enum Shield: String, Codable, Sendable, CaseIterable { case off, remind, hide }

    public enum Reaction: Equatable, Sendable { case none, remind(String), hide }

    /// Pure: what to do about the front app (and site) right now. Reminds at most every `quiet` seconds;
    /// hiding is for apps only (a browser isn't hidden for one tab — that gets a reminder).
    public static func react(_ mode: Shield, running: FocusSession?, front: ActivitySpan, classifier: Classifier,
                             lastReminder: Date?, now: Date = .now, quiet: TimeInterval = 5 * 60) -> Reaction {
        guard mode != .off, let running, classifier.classify(front).category.isDistraction else { return .none }
        if mode == .hide && front.host == nil { return .hide }
        if let last = lastReminder, now.timeIntervalSince(last) < quiet { return .none }
        return .remind("You're focusing on \(running.title) — \(front.host ?? front.appName) can wait.")
    }
}

// MARK: - The coach's blocks

/// A block the coach suggests ("09:30"–"11:00"); nothing is placed until you tick it and press Add.
public struct BlockSuggestion: Codable, Sendable, Equatable, Hashable {
    public var title: String
    public var day: String?
    public var start: String
    public var end: String
    public var project: String?
    public init(title: String, day: String? = nil, start: String, end: String, project: String? = nil) {
        self.title = title; self.day = day; self.start = start; self.end = end; self.project = project
    }
}

/// One specific fix from the weekly review ("Move Ship v2 to your mornings").
public struct Recommendation: Codable, Sendable, Equatable, Hashable {
    public var title: String
    public var why: String
    public init(title: String, why: String) { self.title = title; self.why = why }
}

extension Planner {
    /// Places ticked block suggestions; any that clash with a block already there are skipped. Returns how many landed.
    @discardableResult
    public mutating func acceptBlocks(_ suggestions: [BlockSuggestion], day: String) -> Int {
        suggestions.reduce(0) { n, s in
            guard let a = TimeBlock.minute(s.start), let b = TimeBlock.minute(s.end), b > a else { return n }
            var block = TimeBlock(title: s.title, day: s.day ?? day, start: a, end: b, project: s.project)
            block.fromCoach = true
            return addBlock(block) == nil ? n : n + 1
        }
    }
}

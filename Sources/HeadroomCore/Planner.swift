import Foundation

/// Your tasks and habits — the planner add-on. Built on four ideas:
/// clarity (the Big 3: at most three tasks that matter today), execution (one click to finish),
/// evidence (XP and streaks computed from what you actually did, never stored as a score that can drift)
/// and reflection (identity "votes" — every completion counts toward who you're becoming).
///
/// Lives in `planner.json` beside Headroom's other data. The app and `headroom-cli` both write it, so every
/// change goes through `PlannerStore.mutate`, which re-reads the file first: an add from Claude Code in a
/// terminal is never lost to the window's older copy.
public struct Planner: Codable, Sendable, Equatable {
    public var tasks: [PlannerTask] = []
    public var habits: [Habit] = []

    public init() {}

    /// Only three tasks a day can be big: choosing is the point.
    public static let bigLimit = 3

    // MARK: Days

    /// "2026-11-01" in the Mac's own time zone: a habit done at 23:30 counts for that evening, wherever you are.
    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func date(_ key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    public static func key(daysFrom date: Date, _ days: Int, calendar: Calendar = .current) -> String {
        key(calendar.date(byAdding: .day, value: days, to: date) ?? date, calendar: calendar)
    }

    // MARK: Tasks

    /// Today's list: anything planned for today or earlier and still open (it rolls forward), plus what was
    /// finished today. Big ones first.
    public func today(_ now: Date = .now, calendar: Calendar = .current) -> [PlannerTask] {
        let today = Self.key(now, calendar: calendar)
        return tasks.filter { t in
            if let done = t.done { return Self.key(done, calendar: calendar) == today }
            return t.day.map { $0 <= today } ?? false
        }
        .sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            if a.big != b.big { return a.big }
            return a.created < b.created
        }
    }

    public func bigToday(_ now: Date = .now, calendar: Calendar = .current) -> [PlannerTask] {
        today(now, calendar: calendar).filter(\.big)
    }

    /// Planned for a later day.
    public func upcoming(_ now: Date = .now, calendar: Calendar = .current) -> [PlannerTask] {
        let today = Self.key(now, calendar: calendar)
        return tasks.filter { !$0.isDone && ($0.day ?? "") > today }.sorted { ($0.day ?? "") < ($1.day ?? "") }
    }

    /// No day yet: captured, not committed to.
    public var inbox: [PlannerTask] { tasks.filter { !$0.isDone && $0.day == nil }.sorted { $0.created < $1.created } }

    /// Whether another task can be big on that day (finished big ones still count: three is three).
    public func canMakeBig(on day: String, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let todayKey = Self.key(now, calendar: calendar)
        let onToday = Set(today(now, calendar: calendar).map(\.id))
        let count = tasks.filter { t in
            guard t.big else { return false }
            return day == todayKey ? onToday.contains(t.id) : t.day == day
        }.count
        return count < Self.bigLimit
    }

    @discardableResult
    public mutating func add(_ title: String, day: String?, big: Bool = false, project: String? = nil,
                             source: PlannerTask.Source = .app, now: Date = .now, calendar: Calendar = .current) -> PlannerTask {
        let wantsBig = big && canMakeBig(on: day ?? Self.key(now, calendar: calendar), now: now, calendar: calendar)
        let task = PlannerTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines), created: now, day: day,
                               big: wantsBig && day != nil, project: project, source: source)
        tasks.append(task)
        return task
    }

    public mutating func update(_ id: UUID, _ change: (inout PlannerTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
    }

    public mutating func complete(_ id: UUID, at date: Date = .now) {
        update(id) { $0.done = $0.done == nil ? date : nil }
    }

    public mutating func remove(_ id: UUID) { tasks.removeAll { $0.id == id } }

    /// Finished tasks older than 90 days go; XP already counted them only while they're kept, so the level is
    /// "what you've done lately" rather than a number that only grows.
    public mutating func prune(now: Date = .now) {
        tasks.removeAll { $0.done.map { now.timeIntervalSince($0) > 90 * 86_400 } ?? false }
    }

    // MARK: Habits

    public func habitsDue(_ now: Date = .now, calendar: Calendar = .current) -> [Habit] {
        habits.filter { !$0.archived && $0.isScheduled(now, calendar: calendar) }
    }

    public mutating func toggleHabit(_ id: UUID, on date: Date = .now, calendar: Calendar = .current) {
        guard let i = habits.firstIndex(where: { $0.id == id }) else { return }
        let key = Self.key(date, calendar: calendar)
        if habits[i].done.contains(key) { habits[i].done.remove(key) } else { habits[i].done.insert(key) }
    }

    // MARK: Progress

    /// Every point comes from something done, so nothing can be farmed: a task is 10, a big one 30, a habit
    /// check-in 10 plus a little for keeping its streak alive (capped, so a long streak is a bonus, not a wall
    /// to protect at all costs).
    public func xp(calendar: Calendar = .current) -> Int {
        let fromTasks = tasks.reduce(0) { $0 + ($1.isDone ? ($1.big ? 30 : 10) : 0) }
        var fromHabits = 0
        for h in habits {
            var run = 0
            var previous: String?
            for day in h.done.sorted() {
                let next = previous.flatMap { Self.date($0, calendar: calendar) }.map { Self.key(daysFrom: $0, 1, calendar: calendar) }
                run = next == day ? run + 1 : 1
                fromHabits += 10 + min(run - 1, 5) * 2
                previous = day
            }
        }
        return fromTasks + fromHabits
    }

    public struct Level: Sendable, Equatable {
        public var number: Int
        /// XP into this level, and how much the level needs.
        public var into: Int
        public var needed: Int
        public var fraction: Double { needed > 0 ? Double(into) / Double(needed) : 0 }
    }

    /// Each level needs 100 XP more than the last (100, 200, 300…): early levels come in a day or two,
    /// later ones reward weeks of showing up.
    public static func level(for xp: Int) -> Level {
        var level = 1, floor = 0
        while xp >= floor + level * 100 { floor += level * 100; level += 1 }
        return Level(number: level, into: xp - floor, needed: level * 100)
    }

    /// Votes for each identity this week (Monday on): habit check-ins whose habit names that identity.
    public func votes(weekOf now: Date = .now, calendar: Calendar = .current) -> [(identity: String, votes: Int)] {
        var cal = calendar
        cal.firstWeekday = 2
        guard let week = cal.dateInterval(of: .weekOfYear, for: now) else { return [] }
        let start = Self.key(week.start, calendar: cal), end = Self.key(week.end.addingTimeInterval(-1), calendar: cal)
        var tally: [String: Int] = [:]
        for h in habits where !(h.identity ?? "").isEmpty {
            tally[h.identity!, default: 0] += h.done.filter { $0 >= start && $0 <= end }.count
        }
        return tally.map { ($0.key, $0.value) }.sorted { $0.votes > $1.votes }
    }
}

public struct PlannerTask: Codable, Sendable, Identifiable, Equatable, Hashable {
    /// Where it was added from: the window, the quick-add panel, the CLI (you or a coding agent).
    public enum Source: String, Codable, Sendable { case app, quickAdd, cli, claude }

    public var id = UUID()
    public var title: String
    public var created: Date
    /// "2026-11-01"; nil = inbox, not planned yet.
    public var day: String?
    public var big: Bool
    public var done: Date?
    /// A project name or path, so work can be grouped (and later matched to Claude Code sessions).
    public var project: String?
    public var source: Source
    public var isDone: Bool { done != nil }
}

/// A habit in the Atomic Habits shape: who it makes you (identity), when it happens (the cue, often
/// "after I …" — stacked on something you already do), and the two-minute version for hard days.
public struct Habit: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public var title: String
    public var identity: String?
    public var cue: String?
    public var twoMinute: String?
    /// Weekdays it's planned for, 1 = Sunday … 7 = Saturday (Calendar's numbering); empty = every day.
    public var weekdays: Set<Int> = []
    /// Minutes after midnight for the nudge; nil = no nudge.
    public var remindAt: Int?
    public var created: Date
    /// Day keys it was done on.
    public var done: Set<String> = []
    public var archived = false

    public init(title: String, identity: String? = nil, cue: String? = nil, twoMinute: String? = nil,
                weekdays: Set<Int> = [], remindAt: Int? = nil, created: Date = .now) {
        self.title = title; self.identity = identity; self.cue = cue; self.twoMinute = twoMinute
        self.weekdays = weekdays; self.remindAt = remindAt; self.created = created
    }

    public func isScheduled(_ date: Date, calendar: Calendar = .current) -> Bool {
        weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: date))
    }

    public func isDone(_ date: Date = .now, calendar: Calendar = .current) -> Bool {
        done.contains(Planner.key(date, calendar: calendar))
    }

    public enum Streak: Sendable, Equatable {
        /// Kept going: this many planned days done, with at most single misses in between.
        case going(Int)
        /// Missed the last planned day: today decides ("never miss twice").
        case missedOnce(Int)
        /// Two planned days in a row missed: start again, no shame.
        case none
    }

    /// "Never miss twice": one missed planned day bends the streak, two in a row break it. Today only counts
    /// once it's done — the day isn't over. Looks back at most a year.
    public func streak(_ now: Date = .now, calendar: Calendar = .current) -> Streak {
        let createdKey = Planner.key(created, calendar: calendar)
        var count = 0, missesInARow = 0
        var lastPlannedMissed: Bool? = nil // the most recent planned day before today
        for back in 0..<366 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: now) else { break }
            let key = Planner.key(day, calendar: calendar)
            if done.contains(key) {
                count += 1
                missesInARow = 0
                if back > 0, lastPlannedMissed == nil { lastPlannedMissed = false }
                continue
            }
            // Today isn't a miss yet; days before the habit existed never are.
            if back == 0 || key < createdKey || !isScheduled(day, calendar: calendar) {
                if key < createdKey { break }
                continue
            }
            if lastPlannedMissed == nil { lastPlannedMissed = true }
            missesInARow += 1
            if missesInARow == 2 { break }
        }
        if count == 0 { return .none }
        // (Two misses right behind today stop the walk before anything is counted: that's `.none` above.)
        if lastPlannedMissed == true, !isDone(now, calendar: calendar) { return .missedOnce(count) }
        return .going(count)
    }

    /// The last `days` planned-or-not days, oldest first: done, missed, or not planned.
    public func recent(_ days: Int = 7, now: Date = .now, calendar: Calendar = .current) -> [(key: String, done: Bool, scheduled: Bool)] {
        (0..<days).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { return nil }
            let key = Planner.key(d, calendar: calendar)
            return (key, done.contains(key), key >= Planner.key(created, calendar: calendar) && isScheduled(d, calendar: calendar))
        }
    }
}

/// Reads and writes `planner.json`. Every write re-reads first, so two writers (the app and the CLI) merge
/// instead of overwriting each other.
public enum PlannerStore {
    public static var defaultURL: URL { HeadroomPaths.support.appendingPathComponent("planner.json") }

    public static func load(from url: URL = defaultURL) -> Planner {
        guard let data = try? Data(contentsOf: url) else { return Planner() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Planner.self, from: data)) ?? Planner()
    }

    public static func save(_ planner: Planner, to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(planner) { try? data.write(to: url, options: .atomic) }
    }

    @discardableResult
    public static func mutate<T>(at url: URL = defaultURL, _ change: (inout Planner) -> T) -> (Planner, T) {
        var planner = load(from: url)
        let result = change(&planner)
        save(planner, to: url)
        return (planner, result)
    }

    public static func modified(at url: URL = defaultURL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

import Foundation

/// Your tasks and habits — the planner add-on. Built on four ideas:
/// clarity (the Big 3: at most three tasks that matter today), execution (one click to finish),
/// evidence (XP and streaks computed from what you actually did, never stored as a score that can drift)
/// and reflection (identity "votes" — every completion counts toward who you're becoming).
///
/// Lives in `planner.json` beside Headroom's other data. The app and `headroom-cli` both write it, so every
/// change goes through `PlannerStore.mutate`, which locks and re-reads the file first: an add from Claude Code
/// in a terminal is never lost to the window's older copy, nor to another add running at the same moment.
public struct Planner: Codable, Sendable, Equatable {
    public var tasks: [PlannerTask] = []
    public var habits: [Habit] = []
    /// Focus sessions, rewards you set yourself, what you spent coins on, and habit challenges (Progression.swift).
    public var sessions: [FocusSession] = []
    public var rewards: [Reward] = []
    public var purchases: [Purchase] = []
    public var challenges: [Challenge] = []
    /// The current two weeks' main and side quests (Quests.swift).
    public var season: Season?
    /// Journal entries and mood/energy check-ins, one per day (LifeLog.swift).
    public var logs: [DayLog] = []

    public init() {}

    // Missing keys decode to their defaults, so a file written by an older or newer Headroom still reads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decodeIfPresent([PlannerTask].self, forKey: .tasks) ?? []
        habits = try c.decodeIfPresent([Habit].self, forKey: .habits) ?? []
        sessions = try c.decodeIfPresent([FocusSession].self, forKey: .sessions) ?? []
        rewards = try c.decodeIfPresent([Reward].self, forKey: .rewards) ?? []
        purchases = try c.decodeIfPresent([Purchase].self, forKey: .purchases) ?? []
        challenges = try c.decodeIfPresent([Challenge].self, forKey: .challenges) ?? []
        season = try c.decodeIfPresent(Season.self, forKey: .season)
        logs = try c.decodeIfPresent([DayLog].self, forKey: .logs) ?? []
    }

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

    /// Whether another task can be big on that day (finished big ones still count: three is three). A day
    /// before today means today — that's where an overdue task shows. `except` leaves out the task being changed.
    public func canMakeBig(on day: String, except: UUID? = nil, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let todayKey = Self.key(now, calendar: calendar)
        let day = max(day, todayKey)
        let onToday = Set(today(now, calendar: calendar).map(\.id))
        let count = tasks.filter { t in
            guard t.big, t.id != except else { return false }
            return day == todayKey ? onToday.contains(t.id) : t.day == day && !t.isDone
        }.count
        return count < Self.bigLimit
    }

    /// Plans a task for a day (nil = back to the inbox). It stays big only if that day has room.
    public mutating func schedule(_ id: UUID, day: String?, now: Date = .now, calendar: Calendar = .current) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].day = day
        if tasks[i].big, day.map({ !canMakeBig(on: $0, except: id, now: now, calendar: calendar) }) ?? true { tasks[i].big = false }
    }

    /// Makes a task one of the Big 3 (or not). Returns false when its day is already full, or it has no day.
    @discardableResult
    public mutating func setBig(_ id: UUID, _ big: Bool, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return false }
        if big {
            guard let day = tasks[i].day, canMakeBig(on: day, except: id, now: now, calendar: calendar) else { return false }
        }
        tasks[i].big = big
        return true
    }

    @discardableResult
    public mutating func add(_ title: String, day: String?, big: Bool = false, project: String? = nil, effort: Int = 1,
                             area: String? = nil, source: PlannerTask.Source = .app, now: Date = .now,
                             calendar: Calendar = .current) -> PlannerTask {
        let wantsBig = big && canMakeBig(on: day ?? Self.key(now, calendar: calendar), now: now, calendar: calendar)
        var task = PlannerTask(title: title.trimmingCharacters(in: .whitespacesAndNewlines), created: now, day: day,
                               big: wantsBig && day != nil, project: project, source: source)
        task.effort = min(max(effort, 1), 3)
        task.area = area?.trimmingCharacters(in: .whitespaces).nilIfBlank
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

    // MARK: Habits

    public func habitsDue(_ now: Date = .now, calendar: Calendar = .current) -> [Habit] {
        habits.filter { !$0.archived && $0.isScheduled(now, calendar: calendar) }
    }

    public mutating func toggleHabit(_ id: UUID, on date: Date = .now, calendar: Calendar = .current) {
        guard let i = habits.firstIndex(where: { $0.id == id }) else { return }
        let key = Self.key(date, calendar: calendar)
        if habits[i].done.contains(key) { habits[i].done.remove(key) } else { habits[i].done.insert(key) }
    }

    /// Checks a habit off (never unchecks: running it twice is harmless).
    public mutating func checkHabit(_ id: UUID, on date: Date = .now, calendar: Calendar = .current) {
        guard let i = habits.firstIndex(where: { $0.id == id }) else { return }
        habits[i].done.insert(Self.key(date, calendar: calendar))
    }

    // MARK: Progress

    /// Every point comes from something done (see `ledger`), so nothing can be farmed and nothing drifts.
    /// Nothing is ever taken away for time passing: the level only grows.
    public func xp(now: Date = .now, calendar: Calendar = .current) -> Int {
        ledger(now: now, calendar: calendar).reduce(0) { $0 + $1.xp }
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
    public static func level(for xp: Int, step: Int = 100) -> Level {
        var level = 1, floor = 0
        while xp >= floor + level * step { floor += level * step; level += 1 }
        return Level(number: level, into: xp - floor, needed: level * step)
    }

    /// Votes for each identity this week (Monday on): habit check-ins whose habit names that identity.
    public func votes(weekOf now: Date = .now, calendar: Calendar = .current) -> [(identity: String, votes: Int)] {
        var cal = calendar
        cal.firstWeekday = 2
        guard let week = cal.dateInterval(of: .weekOfYear, for: now) else { return [] }
        let start = Self.key(week.start, calendar: cal), end = Self.key(week.end.addingTimeInterval(-1), calendar: cal)
        var tally: [String: Int] = [:]
        for h in habits where !h.archived && !(h.identity ?? "").isEmpty {
            tally[h.identity!, default: 0] += h.done.filter { $0 >= start && $0 <= end }.count
        }
        return tally.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.votes > $1.votes }
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
    /// How hard: 1 easy, 2 medium, 3 hard (10/20/30 XP, +20 for one of the Big 3).
    public var effort = 1
    /// The life area it grows (Health, Work, Writing…): its XP also levels that area.
    public var area: String?
    public var isDone: Bool { done != nil }
    public var xp: Int { effort * 10 + (big ? 20 : 0) }

    public init(title: String, created: Date, day: String?, big: Bool, project: String?, source: Source) {
        self.title = title; self.created = created; self.day = day; self.big = big; self.project = project; self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? .now
        day = try c.decodeIfPresent(String.self, forKey: .day)
        big = try c.decodeIfPresent(Bool.self, forKey: .big) ?? false
        done = try c.decodeIfPresent(Date.self, forKey: .done)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .app
        effort = min(max(try c.decodeIfPresent(Int.self, forKey: .effort) ?? 1, 1), 3)
        area = try c.decodeIfPresent(String.self, forKey: .area)
    }
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
    /// Build a habit (check it off) or break one (log a slip; every clean day counts). No damage, no HP.
    public enum Kind: String, Codable, Sendable { case build, avoid }
    public var kind: Kind = .build
    /// Days an avoid-habit slipped.
    public var slips: Set<String> = []
    /// The life area it grows.
    public var area: String?
    /// A daily time target, measured from the timeline and focus sessions (Quests.swift).
    public var minutes: Int?
    public var track: QuotaTrack?
    /// Checked off by a commit of yours (LifeLog.swift).
    public var proof: HabitProof?

    public init(title: String, identity: String? = nil, cue: String? = nil, twoMinute: String? = nil,
                weekdays: Set<Int> = [], remindAt: Int? = nil, created: Date = .now) {
        self.title = title; self.identity = identity; self.cue = cue; self.twoMinute = twoMinute
        self.weekdays = weekdays; self.remindAt = remindAt; self.created = created
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        identity = try c.decodeIfPresent(String.self, forKey: .identity)
        cue = try c.decodeIfPresent(String.self, forKey: .cue)
        twoMinute = try c.decodeIfPresent(String.self, forKey: .twoMinute)
        weekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? []
        remindAt = try c.decodeIfPresent(Int.self, forKey: .remindAt)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? .distantPast
        done = try c.decodeIfPresent(Set<String>.self, forKey: .done) ?? []
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .build
        slips = try c.decodeIfPresent(Set<String>.self, forKey: .slips) ?? []
        area = try c.decodeIfPresent(String.self, forKey: .area)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        track = try? c.decodeIfPresent(QuotaTrack.self, forKey: .track)
        proof = try? c.decodeIfPresent(HabitProof.self, forKey: .proof)
    }

    /// The planned day before this one (within a week), as a key.
    public func plannedDay(before date: Date, calendar: Calendar = .current) -> String? {
        for back in 1...7 {
            guard let d = calendar.date(byAdding: .day, value: -back, to: date) else { return nil }
            if isScheduled(d, calendar: calendar) { return Planner.key(d, calendar: calendar) }
        }
        return nil
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
        if kind == .avoid {
            let clean = cleanDays(now, calendar: calendar)
            return clean > 0 ? .going(clean) : .none
        }
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

/// Reads and writes `planner.json`. Every write takes a lock and re-reads first, so writers (the app, any
/// number of CLI runs at once) merge instead of overwriting each other.
public enum PlannerStore {
    public static var defaultURL: URL { HeadroomPaths.support.appendingPathComponent("planner.json") }

    public static func load(from url: URL = defaultURL) -> Planner {
        guard let data = try? Data(contentsOf: url) else { return Planner() }
        return (try? decode(data)) ?? Planner()
    }

    static func decode(_ data: Data) throws -> Planner {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Planner.self, from: data)
    }

    /// For a write: a file that exists but can't be read is set aside (planner-unreadable-<date>.json) before
    /// anything replaces it — your tasks are never silently swapped for an empty list.
    static func loadForWrite(from url: URL) -> Planner {
        guard let data = try? Data(contentsOf: url) else { return Planner() }
        if let planner = try? decode(data) { return planner }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("planner-unreadable-\(stamp).json")
        try? FileManager.default.copyItem(at: url, to: aside)
        return Planner()
    }

    public static func save(_ planner: Planner, to url: URL = defaultURL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(planner) { try? data.write(to: url, options: .atomic) }
    }

    /// Locked read → change → write. `modified` is the file's date right after this write, read under the
    /// lock, so a watcher that records it can't skip someone else's write that lands just after.
    @discardableResult
    public static func mutate<T>(at url: URL = defaultURL, _ change: (inout Planner) -> T) -> (planner: Planner, result: T, modified: Date?) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }
        var planner = loadForWrite(from: url)
        let result = change(&planner)
        save(planner, to: url)
        return (planner, result, modified(at: url))
    }

    public static func modified(at url: URL = defaultURL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

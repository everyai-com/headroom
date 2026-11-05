import Foundation

// The planner's game layer, after LiFE RPG and Octalysis but kept white-hat: everything you earn comes from
// something you did, nothing is ever taken away for missing a day, and nothing costs coins to "protect".
//
// - Ledger: every XP and coin is worked out from tasks, habits, focus sessions, challenges and purchases —
//   never stored — so undoing a task takes its points back and nothing can drift.
// - Coins: earned 1:1 with XP, spent on rewards you set yourself. Spending never lowers your level.
// - Areas: tasks and habits name a life area (Health, Work…); each area levels on its own, faster curve.

/// A stretch of focused work. Running while `end` is nil; one at a time.
public struct FocusSession: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public var title: String
    public var start: Date
    public var end: Date?
    public var taskID: UUID?
    public var area: String?
    /// Found in the timeline (40+ minutes in one project), not started by hand.
    public var detected: Bool?
    /// How it felt, asked when you stop it.
    public var feel: Feel?

    /// At most this much of one session counts (a timer left running overnight isn't a night of work).
    public static let maxMinutes = 180
    /// Shorter than this earns nothing: a focus session is a decision, not a click.
    public static let minMinutes = 5

    public init(title: String, start: Date = .now, taskID: UUID? = nil, area: String? = nil) {
        self.title = title; self.start = start; self.taskID = taskID; self.area = area
    }

    public var isRunning: Bool { end == nil }

    public func minutes(now: Date = .now) -> Int {
        min(Self.maxMinutes, max(0, Int((end ?? now).timeIntervalSince(start) / 60)))
    }

    /// 20 XP an hour (one per three minutes), only once a session is over.
    public var xp: Int {
        guard let end else { return 0 }
        let m = min(Self.maxMinutes, Int(end.timeIntervalSince(start) / 60))
        return m >= Self.minMinutes ? m / 3 : 0
    }
}

/// Something you'd enjoy, priced in coins by you.
public struct Reward: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public var title: String
    public var cost: Int
    public var created: Date
    public var archived = false

    public init(title: String, cost: Int, created: Date = .now) {
        self.title = title; self.cost = max(1, cost); self.created = created
    }
}

public struct Purchase: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public var rewardID: UUID?
    public var title: String
    public var cost: Int
    public var date: Date

    public init(rewardID: UUID?, title: String, cost: Int, date: Date) {
        self.rewardID = rewardID; self.title = title; self.cost = cost; self.date = date
    }
}

/// "Do this habit N times between these days" (LiFE RPG's boss fight). Reaching it pays a bonus; running out
/// of days just ends it — no failure penalty.
public struct Challenge: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public var title: String
    public var habitID: UUID
    public var target: Int
    /// Day keys, inclusive.
    public var start: String
    public var end: String

    public init(title: String, habitID: UUID, target: Int, start: String, end: String) {
        self.title = title; self.habitID = habitID; self.target = max(1, target); self.start = start; self.end = end
    }

    public var bonus: Int { min(300, target * 10) }
}

/// One line of "what earned what".
public struct LedgerEntry: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case task, habit, clean, focus, challenge, purchase, journal, checkin, sync, milestone }
    public var id: String
    public var date: Date
    public var kind: Kind
    public var title: String
    public var xp: Int
    public var coins: Int
    public var area: String?
}

extension Habit {
    /// Avoid-habits: consecutive clean days up to yesterday (today isn't over), since it was made or last slipped.
    public func cleanDays(_ now: Date = .now, calendar: Calendar = .current) -> Int {
        let createdKey = Planner.key(created, calendar: calendar)
        var days = 0
        for back in 1...366 {
            guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { break }
            let key = Planner.key(d, calendar: calendar)
            if key < createdKey || slips.contains(key) { break }
            days += 1
        }
        return days
    }

    public func slipped(_ date: Date = .now, calendar: Calendar = .current) -> Bool {
        slips.contains(Planner.key(date, calendar: calendar))
    }
}

extension Planner {
    // MARK: Ledger

    /// Everything that earned (or spent) points, newest first.
    public func ledger(now: Date = .now, calendar: Calendar = .current) -> [LedgerEntry] {
        var out: [LedgerEntry] = []
        func noon(_ key: String) -> Date { Self.date(key, calendar: calendar)?.addingTimeInterval(12 * 3600) ?? now }

        for t in tasks {
            guard let done = t.done else { continue }
            out.append(LedgerEntry(id: "t" + t.id.uuidString, date: done, kind: .task, title: t.title, xp: t.xp, coins: t.xp, area: t.area))
        }
        let todayKey = Self.key(now, calendar: calendar)
        for h in habits {
            switch h.kind {
            case .build:
                // 10 a check-in, plus 2 for each planned day in a row before it (up to +10): a long run is a bonus,
                // not a wall to protect.
                var run = 0
                var previous: String?
                for day in h.done.sorted() {
                    let plannedBefore = Self.date(day, calendar: calendar).flatMap { h.plannedDay(before: $0, calendar: calendar) }
                    run = previous != nil && previous == plannedBefore ? run + 1 : 1
                    let xp = 10 + min(run - 1, 5) * 2
                    out.append(LedgerEntry(id: "h" + h.id.uuidString + day, date: noon(day), kind: .habit, title: h.title, xp: xp, coins: xp, area: h.area))
                    previous = day
                }
            case .avoid:
                // 5 for every finished day without a slip, since the habit was made (at most a year back).
                let createdKey = Self.key(h.created, calendar: calendar)
                for back in 1...366 {
                    guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { break }
                    let key = Self.key(d, calendar: calendar)
                    if key < createdKey { break }
                    if key >= todayKey || h.slips.contains(key) { continue }
                    out.append(LedgerEntry(id: "c" + h.id.uuidString + key, date: noon(key), kind: .clean, title: h.title, xp: 5, coins: 5, area: h.area))
                }
            }
        }
        for s in sessions where s.xp > 0 {
            out.append(LedgerEntry(id: "f" + s.id.uuidString, date: s.end ?? now, kind: .focus, title: s.title, xp: s.xp, coins: s.xp, area: s.area))
        }
        for c in challenges where challengeProgress(c, now: now, calendar: calendar) >= c.target {
            let h = habits.first { $0.id == c.habitID }
            out.append(LedgerEntry(id: "x" + c.id.uuidString, date: challengeReached(c, calendar: calendar) ?? now, kind: .challenge,
                                   title: c.title, xp: c.bonus, coins: c.bonus, area: h?.area))
        }
        out += logEntries(calendar: calendar)
        out += milestoneEntries(calendar: calendar)
        for p in purchases {
            out.append(LedgerEntry(id: "p" + p.id.uuidString, date: p.date, kind: .purchase, title: p.title, xp: 0, coins: -p.cost, area: nil))
        }
        return out.sorted { $0.date > $1.date }
    }

    /// Coins to spend: earned (1:1 with XP) minus spent. Can dip below zero only if you undo things after spending.
    public func coins(now: Date = .now, calendar: Calendar = .current) -> Int {
        ledger(now: now, calendar: calendar).reduce(0) { $0 + $1.coins }
    }

    // MARK: Areas

    public struct AreaProgress: Sendable, Equatable, Identifiable {
        public var name: String
        public var xp: Int
        public var level: Level
        public var id: String { name }
    }

    /// Every area named by a task, habit or session, with its level (a faster curve: 50, 100, 150…).
    public func areas(now: Date = .now, calendar: Calendar = .current) -> [AreaProgress] {
        var xp: [String: Int] = [:]
        for name in tasks.compactMap(\.area) + habits.filter { !$0.archived }.compactMap(\.area) { xp[name, default: 0] += 0 }
        for e in ledger(now: now, calendar: calendar) { if let a = e.area { xp[a, default: 0] += e.xp } }
        return xp.map { AreaProgress(name: $0.key, xp: $0.value, level: Self.level(for: $0.value, step: 50)) }
            .sorted { $0.xp != $1.xp ? $0.xp > $1.xp : $0.name < $1.name }
    }

    // MARK: Ranks

    /// A title every few levels — something to aim at between level-ups.
    public static let ranks: [(level: Int, title: String)] = [
        (1, "Novice"), (3, "Apprentice"), (6, "Adept"), (10, "Expert"), (15, "Master"), (21, "Grandmaster"), (30, "Legend"),
    ]

    public static func rank(for level: Int) -> (title: String, next: (level: Int, title: String)?) {
        let i = ranks.lastIndex { $0.level <= level } ?? 0
        return (ranks[i].title, ranks.indices.contains(i + 1) ? ranks[i + 1] : nil)
    }

    // MARK: Focus

    public var runningSession: FocusSession? { sessions.first { $0.isRunning } }

    /// Starts a session (ending any that's running).
    @discardableResult
    public mutating func startFocus(_ title: String, taskID: UUID? = nil, area: String? = nil, now: Date = .now) -> FocusSession {
        stopFocus(now: now)
        let area = area ?? taskID.flatMap { id in tasks.first { $0.id == id }?.area }
        let s = FocusSession(title: title, start: now, taskID: taskID, area: area)
        sessions.append(s)
        return s
    }

    @discardableResult
    public mutating func stopFocus(now: Date = .now) -> FocusSession? {
        guard let i = sessions.firstIndex(where: \.isRunning) else { return nil }
        sessions[i].end = min(now, sessions[i].start.addingTimeInterval(TimeInterval(FocusSession.maxMinutes * 60)))
        return sessions[i]
    }

    public func focusMinutes(on date: Date = .now, calendar: Calendar = .current) -> Int {
        let key = Self.key(date, calendar: calendar)
        return sessions.filter { Self.key($0.start, calendar: calendar) == key }.reduce(0) { $0 + $1.minutes(now: date) }
    }

    // MARK: Rewards

    public enum BuyResult: Equatable, Sendable { case bought(Purchase), short(by: Int), missing }

    public mutating func buy(_ rewardID: UUID, now: Date = .now, calendar: Calendar = .current) -> BuyResult {
        guard let r = rewards.first(where: { $0.id == rewardID && !$0.archived }) else { return .missing }
        let have = coins(now: now, calendar: calendar)
        guard have >= r.cost else { return .short(by: r.cost - have) }
        let p = Purchase(rewardID: r.id, title: r.title, cost: r.cost, date: now)
        purchases.append(p)
        return .bought(p)
    }

    // MARK: Challenges

    /// Check-ins (or clean days, for an avoid-habit) inside the challenge's days.
    public func challengeProgress(_ c: Challenge, now: Date = .now, calendar: Calendar = .current) -> Int {
        guard let h = habits.first(where: { $0.id == c.habitID }) else { return 0 }
        switch h.kind {
        case .build:
            return h.done.filter { $0 >= c.start && $0 <= c.end }.count
        case .avoid:
            let todayKey = Self.key(now, calendar: calendar)
            guard let first = Self.date(c.start, calendar: calendar) else { return 0 }
            var count = 0
            for i in 0..<400 {
                guard let d = calendar.date(byAdding: .day, value: i, to: first) else { break }
                let key = Self.key(d, calendar: calendar)
                if key > c.end || key >= todayKey { break }
                if key >= Self.key(h.created, calendar: calendar) && !h.slips.contains(key) { count += 1 }
            }
            return count
        }
    }

    /// The day the target was reached (for the ledger), for a build habit.
    func challengeReached(_ c: Challenge, calendar: Calendar) -> Date? {
        guard let h = habits.first(where: { $0.id == c.habitID }), h.kind == .build else { return nil }
        let days = h.done.filter { $0 >= c.start && $0 <= c.end }.sorted()
        guard days.count >= c.target else { return nil }
        return Self.date(days[c.target - 1], calendar: calendar)?.addingTimeInterval(12 * 3600)
    }

    public enum ChallengeState: Equatable, Sendable { case upcoming, active(daysLeft: Int), won, ended }

    public func state(of c: Challenge, now: Date = .now, calendar: Calendar = .current) -> ChallengeState {
        if challengeProgress(c, now: now, calendar: calendar) >= c.target { return .won }
        let today = Self.key(now, calendar: calendar)
        if today < c.start { return .upcoming }
        if today > c.end { return .ended }
        let days = Self.date(c.end, calendar: calendar).map { calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: $0).day ?? 0 } ?? 0
        return .active(daysLeft: days + 1)
    }

    // MARK: Avoid-habits

    public mutating func toggleSlip(_ id: UUID, on date: Date = .now, calendar: Calendar = .current) {
        guard let i = habits.firstIndex(where: { $0.id == id }) else { return }
        let key = Self.key(date, calendar: calendar)
        if habits[i].slips.contains(key) { habits[i].slips.remove(key) } else { habits[i].slips.insert(key) }
    }
}

extension Planner {
    /// Quick capture: "Run 5k #health !!" → title "Run 5k", area "Health", effort 2. "!!!" is hard; one "!" stays easy.
    public static func parseCapture(_ text: String) -> (title: String, area: String?, effort: Int) {
        var words: [Substring] = []
        var area: String?
        var effort = 1
        for w in text.split(separator: " ", omittingEmptySubsequences: true) {
            if w.count > 1, w.hasPrefix("#"), area == nil {
                let name = w.dropFirst()
                area = name.prefix(1).uppercased() + name.dropFirst()
            } else if (1...3).contains(w.count), w.allSatisfy({ $0 == "!" }) {
                effort = w.count
            } else {
                words.append(w)
            }
        }
        return (words.joined(separator: " "), area, effort)
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

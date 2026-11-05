import Foundation

// The rest of the Superfocus loop, kept local: milestones and protected hours per quest, a signed season
// commitment, a daily focus score (planned work done = 90%, the evening sync = the last 10%), how work felt
// (energizing or draining) and when you work best, a stack that places the day's tasks into free time, the
// one "top thing" a day is for, and a wrap when the season ends.

// MARK: - Milestones and protected time

/// A checkpoint on the way to a quest, with the day it should be done by.
public struct Milestone: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public var title: String
    public var project: String
    public var due: String?
    public var done: String?
    /// "Working on it now": pinned ones lead the season card and the coach's week.
    public var pinned: Bool?

    public init(title: String, project: String, due: String? = nil) {
        self.title = title; self.project = project; self.due = due
    }

    /// Past its day and not done by it.
    public func isLate(today: String) -> Bool {
        guard let due, due < today else { return false }
        return done.map { $0 > due } ?? true
    }

    /// 30 XP when you tick it: the visible progress a big goal needs.
    public static let xp = 30
}

/// Hours you guard for a quest every week ("Mon–Fri 9:00–11:00 is Connector SaaS").
public struct ProtectedTime: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id = UUID()
    public var project: String
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    public var start: Int
    public var end: Int

    public init(project: String, weekdays: Set<Int>, start: Int, end: Int) {
        self.project = project; self.weekdays = weekdays; self.start = start; self.end = max(end, start + 15)
    }

    public var minutesPerWeek: Int { weekdays.count * (end - start) }
}

extension Season {
    /// This day's protected time, as blocks to draw (never stored).
    public func protectedBlocks(on day: String, calendar: Calendar = .current) -> [TimeBlock] {
        guard isActive(on: day), let d = Planner.date(day, calendar: calendar) else { return [] }
        let weekday = calendar.component(.weekday, from: d)
        return (protected ?? []).filter { $0.weekdays.contains(weekday) }.map { p in
            var b = TimeBlock(title: p.project, day: day, start: p.start, end: p.end, project: p.project)
            b.protected = true
            return b
        }
    }

    /// Milestones still open, pinned first, then by due day.
    public var openMilestones: [Milestone] {
        (milestones ?? []).filter { $0.done == nil }.sorted { a, b in
            if (a.pinned ?? false) != (b.pinned ?? false) { return a.pinned ?? false }
            return (a.due ?? "9999") < (b.due ?? "9999")
        }
    }
}

extension Planner {
    /// Protected time with no real block on top of it: a block you place inside it takes its place.
    public func protectedBlocks(on day: String, calendar: Calendar = .current) -> [TimeBlock] {
        let real = blocks(on: day)
        return (season?.protectedBlocks(on: day, calendar: calendar) ?? []).filter { p in
            !real.contains { $0.start < p.end && $0.end > p.start }
        }
    }

    public mutating func editSeason(_ change: (inout Season) -> Void) {
        guard var s = season else { return }
        change(&s)
        season = s
    }

    public mutating func editMilestone(_ id: UUID, _ change: (inout Milestone) -> Void) {
        editSeason { s in if let i = s.milestones?.firstIndex(where: { $0.id == id }) { change(&s.milestones![i]) } }
    }

    /// Ticks a milestone (or unticks it). Done is a day, so lateness is a fact, not a judgement.
    public mutating func toggleMilestone(_ id: UUID, now: Date = .now, calendar: Calendar = .current) {
        guard var s = season, var list = s.milestones, let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].done = list[i].done == nil ? Self.key(now, calendar: calendar) : nil
        if list[i].done != nil { list[i].pinned = nil }
        s.milestones = list
        season = s
    }

    /// Ends the season: it moves to `pastSeasons` (for the wrap) with the day it ended.
    public mutating func endSeason(now: Date = .now, calendar: Calendar = .current) {
        guard var s = season else { return }
        s.ended = min(s.end, Self.key(now, calendar: calendar))
        pastSeasons.append(s)
        season = nil
    }

    func milestoneEntries(calendar: Calendar) -> [LedgerEntry] {
        ((season.map { [$0] } ?? []) + pastSeasons).flatMap { s in
            (s.milestones ?? []).compactMap { m -> LedgerEntry? in
                guard let done = m.done else { return nil }
                let date = Self.date(done, calendar: calendar)?.addingTimeInterval(18 * 3600) ?? .now
                return LedgerEntry(id: "ms" + m.id.uuidString, date: date, kind: .milestone, title: m.title,
                                   xp: Milestone.xp, coins: Milestone.xp, area: nil)
            }
        }
    }
}

// MARK: - The daily focus score

/// Planned work done is up to 90%; the evening sync is the last 10%, so a day ends at 100% only once you've
/// looked back at it.
public struct DayScore: Sendable, Equatable {
    public var planned: Int
    public var done: Int
    public var synced: Bool

    public var value: Double {
        let work = planned == 0 ? (synced ? 1 : 0) : Double(done) / Double(planned)
        return work * 0.9 + (synced ? 0.1 : 0)
    }
    public var percent: Int { Int((value * 100).rounded()) }
}

extension Planner {
    /// Tasks planned for the day (today also carries what rolled over), blocks not tied to a task (unless you
    /// left them out), and the day's habits to build.
    public func score(on date: Date = .now, now: Date = .now, calendar: Calendar = .current) -> DayScore {
        let key = Self.key(date, calendar: calendar)
        let todayKey = Self.key(now, calendar: calendar)
        let dayTasks = tasks.filter { t in
            if let d = t.done { return Self.key(d, calendar: calendar) == key || t.day == key }
            guard let day = t.day else { return false }
            return day == key || (key == todayKey && day < key)
        }
        let dayBlocks = blocks(on: key).filter { $0.taskID == nil && $0.counts != false }
        let dayHabits = habits.filter { !$0.archived && $0.kind == .build && $0.isScheduled(date, calendar: calendar) }
        let planned = dayTasks.count + dayBlocks.count + dayHabits.count
        let done = dayTasks.filter(\.isDone).count + dayBlocks.filter { $0.done != nil }.count
            + dayHabits.filter { $0.done.contains(key) }.count
        return DayScore(planned: planned, done: done, synced: log(on: key)?.isSynced ?? false)
    }

    /// The task a day is for, if you picked one.
    public func topThing(on day: String) -> PlannerTask? {
        log(on: day)?.top.flatMap { id in tasks.first { $0.id == id } }
    }
}

// MARK: - Energy and when you work best

/// How a block or a focus session felt.
public enum Feel: String, Codable, Sendable, CaseIterable {
    case energizing, neutral, draining
    public var title: String { switch self { case .energizing: "Energizing"; case .neutral: "Neutral"; case .draining: "Draining" } }
    public var symbol: String { switch self { case .energizing: "bolt.fill"; case .neutral: "minus.circle"; case .draining: "battery.25" } }
}

/// Morning (before noon), afternoon (to 5 pm), evening (to 9 pm), night.
public enum DayPart: String, Codable, Sendable, CaseIterable {
    case morning, afternoon, evening, night

    public static func of(minute: Int) -> DayPart {
        switch minute {
        case 5 * 60..<12 * 60: .morning
        case 12 * 60..<17 * 60: .afternoon
        case 17 * 60..<21 * 60: .evening
        default: .night
        }
    }

    public static func of(_ date: Date, calendar: Calendar = .current) -> DayPart {
        of(minute: calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
    }

    public var title: String { rawValue.capitalized }

    /// The season wrap's line for when you focus most.
    public var chronotype: String {
        switch self {
        case .morning: "You do your best work in the morning"
        case .afternoon: "You hit your stride in the afternoon"
        case .evening: "You hit your stride in the evening"
        case .night: "You come alive after dark"
        }
    }

    /// The part of the day with the most finished focus minutes.
    public static func peak(_ sessions: [FocusSession], calendar: Calendar = .current) -> DayPart? {
        var minutes: [DayPart: Int] = [:]
        for s in sessions where !s.isRunning { minutes[of(s.start, calendar: calendar), default: 0] += s.minutes() }
        return minutes.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }
}

public enum EnergyPatterns {
    public struct Tally: Sendable, Equatable { public var energizing = 0, draining = 0 }

    /// Energizing/draining counts by part of the day and by project, from rated sessions and blocks since `since`.
    public static func tally(_ p: Planner, since: Date, calendar: Calendar = .current) -> (parts: [DayPart: Tally], projects: [String: Tally]) {
        var parts: [DayPart: Tally] = [:], projects: [String: Tally] = [:]
        func add(_ feel: Feel?, _ part: DayPart, _ project: String?) {
            guard let feel, feel != .neutral else { return }
            var t = parts[part] ?? Tally()
            if feel == .energizing { t.energizing += 1 } else { t.draining += 1 }
            parts[part] = t
            if let project {
                var pt = projects[project] ?? Tally()
                if feel == .energizing { pt.energizing += 1 } else { pt.draining += 1 }
                projects[project] = pt
            }
        }
        for s in p.sessions where s.start >= since {
            let project = s.taskID.flatMap { id in p.tasks.first { $0.id == id }?.project } ?? s.area
            add(s.feel, DayPart.of(s.start, calendar: calendar), project)
        }
        for b in p.blocks {
            guard let d = Planner.date(b.day, calendar: calendar), d >= calendar.startOfDay(for: since) else { continue }
            add(b.feel, DayPart.of(minute: b.start), b.project)
        }
        return (parts, projects)
    }

    /// Plain lines for the coach and the Progress screen ("Afternoons drained you 4 times, energized you once").
    public static func lines(_ p: Planner, since: Date, calendar: Calendar = .current) -> [String] {
        let t = tally(p, since: since, calendar: calendar)
        func times(_ n: Int) -> String { n == 1 ? "once" : "\(n) times" }
        let parts = DayPart.allCases.compactMap { part -> String? in
            guard let x = t.parts[part], x.energizing + x.draining > 0 else { return nil }
            return "\(part.title)s energized you \(times(x.energizing)), drained you \(times(x.draining))"
        }
        let projects = t.projects.sorted { $0.key < $1.key }.map { name, x in
            "\(name): energized \(times(x.energizing)), drained \(times(x.draining))"
        }
        return parts + projects
    }
}

extension FocusMode {
    /// What a focus quality score means.
    public static func verdict(_ quality: Double) -> String {
        switch Int((quality * 100).rounded()) {
        case 90...: "Locked in. Great session"
        case 70..<90: "Solid focus with a few distractions"
        case 50..<70: "In and out of focus"
        default: "Tough one. The distractions won"
        }
    }
}

// MARK: - The stack: the day's tasks, placed in free time

public enum Stack {
    /// How long a task's block should be when the stack places it.
    public static func minutes(for task: PlannerTask) -> Int {
        // TODO(human): how long a task gets. Default: 30 min per effort point (1–3), plus 30 for a big one.
        task.effort * 30 + (task.big ? 30 : 0)
    }
}

extension Planner {
    /// Blocks for the day's open tasks that don't have one yet, big ones first: a task for a quest goes into
    /// that quest's protected time when there's room, anything else into free time around blocks, protected
    /// time and calendar events. Proposals only — nothing is added until you keep them.
    public func stack(on day: String, from: Int, busy: [DateInterval] = [], now: Date = .now, calendar: Calendar = .current) -> [TimeBlock] {
        var copy = self
        let taken = Set(blocks.filter { $0.day == day }.compactMap(\.taskID))
        let open = (day == Self.key(now, calendar: calendar) ? today(now, calendar: calendar) : tasks.filter { $0.day == day })
            .filter { !$0.isDone && !taken.contains($0.id) }
            .sorted { a, b in a.big != b.big ? a.big : a.effort != b.effort ? a.effort > b.effort : a.created < b.created }
        var out: [TimeBlock] = []
        for t in open {
            let length = Stack.minutes(for: t)
            var start: Int?
            if let project = t.project {
                for p in protectedBlocks(on: day, calendar: calendar) where p.project?.caseInsensitiveCompare(project) == .orderedSame {
                    start = copy.firstFree(on: day, from: max(from, p.start), minutes: length, busy: busy, until: p.end, allow: project, calendar: calendar)
                    if start != nil { break }
                }
            }
            if start == nil { start = copy.firstFree(on: day, from: from, minutes: length, busy: busy, calendar: calendar) }
            guard let s = start else { continue }
            let b = TimeBlock(title: t.title, day: day, start: s, end: s + length, project: t.project, taskID: t.id)
            if copy.addBlock(b) != nil { out.append(b) }
        }
        return out
    }
}

// MARK: - The season wrap

public struct SeasonWrap: Sendable, Equatable {
    public struct QuestTotal: Sendable, Equatable {
        public var project: String
        public var minutes: Int
        public var target: Int
    }
    public var days: Int
    public var focusMinutes: Int
    public var focusDays: Int
    public var tasksDone: Int
    public var milestonesDone: Int
    public var milestones: Int
    public var quests: [QuestTotal]
    /// Weeks marked on track, out of all quest-weeks played.
    public var onTrack: Int
    public var weeks: Int
    public var peak: DayPart?
    /// The previous season's focus minutes, for "compared with last season".
    public var previousFocusMinutes: Int?

    public static func of(_ s: Season, planner: Planner, previous: Season? = nil, now: Date = .now, calendar: Calendar = .current) -> SeasonWrap {
        func range(_ s: Season) -> (String, String) { (s.start, min(s.ended ?? s.end, s.end)) }
        func inside(_ d: Date, _ s: Season) -> Bool { let k = Planner.key(d, calendar: calendar); let r = range(s); return k >= r.0 && k <= r.1 }
        let sessions = planner.sessions.filter { !$0.isRunning && inside($0.start, s) }
        let last = min(range(s).1, Planner.key(now, calendar: calendar))
        let days = s.dayNumber(on: last, calendar: calendar) ?? s.days
        let quests = s.quests.map { q in
            SeasonWrap.QuestTotal(project: q.project, minutes: (s.log ?? [:]).values.reduce(0) { $0 + ($1[q.project.lowercased()] ?? 0) },
                                  target: q.hoursPerWeek * 60 * s.weekCount)
        }
        let played = s.grid(now: now, calendar: calendar).flatMap(\.weeks).filter { $0 != .upcoming }
        return SeasonWrap(
            days: days,
            focusMinutes: sessions.reduce(0) { $0 + $1.minutes() },
            focusDays: Set(sessions.map { Planner.key($0.start, calendar: calendar) }).count,
            tasksDone: planner.tasks.filter { $0.done.map { inside($0, s) } ?? false }.count,
            milestonesDone: (s.milestones ?? []).filter { $0.done != nil }.count,
            milestones: (s.milestones ?? []).count,
            quests: quests,
            onTrack: played.filter { $0 == .onTrack }.count,
            weeks: played.count,
            peak: DayPart.peak(sessions, calendar: calendar),
            previousFocusMinutes: previous.map { p in planner.sessions.filter { !$0.isRunning && inside($0.start, p) }.reduce(0) { $0 + $1.minutes() } })
    }
}

// MARK: - Coach memory

/// What the coach knows about you, in your own words: a plain file you can read and edit, sent with every
/// coach prompt. The coach can suggest lines; they're added only when you tick them.
public struct CoachMemory: Sendable {
    public let url: URL
    public init(url: URL = HeadroomPaths.support.appendingPathComponent("coach-memory.md")) { self.url = url }

    public func load() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    public func save(_ text: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Adds lines as "- …" bullets, skipping ones already there.
    public func remember(_ lines: [String]) {
        var text = load()
        for l in lines.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !l.isEmpty && !text.contains(l) {
            if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
            text += "- \(l)\n"
        }
        save(text)
    }
}

// MARK: - Planning a season from a brain dump

/// What the coach suggests for a new season. Nothing is saved until you look it over and press Start.
public struct SeasonDraft: Codable, Sendable, Equatable {
    public struct Step: Codable, Sendable, Equatable, Hashable {
        public var title: String
        public var project: String
        /// Week of the season it should be done by (1-based).
        public var week: Int?
    }
    public var main: Season.Quest
    public var sides: [Season.Quest] = []
    public var support: [String] = []
    public var milestones: [Step] = []
    public var manifesto: String = ""
    /// Questions the coach would ask before committing; shown, never required.
    public var questions: [String] = []

    enum CodingKeys: String, CodingKey { case main, sides, support, milestones, manifesto, questions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        main = try c.decode(Season.Quest.self, forKey: .main)
        sides = Array(((try? c.decodeIfPresent([Season.Quest].self, forKey: .sides)) ?? []).prefix(Season.maxSideQuests))
        support = (try? c.decodeIfPresent([String].self, forKey: .support)) ?? []
        milestones = Array(((try? c.decodeIfPresent([Step].self, forKey: .milestones)) ?? []).prefix(15))
        manifesto = (try? c.decodeIfPresent(String.self, forKey: .manifesto)) ?? ""
        questions = Array(((try? c.decodeIfPresent([String].self, forKey: .questions)) ?? []).prefix(3))
    }

    /// The season this draft becomes, starting on `start` and running `weeks` weeks. Milestones land on the
    /// last day of their week.
    public func season(start: String, weeks: Int, calendar: Calendar = .current) -> Season? {
        guard let s = Planner.date(start, calendar: calendar) else { return nil }
        let w = min(max(weeks, 1), 12)
        var season = Season(start: start, end: Planner.key(daysFrom: s, w * 7 - 1, calendar: calendar), main: main, sides: sides)
        season.support = support.isEmpty ? nil : support
        season.milestones = milestones.map { m in
            Milestone(title: m.title, project: m.project, due: m.week.map { Planner.key(daysFrom: s, min(max($0, 1), w) * 7 - 1, calendar: calendar) })
        }
        season.manifesto = manifesto.isEmpty ? nil : manifesto
        return season
    }
}

extension Coach {
    /// For "Draft with Claude" in the season editor: goals from a brain dump, 3–5 at most.
    public static func seasonPrompt(dump: String, weeks: Int, _ c: DayContext, calendar: Calendar = .current) -> String {
        var lines = facts(c, calendar: calendar)
        lines.append("""

        The user is planning a new \(weeks)-week season. What they want to have achieved or experienced by the end:
        \"\"\"
        \(dump.prefix(6000))
        \"\"\"
        Turn it into a focused season — fewer goals done well beats many spread thin (3–5 at most in total):
        "main": the ONE core quest, as a short project name (reuse a project name from above when one fits) with realistic \
        "hoursPerWeek"; "sides": at most 2 secondary quests the same way; "support": areas that still need doing but don't \
        move the season (admin, gym…). "milestones": 2–5 per quest, each a visible checkpoint with the season "week" it \
        should be done by, spread across the season. "manifesto": 2–4 sentences in the first person that the user could \
        sign ("This season I…"), naming what they'll say no to. "questions": up to 3 short questions that would sharpen \
        the plan, only if something important is unclear.
        Reply with ONLY this JSON, no code fence: {"main": {"project": "…", "hoursPerWeek": 20}, "sides": [{"project": "…", "hoursPerWeek": 8}], "support": ["…"], "milestones": [{"title": "…", "project": "…", "week": 4}], "manifesto": "…", "questions": ["…"]}
        """)
        return lines.joined(separator: "\n")
    }

    public static func parseSeason(_ reply: String) -> SeasonDraft? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let draft = try? JSONDecoder().decode(SeasonDraft.self, from: Data(reply[open...close].utf8)),
              !draft.main.project.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return draft
    }
}

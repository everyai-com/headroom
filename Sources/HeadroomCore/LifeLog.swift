import Foundation

// The rest of LiFE RPG's daily loop, kept white-hat like the game layer: a journal (+10 XP a day), a one-tap
// mood and energy check-in (+5), sleep estimated from when the Mac rested, focus found on its own in the
// timeline, habits that your commits check off, and a month of every habit at a glance.

/// One day's journal and check-in. `reflection` is what your Claude CLI said about it, when you asked.
public struct DayLog: Codable, Sendable, Equatable, Identifiable {
    public var day: String
    /// 1 (low) … 5 (great); nil = not checked in.
    public var mood: Int?
    public var energy: Int?
    public var note: String = ""
    public var reflection: String?
    public var updated: Date
    public var id: String { day }

    public init(day: String, updated: Date = .now) { self.day = day; self.updated = updated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        mood = try c.decodeIfPresent(Int.self, forKey: .mood).map(DayLog.clamp)
        energy = try c.decodeIfPresent(Int.self, forKey: .energy).map(DayLog.clamp)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        reflection = try c.decodeIfPresent(String.self, forKey: .reflection)
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? .now
    }

    static func clamp(_ v: Int) -> Int { min(max(v, 1), 5) }

    /// A few real words: one line of "fine" isn't a journal entry.
    public static let minimumWords = 5
    public var isJournal: Bool { note.split(whereSeparator: \.isWhitespace).count >= Self.minimumWords }
    public var isCheckIn: Bool { mood != nil && energy != nil }

    public static let moodWords = ["", "rough", "low", "okay", "good", "great"]
    public static let energyWords = ["", "drained", "tired", "steady", "high", "buzzing"]
}

extension Planner {
    public func log(on day: String) -> DayLog? { logs.first { $0.day == day } }

    /// Changes a day's log, making it if it's new.
    public mutating func updateLog(_ day: String, now: Date = .now, _ change: (inout DayLog) -> Void) {
        if let i = logs.firstIndex(where: { $0.day == day }) {
            change(&logs[i]); logs[i].updated = now
        } else {
            var log = DayLog(day: day, updated: now)
            change(&log)
            logs.append(log)
        }
    }

    /// Ledger lines for journals and check-ins (Progression.swift adds them in).
    func logEntries(calendar: Calendar) -> [LedgerEntry] {
        logs.flatMap { l -> [LedgerEntry] in
            let noon = Self.date(l.day, calendar: calendar)?.addingTimeInterval(20 * 3600) ?? l.updated
            var out: [LedgerEntry] = []
            if l.isJournal { out.append(LedgerEntry(id: "j" + l.day, date: noon, kind: .journal, title: "Journal", xp: 10, coins: 10, area: nil)) }
            if l.isCheckIn { out.append(LedgerEntry(id: "m" + l.day, date: noon, kind: .checkin, title: "Check-in", xp: 5, coins: 5, area: nil)) }
            return out
        }
    }
}

// MARK: - Proof habits

/// "A commit checks this off": any commit of yours today, or only in one project.
public struct HabitProof: Codable, Sendable, Equatable, Hashable {
    public var project: String?
    public init(project: String? = nil) { self.project = project }

    public func matches(_ c: Commit) -> Bool {
        project.map { c.project.caseInsensitiveCompare($0) == .orderedSame } ?? true
    }

    public var label: String { project.map { "a commit in \($0)" } ?? "any commit" }
}

extension Planner {
    /// Checks off proof habits that today's commits satisfy. Returns the ones it checked. Never unchecks.
    @discardableResult
    public mutating func applyProof(_ commits: [Commit], on date: Date = .now, calendar: Calendar = .current) -> [Habit] {
        let key = Self.key(date, calendar: calendar)
        let today = commits.filter { Self.key($0.date, calendar: calendar) == key }
        var met: [Habit] = []
        for i in habits.indices where !habits[i].archived && habits[i].kind == .build && !habits[i].done.contains(key) {
            guard let proof = habits[i].proof, today.contains(where: proof.matches) else { continue }
            habits[i].done.insert(key)
            met.append(habits[i])
        }
        return met
    }
}

// MARK: - Focus found in the timeline

/// A stretch of one project with no distraction in it, long enough to be deep work.
public struct FocusStretch: Sendable, Equatable {
    public var project: String
    public var area: String?
    public var start: Date
    public var end: Date
    public init(project: String, area: String?, start: Date, end: Date) { self.project = project; self.area = area; self.start = start; self.end = end }
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

public enum FocusDetector {
    /// At least this long in one project counts as focus without pressing Start.
    public static let minMinutes = 40
    /// Gaps shorter than this (a sip of coffee, another window) don't break a stretch.
    public static let allowedGap: TimeInterval = 5 * 60
    /// A distraction longer than this does.
    public static let distractionBreak: TimeInterval = 2 * 60

    /// Finished stretches only (nothing in them for `allowedGap`), so one still going is never cut short.
    public static func stretches(_ spans: [ActivitySpan], classifier: Classifier, now: Date = .now) -> [FocusStretch] {
        var byProject: [String: (name: String, area: String?, spans: [ActivitySpan])] = [:]
        var breaks: [(Date, Date)] = []
        for s in spans where s.end > s.start {
            let c = classifier.classify(s)
            if c.category.isDistraction {
                if s.end.timeIntervalSince(s.start) >= distractionBreak { breaks.append((s.start, s.end)) }
                continue
            }
            guard let p = c.project else { continue }
            byProject[p.lowercased(), default: (p, c.area, [])].spans.append(s)
        }
        var out: [FocusStretch] = []
        for (_, group) in byProject {
            // Merge across short gaps, then cut wherever a real distraction sat inside.
            var merged: [(Date, Date)] = []
            for s in group.spans.sorted(by: { $0.start < $1.start }) {
                if let last = merged.last, s.start.timeIntervalSince(last.1) <= allowedGap { merged[merged.count - 1].1 = max(last.1, s.end) } else { merged.append((s.start, s.end)) }
            }
            for (start, end) in merged where now.timeIntervalSince(end) >= allowedGap {
                var pieces = [(start, end)]
                for b in breaks {
                    pieces = pieces.flatMap { p -> [(Date, Date)] in
                        guard b.0 < p.1, b.1 > p.0 else { return [p] }
                        return [(p.0, b.0), (b.1, p.1)].filter { $0.1 > $0.0 }
                    }
                }
                for p in pieces where p.1.timeIntervalSince(p.0) >= TimeInterval(minMinutes * 60) {
                    out.append(FocusStretch(project: group.name, area: group.area, start: p.0, end: p.1))
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}

extension Planner {
    /// Records found stretches as focus sessions (marked `detected`), skipping any that overlap a session
    /// already there — yours or one found earlier. Long ones are split at the 3 h cap so none of it is lost.
    @discardableResult
    public mutating func recordDetectedFocus(_ stretches: [FocusStretch]) -> [FocusSession] {
        var added: [FocusSession] = []
        let cap = TimeInterval(FocusSession.maxMinutes * 60)
        for st in stretches {
            var start = st.start
            while st.end.timeIntervalSince(start) >= TimeInterval(FocusSession.minMinutes * 60) {
                let end = min(st.end, start.addingTimeInterval(cap))
                let overlaps = sessions.contains { s in s.start < end && (s.end ?? .distantFuture) > start }
                if !overlaps {
                    var s = FocusSession(title: "Deep work · \(st.project)", start: start, area: st.area)
                    s.end = end
                    s.detected = true
                    sessions.append(s)
                    added.append(s)
                }
                start = end
            }
        }
        return added
    }
}

// MARK: - Sleep, from when the Mac rested

/// When the Mac slept, woke, locked or unlocked. Times only — nothing about what was on screen.
public struct RestEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case sleep, wake, lock, unlock, launch }
    public var date: Date
    public var kind: Kind
    public init(_ kind: Kind, at date: Date) { self.kind = kind; self.date = date }
    var isAway: Bool { kind == .sleep || kind == .lock }
}

public struct SleepEstimate: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

public enum Rest {
    /// Away stretches: from a sleep or lock to the next wake, unlock or launch.
    public static func away(_ events: [RestEvent]) -> [DateInterval] {
        var out: [DateInterval] = []
        var since: Date?
        for e in events.sorted(by: { $0.date < $1.date }) {
            if e.isAway { if since == nil { since = e.date } } else if let s = since {
                if e.date > s { out.append(DateInterval(start: s, end: e.date)) }
                since = nil
            }
        }
        return out
    }

    /// The night that ended on `day`: the longest time away from the Mac that looks like sleep. Short trips
    /// back to the Mac in the night (under 20 minutes) don't split it. An estimate — the Mac only knows when
    /// you weren't at it.
    public static func night(endingOn day: String, events: [RestEvent], calendar: Calendar = .current) -> SleepEstimate? {
        guard let midnight = Planner.date(day, calendar: calendar) else { return nil }
        var joined: [DateInterval] = []
        for a in away(events) {
            if let last = joined.last, a.start.timeIntervalSince(last.end) < 20 * 60 {
                joined[joined.count - 1] = DateInterval(start: last.start, end: max(last.end, a.end))
            } else { joined.append(a) }
        }
        return joined.filter { looksLikeSleep($0, midnight: midnight) }
            .max { $0.duration < $1.duration }
            .map { SleepEstimate(start: $0.start, end: $0.end) }
    }

    /// Whether one away stretch could be the night's sleep. `midnight` is the start of the day it ends on.
    static func looksLikeSleep(_ a: DateInterval, midnight: Date) -> Bool {
        // TODO(human): the rule for "this was sleep". Default: 3–14 h away, starting between 18:00 the evening
        // before and 06:00, and ending between 03:00 and 14:00 that day.
        let hours = a.duration / 3600
        let startsFrom = midnight.addingTimeInterval(-6 * 3600), startsBy = midnight.addingTimeInterval(6 * 3600)
        let endsFrom = midnight.addingTimeInterval(3 * 3600), endsBy = midnight.addingTimeInterval(14 * 3600)
        return hours >= 3 && hours <= 14 && a.start >= startsFrom && a.start <= startsBy && a.end >= endsFrom && a.end <= endsBy
    }
}

/// `rest.json`: the Mac's sleep, wake, lock and unlock times, 30 days of them.
public struct RestStore: Sendable {
    public let url: URL
    public init(url: URL = HeadroomPaths.support.appendingPathComponent("rest.json")) { self.url = url }

    public func load() -> [RestEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? d.decode([RestEvent].self, from: data)) ?? []
    }

    public func append(_ event: RestEvent, now: Date = .now) {
        let keep = load().filter { now.timeIntervalSince($0.date) < 30 * 86_400 } + [event]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        if let data = try? e.encode(keep) { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - A month of habits

public enum DayMark: Sendable, Equatable { case done, missed, slipped, clean, off, future }

extension Habit {
    /// Every day of the month holding `date`: done, missed (planned, not done), slipped, clean (avoid-habits),
    /// off (not planned, or before the habit existed), or still to come. Today isn't a miss until it's over.
    public func month(of date: Date, now: Date = .now, calendar: Calendar = .current) -> [(key: String, mark: DayMark)] {
        guard let range = calendar.range(of: .day, in: .month, for: date),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else { return [] }
        let today = Planner.key(now, calendar: calendar), createdKey = Planner.key(created, calendar: calendar)
        return (0..<range.count).compactMap { i in
            guard let d = calendar.date(byAdding: .day, value: i, to: first) else { return nil }
            let key = Planner.key(d, calendar: calendar)
            let mark: DayMark
            if kind == .avoid {
                mark = slips.contains(key) ? .slipped : key > today || key == today ? .future : key < createdKey ? .off : .clean
            } else if done.contains(key) {
                mark = .done
            } else if key >= today {
                mark = .future
            } else {
                mark = key < createdKey || !isScheduled(d, calendar: calendar) ? .off : .missed
            }
            return (key, mark)
        }
    }
}

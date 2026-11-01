import Foundation
import HeadroomCore

/// `headroom-cli today|add|done|later|habits|habit` — the planner from a terminal, so you or a coding agent
/// (Claude Code) can plan the day without leaving the shell. These write only Headroom's own planner.json,
/// never a file of yours; the app picks the change up within seconds.
enum PlannerCommands {
    static let names: Set<String> = ["today", "add", "done", "later", "habits", "habit"]

    static func run(_ args: [String], json: Bool) {
        var rest = Array(args.dropFirst())
        func flag(_ name: String) -> Bool {
            guard let i = rest.firstIndex(of: name) else { return false }
            rest.remove(at: i)
            return true
        }
        func option(_ name: String) -> String? {
            guard let i = rest.firstIndex(of: name), rest.indices.contains(i + 1) else { return nil }
            let value = rest[i + 1]
            rest.removeSubrange(i...i + 1)
            return value
        }
        let now = Date()
        let today = Planner.key(now)

        switch args[0] {
        case "today":
            show(PlannerStore.load(), json: json)

        case "add":
            let big = flag("--big")
            let project = option("--project")
            let source: PlannerTask.Source = option("--from") == "claude" ? .claude : .cli
            var day: String? = today
            if flag("--tomorrow") { day = Planner.key(daysFrom: now, 1) }
            if flag("--inbox") { day = nil }
            if let d = option("--day") { day = dayKey(d) }
            _ = flag("--today")
            let title = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { fail("usage: headroom-cli add \"what to do\" [--big] [--tomorrow|--day YYYY-MM-DD|--inbox] [--project name]") }
            let task = PlannerStore.mutate { $0.add(title, day: day, big: big, project: project, source: source) }.result
            if json { emitJSON(taskJSON(task)); return }
            if big && !task.big { print(day == nil ? "Added to the inbox (plan it for a day to make it big)." : "Already three big tasks that day — added as an ordinary one.") }
            else { print("Added\(task.big ? " ★" : ""): \(task.title)\(day.map { $0 == today ? "" : " (\($0))" } ?? " (inbox)")") }

        case "done", "later":
            let ref = rest.joined(separator: " ")
            let tomorrow = Planner.key(daysFrom: now, 1)
            let (planner, outcome, _) = PlannerStore.mutate { p -> Result<PlannerTask, Lookup> in
                // Numbers are the ones `today` prints (today's open tasks); words and ids also reach the inbox and later days.
                let numbered = p.today(now).filter { !$0.isDone }
                let found = find(ref, numbered: numbered, in: numbered + p.inbox + p.upcoming(now))
                guard case .success(let t) = found else { return found }
                if args[0] == "done" { p.complete(t.id, at: now) }
                else if (t.day ?? "") < tomorrow { p.schedule(t.id, day: tomorrow, now: now) } // never pulls a later day forward
                return .success(t)
            }
            let found = outcome.or(ref)
            if json { emitJSON(taskJSON(planner.tasks.first { $0.id == found.id } ?? found)) }
            else {
                print(args[0] == "done" ? "Done: \(found.title)  (+\(found.big ? 30 : 10) XP · \(levelLine(planner)))" : "Moved to tomorrow: \(found.title)")
            }

        case "habits":
            showHabits(PlannerStore.load(), json: json)

        case "habit":
            let sub = rest.first ?? ""
            rest = Array(rest.dropFirst())
            if sub == "add" {
                let identity = option("--identity"), cue = option("--cue"), two = option("--two-minute")
                var at: Int?
                if let s = option("--at") {
                    guard let m = minutes(s) else { fail("--at wants a time like 21:00") }
                    at = m
                }
                var weekdays: Set<Int> = []
                if let s = option("--days") {
                    guard let d = parseWeekdays(s) else { fail("--days wants names like mon,wed,fri (or weekdays)") }
                    weekdays = d
                }
                let title = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { fail("usage: headroom-cli habit add \"Read 10 pages\" [--identity \"a reader\"] [--cue \"after dinner\"] [--two-minute \"read one page\"] [--at 21:00] [--days mon,wed,fri]") }
                let habit = Habit(title: title, identity: identity, cue: cue, twoMinute: two, weekdays: weekdays, remindAt: at)
                PlannerStore.mutate { $0.habits.append(habit) }
                print("New habit: \(title)\(identity.map { " — every time is a vote for being \($0)" } ?? "")")
            } else if sub == "done" {
                let undo = flag("--undo")
                let ref = rest.joined(separator: " ")
                let (planner, outcome, _) = PlannerStore.mutate { p -> Result<Habit, Lookup> in
                    let due = p.habitsDue(now)
                    let found = find(ref, numbered: due, in: due)
                    guard case .success(let h) = found else { return found }
                    // Checking is idempotent (an agent retrying can't uncheck it); --undo unchecks.
                    if undo { if h.isDone(now) { p.toggleHabit(h.id, on: now) } } else { p.checkHabit(h.id, on: now) }
                    return .success(h)
                }
                let found = outcome.or(ref, what: "habit due today")
                guard let h = planner.habits.first(where: { $0.id == found.id }) else { fail("That habit is gone.") }
                if json { emitJSON(habitJSON(h)); return }
                print(h.isDone(now) ? "✓ \(h.title)  \(streakText(h.streak(now))) · \(levelLine(planner))" : "Unchecked \(h.title)")
            } else {
                fail("usage: headroom-cli habit add|done …")
            }
        default:
            break
        }
    }

    // MARK: Output

    static func show(_ p: Planner, json: Bool) {
        let now = Date()
        let tasks = p.today(now)
        if json {
            emitJSON(["date": Planner.key(now), "xp": p.xp(), "level": Planner.level(for: p.xp()).number,
                      "tasks": tasks.map(taskJSON), "inbox": p.inbox.map(taskJSON), "upcoming": p.upcoming(now).map(taskJSON),
                      "habits": p.habitsDue(now).map(habitJSON)])
            return
        }
        print("Today · \(levelLine(p))\n")
        let open = tasks.filter { !$0.isDone }
        if tasks.isEmpty { print("  Nothing planned. Pick up to three big ones: headroom-cli add \"…\" --big") }
        for (i, t) in open.enumerated() { print("  \(i + 1). \(t.big ? "★ " : "")\(t.title)\(t.project.map { "  [\($0)]" } ?? "")") }
        for t in tasks where t.isDone { print("  ✓ \(t.title)") }
        let due = p.habitsDue(now)
        if !due.isEmpty {
            print("\nHabits")
            for (i, h) in due.enumerated() {
                print("  \(i + 1). \(h.isDone(now) ? "✓" : "○") \(h.title)  \(streakText(h.streak(now)))\(h.isDone(now) ? "" : h.twoMinute.map { "  — or just: \($0)" } ?? "")")
            }
        }
        if !p.inbox.isEmpty { print("\nInbox: \(p.inbox.count) unplanned") }
        if !p.upcoming(now).isEmpty { print("Later: \(p.upcoming(now).count) planned") }
    }

    static func showHabits(_ p: Planner, json: Bool) {
        let now = Date()
        let habits = p.habits.filter { !$0.archived }
        if json { emitJSON(habits.map(habitJSON)); return }
        if habits.isEmpty { print("No habits yet: headroom-cli habit add \"Read 10 pages\" --identity \"a reader\" --two-minute \"read one page\""); return }
        for h in habits {
            let dots = h.recent(7, now: now).map { $0.done ? "●" : $0.scheduled ? "○" : "·" }.joined()
            print("  \(dots)  \(h.title)  \(streakText(h.streak(now)))\(h.identity.map { "  — \($0)" } ?? "")")
        }
        let votes = p.votes(weekOf: now)
        if !votes.isEmpty { print("\nThis week: " + votes.map { "\($0.votes) vote\($0.votes == 1 ? "" : "s") for being \($0.identity)" }.joined(separator: " · ")) }
    }

    static func streakText(_ s: Habit.Streak) -> String {
        switch s {
        case .going(let n): n == 1 ? "1 day" : "\(n) days"
        case .missedOnce(let n): "\(n) days — never miss twice: today counts"
        case .none: "new start"
        }
    }

    static func levelLine(_ p: Planner) -> String {
        let l = Planner.level(for: p.xp())
        return "level \(l.number), \(l.into)/\(l.needed) XP"
    }

    static func taskJSON(_ t: PlannerTask) -> [String: Any] {
        ["id": t.id.uuidString, "title": t.title, "day": t.day as Any, "big": t.big, "done": t.done.map { ISO8601DateFormatter().string(from: $0) } as Any,
         "project": t.project as Any, "source": t.source.rawValue]
    }

    static func habitJSON(_ h: Habit) -> [String: Any] {
        let streak: Any = switch h.streak() {
        case .going(let n): ["state": "going", "days": n]
        case .missedOnce(let n): ["state": "missedOnce", "days": n]
        case .none: ["state": "none", "days": 0]
        }
        return ["id": h.id.uuidString, "title": h.title, "identity": h.identity as Any, "cue": h.cue as Any,
                "twoMinute": h.twoMinute as Any, "doneToday": h.isDone(), "streak": streak]
    }

    static func emitJSON(_ object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    // MARK: Parsing

    enum Lookup: Error {
        case none
        case several([String])
    }

    /// A number from the printed list, an id prefix, or words from the title. Several title matches are an
    /// error, not a guess: a coding agent ticking off the wrong task is worse than asking again.
    static func find<T: Identifiable>(_ ref: String, numbered: [T], in items: [T]) -> Result<T, Lookup> where T.ID == UUID {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return .failure(.none) }
        if let n = Int(ref) { return numbered.indices.contains(n - 1) ? .success(numbered[n - 1]) : .failure(.none) }
        if ref.count >= 4, let hit = items.first(where: { $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) }) { return .success(hit) }
        func title(_ item: T) -> String { (item as? PlannerTask)?.title ?? (item as? Habit)?.title ?? "" }
        if let exact = items.first(where: { title($0).lowercased() == ref.lowercased() }) { return .success(exact) }
        let hits = items.filter { title($0).lowercased().contains(ref.lowercased()) }
        if hits.count == 1 { return .success(hits[0]) }
        return .failure(hits.isEmpty ? .none : .several(hits.map(title)))
    }

    /// "2026-11-3" → "2026-11-03"; a date that doesn't exist (Feb 30) is refused, not rolled over.
    static func dayKey(_ s: String) -> String {
        guard let d = Planner.date(s) else { fail("--day wants a date like 2026-11-03") }
        let key = Planner.key(d)
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard key.split(separator: "-").compactMap({ Int($0) }) == parts else { fail("There's no \(s).") }
        return key
    }

    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return p[0] * 60 + p[1]
    }

    static func parseWeekdays(_ s: String) -> Set<Int>? {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let s = s.lowercased()
        if s == "weekdays" { return [2, 3, 4, 5, 6] }
        if s == "weekends" { return [1, 7] }
        var days = Set<Int>()
        for part in s.split(separator: ",") {
            guard part.count >= 3, let i = names.firstIndex(of: String(part.prefix(3))) else { return nil }
            days.insert(i + 1)
        }
        return days.isEmpty ? nil : days
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

extension Result where Failure == PlannerCommands.Lookup {
    /// The match, or exit with what went wrong.
    func or(_ ref: String, what: String = "open task") -> Success {
        switch self {
        case .success(let value): return value
        case .failure(.none): PlannerCommands.fail("No \(what) matches “\(ref)”. `headroom-cli today` lists them with numbers.")
        case .failure(.several(let titles)):
            PlannerCommands.fail("“\(ref)” matches \(titles.count): " + titles.map { "“\($0)”" }.joined(separator: ", ") + ". Use more words or the number.")
        }
    }
}

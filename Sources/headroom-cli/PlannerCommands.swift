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
            if let d = option("--day") {
                guard Planner.date(d) != nil else { fail("--day wants a date like 2026-11-03") }
                day = d
            }
            _ = flag("--today")
            let title = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { fail("usage: headroom-cli add \"what to do\" [--big] [--tomorrow|--day YYYY-MM-DD|--inbox] [--project name]") }
            let (_, task) = PlannerStore.mutate { $0.add(title, day: day, big: big, project: project, source: source) }
            if big && !task.big { print(day == nil ? "Added to the inbox (plan it for a day to make it big)." : "Already three big tasks that day — added as an ordinary one.") }
            else if !json { print("Added\(task.big ? " ★" : ""): \(task.title)\(day.map { $0 == today ? "" : " (\($0))" } ?? " (inbox)")") }
            if json { emitJSON(taskJSON(task)) }

        case "done", "later":
            let ref = rest.joined(separator: " ")
            let (planner, found) = PlannerStore.mutate { p -> PlannerTask? in
                guard let t = find(ref, in: p.today(now).filter { !$0.isDone } + p.inbox + p.upcoming(now)) else { return nil }
                if args[0] == "done" { p.complete(t.id, at: now) } else { p.update(t.id) { $0.day = Planner.key(daysFrom: now, 1); $0.big = false } }
                return t
            }
            guard let found else { fail("No open task matches “\(ref)”. `headroom-cli today` lists them with numbers.") }
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
                let at = option("--at").flatMap(minutes)
                let weekdays = option("--days").map(parseWeekdays) ?? []
                let title = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { fail("usage: headroom-cli habit add \"Read 10 pages\" [--identity \"a reader\"] [--cue \"after dinner\"] [--two-minute \"read one page\"] [--at 21:00] [--days mon,wed,fri]") }
                let habit = Habit(title: title, identity: identity, cue: cue, twoMinute: two, weekdays: weekdays, remindAt: at)
                PlannerStore.mutate { $0.habits.append(habit) }
                print("New habit: \(title)\(identity.map { " — every time is a vote for being \($0)" } ?? "")")
            } else if sub == "done" {
                let ref = rest.joined(separator: " ")
                let (planner, found) = PlannerStore.mutate { p -> Habit? in
                    let due = p.habitsDue(now)
                    guard let h = find(ref, in: due) else { return nil }
                    p.toggleHabit(h.id, on: now)
                    return h
                }
                guard let found, let h = planner.habits.first(where: { $0.id == found.id }) else { fail("No habit due today matches “\(ref)”.") }
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

    /// A number from the list, an id prefix, or words from the title.
    static func find<T: Identifiable>(_ ref: String, in items: [T]) -> T? where T.ID == UUID {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        if let n = Int(ref), items.indices.contains(n - 1) { return items[n - 1] }
        if ref.count >= 4, let hit = items.first(where: { $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) }) { return hit }
        let words = ref.lowercased()
        return items.first { item in
            let title = (item as? PlannerTask)?.title ?? (item as? Habit)?.title ?? ""
            return !words.isEmpty && title.lowercased().contains(words)
        }
    }

    static func minutes(_ s: String) -> Int? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return p[0] * 60 + p[1]
    }

    static func parseWeekdays(_ s: String) -> Set<Int> {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        if s == "weekdays" { return [2, 3, 4, 5, 6] }
        return Set(s.lowercased().split(separator: ",").compactMap { names.firstIndex(of: String($0.prefix(3))).map { $0 + 1 } })
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

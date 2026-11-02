import Foundation
import HeadroomCore

/// `headroom-cli today|add|done|later|habits|habit` — the planner from a terminal, so you or a coding agent
/// (Claude Code) can plan the day without leaving the shell. These write only Headroom's own planner.json,
/// never a file of yours; the app picks the change up within seconds.
enum PlannerCommands {
    static let names: Set<String> = ["today", "add", "done", "later", "habits", "habit", "focus", "rewards", "reward", "buy",
                                     "stats", "challenge", "timeline", "season"]

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
            let area = option("--area")
            var effort = 1
            if let e = option("--effort") {
                guard let n = Int(e), (1...3).contains(n) else { fail("--effort is 1 (easy), 2 or 3 (hard)") }
                effort = n
            }
            var day: String? = today
            if flag("--tomorrow") { day = Planner.key(daysFrom: now, 1) }
            if flag("--inbox") { day = nil }
            if let d = option("--day") { day = dayKey(d) }
            _ = flag("--today")
            let title = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { fail("usage: headroom-cli add \"what to do\" [--big] [--tomorrow|--day YYYY-MM-DD|--inbox] [--project name]") }
            let task = PlannerStore.mutate { $0.add(title, day: day, big: big, project: project, effort: effort, area: area, source: source) }.result
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
                print(args[0] == "done" ? "Done: \(found.title)  (+\(found.xp) XP · \(levelLine(planner)))" : "Moved to tomorrow: \(found.title)")
            }

        case "habits":
            showHabits(PlannerStore.load(), json: json)

        case "habit":
            let sub = rest.first ?? ""
            rest = Array(rest.dropFirst())
            if sub == "add" {
                let identity = option("--identity"), cue = option("--cue"), two = option("--two-minute"), area = option("--area")
                let avoid = flag("--avoid")
                let dailyMinutes = option("--minutes").flatMap(Int.init)
                let trackProject = option("--track")
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
                var habit = Habit(title: title, identity: identity, cue: cue, twoMinute: two, weekdays: weekdays, remindAt: at)
                habit.area = area
                if avoid { habit.kind = .avoid }
                if let dailyMinutes, dailyMinutes > 0, let trackProject {
                    habit.minutes = dailyMinutes
                    habit.track = QuotaTrack(project: trackProject)
                }
                PlannerStore.mutate { $0.habits.append(habit) }
                print("New habit\(avoid ? " to break" : ""): \(title)\(identity.map { " — every \(avoid ? "clean day" : "time") is a vote for being \($0)" } ?? "")")
            } else if sub == "slip" {
                // An avoid-habit slipped today: the clean run restarts, nothing else is lost.
                let undo = flag("--undo")
                let ref = rest.joined(separator: " ")
                let (planner, outcome, _) = PlannerStore.mutate { p -> Result<Habit, Lookup> in
                    let avoid = p.habits.filter { !$0.archived && $0.kind == .avoid }
                    let found = find(ref, numbered: avoid, in: avoid)
                    guard case .success(let h) = found else { return found }
                    if h.slipped(now) == undo { p.toggleSlip(h.id, on: now) }
                    return .success(h)
                }
                let found = outcome.or(ref, what: "habit to break")
                guard let h = planner.habits.first(where: { $0.id == found.id }) else { fail("That habit is gone.") }
                print(h.slipped(now) ? "Logged. \(h.title): a fresh start tomorrow — one slip doesn't undo the days you had." : "Unlogged the slip for \(h.title).")
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
                fail("usage: headroom-cli habit add|done|slip …")
            }
        case "focus":
            let sub = rest.first ?? ""
            if sub == "stop" {
                let (planner, session, _) = PlannerStore.mutate { $0.stopFocus(now: now) }
                guard let session else { fail("No focus session is running.") }
                if json { emitJSON(sessionJSON(session)); return }
                print("Focused \(session.minutes(now: now)) min on \(session.title)\(session.xp > 0 ? "  (+\(session.xp) XP · \(levelLine(planner)))" : "  (under \(FocusSession.minMinutes) min — no XP)")")
            } else if sub.isEmpty || sub == "status" {
                let p = PlannerStore.load()
                if json { emitJSON(p.runningSession.map(sessionJSON) ?? [:]); return }
                if let s = p.runningSession { print("Focusing on \(s.title) for \(s.minutes(now: now)) min. `headroom-cli focus stop` when done.") }
                else { print("No session running. Today: \(p.focusMinutes(on: now)) min focused. Start: headroom-cli focus start \"what\" (or a task number)") }
            } else if sub == "start" {
                rest = Array(rest.dropFirst())
                let area = option("--area")
                let ref = rest.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                guard !ref.isEmpty else { fail("usage: headroom-cli focus start \"what you're working on\" | <task number> [--area name]") }
                let (_, session, _) = PlannerStore.mutate { p -> FocusSession in
                    let open = p.today(now).filter { !$0.isDone }
                    if case .success(let t) = find(ref, numbered: open, in: open) { return p.startFocus(t.title, taskID: t.id, area: area, now: now) }
                    return p.startFocus(ref, area: area, now: now)
                }
                if json { emitJSON(sessionJSON(session)); return }
                print("Focus started: \(session.title)\(session.area.map { " [\($0)]" } ?? ""). 20 XP an hour, up to 3 h.")
            } else {
                fail("usage: headroom-cli focus [start \"…\"|stop]")
            }

        case "rewards":
            let p = PlannerStore.load()
            let rewards = p.rewards.filter { !$0.archived }
            if json { emitJSON(["coins": p.coins(now: now), "rewards": rewards.map { ["id": $0.id.uuidString, "title": $0.title, "cost": $0.cost] }]); return }
            print("\(p.coins(now: now)) coins\n")
            if rewards.isEmpty { print("  No rewards yet: headroom-cli reward add \"Dinner out\" 500") }
            for (i, r) in rewards.enumerated() { print("  \(i + 1). \(r.title)  — \(r.cost) coins\(p.coins(now: now) >= r.cost ? "  ✓ can buy" : "")") }

        case "reward":
            guard rest.first == "add" else { fail("usage: headroom-cli reward add \"Dinner out\" 500") }
            rest = Array(rest.dropFirst())
            guard let last = rest.last, let cost = Int(last), cost > 0 else { fail("usage: headroom-cli reward add \"Dinner out\" 500") }
            let title = rest.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { fail("usage: headroom-cli reward add \"Dinner out\" 500") }
            PlannerStore.mutate { $0.rewards.append(Reward(title: title, cost: cost, created: now)) }
            print("Reward added: \(title) — \(cost) coins")

        case "buy":
            let ref = rest.joined(separator: " ")
            let (planner, outcome, _) = PlannerStore.mutate { p -> Result<Planner.BuyResult, Lookup> in
                let rewards = p.rewards.filter { !$0.archived }
                switch find(ref, numbered: rewards, in: rewards) {
                case .success(let r): return .success(p.buy(r.id, now: now))
                case .failure(let e): return .failure(e)
                }
            }
            switch outcome.or(ref, what: "reward") {
            case .bought(let purchase): print("Enjoy it: \(purchase.title). \(planner.coins(now: now)) coins left.")
            case .short(let n): fail("\(n) coins short — keep going.")
            case .missing: fail("That reward is gone.")
            }

        case "challenge":
            // headroom-cli challenge add "<habit>" <times> [--days 30]
            guard rest.first == "add" else { fail("usage: headroom-cli challenge add \"<habit>\" <times> [--days 30]") }
            rest = Array(rest.dropFirst())
            let days = option("--days").map { Int($0) ?? 0 } ?? 30
            guard let last = rest.last, let target = Int(last), target > 0, days > 0 else { fail("usage: headroom-cli challenge add \"<habit>\" <times> [--days 30]") }
            let ref = rest.dropLast().joined(separator: " ")
            let (_, outcome, _) = PlannerStore.mutate { p -> Result<Challenge, Lookup> in
                let habits = p.habits.filter { !$0.archived }
                switch find(ref, numbered: habits, in: habits) {
                case .success(let h):
                    let c = Challenge(title: "\(h.title) \(target)× in \(days) days", habitID: h.id, target: target,
                                      start: Planner.key(now), end: Planner.key(daysFrom: now, days - 1))
                    p.challenges.append(c)
                    return .success(c)
                case .failure(let e): return .failure(e)
                }
            }
            let c = outcome.or(ref, what: "habit")
            print("Challenge on: \(c.title) — +\(c.bonus) XP when you get there. Nothing lost if you don't.")

        case "stats":
            let p = PlannerStore.load()
            let level = Planner.level(for: p.xp(now: now))
            let rank = Planner.rank(for: level.number)
            let areas = p.areas(now: now)
            let log = Array(p.ledger(now: now).prefix(10))
            if json {
                emitJSON(["xp": p.xp(now: now), "level": level.number, "rank": rank.title, "coins": p.coins(now: now),
                          "focusMinutesToday": p.focusMinutes(on: now),
                          "areas": areas.map { ["name": $0.name, "xp": $0.xp, "level": $0.level.number] },
                          "challenges": p.challenges.map { ["title": $0.title, "progress": p.challengeProgress($0, now: now), "target": $0.target] },
                          "log": log.map { ["date": ISO8601DateFormatter().string(from: $0.date), "kind": $0.kind.rawValue, "title": $0.title, "xp": $0.xp, "coins": $0.coins] }])
                return
            }
            print("\(rank.title) · \(levelLine(p)) · \(p.coins(now: now)) coins\(rank.next.map { " · \($0.title) at level \($0.level)" } ?? "")")
            print("Focused today: \(p.focusMinutes(on: now)) min")
            if !areas.isEmpty {
                print("\nAreas")
                for a in areas { print("  \(a.name)  level \(a.level.number) · \(a.level.into)/\(a.level.needed) XP") }
            }
            let live = p.challenges.filter { if case .ended = p.state(of: $0, now: now) { return false }; return true }
            if !live.isEmpty {
                print("\nChallenges")
                for c in live { print("  \(c.title)  \(p.challengeProgress(c, now: now))/\(c.target)\(p.state(of: c, now: now) == .won ? " ✓ +\(c.bonus) XP" : "")") }
            }
            if !log.isEmpty {
                print("\nLately")
                for e in log { print("  \(e.coins < 0 ? "\(e.coins) coins" : "+\(e.xp) XP")  \(e.title)") }
            }

        case "timeline":
            // Read-only: where today (or --day) went, from the app's timeline and Claude Code's logs.
            var day = Planner.key(now)
            if let d = option("--day") { day = dayKey(d) }
            let store = TimelineStore()
            let spans = store.load(day) + ClaudeCodeActivity.spans(on: day)
            let classifier = Classifier(settings: store.loadSettings(),
                                        projects: ClaudeCodeActivity.projectPaths().map { URL(fileURLWithPath: $0).lastPathComponent })
            let byKind = TimelineMath.totals(spans) { classifier.classify($0).category.title }
            let byProject = TimelineMath.totals(spans) { classifier.classify($0).project }
            let byApp = TimelineMath.totals(spans) { $0.host ?? $0.appName }
            if json {
                func list(_ t: [TimelineMath.Total]) -> [[String: Any]] { t.map { ["name": $0.name, "minutes": Int($0.seconds / 60)] } }
                emitJSON(["day": day, "minutes": Int(TimelineMath.covered(spans) / 60), "byKind": list(byKind), "byProject": list(byProject),
                          "appsAndSites": list(Array(byApp.prefix(20)))])
                return
            }
            if spans.isEmpty { print("Nothing recorded for \(day). Turn on Timeline in Headroom (Home › Where today went)."); return }
            func line(_ t: TimelineMath.Total) -> String { "  \(t.name)  \(Int(t.seconds / 60) / 60) h \(String(format: "%02d", Int(t.seconds / 60) % 60)) m" }
            print("\(day) · \(Int(TimelineMath.covered(spans) / 60)) min at the Mac\n")
            print("By kind of work"); byKind.forEach { print(line($0)) }
            if !byProject.isEmpty { print("\nBy project"); byProject.forEach { print(line($0)) } }
            print("\nApps & sites"); byApp.prefix(12).forEach { print(line($0)) }

        case "season":
            // headroom-cli season · season set "<main>" <h/wk> ["<side>" <h/wk>]… [--weeks 2] · season end
            if rest.first == "end" {
                PlannerStore.mutate { $0.season = nil }
                print("Season ended.")
            } else if rest.first == "set" {
                rest = Array(rest.dropFirst())
                let weeks = option("--weeks").flatMap(Int.init) ?? 2
                var quests: [Season.Quest] = []
                var i = 0
                while i + 1 < rest.count, let h = Int(rest[i + 1]) { quests.append(.init(project: rest[i], hoursPerWeek: h)); i += 2 }
                guard let main = quests.first, i == rest.count, (1...6).contains(weeks) else {
                    fail("usage: headroom-cli season set \"Main project\" 20 [\"Side\" 8] [\"Side\" 4] [--weeks 2]")
                }
                if quests.count > 1 + Season.maxSideQuests { fail("A season has one main quest and at most \(Season.maxSideQuests) side quests — that's the point.") }
                let s = Season(start: Planner.key(now), end: Planner.key(daysFrom: now, weeks * 7 - 1), main: main, sides: Array(quests.dropFirst()))
                PlannerStore.mutate { $0.season = s }
                print("Season on until \(s.end): \(main.project) (\(main.hoursPerWeek) h/wk)" + s.sides.map { " · \($0.project) (\($0.hoursPerWeek) h/wk)" }.joined())
            } else {
                let p = PlannerStore.load()
                guard let s = p.season else { print("No season. headroom-cli season set \"Main project\" 20 \"Side\" 8"); return }
                if json {
                    emitJSON(["start": s.start, "end": s.end, "quests": s.quests.map { ["project": $0.project, "hoursPerWeek": $0.hoursPerWeek, "main": $0 == s.main] }])
                    return
                }
                print("Season \(s.start) → \(s.end)")
                for q in s.quests { print("  \(q == s.main ? "★" : "·") \(q.project)  \(q.hoursPerWeek) h/wk") }
            }

        default:
            break
        }
    }

    static func sessionJSON(_ s: FocusSession) -> [String: Any] {
        ["id": s.id.uuidString, "title": s.title, "start": ISO8601DateFormatter().string(from: s.start), "running": s.isRunning,
         "minutes": s.minutes(), "xp": s.xp, "area": s.area as Any]
    }

    // MARK: Output

    static func show(_ p: Planner, json: Bool) {
        let now = Date()
        let tasks = p.today(now)
        if json {
            emitJSON(["date": Planner.key(now), "xp": p.xp(), "level": Planner.level(for: p.xp()).number, "coins": p.coins(),
                      "tasks": tasks.map(taskJSON), "inbox": p.inbox.map(taskJSON), "upcoming": p.upcoming(now).map(taskJSON),
                      "habits": p.habitsDue(now).map(habitJSON)])
            return
        }
        print("Today · \(Planner.rank(for: Planner.level(for: p.xp()).number).title) · \(levelLine(p)) · \(p.coins()) coins")
        if let s = p.runningSession { print("Focusing: \(s.title) (\(s.minutes(now: now)) min)") }
        print("")
        let open = tasks.filter { !$0.isDone }
        if tasks.isEmpty { print("  Nothing planned. Pick up to three big ones: headroom-cli add \"…\" --big") }
        for (i, t) in open.enumerated() {
            print("  \(i + 1). \(t.big ? "★ " : "")\(t.title)\(t.area.map { "  · \($0)" } ?? "")\(t.project.map { "  [\($0)]" } ?? "")  +\(t.xp)")
        }
        for t in tasks where t.isDone { print("  ✓ \(t.title)") }
        let due = p.habitsDue(now)
        if !due.isEmpty {
            print("\nHabits")
            for (i, h) in due.enumerated() {
                if h.kind == .avoid { print("  \(i + 1). \(h.slipped(now) ? "✗" : "·") \(h.title)  \(h.cleanDays(now)) clean days"); continue }
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
            let dots = h.kind == .avoid
                ? h.recent(7, now: now).map { h.slips.contains($0.key) ? "✗" : $0.scheduled ? "●" : "·" }.joined()
                : h.recent(7, now: now).map { $0.done ? "●" : $0.scheduled ? "○" : "·" }.joined()
            print("  \(dots)  \(h.title)  \(streakText(h.streak(now), avoid: h.kind == .avoid))\(h.identity.map { "  — \($0)" } ?? "")")
        }
        let votes = p.votes(weekOf: now)
        if !votes.isEmpty { print("\nThis week: " + votes.map { "\($0.votes) vote\($0.votes == 1 ? "" : "s") for being \($0.identity)" }.joined(separator: " · ")) }
    }

    static func streakText(_ s: Habit.Streak) -> String {
        streakText(s, avoid: false)
    }

    static func streakText(_ s: Habit.Streak, avoid: Bool) -> String {
        if avoid, case .going(let n) = s { return "\(n) clean day\(n == 1 ? "" : "s")" }
        return switch s {
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
    static func find<T: Titled>(_ ref: String, numbered: [T], in items: [T]) -> Result<T, Lookup> {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return .failure(.none) }
        if let n = Int(ref) { return numbered.indices.contains(n - 1) ? .success(numbered[n - 1]) : .failure(.none) }
        if ref.count >= 4, let hit = items.first(where: { $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) }) { return .success(hit) }
        func title(_ item: T) -> String { item.title }
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
        case .failure(.none):
            let list = what == "reward" ? "rewards" : what == "habit to break" || what == "habit" ? "habits" : "today"
            PlannerCommands.fail("No \(what) matches “\(ref)”. `headroom-cli \(list)` lists them with numbers.")
        case .failure(.several(let titles)):
            PlannerCommands.fail("“\(ref)” matches \(titles.count): " + titles.map { "“\($0)”" }.joined(separator: ", ") + ". Use more words or the number.")
        }
    }
}

/// Anything the CLI can pick by number, id prefix or title words.
protocol Titled: Identifiable where ID == UUID { var title: String { get } }
extension PlannerTask: Titled {}
extension Habit: Titled {}
extension Reward: Titled {}

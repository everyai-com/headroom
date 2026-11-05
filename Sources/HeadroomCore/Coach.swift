import Foundation

// Life OS step 2: proof (your commits, read from git), your calendar, a coach that plans the morning and
// reviews the evening through your own Claude CLI (no tools, nothing written but what you accept), and
// nudges when the day drifts away from its quests.

/// One of your commits: the proof that a day on a project shipped something.
public struct Commit: Sendable, Equatable, Codable, Hashable {
    public var project: String
    public var hash: String
    public var date: Date
    public var subject: String
    public init(project: String, hash: String, date: Date, subject: String) {
        self.project = project; self.hash = hash; self.date = date; self.subject = subject
    }
}

extension Git {
    /// Your commits in a repository between two dates (author = the repo's `user.email`), newest first.
    /// Read-only: `git log` with optional locks off, like `status`.
    public static func commits(repo: String, project: String, since: Date, until: Date) -> [Commit] {
        guard let git = executable else { return [] }
        let base = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", repo]
        guard let email = Shell.run(git, base + ["config", "user.email"], timeout: 5)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty,
              let out = Shell.run(git, base + ["log", "--all", "--no-merges", "--author=\(email)",
                                               "--since=\(Int(since.timeIntervalSince1970))", "--until=\(Int(until.timeIntervalSince1970))",
                                               "--format=%H%x09%ct%x09%s"], timeout: 10) else { return [] }
        return parseLog(out, project: project)
    }

    /// `hash<TAB>unix time<TAB>subject` lines; anything else is skipped.
    static func parseLog(_ out: String, project: String) -> [Commit] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let t = TimeInterval(parts[1]) else { return nil }
            return Commit(project: project, hash: String(parts[0]), date: Date(timeIntervalSince1970: t), subject: String(parts[2]))
        }
    }
}

public enum Proof {
    /// The repositories behind your Claude Code projects, once each (worktrees fold into their repository).
    public static func repos(_ paths: [String], home: String = HeadroomPaths.home) -> [(repo: String, project: String)] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let main = ClaudeCodeActivity.mainCheckout(path)
            guard let root = Git.repoRoot(containing: main, home: home), seen.insert(root.lowercased()).inserted else { return nil }
            return (root, ClaudeCodeActivity.projectName(root))
        }
    }

    /// Your commits on a day across those repositories, newest first. Each commit counts once (the same
    /// hash reached from two checkouts of one repo is one commit).
    public static func commits(on day: String, paths: [String], home: String = HeadroomPaths.home, calendar: Calendar = .current) -> [Commit] {
        guard let start = Planner.date(day, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        var seen = Set<String>()
        return repos(paths, home: home).flatMap { Git.commits(repo: $0.repo, project: $0.project, since: start, until: end) }
            .filter { seen.insert($0.hash).inserted }
            .sorted { $0.date > $1.date }
    }
}

/// An event from your calendars (read through EventKit by the app, never changed).
public struct CalendarEvent: Sendable, Equatable, Codable, Hashable {
    public var title: String
    public var start: Date
    public var end: Date
    public var calendar: String
    public var allDay: Bool
    /// The event's notes and who's invited (names only) — what meeting prep reads.
    public var notes: String?
    public var people: [String]?
    public init(title: String, start: Date, end: Date, calendar: String, allDay: Bool = false, notes: String? = nil, people: [String]? = nil) {
        self.title = title; self.start = start; self.end = end; self.calendar = calendar; self.allDay = allDay
        self.notes = notes; self.people = people
    }
    public var minutes: Int { allDay ? 0 : max(0, Int(end.timeIntervalSince(start) / 60)) }
}

/// How a daily quest stands right now.
public struct QuestStatus: Sendable, Equatable {
    public var title: String
    public var done: Int
    public var target: Int
    public init(title: String, done: Int, target: Int) { self.title = title; self.done = done; self.target = target }
    public var left: Int { max(0, target - done) }
}

/// Everything the coach is told about a day. Built by the app (or the CLI) from what's already on this Mac.
public struct DayContext: Sendable {
    public var now: Date
    public var planner: Planner
    public var events: [CalendarEvent]          // today and tomorrow
    public var commits: [Commit]                // today
    public var byProject: [(name: String, minutes: Int)]
    public var byKind: [(name: String, minutes: Int)]
    public var quests: [QuestStatus]
    public var seasonWeek: [String: Int]        // project (lowercased) → minutes this week
    /// Last night's sleep estimate, and today's (or, in the morning, yesterday's) journal and check-in.
    public var sleep: SleepEstimate?
    public var logs: [DayLog] = []
    /// What the coach knows about the user (their coach-memory.md), and a brain dump to sort (`.dump`).
    public var memory = ""
    public var dump = ""
    /// The meeting to prepare for (`.meeting`).
    public var meeting: CalendarEvent?
    public init(now: Date, planner: Planner, events: [CalendarEvent] = [], commits: [Commit] = [],
                byProject: [(name: String, minutes: Int)] = [], byKind: [(name: String, minutes: Int)] = [],
                quests: [QuestStatus] = [], seasonWeek: [String: Int] = [:]) {
        self.now = now; self.planner = planner; self.events = events; self.commits = commits
        self.byProject = byProject; self.byKind = byKind; self.quests = quests; self.seasonWeek = seasonWeek
    }
}

/// What the coach suggests. Nothing is added until you tick it and press Add.
public struct CoachPlan: Codable, Sendable, Equatable {
    public var big: [String]
    public var tasks: [String]
    public var note: String
    /// Time blocks for the day (or the rest of the season week), and the weekly review's specific fixes.
    public var blocks: [BlockSuggestion] = []
    public var recommendations: [Recommendation] = []
    /// Lines worth keeping in the coach's memory, and (evening) the one task tomorrow is for.
    public var remember: [String] = []
    public var top: String?
    public init(big: [String] = [], tasks: [String] = [], note: String = "", blocks: [BlockSuggestion] = [], recommendations: [Recommendation] = [],
                remember: [String] = [], top: String? = nil) {
        self.big = big; self.tasks = tasks; self.note = note; self.blocks = blocks; self.recommendations = recommendations
        self.remember = remember; self.top = top
    }

    enum CodingKeys: String, CodingKey { case big, tasks, note, blocks, recommendations, remember, top }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        big = (try? c.decodeIfPresent([String].self, forKey: .big)) ?? []
        tasks = (try? c.decodeIfPresent([String].self, forKey: .tasks)) ?? []
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        blocks = (try? c.decodeIfPresent([BlockSuggestion].self, forKey: .blocks)) ?? []
        recommendations = (try? c.decodeIfPresent([Recommendation].self, forKey: .recommendations)) ?? []
        remember = (try? c.decodeIfPresent([String].self, forKey: .remember)) ?? []
        top = (try? c.decodeIfPresent(String.self, forKey: .top)) ?? nil
    }
}

public enum Coach {
    public enum Moment: String, Sendable { case morning, evening, week, dump, meeting }

    /// The prompt for `claude -p`. Plain facts, then the ask, then the exact JSON shape wanted back.
    public static func prompt(_ m: Moment, _ c: DayContext, calendar: Calendar = .current) -> String {
        let today = Planner.key(c.now, calendar: calendar)
        let tomorrow = Planner.key(daysFrom: c.now, 1, calendar: calendar)
        var lines = facts(c, calendar: calendar)
        switch m {
        case .morning:
            lines.append("""

            Plan TODAY (\(today)). If sleep was short or energy is low, plan lighter and say so. Pick at most 3 BIG tasks that move the season's main quest and the daily quests the most, \
            fit around the calendar. Reuse open task titles exactly when one fits; otherwise write new short tasks starting with a verb. \
            Up to 5 small tasks. Time-block the rest of today in "blocks" (HH:mm, after \(TimeBlock.clock(calendar.component(.hour, from: c.now) * 60 + calendar.component(.minute, from: c.now))), never over \
            calendar events or existing blocks, hardest work first, a break between long blocks). In "note", 2–3 sentences: \
            the order to do things and when, naming real times from the calendar.
            """)
        case .evening:
            lines.append("""

            Review TODAY honestly and kindly: what moved, what didn't, where time leaked (name it), in 3–5 sentences in "note". \
            Then plan TOMORROW (\(tomorrow)): at most 3 BIG tasks and up to 5 small ones, reusing open task titles exactly when one fits, \
            and time-block tomorrow in "blocks" (day "\(tomorrow)", around its calendar events).
            """)
        case .week:
            lines.append("""

            Weekly review of the SEASON. For each quest give an honest read (on track, adjust, off track) and why, in "note" \
            (4–6 sentences). Then 2–3 "recommendations": each a specific fix with a short title ("Move X to your mornings") \
            and "why" grounded in the numbers above (when work actually happened, what keeps slipping, energy patterns). \
            Check each open milestone: is the work left realistic before its due day? Name any that needs a new date or \
            splitting. Then "blocks": time blocks for the rest of this season week (each with its "day" YYYY-MM-DD and \
            "project") that close the unblocked hours, inside protected time where there is some, around calendar events. \
            Leave "big" and "tasks" empty.
            """)
        case .dump:
            lines.append("""

            The user brain-dumped this (notes, a meeting, a list, half-thoughts):
            \"\"\"
            \(c.dump.prefix(6000))
            \"\"\"
            Pull out every concrete action as a short task starting with a verb, reusing open task titles exactly when \
            one matches. Put at most 3 that matter most for the season today in "big" (only if today still has room), \
            the rest in "tasks". In "remember", 0–3 short facts about how the user works, people or preferences worth \
            keeping (only ones stated in the dump). In "note", one sentence on what you pulled out.
            """)
        case .meeting:
            let e = c.meeting
            lines.append("""

            Prepare the user for this meeting: "\(e?.title ?? "")" at \(e.map { TimeBlock.clock(calendar.component(.hour, from: $0.start) * 60 + calendar.component(.minute, from: $0.start)) } ?? "") \
            (\(e?.minutes ?? 0) min)\(e?.people.map { $0.isEmpty ? "" : " with " + $0.prefix(12).joined(separator: ", ") } ?? "").
            \(e?.notes.map { "Its notes:\n\"\"\"\n\($0.prefix(3000))\n\"\"\"" } ?? "It has no notes.")
            In "note": the goal of the meeting in one line, then 3–5 short agenda points and 2–3 questions to ask, \
            tied to the season, open tasks and milestones above when they relate (plain text, one item per line, "- " bullets). \
            In "tasks": 0–3 things to do before or right after it, starting with a verb. In "remember": 0–2 facts about \
            these people worth keeping, only if stated above. Leave "big" and "blocks" empty.
            """)
        }
        if m == .evening {
            lines.append(#"Also set "top": the ONE task (exact title from big) tomorrow is for — the thing that makes tomorrow a success if nothing else gets done."#)
        }
        lines.append(#"Reply with ONLY this JSON, no code fence: {"big": ["…"], "tasks": ["…"], "blocks": [{"title": "…", "day": "YYYY-MM-DD", "start": "HH:mm", "end": "HH:mm", "project": "…"}], "recommendations": [{"title": "…", "why": "…"}], "remember": ["…"], "top": "…", "note": "…"}"#)
        return lines.joined(separator: "\n")
    }

    /// Plain facts about the day: what every coach prompt starts with.
    static func facts(_ c: DayContext, calendar: Calendar) -> [String] {
        let today = Planner.key(c.now, calendar: calendar)
        let tomorrow = Planner.key(daysFrom: c.now, 1, calendar: calendar)
        let time = DateFormatter()
        time.calendar = calendar; time.timeZone = calendar.timeZone
        time.dateFormat = "EEE HH:mm"
        let clock = DateFormatter()
        clock.calendar = calendar; clock.timeZone = calendar.timeZone
        clock.dateFormat = "HH:mm"
        func hm(_ minutes: Int) -> String { "\(minutes / 60)h\(String(format: "%02d", minutes % 60))" }
        var lines: [String] = []
        lines.append("You are the user's coach inside Headroom, their life OS. It is \(time.string(from: c.now)).")
        let memory = c.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memory.isEmpty { lines.append("\nWHAT YOU KNOW ABOUT THEM (their own notes, trust these):\n" + String(memory.prefix(3000))) }
        if let v = c.planner.vision, !v.isEmpty {
            lines.append("\nTHEIR VISION (what they want, held as already theirs):")
            if !v.become.isEmpty { lines.append("- become: " + v.become.joined(separator: "; ")) }
            if !v.doing.isEmpty { lines.append("- do: " + v.doing.joined(separator: "; ")) }
            if !v.have.isEmpty { lines.append("- have: " + v.have.joined(separator: "; ")) }
            if !v.picture.isEmpty { lines.append("- picture: \"\(v.picture.prefix(800))\"") }
            if !v.waiting.isEmpty { lines.append("- decisions they're waiting on: " + v.waiting.map { "\($0.title) (decide from \($0.ready(calendar: calendar)))" }.joined(separator: "; ")) }
            lines.append("They follow The Science of Getting Rich: speak in terms of increase, never lack; plan today's work, not tomorrow's emergencies; no hurry.")
        }
        if let s = c.planner.season, s.isActive(on: today) {
            let quests = [s.main] + s.sides
            lines.append("\nSEASON until \(s.end) (hours this week / planned per week):")
            for (i, q) in quests.enumerated() {
                lines.append("- \(i == 0 ? "MAIN" : "side"): \(q.project) \(hm(c.seasonWeek[q.project.lowercased()] ?? 0)) / \(q.hoursPerWeek)h")
            }
            if let day = s.dayNumber(on: today, calendar: calendar) {
                lines.append("Day \(day) of \(s.days). Week by week (on track / adjust / off track):")
                for row in s.grid(now: c.now, calendar: calendar) {
                    let weeks = row.weeks.enumerated().filter { $0.element != .upcoming }.map { "w\($0.offset + 1) \($0.element.rawValue)" }
                    lines.append("- \(row.quest.project): " + weeks.joined(separator: ", "))
                }
            }
            if let m = s.manifesto, !m.isEmpty { lines.append("THEIR SIGNED SEASON COMMITMENT: \"\(m.prefix(600))\"") }
            if let support = s.support, !support.isEmpty { lines.append("SUPPORT AREAS (keep up, don't grow): " + support.joined(separator: ", ")) }
            let open = s.openMilestones
            if !open.isEmpty {
                lines.append("OPEN MILESTONES:")
                open.prefix(12).forEach { m in
                    lines.append("- \(m.pinned == true ? "[NOW] " : "")\(m.title) (\(m.project))\(m.due.map { m.isLate(today: today) ? " — LATE, was due \($0)" : " — due \($0)" } ?? "")")
                }
            }
            if let protected = s.protected, !protected.isEmpty {
                let names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
                lines.append("PROTECTED TIME: " + protected.map { p in
                    "\(p.project) \(p.weekdays.sorted().map { names[$0] }.joined(separator: "/")) \(TimeBlock.clock(p.start))–\(TimeBlock.clock(p.end))"
                }.joined(separator: "; "))
            }
            if let strength = PlanStrength.of(c.planner, done: c.seasonWeek, now: c.now, calendar: calendar) {
                let gaps = strength.gaps.map { "\($0.key) \(hm($0.value))" }.sorted().joined(separator: ", ")
                lines.append("PLAN STRENGTH this season week: \(Int(strength.score * 100))% of the hours still needed have a time block\(gaps.isEmpty ? "" : "; unblocked: " + gaps)")
            }
        }
        let blocks = c.planner.blocks.filter { $0.day == today || $0.day == tomorrow }.sorted { ($0.day, $0.start) < ($1.day, $1.start) }
        if !blocks.isEmpty {
            lines.append("\nTIME BLOCKS:")
            blocks.forEach { lines.append("- \($0.day == today ? "today" : "tomorrow") \(TimeBlock.clock($0.start))–\(TimeBlock.clock($0.end)) \($0.title)") }
        }
        if !c.quests.isEmpty {
            lines.append("\nDAILY QUESTS (done / target today):")
            c.quests.forEach { lines.append("- \($0.title): \(hm($0.done)) / \(hm($0.target))") }
        }
        let habits = c.planner.habitsDue(c.now, calendar: calendar).filter { !$0.isTimed }
        if !habits.isEmpty {
            lines.append("\nHABITS today:")
            habits.forEach { h in
                let state = h.kind == .avoid ? (h.slipped(c.now, calendar: calendar) ? "slipped" : "clean so far") : (h.isDone(c.now, calendar: calendar) ? "done" : "not yet")
                lines.append("- \(h.kind == .avoid ? "avoid " : "")\(h.title): \(state)")
            }
        }
        let open = c.planner.tasks.filter { $0.done == nil && ($0.day ?? today) <= tomorrow }
        if !open.isEmpty {
            lines.append("\nOPEN TASKS:")
            open.prefix(30).forEach { t in
                lines.append("- \(t.big ? "[BIG] " : "")\(t.title)\(t.project.map { " (\($0))" } ?? "")\(t.day.map { $0 < today ? " — overdue since \($0)" : $0 == tomorrow ? " — tomorrow" : "" } ?? " — inbox")")
            }
        }
        let doneToday = c.planner.tasks.filter { $0.done.map { Planner.key($0, calendar: calendar) == today } ?? false }
        if !doneToday.isEmpty { lines.append("\nDONE TODAY: " + doneToday.map(\.title).joined(separator: "; ")) }
        if !c.events.isEmpty {
            lines.append("\nCALENDAR:")
            c.events.sorted { $0.start < $1.start }.forEach { e in
                lines.append("- \(e.allDay ? Planner.key(e.start, calendar: calendar) + " all day" : time.string(from: e.start) + "–" + clock.string(from: e.end)) \(e.title)")
            }
        }
        if !c.byProject.isEmpty {
            lines.append("\nWHERE TODAY WENT (by project): " + c.byProject.prefix(10).map { "\($0.name) \(hm($0.minutes))" }.joined(separator: ", "))
        }
        if !c.byKind.isEmpty {
            lines.append("BY KIND: " + c.byKind.prefix(8).map { "\($0.name) \(hm($0.minutes))" }.joined(separator: ", "))
        }
        if let sl = c.sleep {
            lines.append("SLEEP (estimated from when the Mac rested): \(clock.string(from: sl.start))–\(clock.string(from: sl.end)), \(hm(sl.minutes))")
        }
        for l in c.logs.sorted(by: { $0.day < $1.day }) {
            var parts: [String] = []
            if let m = l.mood { parts.append("mood \(m)/5 (\(DayLog.moodWords[m]))") }
            if let e = l.energy { parts.append("energy \(e)/5 (\(DayLog.energyWords[e]))") }
            if !l.note.isEmpty { parts.append("journal: \"\(l.note.prefix(1200))\"") }
            if let g = l.gratitude, !g.isEmpty { parts.append("grateful for: " + g.joined(separator: "; ")) }
            if let v = l.gave, !v.isEmpty { parts.append("gave value: \(v)") }
            if !parts.isEmpty { lines.append("\(l.day == today ? "TODAY" : l.day): " + parts.joined(separator: "; ")) }
        }
        let focus = c.planner.focusMinutes(on: c.now, calendar: calendar)
        if focus > 0 { lines.append("FOCUS TODAY: \(hm(focus))") }
        let score = c.planner.score(on: c.now, now: c.now, calendar: calendar)
        if score.planned > 0 { lines.append("DAILY SCORE so far: \(score.percent)% (\(score.done) of \(score.planned) planned things done)") }
        for day in [today, tomorrow] {
            if let t = c.planner.topThing(on: day) { lines.append("TOP THING \(day == today ? "TODAY" : "TOMORROW"): \(t.title)\(t.isDone ? " (done)" : "")") }
        }
        for l in c.logs where l.isSynced {
            lines.append("\(l.day == today ? "TODAY" : l.day) RATED: \(DayLog.progressWords[l.progress ?? 0])")
        }
        let energy = EnergyPatterns.lines(c.planner, since: c.now.addingTimeInterval(-30 * 86_400), calendar: calendar)
        if !energy.isEmpty { lines.append("ENERGY (last 30 days, from how blocks and sessions felt): " + energy.joined(separator: "; ")) }
        if let peak = DayPart.peak(c.planner.sessions.filter { $0.start > c.now.addingTimeInterval(-30 * 86_400) }, calendar: calendar) {
            lines.append("MOST FOCUS HAPPENS: \(peak.rawValue)")
        }
        if !c.commits.isEmpty {
            let per = Dictionary(grouping: c.commits, by: \.project).map { "\($0.key) \($0.value.count)" }.sorted()
            lines.append("COMMITS TODAY: " + per.joined(separator: ", "))
        }
        return lines
    }


    /// For the journal's Reflect button: a short, kind reply in plain text, ending with one question.
    public static func reflectionPrompt(_ c: DayContext, day: String) -> String {
        var p = facts(c, calendar: .current)
        p.append("""

        The user just wrote their journal for \(day) (above). Reply to it in plain text, 3–5 sentences, like a wise friend \
        who knows their goals: notice one thing that went well and connect it to their quests or season, name one pattern \
        (sleep, energy, where time went) without judging, then ask ONE question that helps them plan tomorrow. \
        No lists, no headings, no JSON.
        """)
        return p.joined(separator: "\n")
    }

    /// The JSON object in a reply, even with a code fence or a sentence around it.
    public static func parse(_ reply: String) -> CoachPlan? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close,
              let plan = try? JSONDecoder().decode(CoachPlan.self, from: Data(reply[open...close].utf8)) else { return nil }
        var p = plan
        p.big = Array(p.big.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(Planner.bigLimit))
        p.tasks = Array(p.tasks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(8))
        p.blocks = Array(p.blocks.filter { b in
            guard let a = TimeBlock.minute(b.start), let e = TimeBlock.minute(b.end) else { return false }
            return e > a && !b.title.trimmingCharacters(in: .whitespaces).isEmpty
        }.prefix(20))
        p.recommendations = Array(p.recommendations.prefix(4))
        p.remember = Array(p.remember.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(5))
        p.top = p.top.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        return p.big.isEmpty && p.tasks.isEmpty && p.note.isEmpty && p.blocks.isEmpty && p.recommendations.isEmpty && p.remember.isEmpty ? nil : p
    }
}

extension Planner {
    /// Adds what you ticked from a coach plan to a day. A title that matches an open task is that task —
    /// moved to the day (and made big if asked), never a duplicate. Big still means at most three a day.
    @discardableResult
    public mutating func accept(big: [String], tasks: [String], day: String, now: Date = .now, calendar: Calendar = .current) -> Int {
        var count = 0
        for (title, wantsBig) in big.map({ ($0, true) }) + tasks.map({ ($0, false) }) {
            if let existing = self.tasks.first(where: { $0.done == nil && $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                schedule(existing.id, day: day, now: now, calendar: calendar)
                if wantsBig && !existing.big { _ = setBig(existing.id, true, now: now, calendar: calendar) }
            } else {
                _ = add(title, day: day, big: wantsBig, source: .claude, now: now, calendar: calendar)
            }
            count += 1
        }
        return count
    }
}

/// The user's own Claude Code CLI, run with no tools: it reads the prompt and answers, nothing else.
public enum ClaudeCLI {
    public static var executable: String? {
        let home = HeadroomPaths.home
        let extra = [home + "/.local/bin/claude", home + "/.claude/local/claude"]
        return Shell.which("claude") ?? extra.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// No tools, no MCP servers, no session saved (so it never shows up as Claude Code time on the timeline).
    public static func ask(_ prompt: String, timeout: TimeInterval = 180) -> String? {
        guard !HeadroomPaths.isSandboxed, let claude = executable else { return nil }
        return Shell.run(claude, ["-p", "--tools", "", "--strict-mcp-config", "--no-session-persistence", prompt], timeout: timeout)
    }
}

/// A notification that pulls the day back toward its quests.
public struct Nudge: Sendable, Equatable {
    public var title: String
    public var body: String
    public init(title: String, body: String) { self.title = title; self.body = body }
}

public enum Nudges {
    /// What the nudge rule sees on each tick.
    public struct Input: Sendable {
        public var now: Date
        /// Minutes spent on distractions (social, entertainment) in the last 30 minutes.
        public var distractedLast30: Int
        /// The biggest distraction in that window ("youtube.com"), if any.
        public var topDistraction: String?
        public var quests: [QuestStatus]
        /// Minutes left until the end of the working day (0 once it's over).
        public var workMinutesLeft: Int
        public var lastNudge: Date?
        public init(now: Date, distractedLast30: Int, topDistraction: String?, quests: [QuestStatus], workMinutesLeft: Int, lastNudge: Date?) {
            self.now = now; self.distractedLast30 = distractedLast30; self.topDistraction = topDistraction
            self.quests = quests; self.workMinutesLeft = workMinutesLeft; self.lastNudge = lastNudge
        }
    }

    /// Whether to nudge now, and what to say. Pure, so it's tested without a clock or notifications.
    public static func decide(_ i: Input) -> Nudge? {
        // Quiet for an hour after any nudge, never after the working day, and a break isn't drift.
        if let last = i.lastNudge, i.now.timeIntervalSince(last) < 60 * 60 { return nil }
        guard i.workMinutesLeft > 0, i.distractedLast30 >= 15,
              let behind = i.quests.filter({ $0.left > 0 }).max(by: { $0.left < $1.left }) else { return nil }
        func hm(_ m: Int) -> String { m >= 60 ? "\(m / 60)h\(m % 60 == 0 ? "" : String(format: "%02d", m % 60))" : "\(m) min" }
        let source = i.topDistraction.map { " on \($0)" } ?? ""
        let title = "\(i.distractedLast30) min\(source)"
        // Honest when the full target can't fit any more: a smaller win still counts.
        let body = behind.left > i.workMinutesLeft
            ? "\(behind.title) is at \(hm(behind.done)) of \(hm(behind.target)). The full target won't fit today, but 30 minutes now still counts."
            : "\(behind.title) is at \(hm(behind.done)) of \(hm(behind.target)) — \(hm(behind.left)) to go, \(hm(i.workMinutesLeft)) left in the day."
        return Nudge(title: title, body: body)
    }
}

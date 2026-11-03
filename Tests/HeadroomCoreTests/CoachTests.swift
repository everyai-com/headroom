import XCTest
@testable import HeadroomCore

/// Life OS step 2: proof from git, the coach's prompt and reply, accepting a plan. Temp folders only.
final class CoachTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!

    func testRepliesWithAFenceOrChatterStillParse() {
        let reply = """
        Here's your plan:
        ```json
        {"big": ["Send 100 DMs", " ", "Ship pricing page", "Record a short", "One too many"], "tasks": ["Reply to leads"], "note": "Marketing first."}
        ```
        """
        let plan = Coach.parse(reply)
        XCTAssertEqual(plan?.big, ["Send 100 DMs", "Ship pricing page", "Record a short"], "blanks dropped, three big at most")
        XCTAssertEqual(plan?.tasks, ["Reply to leads"])
        XCTAssertNil(Coach.parse("I can't help with that."))
        XCTAssertNil(Coach.parse(#"{"big": [], "tasks": []}"#), "an empty plan is no plan")
        XCTAssertEqual(Coach.parse(#"{"note": "Rest day."}"#)?.note, "Rest day.", "missing keys are fine")
    }

    func testAcceptingAPlanReusesOpenTasksAndKeepsTheBigLimit() {
        var p = Planner()
        let today = Planner.key(now, calendar: cal)
        let old = p.add("Ship pricing page", day: nil, now: now, calendar: cal)
        for t in ["A", "B"] { _ = p.add(t, day: today, big: true, now: now, calendar: cal) }
        let n = p.accept(big: ["ship pricing page", "Send 100 DMs"], tasks: ["Reply to leads"], day: today, now: now, calendar: cal)
        XCTAssertEqual(n, 3)
        XCTAssertEqual(p.tasks.count, 5, "the matching inbox task was moved, not copied")
        let moved = p.tasks.first { $0.id == old.id }!
        XCTAssertEqual(moved.day, today)
        XCTAssertTrue(moved.big)
        XCTAssertFalse(p.tasks.first { $0.title == "Send 100 DMs" }!.big, "a fourth big one is an ordinary task")
        XCTAssertEqual(p.tasks.first { $0.title == "Reply to leads" }?.source, .claude)
    }

    func testPromptCarriesTheDayAndAsksForJSON() {
        var p = Planner()
        p.season = Season(start: "2026-11-02", end: "2026-11-15", main: .init(project: "connector saas", hoursPerWeek: 25))
        _ = p.add("Write the launch thread", day: Planner.key(now, calendar: cal), big: true, now: now, calendar: cal)
        let c = DayContext(now: now, planner: p,
                           events: [CalendarEvent(title: "Client demo", start: now.addingTimeInterval(5 * 3600), end: now.addingTimeInterval(6 * 3600), calendar: "Work")],
                           commits: [Commit(project: "connector saas", hash: "x", date: now, subject: "s")],
                           quests: [QuestStatus(title: "Marketing", done: 90, target: 240)],
                           seasonWeek: ["connector saas": 300])
        let prompt = Coach.prompt(.morning, c, calendar: cal)
        for expected in ["MAIN: connector saas 5h00 / 25h", "Marketing: 1h30 / 4h00", "[BIG] Write the launch thread",
                         "14:00–15:00 Client demo", "COMMITS TODAY: connector saas 1", #""big""#] {
            XCTAssertTrue(prompt.contains(expected), "missing \(expected) in\n\(prompt)")
        }
        XCTAssertTrue(Coach.prompt(.evening, c, calendar: cal).contains("plan TOMORROW (2026-11-04)"))
    }

    func testNudgesOnlyForRealDriftAndSayWhatsTrue() {
        let marketing = QuestStatus(title: "Marketing", done: 90, target: 240)
        func input(_ distracted: Int, left: Int = 300, last: Date? = nil, quests: [QuestStatus]? = nil) -> Nudges.Input {
            Nudges.Input(now: now, distractedLast30: distracted, topDistraction: "youtube.com", quests: quests ?? [marketing],
                         workMinutesLeft: left, lastNudge: last)
        }
        let n = Nudges.decide(input(20))
        XCTAssertEqual(n?.title, "20 min on youtube.com")
        XCTAssertEqual(n?.body, "Marketing is at 1h30 of 4h — 2h30 to go, 5h left in the day.")
        XCTAssertNil(Nudges.decide(input(10)), "a short break isn't drift")
        XCTAssertNil(Nudges.decide(input(20, last: now.addingTimeInterval(-30 * 60))), "quiet for an hour after a nudge")
        XCTAssertNil(Nudges.decide(input(20, left: 0)), "never after the working day")
        XCTAssertNil(Nudges.decide(input(20, quests: [QuestStatus(title: "Marketing", done: 240, target: 240)])), "nothing behind")
        XCTAssertTrue(Nudges.decide(input(20, left: 60))?.body.contains("won't fit today") ?? false)
    }

    func testGitLogLinesBecomeCommits() {
        let out = "abc\t1762160400\tFront desk: book from missed calls\nnot a line\ndef\t1762164000\tTabs\tin subject\n"
        let commits = Git.parseLog(out, project: "magicteams")
        XCTAssertEqual(commits.map(\.hash), ["abc", "def"])
        XCTAssertEqual(commits[1].subject, "Tabs\tin subject")
    }

    func testProofReadsOnlyYourCommitsInTheDay() throws {
        guard let git = Git.executable else { throw XCTSkip("no developer tools") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("shop")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        func run(_ args: [String], env: [String: String] = [:]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: git)
            p.arguments = ["-C", dir.path] + args
            p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        run(["init", "-q"])
        run(["config", "user.email", "me@example.com"]); run(["config", "user.name", "Me"])
        let day = Date()
        let stamp = ISO8601DateFormatter().string(from: day)
        run(["commit", "-q", "--allow-empty", "-m", "Mine"], env: ["GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp])
        run(["commit", "-q", "--allow-empty", "-m", "Theirs", "--author", "Other <other@example.com>"])
        let found = Proof.commits(on: Planner.key(day), paths: [dir.path], home: "/nonexistent-home")
        XCTAssertEqual(found.map(\.subject), ["Mine"])
        XCTAssertEqual(found.first?.project, "shop")
    }
}

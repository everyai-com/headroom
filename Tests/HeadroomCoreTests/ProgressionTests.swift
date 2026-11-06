import XCTest
@testable import HeadroomCore

/// The planner's game layer: effort, areas, focus, coins and rewards, challenges, avoid-habits, ranks.
final class ProgressionTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Monday 2 Nov 2026, noon UTC.
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    func day(_ offset: Int) -> String { Planner.key(daysFrom: now, offset, calendar: cal) }

    func testEffortAndBigSetTaskXP() {
        var p = Planner()
        let easy = p.add("Easy", day: day(0), now: now, calendar: cal)
        let hard = p.add("Hard", day: day(0), effort: 3, now: now, calendar: cal)
        let big = p.add("Big", day: day(0), big: true, effort: 2, now: now, calendar: cal)
        let silly = p.add("Silly", day: day(0), effort: 9, now: now, calendar: cal)
        XCTAssertEqual([easy, hard, big, silly].map(\.xp), [10, 30, 40, 30], "effort is clamped to 1–3")
        for t in [easy, hard, big] { p.complete(t.id, at: now) }
        XCTAssertEqual(p.xp(now: now, calendar: cal), 80)
        XCTAssertEqual(p.coins(now: now, calendar: cal), 80, "coins are earned 1:1 with XP")
    }

    func testAreasLevelOnTheirOwn() {
        var p = Planner()
        let a = p.add("Run", day: day(0), effort: 3, area: "Health", now: now, calendar: cal)
        let b = p.add("Ship", day: day(0), effort: 2, area: "Work", now: now, calendar: cal)
        p.add("Later", day: day(1), area: "Learning", now: now, calendar: cal)
        p.complete(a.id, at: now); p.complete(b.id, at: now)
        var h = Habit(title: "Walk", created: now.addingTimeInterval(-10 * 86_400))
        h.area = "Health"
        h.done = [day(0)]
        p.habits = [h]
        let areas = p.areas(now: now, calendar: cal)
        XCTAssertEqual(areas.map(\.name), ["Health", "Work", "Learning"], "an area with nothing done yet still shows")
        XCTAssertEqual(areas[0].xp, 40)
        XCTAssertEqual(Planner.level(for: 160, step: 50), .init(number: 3, into: 10, needed: 150))
    }

    func testFocusPaysTwentyAnHourOnlyWhenOver() {
        var p = Planner()
        let task = p.add("Write", day: day(0), area: "Writing", now: now, calendar: cal)
        p.startFocus("Write", taskID: task.id, now: now)
        XCTAssertNotNil(p.runningSession)
        XCTAssertEqual(p.xp(now: now.addingTimeInterval(3600), calendar: cal), 0, "a running session hasn't earned yet")
        p.startFocus("Something else", now: now.addingTimeInterval(90 * 60)) // starting another ends the first
        XCTAssertEqual(p.sessions.filter(\.isRunning).count, 1)
        XCTAssertEqual(p.sessions[0].xp, 30, "90 minutes → 30 XP")
        XCTAssertEqual(p.sessions[0].area, "Writing", "the task's area comes along")
        p.stopFocus(now: now.addingTimeInterval(93 * 60))
        XCTAssertEqual(p.sessions[1].xp, 0, "three minutes is a click, not a session")
        p.startFocus("Forgot to stop", now: now)
        p.stopFocus(now: now.addingTimeInterval(10 * 3600))
        XCTAssertEqual(p.sessions[2].xp, 60, "a session counts at most three hours")
    }

    func testRewardsCostCoinsButNeverLevels() {
        var p = Planner()
        let t = p.add("Ship it", day: day(0), big: true, effort: 3, now: now, calendar: cal)
        p.complete(t.id, at: now) // 50
        let dinner = Reward(title: "Dinner out", cost: 40)
        let trip = Reward(title: "Trip", cost: 500)
        p.rewards = [dinner, trip]
        XCTAssertEqual(p.buy(trip.id, now: now, calendar: cal), .short(by: 450), "no overdraft, no debt")
        guard case .bought = p.buy(dinner.id, now: now, calendar: cal) else { return XCTFail() }
        XCTAssertEqual(p.coins(now: now, calendar: cal), 10)
        XCTAssertEqual(p.xp(now: now, calendar: cal), 50, "spending never lowers the level")
        XCTAssertEqual(p.ledger(now: now, calendar: cal).first { $0.kind == .purchase }?.coins, -40)
    }

    func testChallengePaysWhenReachedAndEndsQuietly() {
        var p = Planner()
        var h = Habit(title: "Write", created: now.addingTimeInterval(-30 * 86_400))
        h.done = [day(-5), day(-3), day(-1)]
        p.habits = [h]
        let won = Challenge(title: "Write 3 times", habitID: h.id, target: 3, start: day(-6), end: day(6))
        let lost = Challenge(title: "Write 10 times", habitID: h.id, target: 10, start: day(-20), end: day(-2))
        let active = Challenge(title: "Write 5 times", habitID: h.id, target: 5, start: day(-6), end: day(3))
        p.challenges = [won, lost, active]
        XCTAssertEqual(p.state(of: won, now: now, calendar: cal), .won)
        XCTAssertEqual(p.state(of: lost, now: now, calendar: cal), .ended)
        XCTAssertEqual(p.state(of: active, now: now, calendar: cal), .active(daysLeft: 4))
        let bonus = p.ledger(now: now, calendar: cal).filter { $0.kind == .challenge }
        XCTAssertEqual(bonus.map(\.xp), [30], "only the won one pays; the ended one costs nothing")
    }

    func testAvoidHabitsCountCleanDaysNeverDamage() {
        var p = Planner()
        var h = Habit(title: "No doomscrolling", created: now.addingTimeInterval(-6 * 86_400))
        h.kind = .avoid
        p.habits = [h]
        XCTAssertEqual(p.habits[0].cleanDays(now, calendar: cal), 6)
        XCTAssertEqual(p.xp(now: now, calendar: cal), 30, "5 for each finished clean day; today isn't over")
        p.toggleSlip(h.id, on: now.addingTimeInterval(-2 * 86_400), calendar: cal)
        XCTAssertEqual(p.habits[0].cleanDays(now, calendar: cal), 1, "the run restarts after a slip…")
        XCTAssertEqual(p.xp(now: now, calendar: cal), 25, "…but no XP is taken away beyond that day's")
        XCTAssertEqual(p.habits[0].streak(now, calendar: cal), .going(1))
    }

    func testRanks() {
        XCTAssertEqual(Planner.rank(for: 1).title, "Novice")
        XCTAssertEqual(Planner.rank(for: 7).title, "Adept")
        XCTAssertEqual(Planner.rank(for: 7).next?.title, "Expert")
        XCTAssertNil(Planner.rank(for: 40).next)
    }

    func testOldFilesGetDefaults() throws {
        let json = #"{"tasks":[{"title":"Old","created":"2026-10-01T09:00:00Z","day":"2026-10-01","big":true}]}"#
        let p = try PlannerStore.decode(Data(json.utf8))
        XCTAssertEqual(p.tasks[0].effort, 1)
        XCTAssertEqual(p.tasks[0].xp, 30, "a big task from phase 1 is still worth 30")
        XCTAssertTrue(p.sessions.isEmpty && p.rewards.isEmpty)
    }
}

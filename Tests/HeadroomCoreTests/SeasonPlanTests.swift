import XCTest
@testable import HeadroomCore

/// Milestones, protected time, the daily score and sync, energy, the stack, the top thing, the wrap, the season draft.
final class SeasonPlanTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    // Thursday 5 November 2026, 10:00.
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!
    lazy var today = Planner.key(now, calendar: cal)

    func season() -> Season {
        Season(start: "2026-11-01", end: "2026-12-26", main: .init(project: "Connector SaaS", hoursPerWeek: 20))
    }

    func testALateMilestoneMeansAdjustEvenWithTheHours() {
        var s = season()
        s.log = ["2026-11-01": ["connector saas": 20 * 60]]
        XCTAssertEqual(s.grid(now: now, calendar: cal)[0].weeks[0], .onTrack)
        s.milestones = [Milestone(title: "Pricing page live", project: "Connector SaaS", due: "2026-11-03")]
        XCTAssertEqual(s.grid(now: now, calendar: cal)[0].weeks[0], .adjust, "due Tuesday, not done")
        var p = Planner(); p.season = s
        p.toggleMilestone(s.milestones![0].id, now: now, calendar: cal)
        XCTAssertEqual(p.season?.milestones?[0].done, today)
        XCTAssertEqual(p.season!.grid(now: now, calendar: cal)[0].weeks[0], .adjust, "done two days late is still late")
        XCTAssertEqual(p.xp(now: now, calendar: cal), Milestone.xp)
        p.endSeason(now: now, calendar: cal)
        XCTAssertNil(p.season)
        XCTAssertEqual(p.pastSeasons.first?.ended, today)
        XCTAssertEqual(p.xp(now: now, calendar: cal), Milestone.xp, "a finished season keeps its milestones' XP")
    }

    func testProtectedTimeIsKeptForItsQuestAndCountsAsPlanned() {
        var s = season()
        s.protected = [ProtectedTime(project: "Connector SaaS", weekdays: [5], start: 9 * 60, end: 12 * 60)] // Thursdays
        var p = Planner(); p.season = s
        XCTAssertEqual(p.protectedBlocks(on: today, calendar: cal).map(\.start), [540])
        XCTAssertEqual(p.firstFree(on: today, from: 9 * 60, minutes: 60, calendar: cal), 12 * 60, "someone else's time")
        XCTAssertEqual(p.firstFree(on: today, from: 9 * 60, minutes: 60, allow: "connector saas", calendar: cal), 9 * 60)
        // 2 of the 3 protected hours are still ahead at 10:00.
        let strength = PlanStrength.of(p, done: ["connector saas": 18 * 60], now: now, calendar: cal)
        XCTAssertEqual(strength?.score ?? 0, 1, accuracy: 0.001)
        p.addBlock(TimeBlock(title: "Calls", day: today, start: 10 * 60, end: 11 * 60))
        XCTAssertTrue(p.protectedBlocks(on: today, calendar: cal).isEmpty, "a real block inside it takes its place")
    }

    func testDailyScoreIsNinetyForTheWorkAndTenForTheSync() {
        var p = Planner()
        let a = p.add("Call clinics", day: today, now: now, calendar: cal)
        _ = p.add("Write post", day: today, now: now, calendar: cal)
        p.addBlock(TimeBlock(title: "Admin", day: today, start: 14 * 60, end: 15 * 60))
        var lunch = TimeBlock(title: "Lunch", day: today, start: 12 * 60, end: 13 * 60); lunch.counts = false
        p.addBlock(lunch)
        XCTAssertEqual(p.score(on: now, now: now, calendar: cal), DayScore(planned: 3, done: 0, synced: false))
        p.complete(a.id, at: now)
        p.blocks[0].done = now
        p.updateLog(today, now: now) { $0.progress = 3 }
        let s = p.score(on: now, now: now, calendar: cal)
        XCTAssertEqual(s.percent, 70, "2 of 3 → 60%, plus 10 for the sync")
        XCTAssertEqual(p.xp(now: now, calendar: cal), 10 + 5, "the task and the daily sync")
    }

    func testEnergyPatternsAndWhenYouWorkBest() {
        var p = Planner()
        func session(_ hour: Int, _ minutes: Int, _ feel: Feel?) -> FocusSession {
            var s = FocusSession(title: "x", start: cal.date(bySettingHour: hour, minute: 0, second: 0, of: now)!, area: "Connector SaaS")
            s.end = s.start.addingTimeInterval(TimeInterval(minutes * 60)); s.feel = feel
            return s
        }
        p.sessions = [session(8, 90, .energizing), session(9, 60, .energizing), session(15, 120, .draining), session(16, 60, .neutral)]
        let t = EnergyPatterns.tally(p, since: now.addingTimeInterval(-86_400), calendar: cal)
        XCTAssertEqual(t.parts[.morning], .init(energizing: 2, draining: 0))
        XCTAssertEqual(t.parts[.afternoon], .init(energizing: 0, draining: 1), "neutral isn't counted")
        XCTAssertEqual(EnergyPatterns.lines(p, since: now.addingTimeInterval(-86_400), calendar: cal).first,
                       "Mornings energized you 2 times, drained you 0 times")
        XCTAssertEqual(DayPart.peak(p.sessions, calendar: cal), .afternoon, "180 afternoon minutes beat 150 in the morning")
        XCTAssertEqual(FocusMode.verdict(0.91), "Locked in. Great session")
        XCTAssertEqual(FocusMode.verdict(0.49), "Tough one. The distractions won")
    }

    func testTheStackPlacesTodaysTasksAroundEverything() {
        var s = season()
        s.protected = [ProtectedTime(project: "Connector SaaS", weekdays: [5], start: 13 * 60, end: 15 * 60)]
        var p = Planner(); p.season = s
        let big = p.add("Ship the API", day: today, big: true, now: now, calendar: cal)
        p.tasks[p.tasks.firstIndex { $0.id == big.id }!].project = "Connector SaaS"
        let small = p.add("Reply to Ana", day: today, now: now, calendar: cal)
        let meeting = DateInterval(start: cal.date(bySettingHour: 10, minute: 0, second: 0, of: now)!, duration: 3600)
        let placed = p.stack(on: today, from: 10 * 60, busy: [meeting], now: now, calendar: cal)
        XCTAssertEqual(placed.map(\.taskID), [big.id, small.id], "big first")
        XCTAssertEqual(placed[0].start, 13 * 60, "a quest's task goes into its protected time")
        XCTAssertEqual(placed[1].start, 11 * 60, "after the meeting")
        XCTAssertTrue(placed.allSatisfy { b in b.minutes == Stack.minutes(for: p.tasks.first { $0.id == b.taskID }!) })
        p.blocks = placed
        XCTAssertTrue(p.stack(on: today, from: 10 * 60, now: now, calendar: cal).isEmpty, "a task with a block isn't stacked again")
    }

    func testTopThingWrapAndSeasonDraft() {
        var p = Planner()
        let t = p.add("Close first clinic", day: today, now: now, calendar: cal)
        p.updateLog(today, now: now) { $0.top = t.id }
        XCTAssertEqual(p.topThing(on: today)?.title, "Close first clinic")

        var s = season()
        s.log = ["2026-11-01": ["connector saas": 600]]
        s.milestones = [Milestone(title: "a", project: "Connector SaaS")]
        var f = FocusSession(title: "x", start: cal.date(bySettingHour: 21, minute: 30, second: 0, of: now)!); f.end = f.start.addingTimeInterval(3600)
        p.sessions = [f]
        let wrap = SeasonWrap.of(s, planner: p, now: now, calendar: cal)
        XCTAssertEqual(wrap.days, 5)
        XCTAssertEqual(wrap.focusMinutes, 60)
        XCTAssertEqual(wrap.quests.first?.minutes, 600)
        XCTAssertEqual(wrap.peak, .night)
        XCTAssertEqual(wrap.milestones, 1)

        let reply = #"Here: {"main":{"project":"Connector SaaS","hoursPerWeek":20},"sides":[{"project":"Maker ERP","hoursPerWeek":8},{"project":"a","hoursPerWeek":1},{"project":"b","hoursPerWeek":1}],"support":["Gym"],"milestones":[{"title":"10 paying clinics","project":"Connector SaaS","week":12},{"title":"Beta","project":"Maker ERP","week":40}],"manifesto":"This season I ship."}"#
        let draft = Coach.parseSeason(reply)
        XCTAssertEqual(draft?.sides.count, 2, "at most two side quests")
        let made = draft?.season(start: "2026-11-01", weeks: 12, calendar: cal)
        XCTAssertEqual(made?.end, "2027-01-23")
        XCTAssertEqual(made?.milestones?.map(\.due), ["2027-01-23", "2027-01-23"], "a week past the end lands on the last day")
        XCTAssertEqual(made?.support, ["Gym"])
        XCTAssertNil(Coach.parseSeason(#"{"main":{"project":" ","hoursPerWeek":5}}"#))

        var c = DayContext(now: now, planner: p)
        c.memory = "Mornings are for building; calls after 2 pm."
        c.dump = "call Ana re invoices, fix login bug"
        let prompt = Coach.prompt(.dump, c, calendar: cal)
        XCTAssertTrue(prompt.contains("WHAT YOU KNOW ABOUT THEM"))
        XCTAssertTrue(prompt.contains("call Ana re invoices"))
        XCTAssertTrue(prompt.contains("TOP THING TODAY: Close first clinic"))
        XCTAssertEqual(Coach.parse(#"{"big":[],"tasks":["Call Ana"],"note":"","remember":[" Ana handles invoices "],"top":" "}"#)?.remember, ["Ana handles invoices"])
    }

    func testOldFilesStillRead() throws {
        let p = try PlannerStore.decode(Data(#"{"season":{"start":"2026-11-03","end":"2026-11-16","main":{"project":"a","hoursPerWeek":5},"sides":[]},"logs":[{"day":"2026-11-03","note":""}]}"#.utf8))
        XCTAssertTrue(p.pastSeasons.isEmpty)
        XCTAssertNil(p.season?.milestones)
        XCTAssertNil(p.logs[0].progress)
    }
}

import XCTest
@testable import HeadroomCore

/// Time blocks, 12-week seasons with a weekly read, plan strength, focus quality and the shield, the coach's blocks.
final class FocusPlanTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 10))!
    lazy var today = Planner.key(now, calendar: cal)
    func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func testBlocksNeverOverlapAndFreeSlotsGoAroundThem() {
        var p = Planner()
        XCTAssertNotNil(p.addBlock(TimeBlock(title: "Outreach", day: today, start: 9 * 60, end: 11 * 60)))
        XCTAssertNil(p.addBlock(TimeBlock(title: "Clash", day: today, start: 10 * 60, end: 10 * 60 + 30)))
        XCTAssertNotNil(p.addBlock(TimeBlock(title: "Back to back", day: today, start: 11 * 60, end: 12 * 60)))
        let meeting = DateInterval(start: cal.startOfDay(for: now).addingTimeInterval(12.5 * 3600), duration: 3600) // 12:30–13:30
        XCTAssertEqual(p.firstFree(on: today, from: 9 * 60, minutes: 60, busy: [meeting], calendar: cal), 13 * 60 + 30,
                       "12:00–12:30 is too short, the meeting runs to 13:30")
        XCTAssertNil(p.firstFree(on: today, from: 21 * 60 + 30, minutes: 60, calendar: cal), "nothing past 22:00")
        XCTAssertEqual(TimeBlock.minute("09:30"), 570)
        XCTAssertNil(TimeBlock.minute("9.30"))
    }

    func testSeasonWeeksDayNumbersAndTheWeeklyRead() {
        var s = Season(start: "2026-11-01", end: "2026-12-26", main: .init(project: "Connector SaaS", hoursPerWeek: 20),
                       sides: [.init(project: "Maker ERP", hoursPerWeek: 8)])
        XCTAssertEqual(s.days, 56)
        XCTAssertEqual(s.weekCount, 8)
        XCTAssertEqual(s.dayNumber(on: "2026-11-05", calendar: cal), 5)
        XCTAssertEqual(s.weekIndex(on: "2026-11-08", calendar: cal), 1, "season weeks run from its first day")
        XCTAssertEqual(s.weekDays(7, calendar: cal).last, "2026-12-26")

        var p = Planner()
        p.season = s
        XCTAssertTrue(p.recordSeasonWeek(["connector saas": 300, "maker erp": 60, "youtube": 999], on: now, calendar: cal))
        XCTAssertFalse(p.recordSeasonWeek(["connector saas": 300, "maker erp": 60], on: now, calendar: cal), "unchanged: no write")
        XCTAssertEqual(p.season?.log?["2026-11-01"], ["connector saas": 300, "maker erp": 60], "only the season's quests are kept")
        s = p.season!
        // Day 5 at 10:00 → about 4.4 of 7 days gone: 20 h/wk expects ~12.5 h, so 5 h is off track; 1 h of ~5 h too.
        let grid = s.grid(now: now, calendar: cal)
        XCTAssertEqual(grid.map(\.weeks.first), [.offTrack, .offTrack])
        XCTAssertEqual(grid[0].weeks[1], .upcoming)
        XCTAssertEqual(Season.status(minutes: 20 * 60, hoursPerWeek: 20, elapsed: 1), .onTrack)
        XCTAssertEqual(Season.status(minutes: 14 * 60, hoursPerWeek: 20, elapsed: 1), .adjust)
        XCTAssertEqual(Season.status(minutes: 6 * 60, hoursPerWeek: 20, elapsed: 0.5), .adjust, "judged on pace mid-week")
    }

    func testOldSeasonsAndPlannersStillRead() throws {
        let p = try PlannerStore.decode(Data(#"{"season":{"start":"2026-11-03","end":"2026-11-16","main":{"project":"a","hoursPerWeek":5},"sides":[]}}"#.utf8))
        XCTAssertNil(p.season?.log)
        XCTAssertTrue(p.blocks.isEmpty)
    }

    func testPlanStrengthIsTheShareOfWhatsLeftThatHasABlock() {
        var p = Planner()
        p.season = Season(start: today, end: Planner.key(daysFrom: now, 13, calendar: cal),
                          main: .init(project: "Connector SaaS", hoursPerWeek: 10), sides: [.init(project: "Maker ERP", hoursPerWeek: 4)])
        // 6 h of connector done → 4 h left; 2 h blocked tomorrow. Maker: 4 h left, 4 h blocked. 6 of 8 h covered.
        p.addBlock(TimeBlock(title: "API work", day: Planner.key(daysFrom: now, 1, calendar: cal), start: 540, end: 660, project: "Connector SaaS"))
        p.addBlock(TimeBlock(title: "Maker ERP invoices", day: Planner.key(daysFrom: now, 2, calendar: cal), start: 540, end: 780))
        p.addBlock(TimeBlock(title: "Connector SaaS earlier", day: today, start: 6 * 60, end: 7 * 60)) // already past: doesn't count
        let s = PlanStrength.of(p, done: ["connector saas": 360], now: now, calendar: cal)
        XCTAssertEqual(s?.score ?? 0, 0.75, accuracy: 0.001)
        XCTAssertEqual(s?.gaps, ["Connector SaaS": 120])
    }

    func testFocusQualityAndTheShield() {
        let c = Classifier(settings: TimelineSettings(), projects: ["Headroom"])
        var session = FocusSession(title: "Pricing page", start: at(-60))
        session.end = now
        let spans = [
            ActivitySpan(start: at(-60), end: at(-15), app: "com.apple.dt.Xcode", appName: "Xcode", title: "Headroom — x.swift"),
            ActivitySpan(start: at(-15), end: at(-9), app: "com.google.Chrome", appName: "Chrome", host: "youtube.com"),
            ActivitySpan(start: at(-9), end: now, app: "com.apple.dt.Xcode", appName: "Xcode"),
        ]
        XCTAssertEqual(FocusMode.quality(session, spans: spans, classifier: c, now: now) ?? 0, 0.9, accuracy: 0.001)
        XCTAssertNil(FocusMode.quality(session, spans: [], classifier: c, now: now), "no timeline, no score")

        let yt = ActivitySpan(start: now, end: now, app: "com.google.Chrome", appName: "Chrome", host: "youtube.com")
        let steam = ActivitySpan(start: now, end: now, app: "com.valvesoftware.steam", appName: "Steam")
        XCTAssertEqual(FocusMode.react(.hide, running: session, front: yt, classifier: c, lastReminder: nil, now: now),
                       .remind("You're focusing on Pricing page — youtube.com can wait."), "a browser is never hidden for one tab")
        XCTAssertEqual(FocusMode.react(.remind, running: session, front: yt, classifier: c, lastReminder: at(-2), now: now), .none, "quiet for 5 minutes")
        XCTAssertEqual(FocusMode.react(.remind, running: nil, front: yt, classifier: c, lastReminder: nil, now: now), .none, "only during focus")
        let xcode = ActivitySpan(start: now, end: now, app: "com.apple.dt.Xcode", appName: "Xcode")
        XCTAssertEqual(FocusMode.react(.hide, running: session, front: xcode, classifier: c, lastReminder: nil, now: now), .none)
        _ = steam
    }

    func testCoachBlocksAreParsedCheckedAndPlacedWithoutClashes() {
        let reply = #"""
        {"big":[],"tasks":[],"note":"Connector is behind.","recommendations":[{"title":"Move API work to mornings","why":"Afternoon blocks slipped twice."}],
         "blocks":[{"title":"API work","day":"2026-11-06","start":"09:00","end":"11:00","project":"Connector SaaS"},
                   {"title":"Bad","start":"11:00","end":"10:00"},{"title":"Clash","day":"2026-11-06","start":"10:00","end":"10:30"}]}
        """#
        let plan = Coach.parse(reply)
        XCTAssertEqual(plan?.recommendations.first?.title, "Move API work to mornings")
        XCTAssertEqual(plan?.blocks.map(\.title), ["API work", "Clash"], "an end before its start is dropped")
        var p = Planner()
        XCTAssertEqual(p.acceptBlocks(plan!.blocks, day: today), 1, "the clashing one stays out")
        XCTAssertEqual(p.blocks.first?.fromCoach, true)

        var c = DayContext(now: now, planner: p, seasonWeek: [:])
        c.planner.season = Season(start: today, end: Planner.key(daysFrom: now, 83, calendar: cal), main: .init(project: "Connector SaaS", hoursPerWeek: 20))
        let week = Coach.prompt(.week, c, calendar: cal)
        XCTAssertTrue(week.contains("Day 1 of 84"))
        XCTAssertTrue(week.contains("PLAN STRENGTH"))
        XCTAssertTrue(week.contains("recommendations"))
    }
}

final class CalendarMirrorTests: XCTestCase {
    func testMirrorAddsChangesAndRemovesOnlyItsOwnEvents() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let a = TimeBlock(title: "Outreach", day: "2026-11-05", start: 540, end: 600)
        var b = TimeBlock(title: "Pricing page", day: "2026-11-05", start: 660, end: 720)
        let gone = UUID()
        let ivA = a.interval(calendar: cal)!, ivB = b.interval(calendar: cal)!
        let existing = ["e1": CalendarMirror.Event(title: "Outreach", start: ivA.start, end: ivA.end),
                        "e2": CalendarMirror.Event(title: "Pricing page", start: ivB.start, end: ivB.end),
                        "e3": CalendarMirror.Event(title: "Old", start: ivA.start, end: ivA.end),
                        "mine": CalendarMirror.Event(title: "Something I typed in Calendar", start: ivA.start, end: ivA.end)]
        b.end = 750
        let plan = CalendarMirror.plan(blocks: [a, b], mapped: [a.id: "e1", b.id: "e2", gone: "e3"], existing: existing, calendar: cal)
        XCTAssertTrue(plan.create.isEmpty)
        XCTAssertEqual(plan.update["e2"]?.end, b.interval(calendar: cal)!.end, "moved block → event follows")
        XCTAssertNil(plan.update["e1"], "unchanged: left alone")
        XCTAssertEqual(plan.delete, ["e3"], "only events Headroom made for a block that's gone")
        let again = CalendarMirror.plan(blocks: [a], mapped: [a.id: "deleted-in-calendar"], existing: [:], calendar: cal)
        XCTAssertEqual(again.create.map(\.id), [a.id], "deleted in Calendar but the block is still planned: made again")
    }
}

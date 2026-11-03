import XCTest
@testable import HeadroomCore

/// Journal and check-in XP, proof habits, focus found in the timeline, sleep from rest events, the month view.
final class LifeLogTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 15))!
    func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
    lazy var today = Planner.key(now, calendar: cal)

    func testJournalNeedsRealWordsAndCheckInNeedsBoth() {
        var p = Planner()
        p.updateLog(today, now: now) { $0.note = "fine"; $0.mood = 4 }
        XCTAssertEqual(p.xp(now: now, calendar: cal), 0, "one word isn't a journal; mood alone isn't a check-in")
        p.updateLog(today, now: now) { $0.note = "Called two clinics and shipped the pricing page"; $0.energy = 3 }
        XCTAssertEqual(p.xp(now: now, calendar: cal), 15)
        XCTAssertEqual(p.logs.count, 1, "one log a day")
        p.updateLog(today, now: now) { $0.note = "" }
        XCTAssertEqual(p.xp(now: now, calendar: cal), 5, "clearing the entry takes its XP back")
    }

    func testOldPlannerFilesStillRead() throws {
        let p = try PlannerStore.decode(Data(#"{"tasks":[],"habits":[{"title":"Gym","done":[]}],"sessions":[{"id":"\#(UUID())","title":"x","start":"2026-11-03T10:00:00Z"}]}"#.utf8))
        XCTAssertTrue(p.logs.isEmpty)
        XCTAssertNil(p.habits[0].proof)
        XCTAssertNil(p.sessions[0].detected)
    }

    func testCommitsCheckOffProofHabitsOnce() {
        var p = Planner()
        var any = Habit(title: "Commit something", created: now.addingTimeInterval(-86_400)); any.proof = HabitProof()
        var flare = Habit(title: "Ship Flare", created: now.addingTimeInterval(-86_400)); flare.proof = HabitProof(project: "flare-forge")
        p.habits = [any, flare]
        let yesterday = Commit(project: "flare-forge", hash: "y", date: at(-24 * 60), subject: "old")
        XCTAssertTrue(p.applyProof([yesterday], on: now, calendar: cal).isEmpty, "yesterday's commit isn't today's proof")
        let c = Commit(project: "Headroom", hash: "a", date: at(-30), subject: "Journal card")
        XCTAssertEqual(p.applyProof([c], on: now, calendar: cal).map(\.title), ["Commit something"])
        XCTAssertTrue(p.applyProof([c], on: now, calendar: cal).isEmpty, "checked once")
        let f = Commit(project: "Flare-Forge", hash: "b", date: at(-10), subject: "fix")
        XCTAssertEqual(p.applyProof([c, f], on: now, calendar: cal).map(\.title), ["Ship Flare"], "project matched case-insensitively")
    }

    func testFocusIsFoundInLongStretchesAndBrokenByDistraction() {
        let c = Classifier(settings: TimelineSettings(), projects: ["Headroom"])
        func claude(_ a: Double, _ b: Double) -> ActivitySpan {
            ActivitySpan(start: at(a), end: at(b), app: ActivitySpan.claudeCode, appName: "Claude Code", project: "Headroom")
        }
        let yt = ActivitySpan(start: at(-100), end: at(-90), app: "com.google.Chrome", appName: "Chrome", host: "youtube.com")
        // -180…-100 with a 4-minute gap (one stretch of 80), YouTube at -100…-90, then -90…-60 (30: too short).
        let spans = [claude(-180, -140), claude(-136, -100), yt, claude(-90, -60), claude(-5, 0)]
        let found = FocusDetector.stretches(spans, classifier: c, now: now)
        XCTAssertEqual(found.map(\.minutes), [80])
        XCTAssertEqual(found.first?.project, "Headroom")
        XCTAssertTrue(FocusDetector.stretches([claude(-45, -1)], classifier: c, now: now).isEmpty, "still going: not cut short")

        var p = Planner()
        XCTAssertEqual(p.recordDetectedFocus(found).count, 1)
        XCTAssertEqual(p.recordDetectedFocus(found).count, 0, "found once")
        XCTAssertEqual(p.sessions[0].detected, true)
        XCTAssertEqual(p.sessions[0].xp, 26, "20 XP an hour, like a session you start yourself")
        var mine = Planner()
        var s = FocusSession(title: "Mine", start: at(-170)); s.end = at(-120)
        mine.sessions = [s]
        XCTAssertTrue(mine.recordDetectedFocus(found).isEmpty, "never on top of a session you ran")
        let long = FocusStretch(project: "Headroom", area: nil, start: at(-300), end: at(-10))
        var q = Planner()
        XCTAssertEqual(q.recordDetectedFocus([long]).map { $0.minutes() }, [180, 110], "split at the 3 h cap")
    }

    func testSleepIsTheLongestNightTimeRest() {
        let midnight = cal.startOfDay(for: now)
        func t(_ h: Double) -> Date { midnight.addingTimeInterval(h * 3600) }
        let events = [
            RestEvent(.lock, at: t(-10)), RestEvent(.unlock, at: t(-9)),        // an hour away in the afternoon
            RestEvent(.lock, at: t(-0.75)), RestEvent(.sleep, at: t(-0.7)),     // 23:15 locked, then asleep
            RestEvent(.wake, at: t(3)), RestEvent(.lock, at: t(3.1)),           // a 6-minute check at 03:00
            RestEvent(.wake, at: t(7.25)), RestEvent(.unlock, at: t(7.3)),
            RestEvent(.lock, at: t(13)), RestEvent(.unlock, at: t(14)),         // lunch
        ]
        let n = Rest.night(endingOn: today, events: events, calendar: cal)
        XCTAssertEqual(n?.start, t(-0.75))
        XCTAssertEqual(n?.end, t(7.25))
        XCTAssertNil(Rest.night(endingOn: today, events: [RestEvent(.lock, at: t(13)), RestEvent(.unlock, at: t(17))], calendar: cal),
                     "an afternoon away isn't a night")
    }

    func testMonthShowsDoneMissedAndNotPlanned() {
        var h = Habit(title: "Gym", weekdays: [2, 4, 6], created: cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!)
        h.done = ["2026-11-02"]
        let days = h.month(of: now, now: now, calendar: cal)
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days[0].mark, .off, "before the habit existed")
        XCTAssertEqual(days[1].mark, .done)
        XCTAssertEqual(days[2].mark, .future, "today isn't a miss yet")
        var later = h
        later.done = []
        XCTAssertEqual(later.month(of: now, now: at(3 * 24 * 60), calendar: cal)[3].mark, .missed, "Wednesday, planned, not done")
        XCTAssertEqual(later.month(of: now, now: at(3 * 24 * 60), calendar: cal)[4].mark, .off, "Thursday isn't planned")
    }

    func testCoachIsToldSleepMoodAndJournal() {
        var p = Planner()
        p.updateLog(today, now: now) { $0.mood = 2; $0.energy = 1; $0.note = "Rough night, slow start, still called one clinic" }
        var c = DayContext(now: now, planner: p)
        c.sleep = SleepEstimate(start: at(-15 * 60), end: at(-10 * 60))
        c.logs = p.logs
        let morning = Coach.prompt(.morning, c, calendar: cal)
        XCTAssertTrue(morning.contains("SLEEP"))
        XCTAssertTrue(morning.contains("mood 2/5 (low)"))
        XCTAssertTrue(morning.contains("plan lighter"))
        let reflect = Coach.reflectionPrompt(c, day: today)
        XCTAssertTrue(reflect.contains("Rough night"))
        XCTAssertFalse(reflect.contains("JSON:"), "plain text back, not a plan")
    }
}

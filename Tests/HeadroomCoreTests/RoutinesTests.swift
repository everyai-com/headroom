import XCTest
@testable import HeadroomCore

/// Routines, meeting prep and the pause shield.
final class RoutinesTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }

    func testRoutinesNudgeOnceInsideTheirWindow() {
        let r = Routines.defaults
        XCTAssertTrue(Routines.due(r, now: at(5, 8, 29), nudged: [:], calendar: cal).isEmpty)
        XCTAssertEqual(Routines.due(r, now: at(5, 9), nudged: [:], calendar: cal).map(\.kind), [.morning])
        XCTAssertTrue(Routines.due(r, now: at(5, 9), nudged: ["morning": "2026-11-05"], calendar: cal).isEmpty)
        XCTAssertTrue(Routines.due(r, now: at(5, 10, 31), nudged: [:], calendar: cal).isEmpty, "two hours late is too late")
        XCTAssertTrue(Routines.due(r, now: at(5, 18), nudged: [:], done: [.evening], calendar: cal).isEmpty, "already synced")
        XCTAssertEqual(Routines.due(r, now: at(8, 18, 5), nudged: [:], calendar: cal).map(\.kind), [.evening, .week], "Sunday")
        XCTAssertEqual(Routines.due(r, now: at(5, 18, 5), nudged: [:], calendar: cal).map(\.kind), [.evening], "not on Thursday")
    }

    func testMeetingHeadsUpAndPrompt() {
        let call = CalendarEvent(title: "Clinic demo", start: at(5, 14), end: at(5, 14, 30), calendar: "Work",
                                 notes: "Show the booking flow", people: ["Ana", "Ravi"])
        let lunch = CalendarEvent(title: "Holiday", start: at(5, 0), end: at(6, 0), calendar: "Home", allDay: true)
        XCTAssertNil(MeetingPrep.upcoming([call, lunch], now: at(5, 13, 45), nudged: []))
        XCTAssertEqual(MeetingPrep.upcoming([call, lunch], now: at(5, 13, 52), nudged: []), call)
        XCTAssertNil(MeetingPrep.upcoming([call], now: at(5, 13, 52), nudged: [MeetingPrep.key(call)]))
        XCTAssertEqual(MeetingPrep.next([lunch, call], now: at(5, 9), calendar: cal), call)
        XCTAssertNil(MeetingPrep.next([call], now: at(5, 15), calendar: cal), "it's over")

        var c = DayContext(now: at(5, 13, 52), planner: Planner())
        c.meeting = call
        let p = Coach.prompt(.meeting, c, calendar: cal)
        XCTAssertTrue(p.contains("\"Clinic demo\" at 14:00 (30 min) with Ana, Ravi"))
        XCTAssertTrue(p.contains("Show the booking flow"))
    }

    func testThePauseCardLetsThroughWhatYouAllowed() {
        let session = FocusSession(title: "Ship the API", start: at(5, 9))
        let youtube = ActivitySpan(start: at(5, 10), end: at(5, 10), app: "com.google.Chrome", appName: "Chrome", host: "youtube.com")
        let c = Classifier(settings: TimelineSettings(), projects: [])
        XCTAssertEqual(FocusMode.react(.pause, running: session, front: youtube, classifier: c, lastReminder: nil, now: at(5, 10)),
                       .pause("You're focusing on Ship the API. youtube.com can wait."))
        XCTAssertEqual(FocusMode.react(.pause, running: session, front: youtube, classifier: c, lastReminder: nil,
                                       allowed: ["youtube.com": at(5, 10, 5)], now: at(5, 10)), FocusMode.Reaction.none)
        XCTAssertNotEqual(FocusMode.react(.pause, running: session, front: youtube, classifier: c, lastReminder: nil,
                                          allowed: ["youtube.com": at(5, 10, 5)], now: at(5, 10, 6)), FocusMode.Reaction.none, "time's up")
        XCTAssertEqual(FocusMode.react(.pause, running: nil, front: youtube, classifier: c, lastReminder: nil, now: at(5, 10)), FocusMode.Reaction.none)
    }
}

/// The Science of Getting Rich, as practices: vision, gratitude, value given, the certain way.
final class VisionTests: XCTestCase {
    func testTheCertainWayIsReadFromTheDayAndTicked() throws {
        var p = Planner()
        let day = "2026-11-05"
        let now = Planner.date(day)!.addingTimeInterval(10 * 3600)
        let t = p.add("Call clinics", day: day, now: now)
        XCTAssertTrue(CertainWay.met(p.log(on: day), score: p.score(on: now, now: now)).isEmpty)
        p.complete(t.id, at: now)
        p.updateLog(day, now: now) {
            $0.gratitude = ["a", "b"]; $0.gave = "Ana: a free audit"; $0.visioned = true
            $0.ways = ["noHurry", "creative", "now", "vision"] // "vision" can't be ticked by hand
        }
        var met = CertainWay.met(p.log(on: day), score: p.score(on: now, now: now))
        XCTAssertEqual(met, [.allDone, .value, .vision, .noHurry, .creative, .now], "two thanks aren't three")
        p.updateLog(day, now: now) { $0.gratitude = ["a", "b", "c"] }
        met = CertainWay.met(p.log(on: day), score: p.score(on: now, now: now))
        XCTAssertTrue(met.contains(.gratitude))
        // Task 10, gratitude 5, value 5, vision 5, the certain way 10.
        XCTAssertEqual(p.xp(now: now), 35)

        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let saved = try PlannerStore.decode(e.encode(p))
        XCTAssertEqual(saved.log(on: day)?.gave, "Ana: a free audit")
        XCTAssertNil(try PlannerStore.decode(Data(#"{"logs":[{"day":"2026-11-05","note":""}]}"#.utf8)).vision)
    }

    func testVisionLinesHeadlineAndWaiting() {
        XCTAssertEqual(Vision.lines("- a calm founder\n\n• ships weekly \n"), ["a calm founder", "ships weekly"])
        var v = Vision(have: ["A studio"], picture: "I wake at 6.\nCoffee.")
        XCTAssertEqual(v.headline, "A studio")
        v.become = ["A calm founder"]
        XCTAssertEqual(v.headline, "A calm founder")
        XCTAssertEqual(Decision(title: "Hire", parked: "2026-11-05").ready(), "2026-11-07")
        let c = DayContext(now: Planner.date("2026-11-05")!, planner: { var p = Planner(); p.vision = v; return p }())
        XCTAssertTrue(Coach.prompt(.morning, c).contains("- become: A calm founder"))
    }
}

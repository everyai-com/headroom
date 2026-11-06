import XCTest
@testable import HeadroomCore

/// The planner add-on: the Big 3, rolling tasks, never-miss-twice streaks, XP and the shared file.
final class PlannerTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Sunday 1 Nov 2026, noon UTC.
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12))!
    func day(_ offset: Int) -> String { Planner.key(daysFrom: now, offset, calendar: cal) }

    func testOnlyThreeBigTasksADay() {
        var p = Planner()
        for i in 0..<4 { p.add("Big \(i)", day: day(0), big: true, now: now, calendar: cal) }
        XCTAssertEqual(p.bigToday(now, calendar: cal).count, 3, "the fourth is added as an ordinary task")
        XCTAssertEqual(p.today(now, calendar: cal).count, 4)
        let first = p.bigToday(now, calendar: cal)[0].id
        p.complete(first, at: now)
        XCTAssertFalse(p.canMakeBig(on: day(0), now: now, calendar: cal), "finished big tasks still count: three is three")
        XCTAssertTrue(p.canMakeBig(on: day(1), now: now, calendar: cal))
        XCTAssertFalse(p.add("Inbox", day: nil, big: true, now: now, calendar: cal).big, "an unplanned task can't be big")
    }

    func testOpenTasksRollForwardAndDoneOnesStayForTheDay() {
        var p = Planner()
        let old = p.add("From Friday", day: day(-2), now: now, calendar: cal)
        let finished = p.add("Done Friday", day: day(-2), now: now, calendar: cal)
        p.complete(finished.id, at: now.addingTimeInterval(-2 * 86_400))
        let later = p.add("Tuesday", day: day(2), now: now, calendar: cal)
        p.add("Someday", day: nil, now: now, calendar: cal)
        XCTAssertEqual(p.today(now, calendar: cal).map(\.id), [old.id])
        XCTAssertEqual(p.upcoming(now, calendar: cal).map(\.id), [later.id])
        XCTAssertEqual(p.inbox.map(\.title), ["Someday"])
        p.complete(old.id, at: now)
        XCTAssertEqual(p.today(now, calendar: cal).first?.isDone, true, "finished today: still shown, at the bottom")
        p.complete(old.id, at: now)
        XCTAssertFalse(p.today(now, calendar: cal)[0].isDone, "completing again undoes it")
    }

    func habit(done offsets: [Int], weekdays: Set<Int> = [], createdDaysAgo: Int = 30) -> Habit {
        var h = Habit(title: "Write", identity: "a writer", weekdays: weekdays, created: now.addingTimeInterval(-Double(createdDaysAgo) * 86_400))
        h.done = Set(offsets.map(day))
        return h
    }

    func testNeverMissTwice() {
        XCTAssertEqual(habit(done: [0, -1, -2]).streak(now, calendar: cal), .going(3))
        XCTAssertEqual(habit(done: [-1, -2]).streak(now, calendar: cal), .going(2), "today isn't missed until it's over")
        XCTAssertEqual(habit(done: [-2, -3]).streak(now, calendar: cal), .missedOnce(2), "missed yesterday: today decides")
        XCTAssertEqual(habit(done: [0, -2, -3]).streak(now, calendar: cal), .going(3), "one miss bends it, doesn't break it")
        XCTAssertEqual(habit(done: [-3, -4]).streak(now, calendar: cal), .none, "two misses in a row break it")
        XCTAssertEqual(habit(done: [0, -1, -4, -5]).streak(now, calendar: cal), .going(2), "older days behind a double miss don't count")
        XCTAssertEqual(habit(done: [], createdDaysAgo: 0).streak(now, calendar: cal), .none)
    }

    func testUnplannedDaysAreNotMisses() {
        // Weekdays only (Mon–Fri = 2…6); today is Sunday, Friday was done, Saturday isn't planned.
        let weekdays: Set<Int> = [2, 3, 4, 5, 6]
        XCTAssertEqual(habit(done: [-2, -3], weekdays: weekdays).streak(now, calendar: cal), .going(2))
        XCTAssertFalse(habit(done: [], weekdays: weekdays).isScheduled(now, calendar: cal))
    }

    func testXPAndLevels() {
        var p = Planner()
        let big = p.add("Ship", day: day(0), big: true, now: now, calendar: cal)
        let small = p.add("Email", day: day(0), now: now, calendar: cal)
        p.complete(big.id, at: now)
        p.complete(small.id, at: now)
        XCTAssertEqual(p.xp(calendar: cal), 40)
        p.habits = [habit(done: [0, -1, -2])]
        XCTAssertEqual(p.xp(calendar: cal), 40 + 10 + 12 + 14, "streak days earn a little more")
        XCTAssertEqual(Planner.level(for: 0), .init(number: 1, into: 0, needed: 100))
        XCTAssertEqual(Planner.level(for: 150), .init(number: 2, into: 50, needed: 200))
        XCTAssertEqual(Planner.level(for: 300).number, 3)
    }

    func testVotesCountThisWeekPerIdentity() {
        var p = Planner()
        // Sunday 1 Nov: the week (Monday on) started 26 Oct.
        p.habits = [habit(done: [0, -1, -6, -7])]
        XCTAssertEqual(p.votes(weekOf: now, calendar: cal).first?.votes, 3, "Mon 26 Oct – Sun 1 Nov; 25 Oct is last week")
        XCTAssertEqual(p.votes(weekOf: now, calendar: cal).first?.identity, "a writer")
    }

    func testMutateRereadsTheFileSoTwoWritersMerge() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("planner.json")
        let stale = PlannerStore.load(from: url) // the window's copy
        PlannerStore.mutate(at: url) { $0.add("From the CLI", day: nil, source: .cli) }
        XCTAssertTrue(stale.tasks.isEmpty)
        let merged = PlannerStore.mutate(at: url) { $0.add("From the window", day: nil) }
        XCTAssertEqual(Set(merged.planner.tasks.map(\.title)), ["From the CLI", "From the window"])
        XCTAssertEqual(PlannerStore.load(from: url).tasks.count, 2)
    }

    func testConcurrentWritersAllLand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("planner.json")
        // Several `headroom-cli add` runs at once (an agent fanning out): the lock keeps every one.
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            PlannerStore.mutate(at: url) { $0.add("Task \(i)", day: nil) }
        }
        XCTAssertEqual(PlannerStore.load(from: url).tasks.count, 20)
    }

    func testAnUnreadableFileIsSetAsideNotErased() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("planner.json")
        try Data("{ not json".utf8).write(to: url)
        PlannerStore.mutate(at: url) { $0.add("New", day: nil) }
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("planner-unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(aside[0]), encoding: .utf8), "{ not json")
    }

    func testOlderFilesWithMissingKeysStillRead() throws {
        let json = #"{"tasks":[{"title":"Old task","created":"2026-10-01T09:00:00Z","day":"2026-10-01"}],"habits":[{"title":"Read","created":"2026-10-01T09:00:00Z"}]}"#
        let p = try PlannerStore.decode(Data(json.utf8))
        XCTAssertEqual(p.tasks.first?.title, "Old task")
        XCTAssertEqual(p.tasks.first?.big, false)
        XCTAssertEqual(p.habits.first?.archived, false)
    }

    func testMovingABigTaskKeepsItBigOnlyIfThereIsRoom() {
        var p = Planner()
        for i in 0..<3 { p.add("Today \(i)", day: day(0), big: true, now: now, calendar: cal) }
        let later = p.add("Tomorrow", day: day(1), big: true, now: now, calendar: cal)
        p.schedule(later.id, day: day(0), now: now, calendar: cal)
        XCTAssertEqual(p.bigToday(now, calendar: cal).count, 3, "a fourth big task can't sneak in by moving days")
        let overdue = p.add("Overdue", day: day(-3), now: now, calendar: cal)
        XCTAssertFalse(p.setBig(overdue.id, true, now: now, calendar: cal), "an overdue task is checked against today")
        let moved = p.bigToday(now, calendar: cal)[0].id
        p.schedule(moved, day: day(2), now: now, calendar: cal)
        XCTAssertTrue(p.tasks.first { $0.id == moved }!.big, "room on the new day: stays big")
        p.schedule(moved, day: nil, now: now, calendar: cal)
        XCTAssertFalse(p.tasks.first { $0.id == moved }!.big, "the inbox has no Big 3")
    }

    func testStreakBonusCountsPlannedDaysNotCalendarDays() {
        var p = Planner()
        // Mon/Wed/Fri habit done three planned days in a row: 10 + 12 + 14.
        var h = Habit(title: "Gym", weekdays: [2, 4, 6], created: now.addingTimeInterval(-30 * 86_400))
        h.done = [day(-6), day(-4), day(-2)] // Mon 26, Wed 28, Fri 30 Oct
        p.habits = [h]
        XCTAssertEqual(p.xp(calendar: cal), 36)
    }

    func testArchivedHabitsDontVote() {
        var p = Planner()
        var h = habit(done: [0])
        h.archived = true
        p.habits = [h]
        XCTAssertTrue(p.votes(weekOf: now, calendar: cal).isEmpty)
    }
}

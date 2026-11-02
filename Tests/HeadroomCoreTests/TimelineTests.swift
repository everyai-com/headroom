import XCTest
@testable import HeadroomCore

/// The activity timeline: recording, classifying, adding up without double counting, Claude Code's logs,
/// time-target quests and seasons. Every file lives in a throwaway temp folder.
final class TimelineTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func testRecorderMergesTheSameWindowAndSplitsOnChange() {
        var r = TimelineRecorder()
        let xcode = ActivitySample(app: "com.apple.dt.Xcode", appName: "Xcode", title: "Headroom — Planner.swift")
        for i in 0..<6 { r.record(xcode, at: at(Double(i) * 10 / 60), interval: 10) }
        r.record(ActivitySample(app: "com.google.Chrome", appName: "Chrome", host: "youtube.com"), at: at(1), interval: 10)
        XCTAssertEqual(r.spans.count, 2)
        XCTAssertEqual(r.spans[0].seconds, 60, accuracy: 0.5)
        XCTAssertEqual(r.spans[1].start, r.spans[0].end, "a new span never reaches back over the last one")
        // Away for ten minutes: the same window again is a new span, not ten minutes of "Xcode".
        r.record(xcode, at: at(11), interval: 10)
        XCTAssertEqual(r.spans.count, 3)
    }

    func testRulesBeatBuiltInsAndProjectsComeFromTitles() {
        var settings = TimelineSettings()
        settings.rules = [ActivityRule(kind: .host, value: "linkedin.com", project: "Magicteams", area: "Marketing", category: .writing)]
        let c = Classifier(settings: settings, projects: ["Headroom", "flare-forge", "app"])
        let li = ActivitySpan(start: now, end: at(5), app: "com.google.Chrome", appName: "Chrome", host: "www.linkedin.com")
        XCTAssertEqual(c.classify(li), Classification(category: .writing, project: "Magicteams", area: "Marketing"))
        let yt = ActivitySpan(start: now, end: at(5), app: "com.google.Chrome", appName: "Chrome", host: "m.youtube.com")
        XCTAssertEqual(c.classify(yt).category, .entertainment)
        XCTAssertTrue(c.classify(yt).category.isDistraction)
        let xcode = ActivitySpan(start: now, end: at(5), app: "com.apple.dt.Xcode", appName: "Xcode", title: "flare-forge — main.swift")
        XCTAssertEqual(c.classify(xcode).project, "flare-forge")
        XCTAssertEqual(c.classify(xcode).category, .coding)
        let word = ActivitySpan(start: now, end: at(5), app: "com.apple.Notes", appName: "Notes", title: "headroomy ideas and an app list")
        XCTAssertNil(c.classify(word).project, "whole words only, and names under 4 letters never match")
    }

    func testOverlapsCountOnce() {
        let a = ActivitySpan(start: now, end: at(30), app: "com.apple.Terminal", appName: "Terminal")
        let b = ActivitySpan(start: at(20), end: at(50), app: ActivitySpan.claudeCode, appName: "Claude Code", project: "Headroom")
        let c = ActivitySpan(start: at(60), end: at(70), app: "com.apple.Terminal", appName: "Terminal")
        XCTAssertEqual(TimelineMath.covered([a, b, c]) / 60, 60, accuracy: 0.01)
    }

    func testExcludedAppsAndSitesAreNeverRecorded() {
        var s = TimelineSettings()
        s.excludedHosts = ["mybank.com"]
        XCTAssertTrue(s.excludes(ActivitySample(app: "com.1password.1password", appName: "1Password")))
        XCTAssertTrue(s.excludes(ActivitySample(app: "com.apple.Safari", appName: "Safari", host: "secure.mybank.com")))
        XCTAssertFalse(s.excludes(ActivitySample(app: "com.apple.Safari", appName: "Safari", host: "github.com")))
    }

    func testClaudeCodeLogsBecomeStretchesOfWork() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ type: String, _ minutes: Double) -> String {
            #"{"type":"\#(type)","timestamp":"\#(iso.string(from: at(minutes)))","cwd":"/Applications/Headroom","message":{"content":"…"}}"#
        }
        let log = [
            #"{"type":"queue-operation","timestamp":"\#(iso.string(from: at(-100)))"}"#,
            line("user", 0), line("assistant", 2), line("assistant", 4), // one stretch, 0–4
            line("user", 30), line("assistant", 31),                       // another, 30–31
        ].joined(separator: "\n")
        let spans = ClaudeCodeActivity.spans(fromLog: log, from: at(-60), to: at(600))
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].project, "Headroom")
        XCTAssertEqual(spans[0].seconds / 60, 4, accuracy: 0.01)
        XCTAssertEqual(spans[1].seconds / 60, 1, accuracy: 0.01, "a stretch is at least a minute")
    }

    func testWorktreesCountAsTheirRepository() {
        XCTAssertEqual(ClaudeCodeActivity.projectName("/Applications/Headroom/.claude/worktrees/frosty-einstein-dc8eed"), "Headroom")
        XCTAssertEqual(ClaudeCodeActivity.projectName("/Users/me/flare-forge"), "flare-forge")
    }

    func testStoreKeepsThirtyDaysAndForgets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineStore(dir: dir)
        let span = ActivitySpan(start: now, end: at(5), app: "a", appName: "A")
        for back in [0, 29, 31] { store.save([span], day: Planner.key(daysFrom: now, -back, calendar: cal)) }
        store.saveSettings(TimelineSettings())
        store.prune(now: now, calendar: cal)
        XCTAssertEqual(store.load(Planner.key(daysFrom: now, -29, calendar: cal)).count, 1)
        XCTAssertTrue(store.load(Planner.key(daysFrom: now, -31, calendar: cal)).isEmpty, "older than 30 days is deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rules.json").path), "rules are kept")
        store.forget(Planner.key(now, calendar: cal))
        XCTAssertTrue(store.load(Planner.key(now, calendar: cal)).isEmpty)
    }

    func testTimedHabitFillsFromTimelineAndFocusAndChecksItself() {
        var settings = TimelineSettings()
        settings.rules = [ActivityRule(kind: .host, value: "linkedin.com", project: "Magicteams")]
        let classifier = Classifier(settings: settings, projects: [])
        let spans = [
            ActivitySpan(start: now, end: at(90), app: "com.google.Chrome", appName: "Chrome", host: "linkedin.com"),
            ActivitySpan(start: at(90), end: at(120), app: "com.google.Chrome", appName: "Chrome", host: "youtube.com"),
        ]
        var p = Planner()
        let task = p.add("Post the launch thread", day: Planner.key(now, calendar: cal), project: "Magicteams", now: now, calendar: cal)
        var session = FocusSession(title: "Thread", start: at(60), taskID: task.id) // overlaps 30 min of LinkedIn
        session.end = at(150)
        var h = Habit(title: "Marketing", created: now.addingTimeInterval(-86_400))
        h.minutes = 120
        h.track = QuotaTrack(project: "Magicteams")
        p.habits = [h]
        let m = Quests.minutes(h.track!, spans: spans, sessions: [session], tasks: p.tasks, classifier: classifier, now: at(200))
        XCTAssertEqual(m, 150, "90 on LinkedIn + 60 more of focus; the overlap counts once; YouTube doesn't count")
        XCTAssertEqual(p.applyQuotas([h.id: m], on: now, calendar: cal).map(\.title), ["Marketing"])
        XCTAssertTrue(p.habits[0].isDone(now, calendar: cal))
        XCTAssertTrue(p.applyQuotas([h.id: m], on: now, calendar: cal).isEmpty, "checked once, celebrated once")
        var fresh = Planner()
        fresh.habits = [h]
        XCTAssertTrue(fresh.applyQuotas([h.id: 10], on: now, calendar: cal).isEmpty, "under target: not checked")
    }

    func testSeasonHoldsAtMostTwoSideQuests() {
        let s = Season(start: "2026-11-02", end: "2026-11-15", main: .init(project: "Magicteams", hoursPerWeek: 20),
                       sides: [.init(project: "Headroom", hoursPerWeek: 8), .init(project: "Flare", hoursPerWeek: 4), .init(project: "Video OS", hoursPerWeek: 2)])
        XCTAssertEqual(s.sides.map(\.project), ["Headroom", "Flare"], "focus is the point: two side quests at most")
        XCTAssertTrue(s.isActive(on: "2026-11-10"))
        XCTAssertFalse(s.isActive(on: "2026-11-16"))
        XCTAssertEqual(Planner.week(of: now, calendar: cal).first, "2026-11-02")
    }
}

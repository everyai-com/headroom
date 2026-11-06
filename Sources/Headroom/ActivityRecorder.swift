import SwiftUI
import AppKit
import ApplicationServices
import HeadroomCore

/// Records the timeline (Settings → Add-ons → Timeline, off by default; not in the App Store edition): every
/// 10 s, while you're at the keyboard, which app is in front — plus its window title once Accessibility is
/// allowed, and the site (never the full URL) for browsers you allow. Incognito windows and excluded apps and
/// sites are skipped. Everything stays in Application Support/Headroom/timeline for 30 days.
///
/// Never waits on a permission prompt: titles are read only when `AXIsProcessTrusted()` already says yes, and
/// a browser is asked for its tab only when macOS already allows it (checked without prompting); the prompts
/// come only from the buttons on the Timeline screen, on a background thread.
@MainActor
final class ActivityRecorder: ObservableObject {
    static let shared = ActivityRecorder()

    @Published private(set) var today: [ActivitySpan] = []
    @Published private(set) var claudeToday: [ActivitySpan] = []
    @Published var settings = TimelineSettings()
    @Published private(set) var projects: [String] = []
    @Published private(set) var titlesAllowed = AXIsProcessTrusted()
    @Published private(set) var browsersAllowed: [String: Bool] = [:]
    /// Minutes per project (lowercased) this week — the season's week while one runs, else Monday on. Refreshed every 10 minutes.
    @Published private(set) var weekProjectMinutes: [String: Int] = [:]
    private var lastWeek = Date.distantPast

    var isOn: Bool { UserDefaults.standard.bool(forKey: "timelineOn") && !Edition.appStore }
    var available: Bool { !Edition.appStore }

    static let interval: TimeInterval = 10
    /// Away from the keyboard this long and nothing is recorded — longer for video and calls, which you watch.
    static let idleLimit: TimeInterval = 180
    static let watchingIdleLimit: TimeInterval = 30 * 60

    private let store = TimelineStore()
    private var recorder = TimelineRecorder()
    private var day = Planner.key(.now)
    private var timer: Timer?
    private var lastSave = Date.distantPast
    private var lastClaude = Date.distantPast
    private var settingsDate: Date?
    private let browserQueue = DispatchQueue(label: "headroom.timeline.browser")
    private var pendingHost: (app: String, host: String?, at: Date)?

    var classifier: Classifier { Classifier(settings: settings, projects: projects) }
    /// Mac spans and Claude Code's, together.
    var allToday: [ActivitySpan] { today + claudeToday }

    private init() {
        if AppModel.demoMode {
            today = TimelineDemo.spans()
            claudeToday = TimelineDemo.claude()
            projects = ["Headroom", "magicteams", "flare-forge"]
            settings.rules = TimelineDemo.rules
            weekProjectMinutes = ["magicteams": 9 * 60 + 40, "headroom": 7 * 60 + 15, "flare-forge": 2 * 60 + 5, "video os": 3 * 60 + 30]
            return
        }
        reloadSettings()
        recorder = TimelineRecorder(spans: store.load(day))
        today = recorder.spans
        Task.detached(priority: .utility) {
            let paths = ClaudeCodeActivity.projectPaths()
            await MainActor.run { self.projects = Array(Set(paths.map(ClaudeCodeActivity.projectName))).sorted() }
        }
        refreshClaude(force: true)
        update()
    }

    /// Starts or stops sampling to match the setting (called when it changes and each tick).
    func update() {
        guard !AppModel.demoMode else { return }
        titlesAllowed = AXIsProcessTrusted()
        if store.settingsDate() != settingsDate { reloadSettings() } // taught from the CLI or an agent
        if isOn, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
                Task { @MainActor in ActivityRecorder.shared.sample() }
            }
            store.prune()
        } else if !isOn, let t = timer {
            t.invalidate()
            timer = nil
            save()
        }
        refreshClaude()
    }

    func setOn(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "timelineOn")
        update()
    }

    // MARK: Sampling

    private func sample() {
        let now = Date()
        let key = Planner.key(now)
        if key != day { save(); day = key; recorder = TimelineRecorder(); today = [] }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              !["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"].contains(bundle) else { return }
        let name = app.localizedName ?? bundle
        let isBrowser = Classifier.browsers.contains(bundle)
        var sample = ActivitySample(app: bundle, appName: name)
        if isBrowser {
            sample.host = currentHost(bundle)
            if sample.host == "" { return } // an incognito window: not recorded at all
        } else if titlesAllowed {
            sample.title = Self.windowTitle(pid: app.processIdentifier)
        }
        guard !settings.excludes(sample) else { return }
        let category = classifier.classify(ActivitySpan(start: now, end: now, app: bundle, appName: name, title: sample.title, host: sample.host)).category
        let limit = category == .entertainment || category == .meetings ? Self.watchingIdleLimit : Self.idleLimit
        guard Self.idleSeconds() < limit else { return }
        recorder.record(sample, at: now, interval: Self.interval)
        today = recorder.spans
        if sample.host != nil { // the app switch already covered apps; the timeline knows the site
            FocusShield.shared.check(ActivitySpan(start: now, end: now, app: bundle, appName: name, host: sample.host))
        }
        if now.timeIntervalSince(lastSave) > 60 { save() }
        refreshClaude()
    }

    func save() {
        guard !AppModel.demoMode else { return }
        store.save(recorder.spans, day: day)
        lastSave = .now
    }

    /// "Forget today": the day's file and what's on screen go; the recorder keeps going from now.
    func forgetToday() {
        store.forget(day)
        recorder = TimelineRecorder()
        today = []
    }

    func saveSettings() {
        guard !AppModel.demoMode else { return }
        store.saveSettings(settings)
        settingsDate = store.settingsDate()
    }

    private func reloadSettings() {
        settings = store.loadSettings()
        settingsDate = store.settingsDate()
        refreshWeek(force: true)
    }

    /// Teach it: this app / site / title belongs to a project, an area or a category from now on (and for today).
    func assign(_ kind: ActivityRule.Kind, _ value: String, project: String? = nil, area: String? = nil, category: ActivityCategory? = nil) {
        if let i = settings.rules.firstIndex(where: { $0.kind == kind && $0.value.caseInsensitiveCompare(value) == .orderedSame }) {
            if let project { settings.rules[i].project = project.isEmpty ? nil : project }
            if let area { settings.rules[i].area = area.isEmpty ? nil : area }
            if let category { settings.rules[i].category = category }
        } else {
            settings.rules.append(ActivityRule(kind: kind, value: value, project: project?.nilIfEmpty, area: area?.nilIfEmpty, category: category))
        }
        saveSettings()
    }

    func exclude(app: String? = nil, host: String? = nil) {
        if let app { settings.excludedApps.insert(app) }
        if let host { settings.excludedHosts.insert(host) }
        saveSettings()
        // Take it out of today too.
        recorder = TimelineRecorder(spans: recorder.spans.filter { s in s.app != app && (host == nil || s.host != host) })
        today = recorder.spans
        save()
    }

    /// This week's minutes per project, from the saved days, today, and Claude Code's logs (in the background).
    func refreshWeek(force: Bool = false) {
        guard !AppModel.demoMode, force || Date().timeIntervalSince(lastWeek) > 10 * 60 else { return }
        lastWeek = .now
        let today = day, todaySpans = allToday, classifier = classifier, store = store
        // During a season its own weeks count (7 days from its first day), so the weekly grid lines up.
        let season = PlannerStore.load().season
        let week = season.flatMap { s in s.weekIndex(on: today).map { s.weekDays($0) } } ?? Planner.week(of: .now)
        Task.detached(priority: .utility) {
            var spans = todaySpans
            for d in week where d < today {
                spans += store.load(d) + ClaudeCodeActivity.spans(on: d)
            }
            let minutes = Quests.minutesByProject(spans: spans, classifier: classifier)
            await MainActor.run { ActivityRecorder.shared.weekProjectMinutes = minutes }
        }
    }

    private func refreshClaude(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastClaude) > 5 * 60 else { return }
        lastClaude = .now
        let key = day
        Task.detached(priority: .utility) {
            let spans = ClaudeCodeActivity.spans(on: key)
            await MainActor.run {
                ActivityRecorder.shared.claudeToday = spans
                ActivityRecorder.shared.refreshWeek()
            }
        }
    }

    // MARK: What macOS lets us read

    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    static func windowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return (title as? String)?.nilIfEmpty
    }

    /// The front tab's site, from the last answer (the question runs on a background queue so a slow browser
    /// never holds up the app). "" means an incognito window.
    private func currentHost(_ bundle: String) -> String? {
        let cached = pendingHost.flatMap { $0.app == bundle && Date().timeIntervalSince($0.at) < 30 ? $0.host : nil }
        guard browsersAllowed[bundle] == true, let script = Self.tabScript(bundle) else {
            checkBrowser(bundle)
            return nil
        }
        browserQueue.async {
            var error: NSDictionary?
            let url = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue
            let host: String? = url == "incognito" ? "" : url.flatMap { URL(string: $0)?.host?.lowercased() }
            Task { @MainActor in ActivityRecorder.shared.pendingHost = (bundle, host, .now) }
        }
        return cached
    }

    static func tabScript(_ bundle: String) -> String? {
        switch bundle {
        case "com.apple.Safari":
            return #"tell application id "com.apple.Safari" to return URL of current tab of front window"#
        case "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser":
            return """
            tell application id "\(bundle)"
                try
                    if mode of front window is "incognito" then return "incognito"
                end try
                return URL of active tab of front window
            end tell
            """
        default:
            return nil // Firefox and others don't say which tab is open
        }
    }

    /// Whether macOS already lets Headroom ask this browser (no prompt).
    private func checkBrowser(_ bundle: String) {
        guard browsersAllowed[bundle] == nil else { return }
        browsersAllowed[bundle] = false
        browserQueue.async {
            let allowed = Self.automationAllowed(bundle, ask: false)
            Task { @MainActor in ActivityRecorder.shared.browsersAllowed[bundle] = allowed }
        }
    }

    static func automationAllowed(_ bundle: String, ask: Bool) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let desc = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask) == noErr
    }

    /// From the Timeline screen's button: macOS shows its prompt for each running browser (on a background thread).
    func askBrowsers() {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { Self.tabScript($0) != nil }
        browserQueue.async {
            var result: [String: Bool] = [:]
            for b in Set(running) { result[b] = Self.automationAllowed(b, ask: true) }
            Task { @MainActor in ActivityRecorder.shared.browsersAllowed.merge(result) { $1 } }
        }
    }

    /// From the Timeline screen's button: macOS's Accessibility prompt (it opens System Settings).
    func askTitles() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        titlesAllowed = AXIsProcessTrustedWithOptions(options)
    }
}

/// A day of made-up activity for renders (`--demo`): no real apps, sites or titles are ever drawn.
enum TimelineDemo {
    static let rules = [
        ActivityRule(kind: .host, value: "linkedin.com", project: "magicteams", area: "Marketing", category: .writing),
        ActivityRule(kind: .host, value: "x.com", project: "magicteams", area: "Marketing"),
    ]

    static func spans(now: Date = .now) -> [ActivitySpan] {
        let start = Calendar.current.date(bySettingHour: 8, minute: 40, second: 0, of: now) ?? now
        var t = start
        var out: [ActivitySpan] = []
        func add(_ minutes: Double, _ app: String, _ name: String, title: String? = nil, host: String? = nil) {
            out.append(ActivitySpan(start: t, end: t.addingTimeInterval(minutes * 60), app: app, appName: name, title: title, host: host))
            t = t.addingTimeInterval(minutes * 60 + 60)
        }
        add(18, "com.apple.mail", "Mail", title: "Inbox")
        add(52, "com.apple.dt.Xcode", "Xcode", title: "Headroom — TodayView.swift")
        add(35, "com.apple.Terminal", "Terminal", title: "Headroom — claude")
        add(24, "com.google.Chrome", "Chrome", host: "youtube.com")
        add(46, "com.google.Chrome", "Chrome", host: "linkedin.com")
        add(22, "com.google.Chrome", "Chrome", host: "x.com")
        add(30, "us.zoom.xos", "zoom.us", title: "Zoom Meeting")
        add(40, "com.figma.Desktop", "Figma", title: "magicteams — launch visuals")
        add(15, "com.google.Chrome", "Chrome", host: "instagram.com")
        add(38, "com.microsoft.VSCode", "Code", title: "flare-forge — runner.ts")
        return out.filter { $0.end <= now.addingTimeInterval(3600 * 12) }
    }

    static func claude(now: Date = .now) -> [ActivitySpan] {
        let s = Calendar.current.date(bySettingHour: 9, minute: 35, second: 0, of: now) ?? now
        return [ActivitySpan(start: s, end: s.addingTimeInterval(70 * 60), app: ActivitySpan.claudeCode, appName: "Claude Code",
                             title: "/Applications/Headroom", project: "Headroom")]
    }
}

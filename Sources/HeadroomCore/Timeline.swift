import Foundation

// Where your day went: what app (and site) was in front while you were at the keyboard, and Claude Code's
// own session logs, kept on this Mac only — one JSON file a day in Application Support/Headroom/timeline,
// deleted after 30 days. Nothing here is ever sent anywhere. The app samples; this file stores, classifies
// and adds up (without counting overlapping time twice).

/// A stretch of time in one app / site / window.
public struct ActivitySpan: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id = UUID()
    public var start: Date
    public var end: Date
    /// Bundle ID, or `ActivitySpan.claudeCode` for time read from Claude Code's logs.
    public var app: String
    public var appName: String
    /// The window title (needs Accessibility), for non-browser apps only.
    public var title: String?
    /// The site, for browsers (needs Automation); never the full URL.
    public var host: String?
    /// Known at record time for Claude Code (its folder); otherwise worked out by `Classifier`.
    public var project: String?

    public static let claudeCode = "claude-code"

    public init(start: Date, end: Date, app: String, appName: String, title: String? = nil, host: String? = nil, project: String? = nil) {
        self.start = start; self.end = end; self.app = app; self.appName = appName; self.title = title; self.host = host; self.project = project
    }

    public var seconds: TimeInterval { max(0, end.timeIntervalSince(start)) }
    /// What makes two samples "the same thing".
    var key: String { [app, title ?? "", host ?? ""].joined(separator: "\u{1}") }
}

/// One look at the front window.
public struct ActivitySample: Sendable, Equatable {
    public var app: String
    public var appName: String
    public var title: String?
    public var host: String?
    public init(app: String, appName: String, title: String? = nil, host: String? = nil) {
        self.app = app; self.appName = appName; self.title = title; self.host = host
    }
}

public enum ActivityCategory: String, Codable, Sendable, CaseIterable {
    case coding, writing, design, communication, meetings, learning, social, entertainment, browsing, other

    public var title: String {
        switch self {
        case .coding: "Coding"
        case .writing: "Writing"
        case .design: "Design"
        case .communication: "Messages & mail"
        case .meetings: "Meetings"
        case .learning: "Learning"
        case .social: "Social"
        case .entertainment: "Entertainment"
        case .browsing: "Browsing"
        case .other: "Other"
        }
    }

    /// Time that's usually not what you meant to do (the nudges look at this).
    public var isDistraction: Bool { self == .social || self == .entertainment }
}

/// "This app / site / title is that project or area" — the rules you teach it from the Timeline screen.
public struct ActivityRule: Codable, Sendable, Equatable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case app, host, title, project }
    public var id = UUID()
    public var kind: Kind
    /// Bundle ID, host ("linkedin.com" also matches "www.linkedin.com"), words in the window title, or a project
    /// (matched against the project the span ends up with, so "svikarr folder" can count as Svikarr · Marketing).
    public var value: String
    public var project: String?
    public var area: String?
    public var category: ActivityCategory?

    public init(kind: Kind, value: String, project: String? = nil, area: String? = nil, category: ActivityCategory? = nil) {
        self.kind = kind; self.value = value; self.project = project; self.area = area; self.category = category
    }

    func matches(_ s: ActivitySpan) -> Bool {
        switch kind {
        case .app: return s.app == value
        case .host:
            guard let h = s.host?.lowercased() else { return false }
            let v = value.lowercased()
            return h == v || h.hasSuffix("." + v)
        case .title:
            guard let t = s.title?.lowercased(), !value.isEmpty else { return false }
            return t.contains(value.lowercased())
        case .project:
            return s.project?.caseInsensitiveCompare(value) == .orderedSame
        }
    }
}

/// Your rules, what never to record, and the projects Headroom knows by name. Kept in timeline/rules.json.
public struct TimelineSettings: Codable, Sendable, Equatable {
    public var rules: [ActivityRule] = []
    /// Never recorded at all (password managers by default).
    public var excludedApps: Set<String> = TimelineSettings.defaultExcludedApps
    public var excludedHosts: Set<String> = []

    public static let defaultExcludedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
    ]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([ActivityRule].self, forKey: .rules) ?? []
        excludedApps = try c.decodeIfPresent(Set<String>.self, forKey: .excludedApps) ?? Self.defaultExcludedApps
        excludedHosts = try c.decodeIfPresent(Set<String>.self, forKey: .excludedHosts) ?? []
    }

    public func excludes(_ sample: ActivitySample) -> Bool {
        if excludedApps.contains(sample.app) { return true }
        guard let h = sample.host?.lowercased() else { return false }
        return excludedHosts.contains { h == $0.lowercased() || h.hasSuffix("." + $0.lowercased()) }
    }
}

/// What a span was: its category, and the project and area it counts toward.
public struct Classification: Sendable, Equatable {
    public var category: ActivityCategory
    public var project: String?
    public var area: String?

    public init(category: ActivityCategory, project: String? = nil, area: String? = nil) {
        self.category = category; self.project = project; self.area = area
    }
}

public struct Classifier: Sendable {
    public var settings: TimelineSettings
    /// Project names to spot in window titles (folders of your repositories and Claude Code projects).
    public var projects: [String]

    public init(settings: TimelineSettings, projects: [String]) {
        self.settings = settings
        // Longest first, so "headroom-site" wins over "headroom"; short names would match too much.
        self.projects = Array(Set(projects.filter { $0.count >= 4 })).sorted { $0.count > $1.count }
    }

    public func classify(_ s: ActivitySpan) -> Classification {
        var out = Classification(category: Self.builtInCategory(s), project: s.project, area: nil)
        // Your rules win; the most specific kind (title, then host, then app) is applied last so it overrides.
        for kind in [ActivityRule.Kind.app, .host, .title] {
            for r in settings.rules where r.kind == kind && r.matches(s) {
                if let c = r.category { out.category = c }
                if let p = r.project { out.project = p }
                if let a = r.area { out.area = a }
            }
        }
        if out.project == nil, let title = s.title?.lowercased() {
            out.project = projects.first { name in Self.containsWord(title, name.lowercased()) }
        }
        // Project rules last: they see the project the span ended up with, however it got there.
        var resolved = s
        resolved.project = out.project
        for r in settings.rules where r.kind == .project && r.matches(resolved) {
            if let c = r.category { out.category = c }
            if let p = r.project { out.project = p }
            if let a = r.area { out.area = a }
        }
        return out
    }

    static func containsWord(_ text: String, _ word: String) -> Bool {
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: word, range: search) {
            let before = r.lowerBound == text.startIndex ? nil : text[text.index(before: r.lowerBound)]
            let after = r.upperBound == text.endIndex ? nil : text[r.upperBound]
            func edge(_ c: Character?) -> Bool { c.map { !($0.isLetter || $0.isNumber) } ?? true }
            if edge(before) && edge(after) { return true }
            search = r.upperBound..<text.endIndex
        }
        return false
    }

    static let appCategories: [String: ActivityCategory] = [
        "com.apple.dt.Xcode": .coding, "com.apple.Terminal": .coding, "com.googlecode.iterm2": .coding, "com.microsoft.VSCode": .coding,
        "com.todesktop.230313mzl4w4u92": .coding, "dev.zed.Zed": .coding, "com.github.GitHubClient": .coding, "dev.warp.Warp-Stable": .coding,
        "com.mitchellh.ghostty": .coding, "com.anthropic.claudefordesktop": .coding, "com.openai.codex": .coding, "com.jetbrains.intellij": .coding,
        "com.apple.Notes": .writing, "com.apple.iWork.Pages": .writing, "md.obsidian": .writing, "notion.id": .writing,
        "com.microsoft.Word": .writing, "pro.writer.mac": .writing, "com.ulyssesapp.mac": .writing, "com.apple.TextEdit": .writing,
        "com.figma.Desktop": .design, "com.bohemiancoding.sketch3": .design, "com.adobe.Photoshop": .design, "com.canva.CanvaDesktop": .design,
        "com.apple.FinalCut": .design, "com.apple.iMovieApp": .design,
        "com.apple.mail": .communication, "com.tinyspeck.slackmacgap": .communication, "net.whatsapp.WhatsApp": .communication,
        "ru.keepcoder.Telegram": .communication, "com.apple.MobileSMS": .communication, "com.microsoft.Outlook": .communication,
        "com.hnc.Discord": .social,
        "us.zoom.xos": .meetings, "com.microsoft.teams2": .meetings, "com.apple.FaceTime": .meetings, "com.cisco.webexmeetingsapp": .meetings,
        "com.apple.TV": .entertainment, "com.spotify.client": .entertainment, "com.netflix.Netflix": .entertainment, "com.apple.Music": .entertainment,
    ]

    static let hostCategories: [String: ActivityCategory] = [
        "github.com": .coding, "gitlab.com": .coding, "stackoverflow.com": .coding, "developer.apple.com": .coding,
        "dash.cloudflare.com": .coding, "vercel.com": .coding, "localhost": .coding, "claude.ai": .coding, "chatgpt.com": .coding,
        "docs.google.com": .writing, "notion.so": .writing, "medium.com": .writing, "substack.com": .writing,
        "figma.com": .design, "canva.com": .design,
        "mail.google.com": .communication, "outlook.live.com": .communication, "outlook.office.com": .communication,
        "web.whatsapp.com": .communication, "app.slack.com": .communication,
        "meet.google.com": .meetings, "zoom.us": .meetings, "teams.microsoft.com": .meetings,
        "coursera.org": .learning, "udemy.com": .learning, "wikipedia.org": .learning, "arxiv.org": .learning,
        "x.com": .social, "twitter.com": .social, "instagram.com": .social, "facebook.com": .social, "linkedin.com": .social,
        "reddit.com": .social, "tiktok.com": .social, "threads.net": .social,
        "youtube.com": .entertainment, "netflix.com": .entertainment, "primevideo.com": .entertainment, "hotstar.com": .entertainment,
        "twitch.tv": .entertainment, "spotify.com": .entertainment,
    ]

    public static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "app.zen-browser.zen",
    ]

    static func builtInCategory(_ s: ActivitySpan) -> ActivityCategory {
        if s.app == ActivitySpan.claudeCode { return .coding }
        if let host = s.host?.lowercased() {
            if let c = hostCategories.first(where: { host == $0.key || host.hasSuffix("." + $0.key) })?.value { return c }
            return .browsing
        }
        return appCategories[s.app] ?? .other
    }
}

/// Adds up time. Overlaps (a Claude Code session while the terminal was in front) count once.
public enum TimelineMath {
    /// Seconds covered by the spans, merging overlaps.
    public static func covered(_ spans: [ActivitySpan]) -> TimeInterval {
        let sorted = spans.map { ($0.start, $0.end) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for (s, e) in sorted {
            if let c = current, s <= c.1 { current = (c.0, max(c.1, e)) } else {
                if let c = current { total += c.1.timeIntervalSince(c.0) }
                current = (s, e)
            }
        }
        if let c = current { total += c.1.timeIntervalSince(c.0) }
        return total
    }

    public struct Total: Sendable, Equatable, Identifiable {
        public var name: String
        public var seconds: TimeInterval
        public var id: String { name }
    }

    /// Time per group (category, project, app…), largest first.
    public static func totals(_ spans: [ActivitySpan], by group: (ActivitySpan) -> String?) -> [Total] {
        Dictionary(grouping: spans.compactMap { s in group(s).map { ($0, s) } }, by: \.0)
            .map { Total(name: $0.key, seconds: covered($0.value.map(\.1))) }
            .sorted { $0.seconds > $1.seconds }
    }
}

/// Merges samples into spans: the same app/title/site seen again within `gap` extends the span.
public struct TimelineRecorder: Sendable {
    public private(set) var spans: [ActivitySpan]
    public init(spans: [ActivitySpan] = []) { self.spans = spans }

    public mutating func record(_ sample: ActivitySample, at now: Date, interval: TimeInterval) {
        var span = ActivitySpan(start: now.addingTimeInterval(-interval), end: now, app: sample.app, appName: sample.appName,
                                title: sample.title, host: sample.host)
        if let last = spans.last, last.key == span.key, now.timeIntervalSince(last.end) <= interval * 2 {
            spans[spans.count - 1].end = now
            return
        }
        // Don't reach back over the previous span (or before a gap: a fresh look counts one interval).
        if let last = spans.last, span.start < last.end { span.start = last.end }
        spans.append(span)
    }
}

/// timeline/<day>.json, plus rules.json. Days older than `keepDays` are deleted.
public struct TimelineStore: Sendable {
    public var dir: URL
    public static let keepDays = 30

    public init(dir: URL = HeadroomPaths.support.appendingPathComponent("timeline")) { self.dir = dir }

    func url(_ day: String) -> URL { dir.appendingPathComponent("\(day).json") }

    public func load(_ day: String) -> [ActivitySpan] {
        guard let data = try? Data(contentsOf: url(day)) else { return [] }
        return (try? Self.decoder.decode([ActivitySpan].self, from: data)) ?? []
    }

    public func save(_ spans: [ActivitySpan], day: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(spans) { try? data.write(to: url(day), options: .atomic) }
    }

    /// "Forget today" (or any day): the file goes, nothing else.
    public func forget(_ day: String) { try? FileManager.default.removeItem(at: url(day)) }

    public func prune(now: Date = .now, calendar: Calendar = .current) {
        let oldest = Planner.key(daysFrom: now, -Self.keepDays, calendar: calendar)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasSuffix(".json") && f != "rules.json" {
            let day = String(f.dropLast(5))
            if Planner.date(day, calendar: calendar) != nil, day < oldest { try? FileManager.default.removeItem(at: url(day)) }
        }
    }

    public func loadSettings() -> TimelineSettings {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("rules.json")) else { return TimelineSettings() }
        return (try? Self.decoder.decode(TimelineSettings.self, from: data)) ?? TimelineSettings()
    }

    /// When the rules last changed on disk — the app reloads them, so the CLI and agents can teach it too.
    public func settingsDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("rules.json").path))?[.modificationDate] as? Date
    }

    public func saveSettings(_ s: TimelineSettings) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(s) { try? data.write(to: dir.appendingPathComponent("rules.json"), options: .atomic) }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Claude Code's own logs (~/.claude/projects/<folder>/*.jsonl): every message has a timestamp and the folder it
/// ran in. Messages less than `gap` apart are one stretch of work on that project. Read-only.
public enum ClaudeCodeActivity {
    public static let gap: TimeInterval = 5 * 60

    public static func spans(on day: String, home: String = HeadroomPaths.home, calendar: Calendar = .current) -> [ActivitySpan] {
        let root = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        guard let start = Planner.date(day, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: start),
              let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [ActivitySpan] = []
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                // Only files written on or after that day can hold its messages.
                guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m >= start,
                      let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                out += spans(fromLog: text, from: start, to: end)
            }
        }
        return out
    }

    /// The stretches in one log between two dates.
    public static func spans(fromLog text: String, from start: Date, to end: Date) -> [ActivitySpan] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var stamps: [Date] = []
        var cwd: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // A user or assistant turn: skip bookkeeping lines (queue operations, snapshots).
            guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\"") else { continue }
            if let t = value(of: "timestamp", in: line), let d = iso.date(from: t), d >= start, d < end { stamps.append(d) }
            if cwd == nil { cwd = value(of: "cwd", in: line) }
        }
        guard !stamps.isEmpty else { return [] }
        let project = cwd.map(projectName)
        stamps.sort()
        var out: [ActivitySpan] = []
        var s = stamps[0], e = stamps[0]
        func flush() {
            // A lone message still means a minute of attention.
            out.append(ActivitySpan(start: s, end: max(e, s.addingTimeInterval(60)), app: ActivitySpan.claudeCode, appName: "Claude Code",
                                    title: cwd, project: project))
        }
        for d in stamps.dropFirst() {
            if d.timeIntervalSince(e) <= gap { e = d } else { flush(); s = d; e = d }
        }
        flush()
        return out
    }

    /// The project a folder belongs to: a worktree (".../repo/.claude/worktrees/frosty-einstein") counts as its repository.
    /// Trimmed: folders like "connector saas " would otherwise never match a project typed by hand.
    public static func projectName(_ cwd: String) -> String {
        var root = cwd
        for marker in ["/.claude/worktrees/", "/.worktrees/", "/worktrees/"] {
            if let r = cwd.range(of: marker) { root = String(cwd[..<r.lowerBound]); break }
        }
        return URL(fileURLWithPath: root).lastPathComponent.trimmingCharacters(in: .whitespaces)
    }

    /// `"key":"value"` from a JSON line without parsing it all (lines can be megabytes).
    static func value(of key: String, in line: Substring) -> String? {
        guard let r = line.range(of: "\"\(key)\":\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<close])
    }

    /// Project folders Claude Code has run in (their names, for spotting projects in window titles). The folder
    /// names flatten paths with dashes ("flare-forge" and "flare/forge" look alike), so the real `cwd` is read from
    /// the start of the newest log in each.
    public static func projectPaths(home: String = HeadroomPaths.home) -> [String] {
        let root = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out = Set<String>()
        for dir in dirs {
            let logs = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            guard let newest = logs.max(by: { modified($0) < modified($1) }),
                  let handle = try? FileHandle(forReadingFrom: newest) else { continue }
            let head = String(decoding: handle.readData(ofLength: 256 * 1024), as: UTF8.self)
            try? handle.close()
            if let cwd = head.split(separator: "\n").lazy.compactMap({ value(of: "cwd", in: $0) }).first,
               !cwd.contains("/.claude/worktrees/"), cwd != home {
                out.insert(cwd)
            }
        }
        return out.sorted()
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

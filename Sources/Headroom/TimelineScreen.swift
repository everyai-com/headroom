import SwiftUI
import HeadroomCore

extension ActivityCategory {
    var color: Color {
        switch self {
        case .coding: Color(hex: 0x5B8DEF)
        case .writing: Color(hex: 0x9B7BEA)
        case .design: Color(hex: 0xE36FB2)
        case .communication: Color(hex: 0x4FB6C9)
        case .meetings: Color(hex: 0x56C08C)
        case .learning: Color(hex: 0xD9B44A)
        case .social: Color(hex: 0xF08A4B)
        case .entertainment: Color(hex: 0xE5534B)
        case .browsing: Color(hex: 0x8A94A6)
        case .other: Color(hex: 0x6B7280)
        }
    }
}

enum Minutes {
    /// "4 h 05 m", "45 m".
    static func text(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60)) m" : "\(m) m"
    }
}

/// Where your day went: the day as a strip, time by category and project, and every app and site — each one
/// a right-click away from being taught to a project, an area or "never record this".
struct TimelineScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var timeline = ActivityRecorder.shared
    @Environment(\.snapshotMode) private var snapshot
    @State private var assigning: AssignTarget?

    var spans: [ActivitySpan] { timeline.allToday }

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 14) {
                if !timeline.isOn && !AppModel.demoMode { intro } else {
                    dayCard
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 14) {
                            byCategory
                            byProject
                        }
                        appsAndSites.frame(width: 420)
                    }
                    privacy
                }
            }
        }
        .sheet(item: $assigning) { target in AssignSheet(target: target) }
    }

    // MARK: Off

    var intro: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("See where your day goes", systemImage: "chart.bar.xaxis").font(.system(size: 17, weight: .bold))
                Text("Headroom notes which app is in front while you're at the keyboard — and, if you allow it, the window's title and the site in your browser — so your quests fill themselves (“Marketing · 4 h”), focus time counts without a timer, and the morning plan knows what really happened yesterday.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    bullet("lock", "Stays on this Mac. Nothing is uploaded, ever.")
                    bullet("calendar.badge.clock", "Kept 30 days, then deleted. “Forget today” any time.")
                    bullet("eye.slash", "Never records password managers, incognito windows, or apps and sites you exclude.")
                    bullet("link", "Sites only, never full addresses. No screenshots, no keystrokes.")
                }
                Button("Turn On Timeline") { timeline.setOn(true) }.buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
    }

    func bullet(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
    }

    // MARK: The day

    var dayCard: some View {
        let total = TimelineMath.covered(spans)
        let c = timeline.classifier
        let distracted = TimelineMath.covered(spans.filter { c.classify($0).category.isDistraction })
        let focus = TimelineMath.covered(spans.filter { [.coding, .writing, .design, .learning].contains(c.classify($0).category) })
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    stat(Minutes.text(total), "at the Mac")
                    stat(Minutes.text(focus), "making things", Theme.safe)
                    stat(Minutes.text(distracted), "social & entertainment", distracted > 3600 ? Theme.critical : Theme.textSecondary)
                    Spacer()
                }
                DayStrip(spans: spans, classifier: c).frame(height: 34)
                HStack(spacing: 12) {
                    ForEach(ActivityCategory.allCases.filter { cat in spans.contains { c.classify($0).category == cat } }, id: \.self) { cat in
                        HStack(spacing: 5) {
                            Circle().fill(cat.color).frame(width: 8, height: 8)
                            Text(cat.title).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    func stat(_ value: String, _ label: String, _ tint: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.number(22, weight: .bold)).foregroundStyle(tint)
            Text(label).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
        }
    }

    var byCategory: some View {
        let c = timeline.classifier
        let totals = TimelineMath.totals(spans) { c.classify($0).category.rawValue }
        let top = totals.first?.seconds ?? 1
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "By kind of work", trailing: nil)
                ForEach(totals) { t in
                    let cat = ActivityCategory(rawValue: t.name) ?? .other
                    bar(cat.title, t.seconds, top: top, color: cat.color)
                }
            }
        }
    }

    var byProject: some View {
        let c = timeline.classifier
        let totals = TimelineMath.totals(spans) { c.classify($0).project }
        let top = totals.first?.seconds ?? 1
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "By project", trailing: nil)
                if totals.isEmpty {
                    Text("Projects show up when a window title names one (your repositories and Claude Code projects), or when you assign an app or site to one.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(totals) { t in bar(t.name, t.seconds, top: top, color: Theme.accent) }
            }
        }
    }

    func bar(_ name: String, _ seconds: TimeInterval, top: TimeInterval, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Spacer()
                Text(Minutes.text(seconds)).font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }
            SegmentedBar(segments: [.init(id: name, value: seconds, color: color)], total: max(top, 1), height: 6)
        }
    }

    // MARK: Apps and sites

    struct Row: Identifiable {
        var kind: ActivityRule.Kind
        var value: String
        var name: String
        var seconds: TimeInterval
        var classification: Classification
        var id: String { kind.rawValue + value }
    }

    var rows: [Row] {
        let c = timeline.classifier
        let groups = Dictionary(grouping: spans) { s -> String in s.host.map { "host:" + $0 } ?? "app:" + s.app }
        return groups.compactMap { key, list in
            guard let first = list.first else { return nil }
            let isHost = key.hasPrefix("host:")
            return Row(kind: isHost ? .host : .app, value: isHost ? (first.host ?? "") : first.app,
                       name: isHost ? (first.host ?? "") : first.appName, seconds: TimelineMath.covered(list), classification: c.classify(first))
        }
        .sorted { $0.seconds > $1.seconds }
    }

    var appsAndSites: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Apps & sites", trailing: "right-click to teach")
                ForEach(rows.prefix(snapshot ? 10 : 40)) { r in
                    HStack(spacing: 8) {
                        Circle().fill(r.classification.category.color).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            let detail = [r.classification.project, r.classification.area, r.classification.category.title].compactMap { $0 }
                            Text(detail.joined(separator: " · ")).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                        Spacer()
                        Text(Minutes.text(r.seconds)).font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                    .contextMenu { menu(r) }
                }
            }
        }
    }

    @ViewBuilder func menu(_ r: Row) -> some View {
        let projects = Array(Set(timeline.projects + timeline.settings.rules.compactMap(\.project) + model.planner.tasks.compactMap(\.project))).sorted()
        Menu("Project") {
            ForEach(projects, id: \.self) { p in Button(p) { timeline.assign(r.kind, r.value, project: p) } }
            Divider()
            Button("New Project…") { assigning = AssignTarget(kind: r.kind, value: r.value, name: r.name, field: .project) }
            if r.classification.project != nil { Button("None") { timeline.assign(r.kind, r.value, project: "") } }
        }
        Menu("Area") {
            ForEach(model.planner.areas().map(\.name), id: \.self) { a in Button(a) { timeline.assign(r.kind, r.value, area: a) } }
            Divider()
            Button("New Area…") { assigning = AssignTarget(kind: r.kind, value: r.value, name: r.name, field: .area) }
        }
        Menu("Kind of Work") {
            ForEach(ActivityCategory.allCases, id: \.self) { c in Button(c.title) { timeline.assign(r.kind, r.value, category: c) } }
        }
        Divider()
        Button("Never Record \(r.name)") { timeline.exclude(app: r.kind == .app ? r.value : nil, host: r.kind == .host ? r.value : nil) }
    }

    // MARK: Privacy & permissions

    var privacy: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "What it can see", trailing: nil)
                permission("Window titles", detail: "Lets it tell projects apart (\"Headroom — TodayView.swift\").", ok: timeline.titlesAllowed,
                           action: "Allow…") { timeline.askTitles() }
                let browsers = timeline.browsersAllowed.filter { ActivityRecorder.tabScript($0.key) != nil }
                permission("Sites in your browser", detail: browsers.isEmpty ? "Safari, Chrome, Arc, Brave, Edge. Incognito windows are skipped; Safari doesn't say which windows are private, so exclude sites you never want noted."
                           : browsers.map { "\(Self.browserName($0.key)) \($0.value ? "✓" : "—")" }.sorted().joined(separator: "  "),
                           ok: !browsers.isEmpty && browsers.values.allSatisfy { $0 }, action: "Allow…") { timeline.askBrowsers() }
                HStack {
                    Text("Recording on this Mac only · 30 days").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if !snapshot {
                        Button("Forget Today") { timeline.forgetToday() }.buttonStyle(GhostButtonStyle())
                        Button("Turn Off") { timeline.setOn(false) }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
    }

    func permission(_ title: String, detail: String, ok: Bool, action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Theme.safe : Theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !ok && !snapshot { Button(action, action: perform).buttonStyle(GhostButtonStyle()) }
        }
    }

    static func browserName(_ bundle: String) -> String {
        ["com.apple.Safari": "Safari", "com.google.Chrome": "Chrome", "company.thebrowser.Browser": "Arc", "com.brave.Browser": "Brave",
         "com.microsoft.edgemac": "Edge", "com.vivaldi.Vivaldi": "Vivaldi"][bundle] ?? bundle
    }
}

/// The day from first to last activity, each span a coloured block at its time.
struct DayStrip: View {
    var spans: [ActivitySpan]
    var classifier: Classifier

    var body: some View {
        let start = spans.map(\.start).min() ?? .now
        let end = max(spans.map(\.end).max() ?? .now, start.addingTimeInterval(3600))
        let length = end.timeIntervalSince(start)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(0.05))
                ForEach(spans) { s in
                    let x = geo.size.width * s.start.timeIntervalSince(start) / length
                    let w = max(2, geo.size.width * s.seconds / length)
                    let claude = s.app == ActivitySpan.claudeCode
                    Rectangle().fill(classifier.classify(s).category.color.opacity(claude ? 0.55 : 1))
                        .frame(width: w, height: claude ? geo.size.height * 0.3 : geo.size.height * 0.62)
                        .offset(x: x, y: claude ? geo.size.height * 0.7 : 0)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                HStack {
                    Text(start.formatted(date: .omitted, time: .shortened))
                    Spacer()
                    Text(end.formatted(date: .omitted, time: .shortened))
                }
                .font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.textTertiary).offset(y: 14)
            }
        }
        .padding(.bottom, 12)
    }
}

struct AssignTarget: Identifiable {
    enum Field { case project, area }
    var kind: ActivityRule.Kind
    var value: String
    var name: String
    var field: Field
    var id: String { value + "\(field)" }
}

struct AssignSheet: View {
    @Environment(\.dismiss) private var dismiss
    var target: AssignTarget
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(target.name) counts toward…").font(.system(size: 15, weight: .bold))
            TextField(target.field == .project ? "Project, e.g. Magicteams" : "Area, e.g. Marketing", text: $text)
                .textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Assign", action: save).keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 360)
    }

    func save() {
        let v = text.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return }
        if target.field == .project { ActivityRecorder.shared.assign(target.kind, target.value, project: v) }
        else { ActivityRecorder.shared.assign(target.kind, target.value, area: v) }
        dismiss()
    }
}

// MARK: - Life on Home

/// The top of Home when the planner is on: today's quests, today and tomorrow, the season, and where the day went.
struct LifeHome: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var timeline = ActivityRecorder.shared
    @AppStorage("homeLifeOpen") private var open = true
    @State private var editingSeason = false
    var go: (Screen) -> Void

    var p: Planner { model.planner }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Life").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary).textCase(.uppercase).kerning(0.6)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Spacer()
                    let level = Planner.level(for: p.xp())
                    Text("\(Planner.rank(for: level.number).title) · level \(level.number) · \(p.coins().formatted()) coins")
                        .font(Theme.number(11.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                HStack(alignment: .top, spacing: 14) {
                    quests
                    todayCard
                    tomorrowCard
                }
                HStack(alignment: .top, spacing: 14) {
                    seasonCard
                    dayCard
                }
            }
        }
        .sheet(isPresented: $editingSeason) { SeasonEditor(season: p.season, projects: knownProjects) }
    }

    var knownProjects: [String] {
        Array(Set(timeline.projects + timeline.settings.rules.compactMap(\.project) + p.tasks.compactMap(\.project))).sorted()
    }

    // MARK: Quests

    var quests: some View {
        let due = p.habitsDue().filter { $0.kind == .build }
        let minutes = model.questMinutes(timeline)
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Daily quests", trailing: "\(due.filter { $0.isDone() }.count)/\(due.count)")
                if due.isEmpty {
                    Text("A quest is a habit you do every day — “Train 45 min”, “Marketing 4 h”. Give it a time and it fills in from what you do.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Add a Quest") { go(.today) }.buttonStyle(GhostButtonStyle())
                }
                ForEach(due.prefix(5)) { h in
                    let done = h.isDone()
                    let target = h.isTimed ? h.minutes ?? 0 : 0
                    let have = minutes[h.id] ?? 0
                    HStack(spacing: 10) {
                        ZStack {
                            GaugeRing(fraction: done ? 1 : target > 0 ? min(1, Double(have) / Double(target)) : 0, tint: done ? Theme.safe : Theme.accent, lineWidth: 3.5)
                            if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.safe) }
                        }
                        .frame(width: 24, height: 24)
                        .onTapGesture { if !h.isTimed || done { model.toggleHabit(h) } }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(h.isTimed ? "\(Minutes.text(Double(have) * 60)) of \(Minutes.text(Double(target) * 60))\(h.track.map { " · " + $0.label } ?? "")"
                                 : done ? "done" : h.twoMinute.map { "or just: \($0)" } ?? "tap the ring when done")
                                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Today / tomorrow

    var todayCard: some View {
        let open = p.today().filter { !$0.isDone }
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(title: "Today", trailing: nil)
                    Button { go(.today) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                }
                if let s = p.runningSession {
                    HStack(spacing: 6) {
                        Image(systemName: "timer").foregroundStyle(Theme.safe)
                        FocusClock(start: s.start).foregroundStyle(Theme.safe)
                        Text(s.title).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Button("Stop") { model.stopFocus() }.buttonStyle(GhostButtonStyle()).controlSize(.small)
                    }
                }
                if open.isEmpty { Text(p.today().isEmpty ? "Nothing planned — pick your Big 3." : "All done today.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary) }
                ForEach(open.prefix(5)) { t in TaskRow(task: t, compact: true) }
                if open.count > 5 { Text("+\(open.count - 5) more").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    var tomorrowCard: some View {
        let key = Planner.key(daysFrom: .now, 1)
        let list = p.tasks.filter { $0.day == key && !$0.isDone }
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Tomorrow", trailing: list.isEmpty ? nil : "\(list.count)")
                if list.isEmpty {
                    Text("Nothing yet. Plan tomorrow tonight — right-click a task › Move to Tomorrow.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(list.prefix(5)) { t in TaskRow(task: t, compact: true) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Season

    var seasonCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                if let season = p.season, season.isActive(on: Planner.key(.now)) {
                    let weekMinutes = timeline.weekProjectMinutes
                    HStack {
                        SectionTitle(title: "Season", trailing: "until \(Planner.date(season.end)?.formatted(.dateTime.day().month()) ?? season.end)")
                        Button { editingSeason = true } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(season.quests) { q in
                        let have = weekMinutes[q.project.lowercased()] ?? 0
                        let main = q == season.main
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: main ? "crown.fill" : "circle.fill").font(.system(size: main ? 10 : 5)).foregroundStyle(main ? Theme.review : Theme.textTertiary)
                                Text(q.project).font(.system(size: 13, weight: main ? .semibold : .medium))
                                Spacer()
                                Text("\(Minutes.text(Double(have) * 60)) of \(q.hoursPerWeek) h this week").font(Theme.number(11.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                            }
                            SegmentedBar(segments: [.init(id: q.project, value: Double(have), color: main ? Theme.review : Theme.accent)],
                                         total: Double(q.hoursPerWeek * 60), height: 6)
                        }
                    }
                    let others = weekMinutes.filter { k, _ in !season.quests.contains { $0.project.lowercased() == k } }.values.reduce(0, +)
                    if others > 0 {
                        Text("\(Minutes.text(Double(others) * 60)) on other projects this week").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    SectionTitle(title: "Season", trailing: nil)
                    Text("Many projects, one at a time: pick a main quest and up to two side quests for the next two weeks, with the hours each deserves. Headroom shows planned against real.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Start a Season") { editingSeason = true }.buttonStyle(GhostButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Where the day went

    var dayCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "Where today went", trailing: nil)
                    Button { go(.timeline) } label: { Image(systemName: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
                }
                if !timeline.isOn && !AppModel.demoMode {
                    Text(timeline.available ? "Turn on the timeline and your quests fill themselves from what you actually do. It stays on this Mac."
                         : "The timeline needs the full Headroom download (the App Store edition can't look at other apps).")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if timeline.available { Button("Turn On Timeline") { timeline.setOn(true) }.buttonStyle(GhostButtonStyle()) }
                } else {
                    let c = timeline.classifier
                    let spans = timeline.allToday
                    DayStrip(spans: spans, classifier: c).frame(height: 26)
                    let totals = TimelineMath.totals(spans) { c.classify($0).category.rawValue }.prefix(4)
                    HStack(spacing: 14) {
                        ForEach(Array(totals)) { t in
                            let cat = ActivityCategory(rawValue: t.name) ?? .other
                            HStack(spacing: 5) {
                                Circle().fill(cat.color).frame(width: 7, height: 7)
                                Text("\(cat.title) \(Minutes.text(t.seconds))").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SeasonEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var projects: [String]
    @State private var main: String
    @State private var mainHours: Int
    @State private var sides: [(String, Int)]
    @State private var weeks = 2

    init(season: Season?, projects: [String]) {
        self.projects = projects
        _main = State(initialValue: season?.main.project ?? "")
        _mainHours = State(initialValue: season?.main.hoursPerWeek ?? 20)
        let s = season?.sides.map { ($0.project, $0.hoursPerWeek) } ?? []
        _sides = State(initialValue: s + Array(repeating: ("", 4), count: Season.maxSideQuests - s.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your season").font(.system(size: 17, weight: .bold))
            Text("One main quest gets most of your hours; up to two side quests keep moving. Everything else waits for the next season — that's the point.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            row("Main quest", $main, $mainHours)
            ForEach(sides.indices, id: \.self) { i in
                row("Side quest \(i + 1)", Binding(get: { sides[i].0 }, set: { sides[i].0 = $0 }), Binding(get: { sides[i].1 }, set: { sides[i].1 = $0 }))
            }
            Stepper("Lasts \(weeks) week\(weeks == 1 ? "" : "s")", value: $weeks, in: 1...6)
            HStack {
                if model.planner.season != nil {
                    Button("End Season") { model.plan { $0.season = nil }; dismiss() }.buttonStyle(GhostButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") {
                    let s = Season(start: Planner.key(.now), end: Planner.key(daysFrom: .now, weeks * 7 - 1),
                                   main: .init(project: main.trimmingCharacters(in: .whitespaces), hoursPerWeek: mainHours),
                                   sides: sides.filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }.map { .init(project: $0.0.trimmingCharacters(in: .whitespaces), hoursPerWeek: $0.1) })
                    model.plan { $0.season = s }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(main.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 460)
    }

    func row(_ label: String, _ name: Binding<String>, _ hours: Binding<Int>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
            TextField("Project", text: name).textFieldStyle(.roundedBorder)
            Menu {
                ForEach(projects, id: \.self) { p in Button(p) { name.wrappedValue = p } }
            } label: { Image(systemName: "chevron.down") }
                .menuStyle(.borderlessButton).fixedSize().disabled(projects.isEmpty)
            Stepper("\(hours.wrappedValue) h/wk", value: hours, in: 1...60).fixedSize()
        }
    }
}

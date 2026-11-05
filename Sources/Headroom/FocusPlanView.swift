import SwiftUI
import AppKit
import HeadroomCore
import UserNotifications

/// Today's time blocks beside the calendar: what each hour is for. Blocks live in planner.json; the
/// calendar is only read. The block happening now gets a Focus button.
struct DayPlanCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @Environment(\.snapshotMode) private var snapshot
    @State private var title = ""
    @State private var start = Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: .now) + 1, minute: 0, second: 0, of: .now) ?? .now
    @State private var length = 60
    /// The stack's proposals: today's tasks placed in free time, shown as ghosts until you keep them.
    @State private var proposals: [TimeBlock] = []

    enum Row: Identifiable {
        case event(CalendarEvent), block(TimeBlock)
        var id: String { switch self { case .event(let e): "e\(e.title)\(e.start)"; case .block(let b): b.id.uuidString } }
        var start: Int {
            switch self {
            case .event(let e): Calendar.current.component(.hour, from: e.start) * 60 + Calendar.current.component(.minute, from: e.start)
            case .block(let b): b.start
            }
        }
    }

    var body: some View {
        let day = Planner.key(.now)
        let blocks = model.planner.blocks(on: day)
        let rows = (coach.events(on: day).filter { !$0.allDay }.map(Row.event)
                    + (blocks + model.planner.protectedBlocks(on: day) + proposals).map(Row.block)).sorted { $0.start < $1.start }
        let score = model.planner.score()
        let now = Calendar.current.component(.hour, from: .now) * 60 + Calendar.current.component(.minute, from: .now)
        let blocked = blocks.reduce(0) { $0 + $1.minutes }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(title: "Day plan", trailing: blocks.isEmpty ? nil : "\(Minutes.text(Double(blocked) * 60)) blocked")
                    if score.planned > 0 {
                        Text("Daily score \(score.percent)%").font(Theme.number(11.5, weight: .semibold))
                            .foregroundStyle(score.percent >= 90 ? Theme.safe : Theme.textSecondary)
                            .help("Planned tasks, blocks and habits done count up to 90%; the evening sync is the last 10%. \(score.done) of \(score.planned) done.")
                    }
                    if !snapshot {
                        Button(proposals.isEmpty ? "Stack Tasks" : "Discard") {
                            proposals = proposals.isEmpty ? model.stackToday() : []
                            if proposals.isEmpty { model.show("Every task for today already has a time") }
                        }
                        .buttonStyle(GhostButtonStyle()).controlSize(.small)
                        .help("Place today's tasks without a time into free time — a quest's tasks go into its protected time first")
                    }
                }
                if rows.isEmpty {
                    Text("Give your Big 3 a time. Right-click a task › Block Time Today, add one below, or press Plan My Day and the coach blocks the day around your calendar.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows) { row in
                    switch row {
                    case .event(let e):
                        line(time: e.start.formatted(date: .omitted, time: .shortened), title: e.title, detail: e.calendar,
                             tint: Theme.textTertiary, symbol: "calendar", past: e.end < .now, current: e.start <= .now && .now < e.end)
                    case .block(let b) where b.protected == true:
                        line(time: clock(b.start), title: "Protected for \(b.title)", detail: "\(clock(b.start))–\(clock(b.end)) · kept free for this quest",
                             tint: Theme.accent.opacity(0.45), symbol: "lock", past: b.end <= now, current: false)
                            .opacity(0.75)
                    case .block(let b) where proposals.contains { $0.id == b.id }:
                        line(time: clock(b.start), title: b.title, detail: "\(Minutes.text(Double(b.minutes) * 60)) · suggested by the stack",
                             tint: Theme.accent, symbol: "square.dashed", past: false, current: false)
                            .opacity(0.6)
                            .overlay(alignment: .trailing) {
                                HStack(spacing: 4) {
                                    Button("Keep") { keep([b]) }.buttonStyle(GhostButtonStyle()).controlSize(.small)
                                    Button { proposals.removeAll { $0.id == b.id } } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.borderless).help("Discard")
                                }
                            }
                    case .block(let b):
                        let current = b.start <= now && now < b.end
                        let task = b.taskID.flatMap { id in model.planner.tasks.first { $0.id == id } }
                        let done = b.done != nil || task?.isDone == true
                        line(time: clock(b.start), title: b.title,
                             detail: "\(Minutes.text(Double(b.minutes) * 60))\(b.fromCoach == true ? " · from the coach" : "")\(b.feel.map { " · " + $0.title.lowercased() } ?? "")\(b.counts == false ? " · not scored" : "")",
                             tint: Theme.accent, symbol: "square.fill", past: b.end <= now || done, current: current && !done)
                            .overlay(alignment: .leading) {
                                if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.safe).offset(x: 69) }
                            }
                            .overlay(alignment: .trailing) {
                                if current && !done && model.planner.runningSession == nil && !snapshot {
                                    Button { model.startFocus(b.title, task: b.taskID.flatMap { id in model.planner.tasks.first { $0.id == id } }) } label: {
                                        Label("Focus", systemImage: "timer")
                                    }
                                    .buttonStyle(GhostButtonStyle()).controlSize(.small)
                                }
                            }
                            .contextMenu {
                                if let task {
                                    Button(task.isDone ? "Mark Task Not Done" : "Mark Task Done") { model.toggleTask(task) }
                                } else {
                                    Button(b.done == nil ? "Mark Done" : "Mark Not Done") { model.editBlock(b.id) { $0.done = $0.done == nil ? .now : nil } }
                                }
                                Menu("How It Felt") {
                                    ForEach(Feel.allCases, id: \.self) { f in
                                        Button { model.editBlock(b.id) { $0.feel = $0.feel == f ? nil : f } } label: {
                                            Label(f.title, systemImage: b.feel == f ? "checkmark" : f.symbol)
                                        }
                                    }
                                }
                                if task == nil {
                                    Button(b.counts == false ? "Count Toward Daily Score" : "Leave Out of Daily Score") {
                                        model.editBlock(b.id) { $0.counts = $0.counts == false ? nil : false }
                                    }
                                }
                                Divider()
                                Button("Remove Block", role: .destructive) { model.plan { p in p.blocks.removeAll { $0.id == b.id } } }
                            }
                    }
                }
                if proposals.count > 1 && !snapshot {
                    Button("Keep All \(proposals.count)") { keep(proposals) }.buttonStyle(PrimaryButtonStyle()).controlSize(.small)
                }
                if !snapshot { adder(day) }
            }
        }
    }

    func keep(_ list: [TimeBlock]) {
        let added = model.plan { p in list.filter { p.addBlock($0) != nil }.count }
        proposals.removeAll { b in list.contains { $0.id == b.id } }
        if added < list.count { model.show("\(list.count - added) clashed with something new — left out") }
    }

    /// The Mac's own time format, like the calendar rows (9:30 AM or 09:30).
    func clock(_ minute: Int) -> String {
        Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minute * 60)).formatted(date: .omitted, time: .shortened)
    }

    func line(time: String, title: String, detail: String, tint: Color, symbol: String, past: Bool, current: Bool) -> some View {
        HStack(spacing: 10) {
            Text(time).font(Theme.number(11.5, weight: .semibold)).foregroundStyle(past ? Theme.textTertiary : tint).frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(past ? Theme.fill(0.1) : tint).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: current ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(past ? Theme.textTertiary : Theme.textPrimary)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2).padding(.horizontal, current ? 6 : 0)
        .background(RoundedRectangle(cornerRadius: 8).fill(current ? Theme.accent.opacity(0.08) : .clear))
    }

    func adder(_ day: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(Theme.textTertiary).font(.system(size: 12, weight: .semibold))
            TextField("Block time for…", text: $title).textFieldStyle(.plain).font(.system(size: 13)).onSubmit { add(day) }
            DatePicker("", selection: $start, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
            Picker("", selection: $length) {
                ForEach([30, 45, 60, 90, 120, 180], id: \.self) { Text(Minutes.text(Double($0) * 60)).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.04)))
    }

    func add(_ day: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: start)
        let a = (c.hour ?? 9) * 60 + (c.minute ?? 0)
        if model.plan({ $0.addBlock(TimeBlock(title: t, day: day, start: a, end: a + length)) }) == nil {
            model.show("That overlaps another block")
        } else {
            title = ""
            start = start.addingTimeInterval(TimeInterval(length * 60))
        }
    }
}

/// The season, Superfocus-style: day N of the season, each quest's weeks as on track / adjust / off track,
/// how strong this week's plan is, and the weekly review.
struct SeasonGrid: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @ObservedObject var timeline = ActivityRecorder.shared
    var season: Season

    var body: some View {
        let today = Planner.key(.now)
        let grid = season.grid()
        let current = season.weekIndex(on: today) ?? -1
        VStack(alignment: .leading, spacing: 10) {
            if let day = season.dayNumber(on: today) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Day \(day) of \(season.days)").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("\(season.days - day) days left").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if let strength = PlanStrength.of(model.planner, done: timeline.weekProjectMinutes) {
                        Text("Plan strength \(Int(strength.score * 100))%").font(Theme.number(11.5, weight: .semibold))
                            .foregroundStyle(strength.score >= 0.8 ? Theme.safe : strength.score >= 0.5 ? Theme.review : Theme.textSecondary)
                            .help(strength.gaps.isEmpty ? "Every hour still needed this week has a time block."
                                  : "Not blocked yet: " + strength.gaps.map { "\($0.key) \(Minutes.text(Double($0.value) * 60))" }.sorted().joined(separator: ", "))
                    }
                }
            }
            ForEach(grid, id: \.quest.id) { row in
                HStack(spacing: 8) {
                    Text(row.quest.project).font(.system(size: 11.5, weight: row.quest == season.main ? .semibold : .regular)).lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                    HStack(spacing: 3) {
                        ForEach(Array(row.weeks.enumerated()), id: \.offset) { i, st in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color(st))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(i == current ? Theme.textSecondary : .clear, lineWidth: 1))
                                .frame(height: 12)
                                .help("Week \(i + 1): \(word(st))")
                        }
                    }
                    Text(word(row.weeks.indices.contains(current) ? row.weeks[current] : .upcoming))
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(color(row.weeks.indices.contains(current) ? row.weeks[current] : .upcoming))
                        .frame(width: 62, alignment: .trailing)
                }
            }
        }
    }

    func color(_ s: GoalStatus) -> Color {
        switch s {
        case .onTrack: Theme.safe
        case .adjust: Theme.review
        case .offTrack: Theme.critical.opacity(0.6)
        case .upcoming: Theme.fill(0.07)
        }
    }

    func word(_ s: GoalStatus) -> String {
        switch s {
        case .onTrack: "on track"
        case .adjust: "adjust"
        case .offTrack: "off track"
        case .upcoming: "—"
        }
    }
}

/// Focus mode's shield: while a focus session runs, a distracting app coming to the front is hidden (or you get
/// a reminder), and a distracting site gets a reminder. Hiding never quits anything — ⌘Tab brings it back.
@MainActor
final class FocusShield {
    static let shared = FocusShield()
    private weak var model: AppModel?
    private var lastReminder: Date?
    private var observing = false

    static var mode: FocusMode.Shield {
        get { FocusMode.Shield(rawValue: UserDefaults.standard.string(forKey: "focusShield") ?? "") ?? .remind }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "focusShield") }
    }

    func attach(_ model: AppModel) {
        self.model = model
        guard !observing, !Edition.appStore else { return }
        observing = true
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundle = app?.bundleIdentifier, name = app?.localizedName, pid = app?.processIdentifier
            Task { @MainActor in
                guard let bundle, let pid else { return }
                FocusShield.shared.check(ActivitySpan(start: .now, end: .now, app: bundle, appName: name ?? bundle), pid: pid)
            }
        }
    }

    /// From app switches, and from the timeline's samples (which know the browser's site).
    func check(_ front: ActivitySpan, pid: pid_t? = nil) {
        guard let model, model.plannerAddOn else { return }
        // The top thing: until today's one task is done, the shield acts as if you were focusing on it.
        var running = model.planner.runningSession
        if running == nil, UserDefaults.standard.bool(forKey: "guardTopThing"),
           let top = model.planner.topThing(on: Planner.key(.now)), !top.isDone {
            running = FocusSession(title: top.title, start: Calendar.current.startOfDay(for: .now))
        }
        let reaction = FocusMode.react(Self.mode, running: running, front: front,
                                       classifier: ActivityRecorder.shared.classifier, lastReminder: lastReminder)
        switch reaction {
        case .none: break
        case .hide:
            if let pid, let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier != Bundle.main.bundleIdentifier {
                app.hide()
                model.show("Hid \(front.appName) — you're in focus")
            }
        case .remind(let text):
            lastReminder = .now
            model.show(text)
            Notifier.post("Focus", text)
        }
    }
}

/// The running session's quality (share of it not on distractions) and the shield setting.
struct FocusQuality: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var timeline = ActivityRecorder.shared
    @AppStorage("focusShield") private var shield = FocusMode.Shield.remind.rawValue
    @AppStorage("guardTopThing") private var guardTop = false
    @AppStorage(FocusSound.key) private var sound = FocusSound.Kind.off.rawValue
    @Environment(\.snapshotMode) private var snapshot
    var session: FocusSession

    var body: some View {
        HStack(spacing: 8) {
            if timeline.isOn || AppModel.demoMode,
               let q = FocusMode.quality(session, spans: timeline.allToday, classifier: timeline.classifier) {
                Text("\(Int(q * 100))% focused").font(Theme.number(11.5, weight: .semibold))
                    .foregroundStyle(q >= 0.85 ? Theme.safe : Theme.review)
                    .help("\(FocusMode.verdict(q)). Share of this session not spent on distracting apps and sites (from the timeline).")
            }
            if !snapshot { shieldMenu; soundMenu }
        }
    }

    var shieldMenu: some View {
            Menu {
                Picker("While focusing", selection: $shield) {
                    Text("Don't watch").tag(FocusMode.Shield.off.rawValue)
                    Text("Remind me").tag(FocusMode.Shield.remind.rawValue)
                    Text("Hide distracting apps").tag(FocusMode.Shield.hide.rawValue)
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Guard Today's Top Thing Until It's Done", isOn: $guardTop)
            } label: {
                Image(systemName: shield == FocusMode.Shield.off.rawValue ? "shield.slash" : "shield.lefthalf.filled")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Shield: what happens when a distraction comes up during focus")
    }

    var soundMenu: some View {
        Menu {
            Picker("Focus sound", selection: $sound) {
                ForEach(FocusSound.Kind.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: sound == FocusSound.Kind.off.rawValue ? "speaker.slash" : "waveform")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .onChange(of: sound) { FocusSound.shared.sync(running: model.planner.runningSession != nil) }
        .help("A sound that plays while you focus — made on this Mac, nothing streamed")
    }
}

/// A notification from anywhere in the app (the delegate's own `notify` is private to the tick).
enum Notifier {
    @MainActor static func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

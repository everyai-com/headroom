import SwiftUI
import EventKit
import HeadroomCore

/// Life OS step 2 in the app: your calendar (read-only, after you connect it), proof from your commits,
/// the coach (your Claude CLI, asked only when you press a button) and drift nudges. Full edition only.
@MainActor
final class LifeCoach: ObservableObject {
    static let shared = LifeCoach()

    /// The next seven days' events (the weekly review plans around all of them).
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var calendarConnected = false
    @Published private(set) var commits: [Commit] = []
    @Published private(set) var asking: Coach.Moment?
    @Published var suggestion: Suggestion?
    @Published private(set) var failure: String?
    /// The last thing the coach said today (its plan's note or the evening review).
    @Published private(set) var note: (moment: Coach.Moment, text: String)?
    /// Last night, estimated from when the Mac slept, locked or turned its screen off.
    @Published private(set) var sleep: SleepEstimate?
    /// The day whose journal Claude is reflecting on.
    @Published private(set) var reflecting: String?
    /// A season draft is being written (the editor waits for it).
    @Published private(set) var drafting = false

    struct Suggestion: Identifiable {
        let id = UUID()
        var moment: Coach.Moment
        var day: String
        var plan: CoachPlan
    }

    var available: Bool { !Edition.appStore }
    let hasClaude = ClaudeCLI.executable != nil
    /// When nudges stop for the day (minutes after midnight). Settings could expose it; 19:00 for now.
    var workdayEnd: Int { UserDefaults.standard.object(forKey: "workdayEnd") as? Int ?? 19 * 60 }

    private let store = EKEventStore()
    private var lastCalendar = Date.distantPast
    private var lastProof = Date.distantPast
    private let rest = RestStore()
    private var sleepDay = ""

    private init() {
        if AppModel.demoMode { seedDemo(); return }
        calendarConnected = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if let saved = UserDefaults.standard.dictionary(forKey: "coachNote"), saved["day"] as? String == Planner.key(.now),
           let m = (saved["moment"] as? String).flatMap(Coach.Moment.init(rawValue:)), let text = saved["text"] as? String {
            note = (m, text)
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            Task { @MainActor in LifeCoach.shared.refreshCalendar(force: true) }
        }
        guard available else { return }
        // Times only: when the Mac went to rest and came back. Sleep is the longest rest overnight.
        rest.append(RestEvent(.launch, at: .now))
        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, RestEvent.Kind)] = [
            (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.screensDidSleepNotification, .lock), (NSWorkspace.screensDidWakeNotification, .unlock),
        ]
        for (name, kind) in pairs {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in LifeCoach.shared.rested(kind) } }
        }
        for (name, kind) in [("com.apple.screenIsLocked", RestEvent.Kind.lock), ("com.apple.screenIsUnlocked", .unlock)] {
            DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { _ in
                Task { @MainActor in LifeCoach.shared.rested(kind) }
            }
        }
        refreshSleep(force: true)
    }

    private func rested(_ kind: RestEvent.Kind) {
        rest.append(RestEvent(kind, at: .now))
        if kind == .wake || kind == .unlock { refreshSleep(force: true) }
    }

    func refreshSleep(force: Bool = false) {
        let today = Planner.key(.now)
        guard force || sleepDay != today else { return }
        sleepDay = today
        sleep = Rest.night(endingOn: today, events: rest.load())
    }

    /// From the 30 s tick: calendar every 5 minutes, commits every 10. Never asks for anything.
    func update() {
        guard available, !AppModel.demoMode else { return }
        // Yesterday's note doesn't carry into today.
        if note != nil, UserDefaults.standard.dictionary(forKey: "coachNote")?["day"] as? String != Planner.key(.now) { note = nil }
        refreshCalendar()
        refreshProof()
        refreshSleep()
    }

    // MARK: Calendar

    /// The one place the calendar prompt comes from: the Connect button.
    func connectCalendar() {
        Task {
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            calendarConnected = granted
            if granted { refreshCalendar(force: true) }
        }
    }

    func refreshCalendar(force: Bool = false) {
        guard calendarConnected, force || Date().timeIntervalSince(lastCalendar) > 5 * 60 else { return }
        lastCalendar = .now
        let start = Calendar.current.startOfDay(for: .now)
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let own = UserDefaults.standard.string(forKey: Self.calendarKey)
        events = store.events(matching: predicate)
            .filter { $0.status != .canceled && $0.calendar?.calendarIdentifier != own } // our own blocks aren't "busy"
            .map { CalendarEvent(title: $0.title ?? "Busy", start: $0.startDate, end: $0.endDate,
                                 calendar: $0.calendar?.title ?? "", allDay: $0.isAllDay) }
            .sorted { $0.start < $1.start }
    }

    func events(on day: String) -> [CalendarEvent] {
        events.filter { Planner.key($0.start) == day }
    }

    // MARK: Blocks on your calendar

    /// Your time blocks, copied into a calendar of Headroom's own called "Headroom" (so they reach your phone).
    /// Only that calendar is ever written; turning it off removes only the events Headroom put there.
    static let mirrorKey = "blocksOnCalendar", calendarKey = "headroomCalendarID", mappedKey = "mirroredBlocks"
    @Published private(set) var mirrorOn = UserDefaults.standard.bool(forKey: LifeCoach.mirrorKey)
    private var lastMirror = Date.distantPast

    func setMirror(_ on: Bool, model: AppModel) {
        mirrorOn = on
        UserDefaults.standard.set(on, forKey: Self.mirrorKey)
        if on {
            if calendarConnected { mirror(model: model, force: true) }
            else {
                Task {
                    let granted = (try? await store.requestFullAccessToEvents()) ?? false
                    calendarConnected = granted
                    if granted { refreshCalendar(force: true); mirror(model: model, force: true) }
                    else { failure = "Headroom needs calendar access to show your blocks there (System Settings › Privacy & Security › Calendars)." }
                }
            }
        } else {
            unmirror()
        }
    }

    /// From the tick (at most once a minute) and right after a change: brings the Headroom calendar in line
    /// with the blocks for today and the next 7 days.
    func mirror(model: AppModel, force: Bool = false) {
        guard available, !AppModel.demoMode, mirrorOn, calendarConnected, force || Date().timeIntervalSince(lastMirror) > 60 else { return }
        lastMirror = .now
        guard let cal = headroomCalendar() else {
            failure = "Couldn't make a “Headroom” calendar. Check Calendar › Settings › Accounts that one account allows new calendars."
            return
        }
        let start = Calendar.current.startOfDay(for: .now)
        guard let end = Calendar.current.date(byAdding: .day, value: 8, to: start) else { return }
        let days = Set((0..<8).map { Planner.key(daysFrom: start, $0) })
        let blocks = model.planner.blocks.filter { days.contains($0.day) }
        var mapped: [UUID: String] = [:]
        for (k, v) in (UserDefaults.standard.dictionary(forKey: Self.mappedKey) as? [String: String] ?? [:]) {
            if let id = UUID(uuidString: k) { mapped[id] = v }
        }
        let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [cal]))
        var existing: [String: CalendarMirror.Event] = [:]
        for e in found { existing[e.calendarItemIdentifier] = .init(title: e.title ?? "", start: e.startDate, end: e.endDate) }
        let plan = CalendarMirror.plan(blocks: blocks, mapped: mapped, existing: existing)
        guard !plan.isEmpty else { return }
        for b in plan.create {
            guard let iv = b.interval() else { continue }
            let e = EKEvent(eventStore: store)
            e.title = b.title; e.startDate = iv.start; e.endDate = iv.end; e.calendar = cal
            e.notes = "Time block from Headroom\(b.project.map { " · \($0)" } ?? ""). Change it in Headroom — edits here are replaced."
            if (try? store.save(e, span: .thisEvent, commit: false)) != nil { mapped[b.id] = e.calendarItemIdentifier }
        }
        for (id, target) in plan.update {
            guard let e = store.calendarItem(withIdentifier: id) as? EKEvent, e.calendar?.calendarIdentifier == cal.calendarIdentifier else { continue }
            e.title = target.title; e.startDate = target.start; e.endDate = target.end
            try? store.save(e, span: .thisEvent, commit: false)
        }
        for id in plan.delete {
            if let e = store.calendarItem(withIdentifier: id) as? EKEvent, e.calendar?.calendarIdentifier == cal.calendarIdentifier {
                try? store.remove(e, span: .thisEvent, commit: false)
            }
        }
        try? store.commit()
        // Forget what's gone or in the past (past events stay on the calendar as a record).
        let live = Set(model.planner.blocks.filter { $0.day >= Planner.key(start) }.map(\.id))
        let keep = mapped.filter { live.contains($0.key) && !plan.delete.contains($0.value) }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: keep.map { ($0.key.uuidString, $0.value) }), forKey: Self.mappedKey)
    }

    /// Removes the events Headroom made (today on), and nothing else.
    private func unmirror() {
        guard calendarConnected, let id = UserDefaults.standard.string(forKey: Self.calendarKey), let cal = store.calendar(withIdentifier: id) else { return }
        let mapped = Set((UserDefaults.standard.dictionary(forKey: Self.mappedKey) as? [String: String] ?? [:]).values)
        for value in mapped {
            if let e = store.calendarItem(withIdentifier: value) as? EKEvent, e.calendar?.calendarIdentifier == cal.calendarIdentifier,
               e.endDate > Calendar.current.startOfDay(for: .now) {
                try? store.remove(e, span: .thisEvent, commit: false)
            }
        }
        try? store.commit()
        UserDefaults.standard.removeObject(forKey: Self.mappedKey)
    }

    /// The "Headroom" calendar, made once in the account new events go to (else iCloud, else On My Mac).
    private func headroomCalendar() -> EKCalendar? {
        if let id = UserDefaults.standard.string(forKey: Self.calendarKey), let c = store.calendar(withIdentifier: id) { return c }
        let sources = [store.defaultCalendarForNewEvents?.source].compactMap { $0 }
            + store.sources.filter { $0.sourceType == .calDAV && $0.title.localizedCaseInsensitiveContains("icloud") }
            + store.sources.filter { $0.sourceType == .local }
        for source in sources {
            let c = EKCalendar(for: .event, eventStore: store)
            c.title = "Headroom"
            c.cgColor = NSColor.systemGreen.cgColor
            c.source = source
            if (try? store.saveCalendar(c, commit: true)) != nil {
                UserDefaults.standard.set(c.calendarIdentifier, forKey: Self.calendarKey)
                return c
            }
        }
        return nil
    }

    // MARK: Proof

    func refreshProof(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastProof) > 10 * 60 else { return }
        lastProof = .now
        let day = Planner.key(.now)
        Task.detached(priority: .utility) {
            let found = Proof.commits(on: day, paths: ClaudeCodeActivity.projectPaths())
            await MainActor.run { LifeCoach.shared.commits = found }
        }
    }

    // MARK: Coach

    func ask(_ moment: Coach.Moment, model: AppModel, dump: String = "") {
        guard asking == nil else { return }
        asking = moment
        failure = nil
        var context = context(model: model)
        context.dump = dump
        if moment != .week {
            let days = [Planner.key(.now), Planner.key(daysFrom: .now, 1)]
            context.events = context.events.filter { days.contains(Planner.key($0.start)) }
        }
        let prompt = Coach.prompt(moment, context)
        let day = moment == .evening ? Planner.key(daysFrom: .now, 1) : Planner.key(.now)
        Task.detached(priority: .userInitiated) {
            let reply = ClaudeCLI.ask(prompt)
            let plan = reply.flatMap(Coach.parse)
            await MainActor.run {
                let coach = LifeCoach.shared
                coach.asking = nil
                guard let plan else {
                    coach.failure = reply == nil ? "Claude didn't answer (is `claude` signed in?)." : "Claude's answer wasn't a plan. Try again."
                    return
                }
                if !plan.note.isEmpty { coach.remember(moment, plan.note) }
                coach.suggestion = Suggestion(moment: moment, day: day, plan: plan)
            }
        }
    }

    private func remember(_ moment: Coach.Moment, _ text: String) {
        note = (moment, text)
        UserDefaults.standard.set(["day": Planner.key(.now), "moment": moment.rawValue, "text": text], forKey: "coachNote")
    }

    func context(model: AppModel) -> DayContext {
        let timeline = ActivityRecorder.shared
        let c = timeline.classifier
        let spans = timeline.allToday
        func minutes(_ t: [TimelineMath.Total]) -> [(name: String, minutes: Int)] { t.map { ($0.name, Int($0.seconds / 60)) } }
        let questMinutes = model.questMinutes(timeline)
        let quests = model.planner.habits.filter { $0.isTimed && !$0.archived }
            .map { QuestStatus(title: $0.title, done: questMinutes[$0.id] ?? 0, target: $0.minutes ?? 0) }
        var context = DayContext(now: .now, planner: model.planner, events: events, commits: commits,
                                 byProject: minutes(TimelineMath.totals(spans) { c.classify($0).project }),
                                 byKind: minutes(TimelineMath.totals(spans) { c.classify($0).category.title }),
                                 quests: quests, seasonWeek: timeline.weekProjectMinutes)
        context.sleep = sleep
        context.logs = [Planner.key(daysFrom: .now, -1), Planner.key(.now)].compactMap { model.planner.log(on: $0) }
        context.memory = CoachMemory().load()
        return context
    }

    /// The season editor's "Draft with Claude": goals, milestones and a commitment from what you wrote.
    func draftSeason(_ dump: String, weeks: Int, model: AppModel, done: @escaping @MainActor (SeasonDraft) -> Void) {
        guard !drafting else { return }
        drafting = true
        failure = nil
        let prompt = Coach.seasonPrompt(dump: dump, weeks: weeks, context(model: model))
        Task.detached(priority: .userInitiated) {
            let reply = ClaudeCLI.ask(prompt)
            let draft = reply.flatMap(Coach.parseSeason)
            await MainActor.run {
                LifeCoach.shared.drafting = false
                guard let draft else {
                    LifeCoach.shared.failure = reply == nil ? "Claude didn't answer (is `claude` signed in?)." : "Claude's answer wasn't a season. Try again."
                    return
                }
                done(draft)
            }
        }
    }

    /// The journal's Reflect button: Claude reads the day (and the entry) and answers in a few sentences,
    /// saved beside the entry. Asked only when you press it.
    func reflect(on day: String, model: AppModel) {
        guard reflecting == nil else { return }
        reflecting = day
        failure = nil
        let prompt = Coach.reflectionPrompt(context(model: model), day: day)
        Task.detached(priority: .userInitiated) {
            let reply = ClaudeCLI.ask(prompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                LifeCoach.shared.reflecting = nil
                guard let reply, !reply.isEmpty else { LifeCoach.shared.failure = "Claude didn't answer (is `claude` signed in?)."; return }
                model.updateLog(day) { $0.reflection = reply }
            }
        }
    }

    /// From the tick, while the timeline is on: long stretches in one project become focus sessions.
    func detectFocus(model: AppModel) {
        guard available, !AppModel.demoMode, ActivityRecorder.shared.isOn else { return }
        let t = ActivityRecorder.shared
        model.recordDetectedFocus(FocusDetector.stretches(t.allToday, classifier: t.classifier))
    }

    // MARK: Nudges

    /// From the tick: asks the pure rule, remembers when it last spoke.
    func nudge(model: AppModel) -> Nudge? {
        guard available, !AppModel.demoMode, ActivityRecorder.shared.isOn else { return nil }
        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-30 * 60), end: now)
        let c = ActivityRecorder.shared.classifier
        var bySource: [String: TimeInterval] = [:]
        for s in ActivityRecorder.shared.today where c.classify(s).category.isDistraction {
            guard let overlap = DateInterval(start: s.start, end: max(s.start, s.end)).intersection(with: window) else { continue }
            bySource[s.host ?? s.appName, default: 0] += overlap.duration
        }
        let questMinutes = model.questMinutes(ActivityRecorder.shared)
        let quests = model.planner.habits.filter { $0.isTimed && !$0.archived && !$0.isDone(now) }
            .map { QuestStatus(title: $0.title, done: questMinutes[$0.id] ?? 0, target: $0.minutes ?? 0) }
        let minute = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        let last = UserDefaults.standard.object(forKey: "lastNudge") as? Date
        let input = Nudges.Input(now: now, distractedLast30: Int(bySource.values.reduce(0, +) / 60),
                                 topDistraction: bySource.max { $0.value < $1.value }?.key, quests: quests,
                                 workMinutesLeft: max(0, workdayEnd - minute), lastNudge: last)
        guard let nudge = Nudges.decide(input) else { return nil }
        UserDefaults.standard.set(now, forKey: "lastNudge")
        return nudge
    }

    // MARK: Demo

    private func seedDemo() {
        let day = Calendar.current.startOfDay(for: .now)
        func at(_ h: Double, _ d: Int = 0) -> Date { day.addingTimeInterval(Double(d) * 86_400 + h * 3600) }
        calendarConnected = true
        sleep = SleepEstimate(start: day.addingTimeInterval(-50 * 60), end: day.addingTimeInterval(5.35 * 3600))
        events = [
            CalendarEvent(title: "Standup", start: at(9.5), end: at(9.75), calendar: "Work"),
            CalendarEvent(title: "Demo call · Svikarr client", start: at(14), end: at(14.75), calendar: "Work"),
            CalendarEvent(title: "Gym", start: at(18.5), end: at(19.5), calendar: "Personal"),
            CalendarEvent(title: "Investor coffee", start: at(10, 1), end: at(11, 1), calendar: "Work"),
        ]
        commits = [
            Commit(project: "magicteams", hash: "a1", date: at(11.2), subject: "Front desk: book from missed calls"),
            Commit(project: "magicteams", hash: "a2", date: at(12.1), subject: "Pricing page copy"),
            Commit(project: "Headroom", hash: "b1", date: at(13.4), subject: "Coach card on Today"),
        ]
        note = (.morning, "Marketing first while you're fresh: 9:45–12:00 on LinkedIn outreach, then the pricing page before the 14:00 demo. Keep the gym at 18:30 — it's tonight's quest.")
    }
}

// MARK: - The card on Today

struct CoachCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @Environment(\.snapshotMode) private var snapshot
    @State private var dumping = false
    @State private var editingMemory = false

    var body: some View {
        let today = Planner.key(.now)
        let evening = Calendar.current.component(.hour, from: .now) >= 16
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    SectionTitle(title: "Coach")
                    if coach.hasClaude || snapshot {
                        if let m = coach.asking {
                            ProgressView().controlSize(.small)
                            Text(m == .morning ? "Planning your day…" : m == .week ? "Reviewing your season…" : m == .dump ? "Sorting your brain dump…" : "Reviewing your day…")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        } else if evening {
                            Button { coach.ask(.evening, model: model) } label: { Label("Review My Day", systemImage: "moon.stars") }
                                .buttonStyle(PrimaryButtonStyle())
                            Button { coach.ask(.morning, model: model) } label: { Label("Plan Today", systemImage: "sun.max") }
                                .buttonStyle(GhostButtonStyle())
                            weekButton
                        } else {
                            Button { coach.ask(.morning, model: model) } label: { Label("Plan My Day", systemImage: "sun.max") }
                                .buttonStyle(PrimaryButtonStyle())
                            Button { coach.ask(.evening, model: model) } label: { Label("Review", systemImage: "moon.stars") }
                                .buttonStyle(GhostButtonStyle())
                            weekButton
                        }
                    } else {
                        Text("Install Claude Code to get a plan and a review").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if !snapshot {
                        if coach.hasClaude {
                            Button { dumping = true } label: { Image(systemName: "tray.and.arrow.down") }
                                .buttonStyle(.borderless).help("Brain dump: paste notes, a meeting or a list — the coach pulls out the tasks")
                        }
                        Button { editingMemory = true } label: { Image(systemName: "brain") }
                            .buttonStyle(.borderless).help("What the coach knows about you")
                    }
                }
                if let f = coach.failure {
                    Label(f, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(Theme.review)
                }
                if let n = coach.note {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: n.moment == .morning ? "sun.max.fill" : n.moment == .week ? "flag.checkered" : "moon.stars.fill").foregroundStyle(Theme.accent)
                        Text(n.text).font(.system(size: 13)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(alignment: .top, spacing: 24) {
                    calendar(coach.events(on: today))
                    proof
                }
            }
        }
        .sheet(item: $coach.suggestion) { s in CoachSheet(suggestion: s) }
        .sheet(isPresented: $dumping) { BrainDumpSheet() }
        .sheet(isPresented: $editingMemory) { CoachMemorySheet() }
    }

    @ViewBuilder var weekButton: some View {
        if model.planner.season != nil {
            Button { coach.ask(.week, model: model) } label: { Label("Week", systemImage: "flag.checkered") }
                .buttonStyle(GhostButtonStyle())
                .help("Weekly review: an honest read on each season quest, specific fixes, and time blocks for the rest of the week")
        }
    }

    func calendar(_ events: [CalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calendar").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            if !coach.calendarConnected {
                Button("Connect Calendar…") { coach.connectCalendar() }.buttonStyle(GhostButtonStyle())
                Text("Read only, never changed. The coach plans around it.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            } else if events.isEmpty {
                Text("Nothing on the calendar today").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            if !snapshot {
                Toggle(isOn: Binding(get: { coach.mirrorOn }, set: { coach.setMirror($0, model: model) })) {
                    Text("Show my time blocks in Calendar").font(.system(size: 11.5))
                }
                .toggleStyle(.checkbox)
                .help("Copies today's and the next 7 days' blocks into a calendar called “Headroom”, so they reach your phone. Only that calendar is written; turning this off removes the events it made.")
            }
            ForEach(Array(events.prefix(6).enumerated()), id: \.offset) { _, e in
                HStack(spacing: 8) {
                    Text(e.allDay ? "all day" : e.start.formatted(date: .omitted, time: .shortened))
                        .font(Theme.number(11.5, weight: .semibold)).foregroundStyle(e.end < .now ? Theme.textTertiary : Theme.accent)
                        .frame(width: 64, alignment: .leading)
                    Text(e.title).font(.system(size: 12.5)).lineLimit(1).foregroundStyle(e.end < .now ? Theme.textTertiary : Theme.textPrimary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var proof: some View {
        let per = Dictionary(grouping: coach.commits, by: \.project).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Proof · \(coach.commits.count) commit\(coach.commits.count == 1 ? "" : "s") today")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            if per.isEmpty { Text("Commits you make today show up here").font(.system(size: 12)).foregroundStyle(Theme.textTertiary) }
            ForEach(per.prefix(4), id: \.0) { name, n in
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.safe).font(.system(size: 11))
                    Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("\(n)").font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
            }
            if let latest = coach.commits.first {
                Text("Latest: \(latest.subject)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The coach's plan: tick what you want, Add puts it on the day. Nothing is added without you.
struct CoachSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var suggestion: LifeCoach.Suggestion
    @State private var picked: Set<String> = []
    @State private var pickedBlocks: Set<BlockSuggestion> = []
    @State private var pickedMemory: Set<String> = []
    @State private var setTop = true

    var body: some View {
        let plan = suggestion.plan
        let tomorrow = suggestion.day != Planner.key(.now)
        VStack(alignment: .leading, spacing: 16) {
            Text(suggestion.moment == .morning ? "Your plan for today" : suggestion.moment == .week ? "Your week, honestly"
                 : suggestion.moment == .dump ? "From your brain dump" : "Today, and tomorrow's plan")
                .font(.system(size: 18, weight: .bold, design: .rounded))
            if !plan.note.isEmpty {
                Text(plan.note).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if !plan.recommendations.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "Recommendations")
                    ForEach(plan.recommendations, id: \.self) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.system(size: 13, weight: .semibold))
                            Text(r.why).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !plan.big.isEmpty { group("Big 3", plan.big, big: true) }
            if !plan.tasks.isEmpty { group("Also", plan.tasks, big: false) }
            if !plan.blocks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "Time blocks")
                    ForEach(plan.blocks, id: \.self) { b in
                        Toggle(isOn: Binding(get: { pickedBlocks.contains(b) }, set: { if $0 { pickedBlocks.insert(b) } else { pickedBlocks.remove(b) } })) {
                            HStack(spacing: 8) {
                                Text("\(b.day.flatMap { Planner.date($0)?.formatted(.dateTime.weekday(.abbreviated)) }.map { $0 + " " } ?? "")\(b.start)–\(b.end)")
                                    .font(Theme.number(12, weight: .semibold)).foregroundStyle(Theme.accent)
                                Text(b.title).font(.system(size: 13))
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            if let top = plan.top {
                Toggle(isOn: $setTop) {
                    Text("Make **\(top)** \(tomorrow ? "tomorrow's" : "today's") top thing").font(.system(size: 13))
                }
                .toggleStyle(.checkbox)
            }
            if !plan.remember.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "Remember about you")
                    ForEach(plan.remember, id: \.self) { line in
                        Toggle(isOn: Binding(get: { pickedMemory.contains(line) }, set: { if $0 { pickedMemory.insert(line) } else { pickedMemory.remove(line) } })) {
                            Text(line).font(.system(size: 13))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            HStack {
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(addLabel(tomorrow: tomorrow)) {
                    var placed = 0
                    model.plan { p in
                        p.accept(big: plan.big.filter(picked.contains), tasks: plan.tasks.filter(picked.contains), day: suggestion.day)
                        placed = p.acceptBlocks(plan.blocks.filter(pickedBlocks.contains), day: suggestion.day)
                    }
                    if !pickedMemory.isEmpty { CoachMemory().remember(plan.remember.filter(pickedMemory.contains)) }
                    if setTop, let top = plan.top,
                       let task = model.planner.tasks.first(where: { !$0.isDone && $0.title.caseInsensitiveCompare(top) == .orderedSame }),
                       model.planner.log(on: suggestion.day)?.top != task.id {
                        model.setTopThing(task, day: suggestion.day)
                    }
                    let skipped = pickedBlocks.count - placed
                    model.show("Added \(picked.count + placed)" + (skipped > 0 ? " · \(skipped) block\(skipped == 1 ? "" : "s") clashed and stayed out" : ""))
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty && pickedBlocks.isEmpty && pickedMemory.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { picked = Set(plan.big + plan.tasks); pickedBlocks = Set(plan.blocks) }
    }

    func addLabel(tomorrow: Bool) -> String {
        let n = picked.count + pickedBlocks.count + pickedMemory.count
        if suggestion.moment == .week { return "Add \(n) to the Week" }
        return "Add \(n) to \(tomorrow ? "Tomorrow" : "Today")"
    }

    func group(_ title: String, _ items: [String], big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: title)
            ForEach(items, id: \.self) { item in
                Toggle(isOn: Binding(get: { picked.contains(item) },
                                     set: { if $0 { picked.insert(item) } else { picked.remove(item) } })) {
                    HStack(spacing: 6) {
                        if big { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.accent) }
                        Text(item).font(.system(size: 13))
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

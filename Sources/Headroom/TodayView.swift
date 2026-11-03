import SwiftUI
import AppKit
import HeadroomCore

/// XP just earned: what the notch and the Today screen flash for a moment (the "satisfying" law — the
/// reward has to come right away, not at the end of the week).
struct PlannerReward: Identifiable, Equatable {
    var id = UUID()
    var xp: Int
    var levelUp: Int?
}

extension AppModel {
    /// Every change re-reads planner.json first (the CLI may have written it), then saves.
    @discardableResult
    func plan<T>(_ change: (inout Planner) -> T) -> T {
        if Self.demoMode { return change(&planner) }
        let (fresh, result, modified) = PlannerStore.mutate(change)
        planner = fresh
        plannerRead = modified
        return result
    }

    /// Picks up writes from `headroom-cli` (you or Claude Code) — called from the 30 s tick and when a
    /// planner view appears.
    func reloadPlannerIfChanged() {
        guard !Self.demoMode, let modified = PlannerStore.modified(), modified != plannerRead else { return }
        planner = PlannerStore.load()
        plannerRead = modified
    }

    /// Adds a task; returns why it couldn't be big, if it asked to be (the caller shows it where you're looking).
    @discardableResult
    func addTask(_ title: String, big: Bool, day: String? = Planner.key(.now), source: PlannerTask.Source = .app) -> String? {
        let capture = Planner.parseCapture(title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !capture.title.isEmpty else { return nil }
        let task = plan { $0.add(capture.title, day: day, big: big, effort: capture.effort, area: capture.area, source: source) }
        guard big && !task.big else { return nil }
        return day == nil ? "Added to the inbox — plan it for a day to make it big" : "Three big ones already — added as an ordinary task"
    }

    func toggleTask(_ task: PlannerTask) {
        reward { $0.complete(task.id) }
    }

    func toggleHabit(_ habit: Habit) {
        if habit.kind == .avoid { plan { $0.toggleSlip(habit.id) }; return }
        reward { $0.toggleHabit(habit.id) }
    }

    /// Checks off timed habits whose minutes are met (from the timeline and focus sessions), once each.
    func applyQuests(_ minutes: [UUID: Int]) {
        guard !minutes.isEmpty, model(planner, meets: minutes) else { return }
        var met: [Habit] = []
        reward { met = $0.applyQuotas(minutes) }
        for h in met { show("Quest complete: \(h.title)") }
    }

    private func model(_ p: Planner, meets minutes: [UUID: Int]) -> Bool {
        let today = Planner.key(.now)
        return p.habits.contains { h in h.isTimed && !h.done.contains(today) && (minutes[h.id] ?? 0) >= (h.minutes ?? .max) }
    }

    /// Minutes today toward each timed habit.
    func questMinutes(_ timeline: ActivityRecorder) -> [UUID: Int] {
        let today = Planner.key(.now)
        let sessions = planner.sessions.filter { Planner.key($0.start) == today }
        var out: [UUID: Int] = [:]
        for h in planner.habits where h.isTimed && !h.archived {
            out[h.id] = Quests.minutes(h.track!, spans: timeline.allToday, sessions: sessions, tasks: planner.tasks, classifier: timeline.classifier)
        }
        return out
    }

    /// Proof habits ("a commit checks this off") met by today's commits, once each.
    func applyProof(_ commits: [Commit]) {
        let key = Planner.key(.now)
        guard planner.habits.contains(where: { h in h.proof != nil && !h.done.contains(key) && commits.contains { h.proof!.matches($0) } }) else { return }
        var met: [Habit] = []
        reward { met = $0.applyProof(commits) }
        for h in met { show("Proof: \(h.title) checked off by your commit") }
    }

    /// Focus found in the timeline (40+ minutes in one project, no distraction) becomes a focus session.
    func recordDetectedFocus(_ stretches: [FocusStretch]) {
        guard stretches.contains(where: { st in !planner.sessions.contains { $0.start < st.end && ($0.end ?? .distantFuture) > st.start } }) else { return }
        var added: [FocusSession] = []
        reward { added = $0.recordDetectedFocus(stretches) }
        if let first = added.first { show("Focus found: \(first.minutes()) min on \(first.title.replacingOccurrences(of: "Deep work · ", with: ""))") }
    }

    /// Today's journal and check-in.
    func updateLog(_ day: String = Planner.key(.now), _ change: (inout DayLog) -> Void) {
        reward { $0.updateLog(day, change) }
    }

    func startFocus(_ title: String, task: PlannerTask? = nil) {
        reward { _ = $0.startFocus(title, taskID: task?.id) } // ending a running session can pay out
    }

    func stopFocus() {
        reward { _ = $0.stopFocus() }
    }

    func buy(_ r: Reward) {
        switch plan({ $0.buy(r.id) }) {
        case .bought: show("Enjoy it: \(r.title)")
        case .short(let n): show("\(n) coins short — keep going")
        case .missing: break
        }
    }

    /// Runs a change and flashes the XP it earned (nothing for undoing).
    private func reward(_ change: (inout Planner) -> Void) {
        // Both counts come from the same fresh read, so a CLI write in between can't inflate the flash.
        let (before, after) = plan { p -> (Int, Int) in
            let before = p.xp()
            change(&p)
            return (before, p.xp())
        }
        guard after > before else { return }
        let old = Planner.level(for: before).number, new = Planner.level(for: after).number
        withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
            plannerReward = PlannerReward(xp: after - before, levelUp: new > old ? new : nil)
        }
        let id = plannerReward?.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if plannerReward?.id == id { withAnimation(.easeOut(duration: 0.3)) { plannerReward = nil } }
        }
    }
}

/// The Today screen: the Big 3, everything else for today, habits, and what you're becoming.
struct TodayView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshot
    @State private var newBig = ""
    @State private var newTask = ""
    @State private var editingHabit: HabitDraft?

    var p: Planner { model.planner }

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 14) {
                header
                if LifeCoach.shared.available { CoachCard() }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        bigThree
                        alsoToday
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        DayLogCard()
                        habits
                        later
                    }
                    .frame(width: 380)
                }
            }
        }
        .overlay(alignment: .top) { RewardBurst(reward: model.plannerReward).padding(.top, 60) }
        .onAppear { model.reloadPlannerIfChanged() }
        .sheet(item: $editingHabit) { draft in
            HabitEditor(draft: draft) { saved in
                model.plan { p in
                    if let i = p.habits.firstIndex(where: { $0.id == saved.id }) { p.habits[i] = saved } else { p.habits.append(saved) }
                }
            } archive: { id in
                model.plan { p in if let i = p.habits.firstIndex(where: { $0.id == id }) { p.habits[i].archived = true } }
            }
        }
    }

    // MARK: Header

    var header: some View {
        let level = Planner.level(for: p.xp())
        let today = p.today()
        let build = p.habitsDue().filter { $0.kind == .build }
        let doneCount = today.filter(\.isDone).count + build.filter { $0.isDone() }.count
        let total = today.count + build.count
        return Card {
            HStack(alignment: .center, spacing: 22) {
                ZStack {
                    GaugeRing(fraction: total > 0 ? Double(doneCount) / Double(total) : 0, tint: Theme.safe, lineWidth: 10)
                    VStack(spacing: 0) {
                        Text("\(doneCount)/\(total)").font(Theme.number(20, weight: .bold))
                        Text("done").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 86, height: 86)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Level \(level.number)").font(.system(size: 22, weight: .bold, design: .rounded))
                        Text(Planner.rank(for: level.number).title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text("\(level.into) / \(level.needed) XP").font(Theme.number(12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        Spacer(minLength: 8)
                        Label(p.coins().formatted(), systemImage: "circle.hexagongrid.fill").font(Theme.number(13, weight: .semibold))
                            .foregroundStyle(Theme.review).help("Coins: earned with XP, spent on rewards you choose (Progress).")
                    }
                    SegmentedBar(segments: [.init(id: "xp", value: Double(level.into), color: Theme.safe)], total: Double(level.needed), height: 8)
                        .frame(maxWidth: 360)
                    FocusBar()
                    let votes = p.votes()
                    if !votes.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(votes.prefix(3), id: \.identity) { v in
                                Badge(text: "\(v.votes) vote\(v.votes == 1 ? "" : "s") for being \(v.identity)", color: Theme.accent)
                            }
                        }
                        .help("Every habit you check off is a vote for the person you want to be.")
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Tasks

    var bigThree: some View {
        let big = p.bigToday()
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Big 3", trailing: "\(big.filter(\.isDone).count) of \(big.count) done")
                ForEach(big) { t in TaskRow(task: t) }
                if big.count < Planner.bigLimit {
                    ForEach(0..<(Planner.bigLimit - big.count - 1), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.fill(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .frame(height: 36)
                    }
                    if !snapshot {
                        addField($newBig, prompt: big.isEmpty ? "What matters most today?" : "Another one that matters") {
                            if let why = model.addTask(newBig, big: true) { model.show(why) }
                            newBig = ""
                        }
                    }
                }
            }
        }
    }

    var alsoToday: some View {
        let others = p.today().filter { !$0.big }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Also today", trailing: others.isEmpty ? nil : "\(others.filter { !$0.isDone }.count) open")
                ForEach(others) { t in TaskRow(task: t) }
                if !snapshot { addField($newTask, prompt: "Add a task  (⌃⌥N from anywhere)") { model.addTask(newTask, big: false); newTask = "" } }
            }
        }
    }

    func addField(_ text: Binding<String>, prompt: String, submit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").foregroundStyle(Theme.textTertiary).font(.system(size: 12, weight: .semibold))
            TextField(prompt, text: text).textFieldStyle(.plain).font(.system(size: 13)).onSubmit(submit)
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.04)))
    }

    // MARK: Habits

    var habits: some View {
        let due = p.habitsDue()
        let resting = p.habits.filter { !$0.archived && !$0.isScheduled(.now) }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(title: "Habits")
                    Button { editingHabit = HabitDraft() } label: { Label("New", systemImage: "plus") }.buttonStyle(GhostButtonStyle())
                }
                if p.habits.filter({ !$0.archived }).isEmpty {
                    Text("Start tiny. A habit is who you're becoming, one vote at a time — pick something you can do in two minutes on a bad day.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(due) { h in HabitRow(habit: h) { editingHabit = HabitDraft(h) } }
                if !resting.isEmpty {
                    Text("Not planned today: " + resting.map(\.title).joined(separator: ", "))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    var later: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Later", trailing: p.inbox.isEmpty ? nil : "\(p.inbox.count) in the inbox")
                let upcoming = p.upcoming().prefix(6)
                if upcoming.isEmpty && p.inbox.isEmpty {
                    Text("Nothing planned past today.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(Array(upcoming)) { t in TaskRow(task: t, compact: true) }
                ForEach(p.inbox.prefix(6)) { t in TaskRow(task: t, compact: true) }
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    var task: PlannerTask
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            Button { model.toggleTask(task) } label: { CheckCircle(on: task.isDone, tint: task.big ? Theme.review : Theme.accent) }
                .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.system(size: compact ? 12.5 : 13.5, weight: task.big ? .semibold : .regular))
                    .strikethrough(task.isDone).foregroundStyle(task.isDone ? Theme.textTertiary : Theme.textPrimary).lineLimit(2)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
            }
            Spacer(minLength: 4)
            if model.planner.runningSession?.taskID == task.id {
                Image(systemName: "timer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.safe).help("Focusing on this")
            }
            if !task.isDone && !compact {
                Text("+\(task.xp)").font(Theme.number(10.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    .help("XP for finishing it (effort \(task.effort)\(task.big ? ", one of the Big 3" : ""))")
            }
            if task.big { Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Theme.review) }
        }
        .padding(.vertical, compact ? 2 : 4)
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    var detail: String? {
        var parts: [String] = []
        if let day = task.day, day > Planner.key(.now), let d = Planner.date(day) { parts.append(d.formatted(.dateTime.weekday(.wide).day().month())) }
        if task.day == nil { parts.append("Inbox") }
        if let area = task.area { parts.append(area) }
        if let project = task.project { parts.append(project) }
        if task.source == .claude || task.source == .cli { parts.append(task.source == .claude ? "from Claude" : "from the terminal") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder var menu: some View {
        let today = Planner.key(.now)
        if task.day != today { Button("Do Today") { model.plan { $0.schedule(task.id, day: today) } } }
        Button("Move to Tomorrow") { model.plan { $0.schedule(task.id, day: Planner.key(daysFrom: .now, 1)) } }
        if task.day != nil {
            if task.big {
                Button("Not One of the Big 3") { model.plan { _ = $0.setBig(task.id, false) } }
            } else {
                Button("Make It One of the Big 3") {
                    if !model.plan({ $0.setBig(task.id, true) }) { model.show("Three big ones already — finish or move one first") }
                }
            }
        }
        Button("Move to Inbox") { model.plan { $0.schedule(task.id, day: nil) } }
        Divider()
        if !task.isDone && model.planner.runningSession?.taskID != task.id {
            Button("Focus on This") { model.startFocus(task.title, task: task) }
        }
        Picker("Effort", selection: Binding(get: { task.effort }, set: { e in model.plan { $0.update(task.id) { $0.effort = e } } })) {
            Text("Easy  (+10)").tag(1); Text("Medium  (+20)").tag(2); Text("Hard  (+30)").tag(3)
        }
        let areas = model.planner.areas().map(\.name)
        if !areas.isEmpty {
            Picker("Area", selection: Binding(get: { task.area ?? "" }, set: { a in model.plan { $0.update(task.id) { $0.area = a.isEmpty ? nil : a } } })) {
                Text("None").tag("")
                ForEach(areas, id: \.self) { Text($0).tag($0) }
            }
        }
        Divider()
        Button("Delete Task", role: .destructive) { model.plan { $0.remove(task.id) } }
    }
}

struct HabitRow: View {
    @EnvironmentObject var model: AppModel
    var habit: Habit
    var edit: () -> Void

    var body: some View {
        if habit.kind == .avoid { avoidRow } else { buildRow }
    }

    /// A habit to break: clean days grow on their own; "Slipped" logs today without taking anything away.
    var avoidRow: some View {
        let slipped = habit.slipped()
        let clean = habit.cleanDays()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: slipped ? "arrow.counterclockwise.circle" : "shield.lefthalf.filled")
                .font(.system(size: 17)).foregroundStyle(slipped ? Theme.review : Theme.safe).frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(habit.title).font(.system(size: 13.5, weight: .medium))
                HStack(spacing: 4) {
                    ForEach(habit.recent(7), id: \.key) { d in
                        Circle().fill(habit.slips.contains(d.key) ? Theme.review.opacity(0.7) : d.scheduled && d.key < Planner.key(.now) ? Theme.safe : Theme.fill(0.08))
                            .frame(width: 7, height: 7)
                    }
                    Text(slipped ? "fresh start tomorrow" : clean == 0 ? "day one" : "\(clean) clean day\(clean == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(slipped ? Theme.review : Theme.textTertiary).padding(.leading, 4)
                }
            }
            Spacer(minLength: 0)
            Button(slipped ? "Undo" : "Slipped") { model.toggleHabit(habit) }
                .buttonStyle(GhostButtonStyle()).controlSize(.small)
                .help(slipped ? "Unlog today's slip" : "Log a slip — the clean run restarts; nothing you earned is taken away")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .contextMenu { Button("Edit Habit…", action: edit) }
    }

    var buildRow: some View {
        let done = habit.isDone()
        return HStack(alignment: .top, spacing: 10) {
            Button { model.toggleHabit(habit) } label: { CheckCircle(on: done) }.buttonStyle(.plain).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(habit.title).font(.system(size: 13.5, weight: .medium))
                if !done, let line = nudge { Text(line).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(2) }
                HStack(spacing: 4) {
                    ForEach(habit.recent(7), id: \.key) { d in
                        Circle().fill(d.done ? Theme.safe : d.scheduled ? Theme.fill(0.12) : Theme.fill(0.04)).frame(width: 7, height: 7)
                    }
                    Text(streakText).font(.system(size: 11)).foregroundStyle(streakColor).padding(.leading, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .contextMenu { Button("Edit Habit…", action: edit) }
    }

    /// Make it obvious (the cue) and easy (the two-minute version).
    var nudge: String? {
        [habit.cue.map { $0.prefix(1).uppercased() + $0.dropFirst() }, habit.twoMinute.map { "or just: \($0)" }]
            .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    var streakText: String {
        switch habit.streak() {
        case .going(let n): "\(n) day\(n == 1 ? "" : "s")"
        case .missedOnce(let n): "\(n) day\(n == 1 ? "" : "s") · never miss twice — today counts"
        case .none: "fresh start"
        }
    }

    var streakColor: Color {
        if case .missedOnce = habit.streak() { return Theme.review }
        return Theme.textTertiary
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// "+30 XP" popping up where you'll see it; "Level 4" when a level is reached.
struct RewardBurst: View {
    var reward: PlannerReward?

    var body: some View {
        if let reward {
            HStack(spacing: 6) {
                Image(systemName: reward.levelUp == nil ? "sparkles" : "trophy.fill")
                Text(reward.levelUp.map { "Level \($0)!" } ?? "+\(reward.xp) XP")
            }
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(reward.levelUp == nil ? Theme.safe : Theme.review))
            .shadow(color: Theme.safe.opacity(0.4), radius: 12, y: 4)
            .transition(.scale(scale: 0.5).combined(with: .opacity).combined(with: .offset(y: 12)))
            .id(reward.id)
        }
    }
}

// MARK: Habit editor

struct HabitDraft: Identifiable {
    var habit: Habit
    var isNew: Bool
    var id: UUID { habit.id }
    init() { habit = Habit(title: ""); isNew = true }
    init(_ h: Habit) { habit = h; isNew = false }
}

struct HabitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: HabitDraft
    var save: (Habit) -> Void
    var archive: (UUID) -> Void
    @State private var remind = false
    @State private var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now

    init(draft: HabitDraft, save: @escaping (Habit) -> Void, archive: @escaping (UUID) -> Void) {
        _draft = State(initialValue: draft)
        self.save = save
        self.archive = archive
        if let m = draft.habit.remindAt {
            _remind = State(initialValue: true)
            _time = State(initialValue: Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: .now) ?? .now)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.isNew ? "New habit" : "Edit habit").font(.system(size: 17, weight: .bold))
            Picker("", selection: $draft.habit.kind) {
                Text("Build a habit").tag(Habit.Kind.build)
                Text("Break a habit").tag(Habit.Kind.avoid)
            }
            .pickerStyle(.segmented).labelsHidden()
            field("Habit", draft.habit.kind == .avoid ? "Doomscrolling in bed" : "Write 300 words", \.title)
            field("Area", "Health, Work, Writing…", \.area, help: "Its XP also levels this area of your life (see Progress).")
            if draft.habit.kind == .build { timeTarget; proofToggle }
            field("Who it makes you", "a writer", \.identity, help: "Every time you do it is a vote for being this person.")
            field("When (the cue)", "after my morning coffee", \.cue, help: "Stack it on something you already do.")
            field("Two-minute version", "write one sentence", \.twoMinute, help: "What counts on a bad day — showing up beats skipping.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Days").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    ForEach(Array(zip([2, 3, 4, 5, 6, 7, 1], ["M", "T", "W", "T", "F", "S", "S"])), id: \.0) { day, letter in
                        let on = draft.habit.weekdays.isEmpty || draft.habit.weekdays.contains(day)
                        Button {
                            var days = draft.habit.weekdays.isEmpty ? Set(1...7) : draft.habit.weekdays
                            if days.contains(day) { days.remove(day) } else { days.insert(day) }
                            draft.habit.weekdays = days.count == 7 ? [] : days
                        } label: {
                            Text(letter).font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                                .background(Circle().fill(on ? Theme.accent.opacity(0.85) : Theme.fill(0.06)))
                                .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Toggle("Nudge me at", isOn: $remind)
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().disabled(!remind)
            }
            HStack {
                if !draft.isNew {
                    Button("Archive", role: .destructive) { archive(draft.habit.id); dismiss() }.buttonStyle(GhostButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add Habit" : "Save") {
                    var h = draft.habit
                    h.title = h.title.trimmingCharacters(in: .whitespaces)
                    if h.track?.isEmpty == true { h.minutes = nil; h.track = nil }
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    h.remindAt = remind ? (c.hour ?? 9) * 60 + (c.minute ?? 0) : nil
                    save(h)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.habit.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }

    /// "Marketing · Magicteams — 4 h a day": checked off by itself when the timeline (and focus sessions) reach it.
    var timeTarget: some View {
        let timed = Binding(get: { draft.habit.minutes != nil },
                            set: { on in
                                draft.habit.minutes = on ? 60 : nil
                                draft.habit.track = on ? (draft.habit.track ?? QuotaTrack()) : nil
                            })
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Daily time target — fills in from what you do", isOn: timed)
            if let m = draft.habit.minutes {
                Stepper("\(Minutes.text(Double(m) * 60)) a day", value: Binding(get: { m }, set: { draft.habit.minutes = $0 }), in: 15...720, step: 15)
                HStack(spacing: 8) {
                    TextField("Project (e.g. Magicteams)", text: Binding(get: { draft.habit.track?.project ?? "" },
                                                                          set: { draft.habit.track?.project = $0.nilIfEmpty }))
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: Binding(get: { draft.habit.track?.category }, set: { draft.habit.track?.category = $0 })) {
                        Text("Any kind of work").tag(ActivityCategory?.none)
                        ForEach(ActivityCategory.allCases, id: \.self) { Text($0.title).tag(ActivityCategory?.some($0)) }
                    }
                    .labelsHidden().frame(width: 170)
                }
                Text("Counts time on that project (from window titles, sites you assign, Claude Code and focus sessions) and/or that kind of work. Turn on the Timeline for it to see the Mac.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Commit something": checked off by the first commit of the day (any project, or one).
    var proofToggle: some View {
        let on = Binding(get: { draft.habit.proof != nil }, set: { draft.habit.proof = $0 ? (draft.habit.proof ?? HabitProof()) : nil })
        return VStack(alignment: .leading, spacing: 6) {
            Toggle("Checked off by a commit of yours", isOn: on)
            if draft.habit.proof != nil {
                TextField("Project (empty = any repository)", text: Binding(get: { draft.habit.proof?.project ?? "" },
                                                                          set: { draft.habit.proof?.project = $0.nilIfEmpty }))
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    func field(_ label: String, _ prompt: String, _ key: WritableKeyPath<Habit, String>, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            TextField(prompt, text: Binding(get: { draft.habit[keyPath: key] }, set: { draft.habit[keyPath: key] = $0 }))
                .textFieldStyle(.roundedBorder)
            if let help { Text(help).font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
        }
    }

    func field(_ label: String, _ prompt: String, _ key: WritableKeyPath<Habit, String?>, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
            TextField(prompt, text: Binding(get: { draft.habit[keyPath: key] ?? "" },
                                            set: { draft.habit[keyPath: key] = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
            if let help { Text(help).font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
        }
    }
}

/// Seeded tasks and habits for `--demo` renders.
enum PlannerDemo {
    static func planner(now: Date = .now) -> Planner {
        var p = Planner()
        let today = Planner.key(now)
        let ship = p.add("Ship the planner add-on", day: today, big: true, project: "Headroom", effort: 3, area: "Work", now: now)
        let reel = p.add("Record the demo reel", day: today, big: true, project: "Headroom", effort: 2, area: "Work", now: now)
        p.add("Write the launch post", day: today, big: true, effort: 2, area: "Writing", now: now)
        let mail = p.add("Reply to Arthur", day: today, area: "Work", now: now)
        p.add("Review Claude's PR on drives", day: today, project: "Headroom", effort: 2, area: "Work", source: .claude, now: now)
        p.add("Book dentist", day: Planner.key(daysFrom: now, 1), area: "Health", now: now)
        p.add("Try the Calendar idea", day: nil, now: now)
        p.complete(ship.id, at: now)
        p.complete(mail.id, at: now)
        // A few weeks of history, so the level, areas and log look lived-in.
        for back in 1...24 {
            let day = now.addingTimeInterval(-Double(back) * 86_400)
            let t = p.add(["Plan the week", "Fix the drives bug", "Gym", "Read 30 pages", "Draft the newsletter"][back % 5],
                          day: Planner.key(day), effort: back % 3 + 1, area: ["Work", "Work", "Health", "Learning", "Writing"][back % 5], now: day)
            p.complete(t.id, at: day)
            var s = FocusSession(title: "Deep work", start: day.addingTimeInterval(-3 * 3600), area: back % 2 == 0 ? "Work" : "Writing")
            s.end = s.start.addingTimeInterval(Double(60 + back % 4 * 20) * 60)
            p.sessions.append(s)
        }
        var focus = FocusSession(title: "Record the demo reel", start: now.addingTimeInterval(-26 * 60 - 14), taskID: reel.id, area: "Work")
        p.sessions.append(focus)
        p.rewards = [Reward(title: "Coffee at the good place", cost: 150, created: now), Reward(title: "Dinner out", cost: 800, created: now),
                     Reward(title: "New mechanical keyboard", cost: 4000, created: now)]
        p.purchases = [Purchase(rewardID: p.rewards[0].id, title: "Coffee at the good place", cost: 150, date: now.addingTimeInterval(-3 * 86_400))]
        var write = Habit(title: "Write 300 words", identity: "a writer", cue: "after morning coffee", twoMinute: "write one sentence",
                          remindAt: 9 * 60, created: now.addingTimeInterval(-40 * 86_400))
        write.done = Set((0..<12).filter { $0 != 4 }.map { Planner.key(daysFrom: now, -$0) })
        var walk = Habit(title: "Walk 20 minutes", identity: "someone who moves", cue: "after lunch", twoMinute: "walk to the end of the street",
                         created: now.addingTimeInterval(-40 * 86_400))
        walk.done = Set([2, 3, 5, 6, 7].map { Planner.key(daysFrom: now, -$0) })
        var ship2 = Habit(title: "Commit something", identity: "someone who ships", twoMinute: "fix one typo", created: now.addingTimeInterval(-40 * 86_400))
        ship2.proof = HabitProof()
        ship2.done = Set((1..<20).map { Planner.key(daysFrom: now, -$0) })
        write.area = "Writing"; walk.area = "Health"; ship2.area = "Work"
        var scroll = Habit(title: "No phone in bed", identity: "someone who sleeps well", created: now.addingTimeInterval(-20 * 86_400))
        scroll.kind = .avoid
        scroll.area = "Health"
        scroll.slips = [Planner.key(daysFrom: now, -9)]
        var marketing = Habit(title: "Marketing · magicteams", identity: "a founder who sells", created: now.addingTimeInterval(-20 * 86_400))
        marketing.minutes = 240
        marketing.track = QuotaTrack(project: "magicteams")
        marketing.area = "Work"
        marketing.done = Set([1, 2, 4, 5].map { Planner.key(daysFrom: now, -$0) })
        p.habits = [marketing, write, walk, ship2, scroll]
        var found = FocusSession(title: "Deep work · magicteams", start: now.addingTimeInterval(-4 * 3600), area: "Work")
        found.end = found.start.addingTimeInterval(72 * 60)
        found.detected = true
        p.sessions.append(found)
        for back in 1...12 {
            p.updateLog(Planner.key(daysFrom: now, -back), now: now) { l in
                l.mood = [4, 3, 4, 5, 2, 4, 3][back % 7]; l.energy = [3, 3, 4, 4, 2, 5, 3][back % 7]
                l.note = "Shipped the front desk flow and called two clinics — felt good to sell."
            }
        }
        p.updateLog(today, now: now) { l in
            l.mood = 4; l.energy = 3
            l.note = "Good morning on outreach, the demo call went well. Slumped after lunch and lost 40 minutes to YouTube."
            l.reflection = "The demo landing right after a focused outreach block isn't luck — your best days start with marketing before noon. The afternoon slump follows short nights; last night was 6h10. What would make tomorrow's first two hours as protected as today's?"
        }
        p.season = Season(start: Planner.key(daysFrom: now, -3), end: Planner.key(daysFrom: now, 10),
                          main: .init(project: "magicteams", hoursPerWeek: 20),
                          sides: [.init(project: "Headroom", hoursPerWeek: 8), .init(project: "flare-forge", hoursPerWeek: 4)])
        p.challenges = [Challenge(title: "Write 20× in 30 days", habitID: write.id, target: 20, start: Planner.key(daysFrom: now, -12), end: Planner.key(daysFrom: now, 17)),
                        Challenge(title: "Commit something 14× in 14 days", habitID: ship2.id, target: 14, start: Planner.key(daysFrom: now, -16), end: Planner.key(daysFrom: now, -3))]
        return p
    }
}

/// The notch's Today tab: the Big 3 and today's habits, each one click from done.
struct NotchTodayView: View {
    @EnvironmentObject var model: AppModel
    var notchHeight: CGFloat
    var openToday: () -> Void

    var body: some View {
        let p = model.planner
        let tasks = p.today()
        // Three rows fit: the Big 3 first, then whatever else is open today.
        let shown = Array(tasks.prefix(3))
        let more = tasks.count - shown.count
        let habits = p.habitsDue()
        let shownHabits = Array(habits.prefix(3))
        let level = Planner.level(for: p.xp())
        let build = habits.filter { $0.kind == .build }
        let done = p.today().filter(\.isDone).count + build.filter { $0.isDone() }.count
        let total = p.today().count + build.count
        VStack(alignment: .leading, spacing: 10) {
            Spacer().frame(height: notchHeight - 4)
            HStack(spacing: 10) {
                GaugeRing(fraction: total > 0 ? Double(done) / Double(total) : 0, tint: Theme.safe, lineWidth: 4)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(total == 0 ? "Nothing planned yet" : "\(done) of \(total) done today").font(.system(size: 13, weight: .semibold))
                    if let s = p.runningSession {
                        HStack(spacing: 4) {
                            Image(systemName: "timer").font(.system(size: 9.5, weight: .bold))
                            FocusClock(start: s.start, size: 10.5)
                            Text("· \(s.title)").font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                        }
                        .foregroundStyle(Theme.safe)
                    } else {
                        Text("\(Planner.rank(for: level.number).title) · Level \(level.number) · \(level.into)/\(level.needed) XP · \(p.coins()) coins")
                            .font(Theme.number(10.5, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                }
                Spacer()
                if p.runningSession != nil {
                    Button("Stop") { model.stopFocus() }.buttonStyle(GhostButtonStyle())
                } else if let next = tasks.first(where: { !$0.isDone }) {
                    Button { model.startFocus(next.title, task: next) } label: { Image(systemName: "timer") }
                        .buttonStyle(GhostButtonStyle()).help("Focus on “\(next.title)”")
                }
                Button(action: openToday) { Label("Today", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(GhostButtonStyle())
            }
            VStack(alignment: .leading, spacing: 4) {
                if tasks.isEmpty {
                    Text("Pick up to three things that matter today — ⌃⌥N adds one from anywhere.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(height: 24)
                }
                ForEach(shown) { t in
                    Button { model.toggleTask(t) } label: {
                        HStack(spacing: 8) {
                            CheckCircle(on: t.isDone, tint: t.big ? Theme.review : Theme.accent)
                            Text(t.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                .strikethrough(t.isDone).foregroundStyle(t.isDone ? Theme.textTertiary : Theme.textPrimary)
                            if t.big { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Theme.review) }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if more > 0 {
                    Button(action: openToday) {
                        Text("+\(more) more today").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain).frame(height: 22)
                }
            }
            if !habits.isEmpty {
                HStack(spacing: 6) {
                    ForEach(shownHabits) { h in
                        let avoid = h.kind == .avoid
                        let on = avoid ? !h.slipped() : h.isDone()
                        Button { model.toggleHabit(h) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: avoid ? (on ? "shield.lefthalf.filled" : "arrow.counterclockwise") : on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(h.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Capsule().fill(on ? Theme.safe.opacity(0.22) : Theme.fill(0.08)))
                            .foregroundStyle(on ? Theme.safe : Theme.textSecondary)
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(h.twoMinute.map { "Two-minute version: \($0)" } ?? h.title)
                    }
                    if habits.count > shownHabits.count {
                        Text("+\(habits.count - shownHabits.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 22).padding(.bottom, 16)
        .overlay(alignment: .top) { RewardBurst(reward: model.plannerReward).padding(.top, notchHeight + 4) }
    }
}

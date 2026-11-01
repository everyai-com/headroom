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
        let (fresh, result) = PlannerStore.mutate(change)
        planner = fresh
        plannerRead = PlannerStore.modified()
        return result
    }

    /// Picks up writes from `headroom-cli` (you or Claude Code) — called from the 30 s tick and when a
    /// planner view appears.
    func reloadPlannerIfChanged() {
        guard !Self.demoMode, let modified = PlannerStore.modified(), modified != plannerRead else { return }
        planner = PlannerStore.load()
        plannerRead = modified
    }

    func addTask(_ title: String, big: Bool, day: String? = Planner.key(.now), source: PlannerTask.Source = .app) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let task = plan { $0.add(title, day: day, big: big, source: source) }
        if big && !task.big { show(day == nil ? "Added to the inbox — plan it for a day to make it big" : "Three big ones already — added as an ordinary task") }
    }

    func toggleTask(_ task: PlannerTask) {
        reward { $0.complete(task.id) }
    }

    func toggleHabit(_ habit: Habit) {
        reward { $0.toggleHabit(habit.id) }
    }

    /// Runs a change and flashes the XP it earned (nothing for undoing).
    private func reward(_ change: (inout Planner) -> Void) {
        let before = planner.xp()
        plan(change)
        let after = planner.xp()
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
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        bigThree
                        alsoToday
                    }
                    VStack(alignment: .leading, spacing: 14) {
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
        let doneCount = today.filter(\.isDone).count + p.habitsDue().filter { $0.isDone() }.count
        let total = today.count + p.habitsDue().count
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
                        Text("\(level.into) / \(level.needed) XP").font(Theme.number(12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                    SegmentedBar(segments: [.init(id: "xp", value: Double(level.into), color: Theme.safe)], total: Double(level.needed), height: 8)
                        .frame(maxWidth: 360)
                    Text(headline).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
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

    var headline: String {
        let open = p.bigToday().filter { !$0.isDone }
        if p.bigToday().isEmpty { return "What are the three things that would make today a good day?" }
        if open.isEmpty { return "All three big ones done. Anything else today is a bonus." }
        return "Next: \(open[0].title)"
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
                            model.addTask(newBig, big: true); newBig = ""
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
                if !snapshot { addField($newTask, prompt: "Add a task  (⌥N from anywhere)") { model.addTask(newTask, big: false); newTask = "" } }
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
        if let project = task.project { parts.append(project) }
        if task.source == .claude || task.source == .cli { parts.append(task.source == .claude ? "from Claude" : "from the terminal") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder var menu: some View {
        let today = Planner.key(.now)
        if task.day != today { Button("Do Today") { model.plan { $0.update(task.id) { $0.day = today } } } }
        Button("Move to Tomorrow") { model.plan { $0.update(task.id) { $0.day = Planner.key(daysFrom: .now, 1); $0.big = false } } }
        if task.day != nil {
            if task.big {
                Button("Not One of the Big 3") { model.plan { $0.update(task.id) { $0.big = false } } }
            } else {
                Button("Make It One of the Big 3") {
                    let ok = model.plan { p -> Bool in
                        guard p.canMakeBig(on: task.day ?? today) else { return false }
                        p.update(task.id) { $0.big = true }
                        return true
                    }
                    if !ok { model.show("Three big ones already — finish or move one first") }
                }
            }
        }
        Button("Move to Inbox") { model.plan { $0.update(task.id) { $0.day = nil; $0.big = false } } }
        Divider()
        Button("Delete Task", role: .destructive) { model.plan { $0.remove(task.id) } }
    }
}

struct HabitRow: View {
    @EnvironmentObject var model: AppModel
    var habit: Habit
    var edit: () -> Void

    var body: some View {
        let done = habit.isDone()
        HStack(alignment: .top, spacing: 10) {
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
        case .missedOnce: "never miss twice — today counts"
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
            field("Habit", "Write 300 words", \.title)
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
        let ship = p.add("Ship the planner add-on", day: today, big: true, project: "Headroom", now: now)
        p.add("Record the demo reel", day: today, big: true, project: "Headroom", now: now)
        p.add("Write the launch post", day: today, big: true, now: now)
        let mail = p.add("Reply to Arthur", day: today, now: now)
        p.add("Review Claude's PR on drives", day: today, project: "Headroom", source: .claude, now: now)
        p.add("Book dentist", day: Planner.key(daysFrom: now, 1), now: now)
        p.add("Try the Calendar idea", day: nil, now: now)
        p.complete(ship.id, at: now)
        p.complete(mail.id, at: now)
        var write = Habit(title: "Write 300 words", identity: "a writer", cue: "after morning coffee", twoMinute: "write one sentence",
                          remindAt: 9 * 60, created: now.addingTimeInterval(-40 * 86_400))
        write.done = Set((0..<12).filter { $0 != 4 }.map { Planner.key(daysFrom: now, -$0) })
        var walk = Habit(title: "Walk 20 minutes", identity: "someone who moves", cue: "after lunch", twoMinute: "walk to the end of the street",
                         created: now.addingTimeInterval(-40 * 86_400))
        walk.done = Set([2, 3, 5, 6, 7].map { Planner.key(daysFrom: now, -$0) })
        var ship2 = Habit(title: "Commit something", identity: "someone who ships", twoMinute: "fix one typo", created: now.addingTimeInterval(-40 * 86_400))
        ship2.done = Set((1..<20).map { Planner.key(daysFrom: now, -$0) })
        p.habits = [write, walk, ship2]
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
        let big = p.bigToday()
        let habits = p.habitsDue()
        let level = Planner.level(for: p.xp())
        let done = p.today().filter(\.isDone).count + habits.filter { $0.isDone() }.count
        let total = p.today().count + habits.count
        VStack(alignment: .leading, spacing: 10) {
            Spacer().frame(height: notchHeight - 4)
            HStack(spacing: 10) {
                GaugeRing(fraction: total > 0 ? Double(done) / Double(total) : 0, tint: Theme.safe, lineWidth: 4)
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(total == 0 ? "Nothing planned yet" : "\(done) of \(total) done today").font(.system(size: 13, weight: .semibold))
                    Text("Level \(level.number) · \(level.into)/\(level.needed) XP").font(Theme.number(10.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Button(action: openToday) { Label("Today", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(GhostButtonStyle())
            }
            VStack(alignment: .leading, spacing: 4) {
                if big.isEmpty {
                    Text("Pick up to three things that matter today — ⌥N adds one from anywhere.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(height: 24)
                }
                ForEach(big.prefix(3)) { t in
                    Button { model.toggleTask(t) } label: {
                        HStack(spacing: 8) {
                            CheckCircle(on: t.isDone, tint: Theme.review)
                            Text(t.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                .strikethrough(t.isDone).foregroundStyle(t.isDone ? Theme.textTertiary : Theme.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if !habits.isEmpty {
                HStack(spacing: 6) {
                    ForEach(habits.prefix(4)) { h in
                        let on = h.isDone()
                        Button { model.toggleHabit(h) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 11, weight: .semibold))
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
                    Spacer(minLength: 0)
                }
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 22).padding(.bottom, 16)
        .overlay(alignment: .top) { RewardBurst(reward: model.plannerReward).padding(.top, notchHeight + 4) }
    }
}

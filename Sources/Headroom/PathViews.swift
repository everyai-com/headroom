import SwiftUI
import HeadroomCore

// Today's spine: a setup card until the system is in place, then the day as one path with exactly one next step
// and one primary button, and the evening as one ritual sheet instead of five cards.

// MARK: - Setup

/// The system, set up once: vision, season, calendar, blocks on the phone, routines, the pause shield.
struct SetupCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @ObservedObject var timeline = ActivityRecorder.shared
    @AppStorage("setupHidden") private var hidden = false
    @AppStorage("routinesSeen") private var routinesSeen = false
    @AppStorage("focusShield") private var shield = FocusMode.Shield.remind.rawValue
    @State private var sheet: Sheet?
    @Environment(\.snapshotMode) private var snapshot

    enum Sheet: String, Identifiable { case vision, season, routines; var id: String { rawValue } }

    struct Item: Identifiable {
        var id: String
        var title: String
        var detail: String
        var symbol: String
        var done: Bool
        var action: String
        var run: () -> Void
    }

    var items: [Item] {
        let p = model.planner
        var out = [
            Item(id: "vision", title: "Write your vision", detail: "What you want to have, do and become — definite enough to picture.",
                 symbol: "eye", done: !(p.vision?.isEmpty ?? true), action: "Write It") { sheet = .vision },
            Item(id: "season", title: "Plan a 12-week season", detail: "One main quest, up to two side quests, hours a week and milestones.",
                 symbol: "flag.checkered", done: p.season?.isActive(on: Planner.key(.now)) == true, action: "Plan It") { sheet = .season },
        ]
        if coach.available {
            out += [
                Item(id: "calendar", title: "Connect your calendar", detail: "Read only. The coach and the stack plan around your meetings.",
                     symbol: "calendar", done: coach.calendarConnected, action: "Connect") { coach.connectCalendar() },
                Item(id: "mirror", title: "Put your blocks on your phone", detail: "Time blocks go into a “Headroom” calendar; no other calendar is touched.",
                     symbol: "iphone", done: coach.mirrorOn, action: "Turn On") { coach.setMirror(true, model: model) },
                Item(id: "routines", title: "Set your routines", detail: "A nudge to plan the morning, close the day, review the week and read your vision.",
                     symbol: "alarm", done: routinesSeen, action: "Set Times") { sheet = .routines },
                Item(id: "shield", title: "Guard your focus", detail: "During focus, distracting apps and sites get a pause screen with your vision.",
                     symbol: "shield.lefthalf.filled", done: shield == FocusMode.Shield.pause.rawValue, action: "Turn On") {
                         shield = FocusMode.Shield.pause.rawValue
                         model.show("Pause screen on for focus sessions")
                     },
            ]
        }
        return out
    }

    var body: some View {
        let all = items
        let done = all.filter(\.done).count
        if !hidden && done < all.count {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Finish setting up").font(.system(size: 17, weight: .bold, design: .rounded))
                            Text("Once, a few minutes each. Then the path above runs your day.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Text("\(done) of \(all.count)").font(Theme.number(13, weight: .semibold)).foregroundStyle(Theme.accent)
                        if !snapshot {
                            Button("Hide") { hidden = true }.buttonStyle(.borderless).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    ProgressBar(fraction: Double(done) / Double(max(1, all.count)))
                    // Only what's left; what's done is the bar above.
                    let left = all.filter { !$0.done }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(left) { item in row(item, next: item.id == left.first?.id) }
                    }
                }
            }
            .sheet(item: $sheet) { s in
                switch s {
                case .vision: VisionEditor(vision: model.planner.vision ?? Vision())
                case .season: SeasonEditor(season: nil, projects: projects)
                case .routines: RoutinesSheet().onDisappear { routinesSeen = true }
                }
            }
        }
    }

    func row(_ item: Item, next: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(item.done ? Theme.accent : next ? Theme.accent.opacity(0.16) : Theme.fill(0.06)).frame(width: 30, height: 30)
                Image(systemName: item.done ? "checkmark" : item.symbol).font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(item.done ? Theme.onAccent : next ? Theme.accent : Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.done ? Theme.textTertiary : Theme.textPrimary).strikethrough(item.done)
                if !item.done {
                    Text(item.detail).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if !item.done {
                Button(item.action, action: item.run).buttonStyle(GhostButtonStyle()).controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(next ? Theme.accent.opacity(0.45) : Theme.fill(0.06), lineWidth: next ? 1.5 : 1))
    }

    var projects: [String] {
        Array(Set(timeline.projects + timeline.settings.rules.compactMap(\.project) + model.planner.tasks.compactMap(\.project))).sorted()
    }
}

/// A thin bar in the accent colour.
struct ProgressBar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill(0.07))
                Capsule().fill(Theme.accent).frame(width: max(6, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - The day's path

/// The one next step, big, with the only primary button on the page — and the whole day underneath as a path.
struct DayPathCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @State private var editingVision = false

    var body: some View {
        let now = Date()
        let p = model.planner
        let done = DayPath.done(p, now: now)
        let next = DayPath.next(p, now: now)
        let phase = DayPath.phase(now)
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(phase.title.uppercased()) · \(done.count) OF \(DayPath.Step.allCases.count) ON TODAY'S PATH")
                            .font(.system(size: 11, weight: .bold)).tracking(0.6).foregroundStyle(Theme.accent)
                        if let next {
                            Text(headline(next)).font(.system(size: 24, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                            Text(next.why).font(.system(size: 13.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(phase == .evening ? "Day closed. Rest well." : "On track. Keep going.")
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                            Text(phase == .evening ? "Tomorrow's top thing is set — the morning starts already moving."
                                 : "Everything for now is done. The evening ritual opens after 5 pm.")
                                .font(.system(size: 13.5)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 12)
                    if let next {
                        Button { perform(next) } label: {
                            Label(action(next), systemImage: next.symbol).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 6)
                        }
                        .buttonStyle(PrimaryButtonStyle()).controlSize(.large)
                        .disabled(coach.asking != nil && next == .plan)
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    ForEach(DayPath.Phase.allCases, id: \.self) { ph in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ph.title).font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(ph == phase ? Theme.textPrimary : Theme.textTertiary)
                            HStack(spacing: 6) {
                                ForEach(DayPath.Step.allCases.filter { $0.phase == ph }) { s in
                                    stepDot(s, done: done.contains(s), next: s == next)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .sheet(isPresented: $editingVision) { VisionEditor(vision: model.planner.vision ?? Vision()) }
    }

    func stepDot(_ s: DayPath.Step, done: Bool, next: Bool) -> some View {
        Button { perform(s) } label: {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark" : s.symbol).font(.system(size: 11, weight: .semibold))
                if next { Text(s.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1) }
            }
            .padding(.horizontal, next ? 10 : 0)
            .frame(minWidth: 30, minHeight: 30)
            .background(Capsule().fill(done ? Theme.accent : next ? Theme.accent.opacity(0.16) : Theme.fill(0.06)))
            .foregroundStyle(done ? Theme.onAccent : next ? Theme.accent : Theme.textTertiary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(s.title + (done ? " — done" : ""))
    }

    var topCandidate: PlannerTask? {
        let today = model.planner.today()
        return model.planner.topThing(on: Planner.key(.now)) ?? today.first { $0.big && !$0.isDone } ?? today.first { !$0.isDone }
    }

    func headline(_ s: DayPath.Step) -> String {
        switch s {
        case .vision where model.planner.vision?.isEmpty ?? true: "Write your vision"
        case .top: topCandidate.map { "Make “\($0.title)” the top thing?" } ?? s.title
        case .focus: topCandidate.map { "Focus on “\($0.title)”" } ?? s.title
        default: s.title
        }
    }

    func action(_ s: DayPath.Step) -> String {
        switch s {
        case .vision: (model.planner.vision?.isEmpty ?? true) ? "Write It" : "Read It"
        case .plan: coach.available && coach.hasClaude ? "Plan My Day" : "Add Below"
        case .top: topCandidate == nil ? "Add a Task" : "Make It the One"
        case .block: "Stack My Day"
        case .focus: "Start Focus"
        default: "Close the Day"
        }
    }

    func perform(_ s: DayPath.Step) {
        switch s {
        case .vision:
            if model.planner.vision?.isEmpty ?? true { editingVision = true } else { coach.readingVision = true }
        case .plan:
            if coach.available && coach.hasClaude { coach.ask(.morning, model: model) }
            else { model.show("Add up to three Big 3 tasks below — the ones that move your season") }
        case .top:
            if let t = topCandidate { model.updateLog { $0.top = t.id }; model.show("Today is for “\(t.title)”") }
            else { model.show("Add a task below first") }
        case .block:
            let proposals = model.stackToday()
            guard !proposals.isEmpty else { model.show("Nothing to stack — every task today already has a time, or there's no free time left"); return }
            let placed = model.plan { p in proposals.reduce(0) { n, b in p.addBlock(b) == nil ? n : n + 1 } }
            model.show("Gave \(placed) task\(placed == 1 ? "" : "s") a time today — see the day plan")
        case .focus:
            if let t = topCandidate { model.startFocus(t.title, task: t) } else { model.show("Add a task first") }
        case .gratitude, .gave, .rate, .journal, .tomorrow:
            model.closingDay = true
        }
    }
}

// MARK: - The evening ritual

/// Closing the day in one place: how it moved, three thanks, value given, a few lines, the certain way, and
/// tomorrow's top thing. Saved together; every part earns its own XP through the ledger.
struct EveningSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Int?
    @State private var thanks = ["", "", ""]
    @State private var gave = ""
    @State private var note = ""
    @State private var ways: Set<String> = []
    @State private var tomorrowTop: UUID?
    @State private var newTop = ""

    let day = Planner.key(.now), tomorrow = Planner.key(daysFrom: .now, 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Close the day").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Five minutes. Honest, not harsh — and end on what's coming.").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            .padding(24)
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(1, "How much did today move?", xp: "+5") {
                        HStack(spacing: 6) {
                            ForEach([1, 2, 3, 4], id: \.self) { v in
                                let on = progress == v
                                Button { progress = on ? nil : v } label: {
                                    Text(["", "Little", "Mixed", "Solid", "Massive"][v]).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                                        .padding(.horizontal, 14).frame(height: 30)
                                        .background(Capsule().fill(on ? Theme.accent : Theme.fill(0.06)))
                                        .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    section(2, "Three things you're thankful for", xp: "+5") {
                        VStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { i in
                                TextField(["Someone who helped today", "Something that went right", "Something you'd miss if it were gone"][i], text: $thanks[i])
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    section(3, "Who got more from you than they paid for?", xp: "+5") {
                        TextField("A client, a teammate, a friend — and what you gave", text: $gave).textFieldStyle(.roundedBorder)
                    }
                    section(4, "A few lines about today", xp: "+10") {
                        TextEditor(text: $note).font(.system(size: 13)).scrollContentBackground(.hidden)
                            .padding(6).frame(height: 84)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.04)))
                    }
                    section(5, "In the certain way, today I…", xp: "3+ = +10") {
                        FlowLayout(spacing: 6) {
                            ForEach(CertainWay.Item.allCases.filter(\.isSelfReported), id: \.self) { item in
                                let on = ways.contains(item.rawValue)
                                Button { if on { ways.remove(item.rawValue) } else { ways.insert(item.rawValue) } } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                                        Text(item.short).font(.system(size: 12))
                                    }
                                    .padding(.horizontal, 10).frame(height: 28)
                                    .background(Capsule().fill(on ? Theme.accent.opacity(0.18) : Theme.fill(0.05)))
                                    .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                                }
                                .buttonStyle(.plain)
                                .help(item.title)
                            }
                        }
                    }
                    section(6, "Tomorrow's top thing", xp: nil) {
                        let open = model.planner.tasks.filter { !$0.isDone && ($0.day == nil || $0.day! <= tomorrow) }
                            .sorted { $0.big && !$1.big }.prefix(8)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(open)) { t in
                                Button { tomorrowTop = tomorrowTop == t.id ? nil : t.id; newTop = "" } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: tomorrowTop == t.id ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(tomorrowTop == t.id ? Theme.accent : Theme.textTertiary)
                                        Text(t.title).font(.system(size: 13))
                                        if t.big { Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(Theme.review) }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            TextField("Or something new", text: $newTop).textFieldStyle(.roundedBorder)
                                .onChange(of: newTop) { _, v in if !v.isEmpty { tomorrowTop = nil } }
                        }
                    }
                }
                .padding(24)
            }
            .frame(height: 470)
            Divider().opacity(0.4)
            HStack {
                Button("Not Now") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button { save(); dismiss() } label: { Label("Close the Day", systemImage: "moon.stars") }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 580)
        .onAppear(perform: load)
    }

    func section<C: View>(_ n: Int, _ title: String, xp: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(n)").font(Theme.number(11, weight: .bold)).foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20).background(Circle().fill(Theme.accent.opacity(0.14)))
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if let xp { Text(xp + " XP").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
            }
            content()
        }
    }

    func load() {
        let l = model.planner.log(on: day)
        progress = l?.progress
        let g = l?.gratitude ?? []
        thanks = (0..<3).map { $0 < g.count ? g[$0] : "" }
        gave = l?.gave ?? ""
        note = l?.note ?? ""
        ways = Set(l?.ways ?? [])
        tomorrowTop = model.planner.log(on: tomorrow)?.top
    }

    func save() {
        let g = thanks.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let v = gave.trimmingCharacters(in: .whitespacesAndNewlines), text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateLog(day) { l in
            l.progress = progress
            l.gratitude = g.isEmpty ? nil : g
            l.gave = v.isEmpty ? nil : v
            l.note = text
            l.ways = ways.isEmpty ? nil : ways.sorted()
        }
        let typed = newTop.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            _ = model.addTask(typed, big: true, day: tomorrow)
            tomorrowTop = model.planner.tasks.last { $0.title == typed && !$0.isDone }?.id
        }
        if let id = tomorrowTop { model.updateLog(tomorrow) { $0.top = id } }
    }
}

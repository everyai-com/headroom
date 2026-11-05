import SwiftUI
import AVFoundation
import HeadroomCore

// The rest of the Superfocus loop in the app: the daily sync and the top thing (Today), milestones and the
// season's commitment (season card), the season editor with Claude's draft, the season wrap, the brain dump
// and the coach's memory, how a session felt, energy patterns (Progress) and a focus sound made on this Mac.

// MARK: - Daily sync

/// The end of the day in two minutes: how much it moved, a read per quest, tomorrow's top thing — and the
/// last 10% of the daily score. Today's top thing sits on top all day.
struct DailySyncCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @Environment(\.snapshotMode) private var snapshot
    @State private var open = false

    var body: some View {
        let day = Planner.key(.now), tomorrow = Planner.key(daysFrom: .now, 1)
        let log = model.planner.log(on: day)
        let evening = Calendar.current.component(.hour, from: .now) >= 16
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Top thing", trailing: log?.isSynced == true ? "day synced ✓" : nil)
                topRow(day: day, label: "Today")
                if evening || open || log?.isSynced == true { sync(day: day, tomorrow: tomorrow, log: log) }
                else if !snapshot {
                    Button { withAnimation(.easeOut(duration: 0.2)) { open = true } } label: { Label("Sync My Day", systemImage: "sun.horizon") }
                        .buttonStyle(GhostButtonStyle()).controlSize(.small)
                        .help("Two minutes at the end of the day: how it moved, a read per quest, tomorrow's top thing. It opens by itself after 4 pm.")
                }
            }
        }
    }

    @ViewBuilder func sync(day: String, tomorrow: String, log: DayLog?) -> some View {
                Divider().opacity(0.4)
                Text("How much did today move?").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                HStack(spacing: 5) {
                    ForEach([4, 3, 2, 1], id: \.self) { v in
                        let on = log?.progress == v
                        Button { model.updateLog { $0.progress = on ? nil : v } } label: {
                            Text(["", "Little", "Mixed", "Solid", "Massive"][v]).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                                .padding(.horizontal, 9).frame(height: 24)
                                .background(Capsule().fill(on ? Theme.accent.opacity(0.85) : Theme.fill(0.05)))
                                .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let season = model.planner.season, season.isActive(on: day) {
                    ForEach(season.quests) { q in
                        HStack(spacing: 5) {
                            Text(q.project).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1).frame(width: 110, alignment: .leading)
                            ForEach([3, 2, 1], id: \.self) { v in
                                let on = log?.goals?[q.project] == v
                                Button { model.updateLog { l in var g = l.goals ?? [:]; g[q.project] = on ? nil : v; l.goals = g.isEmpty ? nil : g } } label: {
                                    Text(["", "behind", "some", "moved"][v]).font(.system(size: 11, weight: on ? .semibold : .regular))
                                        .padding(.horizontal, 7).frame(height: 21)
                                        .background(Capsule().fill(on ? Theme.accent.opacity(0.7) : Theme.fill(0.05)))
                                        .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                topRow(day: tomorrow, label: "Tomorrow")
                HStack {
                    Text(log?.isSynced == true ? "+5 XP · the last 10% of today's score" : "Rate the day to finish it at 100% (+5 XP)")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    if !snapshot && coach.hasClaude && LifeCoach.shared.available {
                        Button { coach.ask(.evening, model: model) } label: { Label("Plan Tomorrow", systemImage: "moon.stars") }
                            .buttonStyle(GhostButtonStyle()).controlSize(.small).disabled(coach.asking != nil)
                    }
                }
    }

    @ViewBuilder func topRow(day: String, label: String) -> some View {
        let top = model.planner.topThing(on: day)
        HStack(spacing: 8) {
            Image(systemName: top?.isDone == true ? "checkmark.circle.fill" : "scope")
                .foregroundStyle(top?.isDone == true ? Theme.safe : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                Text(top?.title ?? "Pick the one task that makes the day a success").font(.system(size: top == nil ? 12.5 : 14, weight: top == nil ? .regular : .semibold))
                    .foregroundStyle(top == nil ? Theme.textTertiary : Theme.textPrimary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !snapshot {
                let candidates = model.planner.tasks.filter { !$0.isDone && ($0.day == nil || $0.day! <= day) }.sorted { $0.big && !$1.big }
                Menu {
                    ForEach(candidates.prefix(15)) { t in Button(t.title) { model.setTopThing(t, day: day) } }
                    if let top { Divider(); Button("Clear") { model.setTopThing(top, day: day) } }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(candidates.isEmpty)
            }
        }
    }
}

// MARK: - How a session felt

struct FocusFeelSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var timeline = ActivityRecorder.shared
    var session: FocusSession
    @State private var taskDone = true

    var body: some View {
        let task = session.taskID.flatMap { id in model.planner.tasks.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 16) {
            Text("\(session.title) · \(Minutes.text(Double(session.minutes()) * 60))").font(.system(size: 17, weight: .bold, design: .rounded))
            if timeline.isOn, let q = FocusMode.quality(session, spans: timeline.allToday, classifier: timeline.classifier) {
                Text("\(Int(q * 100))% focused — \(FocusMode.verdict(q))").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            if let task, !task.isDone {
                Toggle("Finished “\(task.title)”", isOn: $taskDone).toggleStyle(.checkbox)
            }
            Text("How did it feel?").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 10) {
                ForEach(Feel.allCases, id: \.self) { f in
                    Button { model.finishSession(session.id, feel: f, taskDone: task != nil && taskDone); dismiss() } label: {
                        Label(f.title, systemImage: f.symbol).frame(minWidth: 110)
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
            Text("Your coach learns when work gives you energy and when it drains you.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            HStack {
                Spacer()
                Button("Skip") { model.finishSession(session.id, feel: nil, taskDone: task != nil && taskDone); dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 460)
    }
}

// MARK: - Energy patterns (Progress)

struct EnergyPatternsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let since = Date().addingTimeInterval(-30 * 86_400)
        let tally = EnergyPatterns.tally(model.planner, since: since)
        let peak = DayPart.peak(model.planner.sessions.filter { $0.start >= since })
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Energy", trailing: "last 30 days")
                if let peak {
                    Label(peak.chronotype, systemImage: "sunrise").font(.system(size: 13, weight: .semibold))
                }
                if tally.parts.isEmpty {
                    Text("Say how a focus session or a block felt (energizing or draining) and you'll see which hours and projects give you energy.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(DayPart.allCases, id: \.self) { part in
                    if let t = tally.parts[part] { bar(part.title, t) }
                }
                if !tally.projects.isEmpty { Divider().opacity(0.4) }
                ForEach(tally.projects.sorted { $0.key < $1.key }.prefix(6), id: \.key) { name, t in bar(name, t) }
            }
        }
    }

    func bar(_ label: String, _ t: EnergyPatterns.Tally) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).lineLimit(1).frame(width: 110, alignment: .leading)
            SegmentedBar(segments: [.init(id: "e", value: Double(t.energizing), color: Theme.safe),
                                    .init(id: "d", value: Double(t.draining), color: Theme.review)].filter { $0.value > 0 },
                         total: Double(max(1, t.energizing + t.draining)), height: 7)
            Text("\(t.energizing)↑ \(t.draining)↓").font(Theme.number(11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Milestones and commitment on the season card

struct SeasonDetails: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshot
    var season: Season

    var body: some View {
        let today = Planner.key(.now)
        VStack(alignment: .leading, spacing: 8) {
            if let m = season.manifesto, !m.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("“\(m)”").font(.system(size: 12.5, design: .serif).italic()).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2).help(m)
                    if let signed = season.signed {
                        Text("Signed \(signed.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            let all = season.milestones ?? []
            if !all.isEmpty {
                Text("Next milestones · \(all.filter { $0.done != nil }.count) of \(all.count) done").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                ForEach(season.openMilestones.prefix(3)) { m in
                    HStack(spacing: 8) {
                        Button { model.toggleMilestone(m.id) } label: {
                            Image(systemName: m.done != nil ? "checkmark.circle.fill" : "circle").foregroundStyle(m.done != nil ? Theme.safe : Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        if m.pinned == true { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.accent) }
                        Text(m.title).font(.system(size: 12.5)).strikethrough(m.done != nil).lineLimit(1)
                            .foregroundStyle(m.done != nil ? Theme.textTertiary : Theme.textPrimary)
                        Spacer(minLength: 4)
                        Text(m.project).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        if let due = m.due {
                            Text(Planner.date(due)?.formatted(.dateTime.day().month(.abbreviated)) ?? due)
                                .font(Theme.number(11, weight: .medium))
                                .foregroundStyle(m.isLate(today: today) ? Theme.review : Theme.textSecondary)
                        }
                    }
                    .contextMenu {
                        if m.done == nil {
                            Button(m.pinned == true ? "Unpin" : "Pin — Working on It Now") { model.plan { p in p.editMilestone(m.id) { $0.pinned = $0.pinned == true ? nil : true } } }
                        }
                        Button("Remove", role: .destructive) { model.plan { p in p.editSeason { $0.milestones?.removeAll { $0.id == m.id } } } }
                    }
                }
            }
            HStack {
                if let support = season.support, !support.isEmpty {
                    Text("Support: " + support.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                if !snapshot {
                    Button { model.wrapSeason = season } label: { Label("Season Wrap", systemImage: "sparkles.rectangle.stack") }
                        .buttonStyle(.borderless).font(.system(size: 11.5))
                }
            }
        }
    }
}

// MARK: - The season wrap

struct SeasonWrapSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var season: Season

    var body: some View {
        let p = model.planner
        let previous = p.pastSeasons.last { $0.start < season.start }
        let w = SeasonWrap.of(season, planner: p, previous: previous)
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(season.ended == nil ? "Your season so far" : "Your season, wrapped").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("\(Planner.date(season.start)?.formatted(date: .abbreviated, time: .omitted) ?? season.start) – \(Planner.date(season.ended ?? season.end)?.formatted(date: .abbreviated, time: .omitted) ?? season.end) · \(w.days) days")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                stat("\(w.focusDays)", "days in focus")
                stat(Minutes.text(Double(w.focusMinutes) * 60), "of deep work")
                stat("\(w.tasksDone)", "tasks closed")
                stat("\(w.milestonesDone)/\(w.milestones)", "milestones")
                stat(w.weeks == 0 ? "—" : "\(Int(Double(w.onTrack) / Double(w.weeks) * 100))%", "weeks on track")
                if let prev = w.previousFocusMinutes {
                    let delta = w.focusMinutes - prev
                    stat("\(delta >= 0 ? "+" : "−")\(Minutes.text(Double(abs(delta)) * 60))", "focus vs last season")
                }
            }
            if let peak = w.peak {
                Label(peak.chronotype, systemImage: "sunrise.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(w.quests, id: \.project) { q in
                    HStack {
                        Text(q.project).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(Minutes.text(Double(q.minutes) * 60)) of \(q.target / 60) h").font(Theme.number(12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                    SegmentedBar(segments: [.init(id: q.project, value: Double(q.minutes), color: Theme.accent)], total: Double(max(1, q.target)), height: 6)
                }
            }
            if w.focusDays > 0 { Text("Consistency compounds.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(PrimaryButtonStyle()) }
        }
        .padding(26).frame(width: 520)
    }

    func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.number(20, weight: .bold))
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
    }
}

// MARK: - Brain dump and the coach's memory

struct BrainDumpSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Brain dump").font(.system(size: 17, weight: .bold))
            Text("Paste or type anything — meeting notes, a Slack thread, a list, half-thoughts. The coach pulls out the tasks; you pick what goes on your list.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(6).frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.04)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sort It") { LifeCoach.shared.ask(.dump, model: model, dump: text); dismiss() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || LifeCoach.shared.asking != nil)
            }
        }
        .padding(22).frame(width: 520)
    }
}

struct CoachMemorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = CoachMemory().load()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What the coach knows about you").font(.system(size: 17, weight: .bold))
            Text("How you work, the people around you, what you prefer. Sent with every coach request; kept in a file on this Mac (coach-memory.md). The coach can suggest lines — they're added only when you tick them.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(6).frame(height: 260)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.04)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("- I build best before noon; calls after 2 pm\n- Svikarr is for clinics in the US\n- Gym Mon/Wed/Fri at 18:30")
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { CoachMemory().save(text); dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 520)
    }
}

// MARK: - The season editor

struct SeasonEditor: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @Environment(\.dismiss) private var dismiss
    var projects: [String]
    @State private var main: String
    @State private var mainHours: Int
    @State private var sides: [(String, Int)]
    @State private var weeks = 12
    @State private var support: String
    @State private var milestones: [Milestone]
    @State private var protected: [ProtectedTime]
    @State private var manifesto: String
    @State private var signed: Date?
    @State private var dump = ""
    @State private var questions: [String] = []
    @State private var showDraft: Bool

    init(season: Season?, projects: [String]) {
        self.projects = projects
        if let season { _weeks = State(initialValue: min(12, max(1, season.weekCount))) }
        _main = State(initialValue: season?.main.project ?? "")
        _mainHours = State(initialValue: season?.main.hoursPerWeek ?? 20)
        let s = season?.sides.map { ($0.project, $0.hoursPerWeek) } ?? []
        _sides = State(initialValue: s + Array(repeating: ("", 4), count: Season.maxSideQuests - s.count))
        _support = State(initialValue: season?.support?.joined(separator: ", ") ?? "")
        _milestones = State(initialValue: season?.milestones ?? [])
        _protected = State(initialValue: season?.protected ?? [])
        _manifesto = State(initialValue: season?.manifesto ?? "")
        _signed = State(initialValue: season?.signed)
        _showDraft = State(initialValue: season == nil)
    }

    var questNames: [String] {
        ([main] + sides.map(\.0)).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your season").font(.system(size: 18, weight: .bold))
                    Text("Fewer goals, done well: one main quest gets most of your hours, up to two side quests keep moving, and everything else waits for the next season.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if coach.hasClaude && coach.available { draftSection }
                    section("Quests") {
                        row("Main quest", $main, $mainHours)
                        ForEach(sides.indices, id: \.self) { i in
                            row("Side quest \(i + 1)", Binding(get: { sides[i].0 }, set: { sides[i].0 = $0 }), Binding(get: { sides[i].1 }, set: { sides[i].1 = $0 }))
                        }
                        HStack(spacing: 10) {
                            Text("Support").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary).frame(width: 90, alignment: .leading)
                            TextField("Admin, gym… (they still happen, they don't grow)", text: $support).textFieldStyle(.roundedBorder)
                        }
                        Stepper("Lasts \(weeks) week\(weeks == 1 ? "" : "s")\(weeks == 12 ? " (recommended)" : "")", value: $weeks, in: 1...12)
                    }
                    section("Milestones") { milestoneRows }
                    section("Protected time") { protectedRows }
                    section("Commitment") { commitment }
                }
                .padding(22)
            }
            Divider()
            HStack {
                if model.planner.season != nil {
                    Button("End Season") {
                        model.plan { $0.endSeason() }
                        model.wrapSeason = model.planner.pastSeasons.last
                        dismiss()
                    }
                    .buttonStyle(GhostButtonStyle())
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.planner.season == nil ? "Start" : "Save") { save() }
                    .keyboardShortcut(.defaultAction).disabled(main.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 600, height: 700)
    }

    func save() {
        // Editing keeps the start and the weekly record; a new season starts today.
        let old = model.planner.season.flatMap { $0.isActive(on: Planner.key(.now)) ? $0 : nil }
        let begin = old?.start ?? Planner.key(.now)
        var s = Season(start: begin, end: Planner.key(daysFrom: Planner.date(begin) ?? .now, weeks * 7 - 1),
                       main: .init(project: main.trimmingCharacters(in: .whitespaces), hoursPerWeek: mainHours),
                       sides: sides.filter { !$0.0.trimmingCharacters(in: .whitespaces).isEmpty }.map { .init(project: $0.0.trimmingCharacters(in: .whitespaces), hoursPerWeek: $0.1) })
        s.log = old?.log
        let list = support.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        s.support = list.isEmpty ? nil : list
        let kept = milestones.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        s.milestones = kept.isEmpty ? nil : kept
        s.protected = protected.isEmpty ? nil : protected
        let text = manifesto.trimmingCharacters(in: .whitespacesAndNewlines)
        s.manifesto = text.isEmpty ? nil : text
        s.signed = text.isEmpty ? nil : signed
        // A season ended on purpose belongs in the past; replacing one that ran out just starts the next.
        model.plan { p in
            if let ended = p.season, old == nil { var e = ended; e.ended = e.ended ?? e.end; p.pastSeasons.append(e) }
            p.season = s
        }
        dismiss()
    }

    // MARK: Sections

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.035)))
    }

    var draftSection: some View {
        section("Draft with Claude") {
            DisclosureGroup(isExpanded: $showDraft) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What would you like to have achieved or experienced by the end? Projects, habits, how you want to feel. The more you share, the sharper the goals.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: $dump).font(.system(size: 13)).scrollContentBackground(.hidden)
                        .padding(6).frame(height: 110)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.05)))
                    HStack {
                        if coach.drafting { ProgressView().controlSize(.small); Text("Turning your answers into goals…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                        if let f = coach.failure { Text(f).font(.system(size: 11.5)).foregroundStyle(Theme.review) }
                        Spacer()
                        Button("Draft My Season") { coach.draftSeason(dump, weeks: weeks, model: model) { apply($0) } }
                            .buttonStyle(PrimaryButtonStyle()).disabled(dump.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || coach.drafting)
                    }
                    ForEach(questions, id: \.self) { q in
                        Label(q, systemImage: "questionmark.bubble").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Write what you want; the coach suggests the quests, milestones and a commitment. You edit everything before it starts.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    func apply(_ d: SeasonDraft) {
        main = d.main.project; mainHours = d.main.hoursPerWeek
        let s = d.sides.map { ($0.project, $0.hoursPerWeek) }
        sides = s + Array(repeating: ("", 4), count: max(0, Season.maxSideQuests - s.count))
        support = d.support.joined(separator: ", ")
        let begin = model.planner.season?.start ?? Planner.key(.now)
        milestones = d.season(start: begin, weeks: weeks)?.milestones ?? []
        manifesto = d.manifesto
        signed = nil
        questions = d.questions
    }

    var milestoneRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Big goals feel far away; milestones make progress visible. A missed one turns that week to “adjust”.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            ForEach($milestones) { $m in
                HStack(spacing: 8) {
                    TextField("Milestone", text: $m.title).textFieldStyle(.roundedBorder)
                    Picker("", selection: $m.project) {
                        ForEach(Array(Set(questNames + [m.project])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    DatePicker("", selection: Binding(get: { m.due.flatMap { Planner.date($0) } ?? .now },
                                                      set: { m.due = Planner.key($0) }), displayedComponents: .date)
                        .labelsHidden().fixedSize()
                    Button { milestones.removeAll { $0.id == m.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            Button { milestones.append(Milestone(title: "", project: questNames.first ?? "", due: Planner.key(daysFrom: .now, 28))) } label: {
                Label("Add Milestone", systemImage: "plus")
            }
            .buttonStyle(.borderless).disabled(questNames.isEmpty)
        }
    }

    var protectedRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hours you guard for a quest every week. The stack puts that quest's tasks there first, nothing else lands in it, and it counts toward plan strength.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            ForEach($protected) { $p in
                HStack(spacing: 8) {
                    Picker("", selection: $p.project) {
                        ForEach(Array(Set(questNames + [p.project])).filter { !$0.isEmpty }.sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 130)
                    HStack(spacing: 2) {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { d in
                            let on = p.weekdays.contains(d)
                            Button { if on { p.weekdays.remove(d) } else { p.weekdays.insert(d) } } label: {
                                Text(String(Calendar.current.veryShortWeekdaySymbols[d - 1])).font(.system(size: 11, weight: on ? .bold : .regular))
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(on ? Theme.accent.opacity(0.85) : Theme.fill(0.06)))
                                    .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    minutePicker($p.start)
                    Text("–").foregroundStyle(Theme.textTertiary)
                    minutePicker($p.end)
                    Button { protected.removeAll { $0.id == p.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                }
            }
            Button { protected.append(ProtectedTime(project: questNames.first ?? "", weekdays: [2, 3, 4, 5, 6], start: 9 * 60, end: 11 * 60)) } label: {
                Label("Protect Time", systemImage: "plus")
            }
            .buttonStyle(.borderless).disabled(questNames.isEmpty)
        }
    }

    func minutePicker(_ value: Binding<Int>) -> some View {
        DatePicker("", selection: Binding(get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(value.wrappedValue * 60)) },
                                          set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); value.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) }),
                   displayedComponents: .hourAndMinute)
            .labelsHidden().fixedSize()
    }

    var commitment: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A few sentences you can sign: what this season is for, and what you'll say no to.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            TextEditor(text: $manifesto).font(.system(size: 13, design: .serif)).scrollContentBackground(.hidden)
                .padding(6).frame(height: 80)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.05)))
                .onChange(of: manifesto) { signed = nil }
            HStack {
                if let signed {
                    Label("Signed \(signed.formatted(date: .abbreviated, time: .shortened))", systemImage: "signature").font(.system(size: 12)).foregroundStyle(Theme.safe)
                } else {
                    Button { signed = .now } label: { Label("Sign It", systemImage: "signature") }
                        .buttonStyle(GhostButtonStyle()).disabled(manifesto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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

// MARK: - Focus sound

/// Noise made on this Mac while a focus session runs (nothing streamed): brown is deep and soft, pink is
/// balanced, white is bright.
@MainActor
final class FocusSound {
    static let shared = FocusSound()
    static let key = "focusSound"

    enum Kind: String, CaseIterable, Sendable {
        case off, brown, pink, white
        var title: String { switch self { case .off: "No sound"; case .brown: "Brown noise"; case .pink: "Pink noise"; case .white: "White noise" } }
    }

    private var engine: AVAudioEngine?
    private var playing: Kind = .off

    /// Plays the chosen sound while a session runs, stops otherwise. Cheap to call on every tick.
    func sync(running: Bool) {
        let kind = Kind(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .off
        let wanted: Kind = running ? kind : .off
        guard wanted != playing else { return }
        engine?.stop()
        engine = nil
        playing = .off
        guard wanted != .off else { return }
        let e = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        let node = makeNoiseNode(NoiseState(wanted))
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = 0.35
        do { try e.start(); engine = e; playing = wanted } catch { engine = nil }
    }
}

/// Generator state, touched only by the audio thread once playing.
private final class NoiseState: @unchecked Sendable {
    let kind: FocusSound.Kind
    var brown: Float = 0
    var b: [Float] = Array(repeating: 0, count: 7)
    init(_ kind: FocusSound.Kind) { self.kind = kind }

    func next() -> Float {
        let white = Float.random(in: -1...1)
        switch kind {
        case .brown:
            brown = (brown + 0.02 * white) / 1.02
            return brown * 3.5
        case .pink:
            // Paul Kellet's filter.
            b[0] = 0.99886 * b[0] + white * 0.0555179; b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520; b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522; b[5] = -0.7616 * b[5] - white * 0.0168980
            let pink = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
            return pink * 0.11
        case .white: return white * 0.3
        case .off: return 0
        }
    }
}

/// Outside the main actor: the render block runs on the audio thread.
private func makeNoiseNode(_ state: NoiseState) -> AVAudioSourceNode {
    AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for frame in 0..<Int(frameCount) {
            let v = state.next()
            for buffer in buffers { UnsafeMutableBufferPointer<Float>(buffer)[frame] = v }
        }
        return noErr
    }
}

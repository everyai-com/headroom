import SwiftUI
import HeadroomCore

/// Today's check-in (mood and energy, one tap each, +5 XP), the journal (+10 XP for a few real words),
/// last night's sleep as the Mac saw it, and Claude's reflection on the entry when you ask for one.
struct DayLogCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @Environment(\.snapshotMode) private var snapshot
    @State private var draft = ""
    @State private var loadedDay = ""

    var body: some View {
        let day = Planner.key(.now)
        let log = model.planner.log(on: day)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Check-in", trailing: sleepText)
                scale("Mood", value: log?.mood, words: DayLog.moodWords) { v in model.updateLog { $0.mood = v } }
                scale("Energy", value: log?.energy, words: DayLog.energyWords) { v in model.updateLog { $0.energy = v } }
                Divider().opacity(0.4)
                Text("Journal").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                if snapshot {
                    Text(log?.note.nilIfEmpty ?? "How did today go?").font(.system(size: 13))
                        .foregroundStyle(log?.note.isEmpty == false ? Theme.textPrimary : Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    TextEditor(text: $draft)
                        .font(.system(size: 13)).scrollContentBackground(.hidden)
                        .frame(minHeight: 70, maxHeight: 140)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.fill(0.04)))
                        .overlay(alignment: .topLeading) {
                            if draft.isEmpty {
                                Text("What went well, what didn't, what you noticed…").font(.system(size: 13))
                                    .foregroundStyle(Theme.textTertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                            }
                        }
                    HStack(spacing: 8) {
                        let changed = draft != (log?.note ?? "")
                        Button("Save") { save(day) }.buttonStyle(GhostButtonStyle()).disabled(!changed)
                        if coach.hasClaude {
                            if coach.reflecting == day {
                                ProgressView().controlSize(.small)
                                Text("Claude is reading it…").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            } else {
                                Button {
                                    if changed { save(day) }
                                    coach.reflect(on: day, model: model)
                                } label: { Label("Reflect with Claude", systemImage: "sparkles") }
                                    .buttonStyle(GhostButtonStyle())
                                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    .help("Your Claude CLI reads the day and your entry, and answers in a few sentences. Nothing else is sent anywhere.")
                            }
                        }
                        Spacer()
                        Text(log?.isJournal == true ? "+10 XP today" : "a few words: +10 XP")
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                if let r = log?.reflection {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles").foregroundStyle(Theme.accent).font(.system(size: 12))
                        Text(r).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.08)))
                }
            }
        }
        .onAppear { load(day) }
        .onChange(of: model.planner.log(on: day)?.note) { _, _ in if draft.isEmpty { load(day) } }
    }

    var sleepText: String? {
        guard let s = coach.sleep else { return nil }
        let start = s.start.formatted(date: .omitted, time: .shortened), end = s.end.formatted(date: .omitted, time: .shortened)
        return "slept ~\(s.minutes / 60)h\(String(format: "%02d", s.minutes % 60)) · \(start)–\(end)"
    }

    func load(_ day: String) {
        draft = model.planner.log(on: day)?.note ?? ""
        loadedDay = day
    }

    func save(_ day: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateLog(day) { $0.note = text }
    }

    func scale(_ label: String, value: Int?, words: [String], set: @escaping (Int?) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary).frame(width: 50, alignment: .leading)
            ForEach(1...5, id: \.self) { v in
                let on = value == v
                Button { set(on ? nil : v) } label: {
                    Text(words[v]).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(Capsule().fill(on ? Theme.accent.opacity(0.85) : Theme.fill(0.05)))
                        .foregroundStyle(on ? Theme.onAccent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Every habit over a month, one square a day — LiFE RPG's monthly view. Missed days are just grey-outlined:
/// it's a mirror, not a scorecard.
struct HabitMonthCard: View {
    @EnvironmentObject var model: AppModel
    @State private var offset = 0

    var body: some View {
        let cal = Calendar.current
        let month = cal.date(byAdding: .month, value: offset, to: .now) ?? .now
        let habits = model.planner.habits.filter { !$0.archived }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: month.formatted(.dateTime.month(.wide).year()))
                    Button { offset -= 1 } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                    Button { offset += 1 } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).disabled(offset >= 0)
                }
                if habits.isEmpty {
                    Text("Habits you add show up here, a square for every day of the month.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(habits) { h in
                    let days = h.month(of: month)
                    let good = days.filter { $0.mark == .done || $0.mark == .clean }.count
                    let counted = days.filter { [.done, .clean, .missed, .slipped].contains($0.mark) }.count
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(h.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(counted == 0 ? "—" : "\(good)/\(counted)").font(Theme.number(11, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        }
                        HStack(spacing: 2.5) {
                            ForEach(days, id: \.key) { d in
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(fill(d.mark))
                                    .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(d.mark == .missed ? Theme.fill(0.18) : .clear, lineWidth: 1))
                                    .frame(height: 12)
                                    .help("\(d.key): \(word(d.mark))")
                            }
                        }
                    }
                }
            }
        }
    }

    func fill(_ m: DayMark) -> Color {
        switch m {
        case .done, .clean: Theme.safe
        case .slipped: Theme.review.opacity(0.7)
        case .missed: .clear
        case .off: Theme.fill(0.04)
        case .future: Theme.fill(0.08)
        }
    }

    func word(_ m: DayMark) -> String {
        switch m {
        case .done: "done"
        case .clean: "clean"
        case .slipped: "slipped"
        case .missed: "missed"
        case .off: "not planned"
        case .future: "to come"
        }
    }
}

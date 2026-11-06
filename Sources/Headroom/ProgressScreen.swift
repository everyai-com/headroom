import SwiftUI
import HeadroomCore

/// The Today header's second line: the running focus session (with a live clock and Stop), or what's next
/// with a button to start focusing on it.
struct FocusBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let p = model.planner
        if let s = p.runningSession {
            HStack(spacing: 8) {
                Image(systemName: "timer").foregroundStyle(Theme.safe)
                Text(s.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                FocusClock(start: s.start).foregroundStyle(Theme.safe)
                FocusQuality(session: s)
                Button("Stop") { model.stopFocus() }.buttonStyle(GhostButtonStyle()).controlSize(.small)
            }
        } else {
            let open = p.today().filter { !$0.isDone }
            let next = open.first
            HStack(spacing: 8) {
                Text(headline(next: next)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let next, !snapshot {
                    Button { model.startFocus(next.title, task: next) } label: { Label("Focus", systemImage: "timer") }
                        .buttonStyle(GhostButtonStyle()).controlSize(.small)
                        .help("Start a focus session on “\(next.title)” — 20 XP an hour")
                }
                let minutes = p.focusMinutes()
                if minutes > 0 {
                    Text("· \(minutes) min focused today").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    func headline(next: PlannerTask?) -> String {
        let big = model.planner.bigToday()
        if big.isEmpty && next == nil { return "What are the three things that would make today a good day?" }
        if let next { return "Next: \(next.title)" }
        return "All done for today. Anything else is a bonus."
    }
}

/// mm:ss (or h:mm:ss) since `start`, ticking every second; frozen in renders.
struct FocusClock: View {
    var start: Date
    var size: CGFloat = 12.5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(start))).font(Theme.number(size, weight: .semibold)).monospacedDigit()
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Progress: your rank, the areas of your life levelling up, the reward shop, habit challenges and everything
/// that earned XP. All of it is worked out from what you did (see `Planner.ledger`).
struct JourneyView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.snapshotMode) private var snapshot
    @State private var newReward = ""
    @State private var newCost = 200
    @State private var challengeHabit: UUID?
    @State private var challengeTimes = 20
    @State private var challengeDays = 30

    var p: Planner { model.planner }

    var body: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 14) {
                hero
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        areas
                        HabitMonthCard()
                        EnergyPatternsCard()
                        challenges
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        shop
                        log
                    }
                    .frame(width: 380)
                }
            }
        }
        .overlay(alignment: .top) { RewardBurst(reward: model.plannerReward).padding(.top, 60) }
        .onAppear { model.reloadPlannerIfChanged() }
    }

    // MARK: Hero

    var hero: some View {
        let xp = p.xp()
        let level = Planner.level(for: xp)
        let rank = Planner.rank(for: level.number)
        return Card {
            HStack(alignment: .center, spacing: 22) {
                ZStack {
                    GaugeRing(fraction: level.fraction, tint: Theme.accent, lineWidth: 10)
                    VStack(spacing: 0) {
                        Text("\(level.number)").font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("level").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(width: 86, height: 86)
                VStack(alignment: .leading, spacing: 6) {
                    Text(rank.title).font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("\(xp.formatted()) XP earned · \(level.needed - level.into) to level \(level.number + 1)"
                         + (rank.next.map { " · \($0.title) at level \($0.level)" } ?? ""))
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 14) {
                        stat(p.coins().formatted(), "coins", "circle.hexagongrid.fill", Theme.review)
                        stat("\(p.focusMinutes())", "min focused today", "timer", Theme.safe)
                        stat("\(p.tasks.filter(\.isDone).count)", "tasks done", "checkmark.circle", Theme.accent)
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
        }
    }

    func stat(_ value: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 12, weight: .semibold))
            Text(value).font(Theme.number(13, weight: .semibold))
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
        }
    }

    // MARK: Areas

    var areas: some View {
        let list = p.areas()
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Areas of your life", trailing: list.isEmpty ? nil : "\(list.count)")
                if list.isEmpty {
                    Text("Give a task or habit an area — type #health or #work when you add it — and that part of your life levels up on its own.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(list) { a in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(a.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text("Lv \(a.level.number)").font(Theme.number(12, weight: .bold)).foregroundStyle(Theme.accent)
                            }
                            SegmentedBar(segments: [.init(id: a.name, value: Double(a.level.into), color: Theme.accent)],
                                         total: Double(a.level.needed), height: 6)
                            Text("\(a.level.into) / \(a.level.needed) XP").font(Theme.number(11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
                    }
                }
            }
        }
    }

    // MARK: Challenges

    var challenges: some View {
        let habits = p.habits.filter { !$0.archived }
        let list = p.challenges.filter { c in
            if case .ended = p.state(of: c) { return Planner.date(c.end).map { Date().timeIntervalSince($0) < 14 * 86_400 } ?? false }
            return true
        }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Challenges", trailing: nil)
                if list.isEmpty {
                    Text("Pick a habit and a number — “write 20 times in 30 days”. Reach it for a bonus; if you don't, it just ends.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(list) { c in challengeRow(c) }
                if !snapshot && !habits.isEmpty {
                    HStack(spacing: 8) {
                        Picker("", selection: Binding(get: { challengeHabit ?? habits[0].id }, set: { challengeHabit = $0 })) {
                            ForEach(habits) { Text($0.title).tag($0.id) }
                        }
                        .labelsHidden().frame(maxWidth: 180)
                        Stepper("\(challengeTimes)×", value: $challengeTimes, in: 1...200).fixedSize()
                        Stepper("in \(challengeDays) days", value: $challengeDays, in: 1...365).fixedSize()
                        Spacer()
                        Button("Start") {
                            let id = challengeHabit ?? habits[0].id
                            let title = habits.first { $0.id == id }?.title ?? "Habit"
                            model.plan { p in
                                p.challenges.append(Challenge(title: "\(title) \(challengeTimes)× in \(challengeDays) days", habitID: id, target: challengeTimes,
                                                              start: Planner.key(.now), end: Planner.key(daysFrom: .now, challengeDays - 1)))
                            }
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                }
            }
        }
    }

    func challengeRow(_ c: Challenge) -> some View {
        let progress = p.challengeProgress(c)
        let state = p.state(of: c)
        let note: String = switch state {
        case .won: "Done — +\(c.bonus) XP"
        case .ended: "Ended at \(progress) — no harm done"
        case .upcoming: "Starts \(Planner.date(c.start)?.formatted(.dateTime.day().month()) ?? c.start)"
        case .active(let left): "\(left) day\(left == 1 ? "" : "s") left · +\(c.bonus) XP"
        }
        let tint = state == .won ? Theme.safe : Theme.accent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: state == .won ? "trophy.fill" : "flag.checkered").foregroundStyle(tint).font(.system(size: 12))
                Text(c.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Text("\(min(progress, c.target))/\(c.target)").font(Theme.number(12, weight: .semibold))
            }
            SegmentedBar(segments: [.init(id: c.id.uuidString, value: Double(min(progress, c.target)), color: tint)], total: Double(c.target), height: 6)
            Text(note).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .contextMenu {
            Button("Remove Challenge", role: .destructive) { model.plan { p in p.challenges.removeAll { $0.id == c.id } } }
        }
    }

    // MARK: Shop

    var shop: some View {
        let coins = p.coins()
        let rewards = p.rewards.filter { !$0.archived }.sorted { $0.cost < $1.cost }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Rewards", trailing: "\(coins.formatted()) coins")
                if rewards.isEmpty {
                    Text("Treat yourself on purpose: name something you'd enjoy and price it in coins. You earn a coin for every XP.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rewards) { r in
                    HStack(spacing: 10) {
                        Image(systemName: "gift").foregroundStyle(Theme.review).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Text(coins >= r.cost ? "\(r.cost.formatted()) coins" : "\(r.cost.formatted()) coins · \((r.cost - coins).formatted()) to go")
                                .font(Theme.number(11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Buy") { model.buy(r) }.buttonStyle(GhostButtonStyle()).controlSize(.small).disabled(coins < r.cost)
                    }
                    .contextMenu {
                        Button("Remove Reward") { model.plan { p in if let i = p.rewards.firstIndex(where: { $0.id == r.id }) { p.rewards[i].archived = true } } }
                    }
                }
                if !snapshot {
                    HStack(spacing: 8) {
                        TextField("A reward, e.g. Dinner out", text: $newReward).textFieldStyle(.plain).font(.system(size: 13))
                            .onSubmit(addReward)
                        TextField("", value: $newCost, format: .number).textFieldStyle(.plain).font(Theme.number(13, weight: .medium))
                            .frame(width: 52).multilineTextAlignment(.trailing)
                        Text("coins").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 10).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
                }
                let bought = p.purchases.sorted { $0.date > $1.date }.prefix(3)
                if !bought.isEmpty {
                    Text("Enjoyed: " + bought.map(\.title).joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    func addReward() {
        let title = newReward.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, newCost > 0 else { return }
        model.plan { $0.rewards.append(Reward(title: title, cost: newCost)) }
        newReward = ""
    }

    // MARK: Log

    var log: some View {
        let entries = Array(p.ledger().prefix(snapshot ? 8 : 25))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "What earned what", trailing: nil)
                if entries.isEmpty {
                    Text("Finish a task or check off a habit — every point shows up here.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(entries) { e in
                    HStack(spacing: 8) {
                        Image(systemName: symbol(e.kind)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(width: 14)
                        Text(e.title).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(e.coins < 0 ? "\(e.coins) coins" : "+\(e.xp)")
                            .font(Theme.number(12, weight: .semibold)).foregroundStyle(e.coins < 0 ? Theme.review : Theme.safe)
                        Text(e.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                            .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(width: 62, alignment: .trailing)
                    }
                }
            }
        }
    }

    func symbol(_ k: LedgerEntry.Kind) -> String {
        switch k {
        case .task: "checkmark.circle"
        case .habit: "repeat"
        case .clean: "shield.lefthalf.filled"
        case .focus: "timer"
        case .challenge: "trophy"
        case .purchase: "gift"
        case .journal: "book"
        case .checkin: "face.smiling"
        case .sync: "sun.horizon"
        case .milestone: "flag.checkered"
        case .gratitude: "heart"
        case .value: "gift"
        case .vision: "eye"
        }
    }
}

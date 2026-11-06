import SwiftUI
import HeadroomCore

/// The vision and the certain way, on Today: what you want to have, do and become, a button to read it (and
/// mark it read), the decisions you're waiting on, and the day's practices — some read from the day, the rest ticked.
struct VisionCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @Environment(\.snapshotMode) private var snapshot
    @State private var editing = false

    var body: some View {
        let day = Planner.key(.now)
        let log = model.planner.log(on: day)
        let vision = model.planner.vision ?? Vision()
        let met = CertainWay.met(log, score: model.planner.score(on: .now))
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Vision", trailing: "\(met.count)/\(CertainWay.Item.allCases.count) in the certain way")
                if vision.isEmpty {
                    Text("Write down what you want to have, do and become — clearly enough to picture it.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Write My Vision…") { editing = true }.buttonStyle(GhostButtonStyle())
                } else {
                    if let line = vision.headline {
                        Text(line).font(.system(size: 15, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    }
                    let rest = (vision.become.dropFirst() + vision.doing + vision.have).prefix(6)
                    if !rest.isEmpty {
                        Text(rest.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button { coach.readingVision = true } label: {
                            Label(log?.visioned == true ? "Read Today" : "Read It", systemImage: log?.visioned == true ? "checkmark" : "eye")
                        }
                        .buttonStyle(GhostButtonStyle())
                        Button("Edit") { editing = true }.buttonStyle(GhostButtonStyle())
                        Spacer()
                    }
                }
                let ready = vision.waiting.filter { $0.ready() <= day }
                if !vision.waiting.isEmpty {
                    Text("Waiting on · \(vision.waiting.count)\(ready.isEmpty ? "" : " · \(ready.count) ready to decide")")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    ForEach(vision.waiting) { d in
                        HStack(spacing: 8) {
                            Image(systemName: d.ready() <= day ? "checkmark.circle" : "hourglass").font(.system(size: 11))
                                .foregroundStyle(d.ready() <= day ? Theme.safe : Theme.textTertiary)
                            Text(d.title).font(.system(size: 13)).lineLimit(1)
                            Spacer()
                            if snapshot {
                                Text("from \(d.ready())").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            } else {
                                Button("Decided") { model.plan { p in p.vision?.waiting.removeAll { $0.id == d.id } } }
                                    .buttonStyle(.borderless).font(.system(size: 12))
                            }
                        }
                    }
                }
                Divider().opacity(0.4)
                // The certain way as chips: the first four are read from the day, the rest are yours to tick.
                FlowLayout(spacing: 6) {
                    ForEach(CertainWay.Item.allCases, id: \.self) { item in
                        let on = met.contains(item)
                        Button {
                            guard item.isSelfReported else { return }
                            model.updateLog(day) { l in
                                var ways = Set(l.ways ?? [])
                                if on { ways.remove(item.rawValue) } else { ways.insert(item.rawValue) }
                                l.ways = ways.sorted()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                                Text(item.short).font(.system(size: 12))
                            }
                            .padding(.horizontal, 9).frame(height: 26)
                            .background(Capsule().fill(on ? Theme.accent.opacity(0.18) : Theme.fill(0.05)))
                            .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .help(item.title + (item.isSelfReported ? "" : " — read from your day"))
                    }
                }
            }
        }
        .sheet(isPresented: $editing) { VisionEditor(vision: vision) }
        .sheet(isPresented: $coach.readingVision) { VisionSheet() }
    }
}

/// Reading the vision: the picture, the lists, the book's summary, and "I read it" (+5 XP, once a day).
struct VisionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let v = model.planner.vision ?? Vision()
        VStack(alignment: .leading, spacing: 16) {
            Text("Your vision").font(.system(size: 22, weight: .bold, design: .rounded))
            Scrolling {
                VStack(alignment: .leading, spacing: 14) {
                    if !v.picture.isEmpty {
                        Text(v.picture).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    list("Who I'm becoming", v.become)
                    list("What I'm doing", v.doing)
                    list("What I have", v.have)
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(title: "The certain way")
                        ForEach(CertainWay.summary, id: \.self) { line in
                            Text("• " + line).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxHeight: 440)
            Text("See it as already yours, and give thanks as if it has arrived.")
                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("I Read It — Thank You") {
                    model.updateLog(Planner.key(.now)) { $0.visioned = true }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 540)
    }

    @ViewBuilder func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: title)
                ForEach(items, id: \.self) { Text("• " + $0).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// Writing the vision: one thing per line, and the picture in the present tense.
struct VisionEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var become: String
    @State private var doing: String
    @State private var have: String
    @State private var picture: String
    @State private var waiting: [Decision]
    @State private var newDecision = ""

    init(vision: Vision) {
        _become = State(initialValue: vision.become.joined(separator: "\n"))
        _doing = State(initialValue: vision.doing.joined(separator: "\n"))
        _have = State(initialValue: vision.have.joined(separator: "\n"))
        _picture = State(initialValue: vision.picture)
        _waiting = State(initialValue: vision.waiting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your vision").font(.system(size: 17, weight: .bold))
            Text("Be definite: vague wishes don't move anything. One thing per line. Ask for enough — a better life, not a little more.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Scrolling {
                VStack(alignment: .leading, spacing: 12) {
                    field("Become", $become, "A calm founder who ships every week")
                    field("Do", $doing, "Run Connector SaaS full time\nTravel to Japan with family")
                    field("Have", $have, "₹1 Cr a year in revenue\nA quiet house with a studio")
                    field("The picture, as if it's already yours", $picture, "I wake up at 6 in the house with the studio…", height: 110)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Waiting on (when in doubt, wait \(Decision.days) days)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        ForEach(waiting) { d in
                            HStack {
                                Text(d.title).font(.system(size: 13))
                                Spacer()
                                Text("decide from \(d.ready())").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                                Button { waiting.removeAll { $0.id == d.id } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("A decision you're unsure about", text: $newDecision).textFieldStyle(.roundedBorder)
                                .onSubmit(park)
                            Button("Park", action: park).disabled(newDecision.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
            .frame(maxHeight: 520)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var v = Vision(have: Vision.lines(have), doing: Vision.lines(doing), become: Vision.lines(become),
                                   picture: picture.trimmingCharacters(in: .whitespacesAndNewlines), updated: .now)
                    v.waiting = waiting
                    model.plan { $0.vision = v }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 560)
    }

    func park() {
        let t = newDecision.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        waiting.append(Decision(title: t, parked: Planner.key(.now)))
        newDecision = ""
    }

    func field(_ title: String, _ text: Binding<String>, _ hint: String, height: CGFloat = 64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            TextEditor(text: text).font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(6).frame(height: height)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(hint).font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
        }
    }
}

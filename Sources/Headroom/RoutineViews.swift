import SwiftUI
import HeadroomCore

/// Routines: when to be nudged to plan the morning, sync the evening and review the week. The nudge only
/// reminds — its button runs the coach, exactly as the Coach card's buttons do.
struct RoutinesSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coach = LifeCoach.shared
    @Environment(\.dismiss) private var dismiss
    @State private var routines = LifeCoach.shared.routines

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Routines").font(.system(size: 17, weight: .bold))
            Text("A notification at these times with a button that starts the coach. Skipped when it's already done (the evening one once you've rated the day).")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            ForEach($routines) { $r in
                HStack(spacing: 12) {
                    Toggle(isOn: $r.on) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.kind.title).font(.system(size: 13, weight: .semibold))
                            Text(r.kind.body).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(2)
                        }
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    if r.kind == .week {
                        Picker("", selection: Binding(get: { r.weekday ?? 1 }, set: { r.weekday = $0 })) {
                            ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                        }
                        .labelsHidden().frame(width: 110)
                    }
                    DatePicker("", selection: time($r.at), displayedComponents: .hourAndMinute)
                        .labelsHidden().frame(width: 90)
                }
                .opacity(r.on ? 1 : 0.6)
            }
            if !model.notificationsEnabled {
                Label("Notifications are off in Settings, so routines stay quiet.", systemImage: "bell.slash")
                    .font(.system(size: 12)).foregroundStyle(Theme.review)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { coach.routines = routines; dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 540)
    }

    /// Minutes after midnight as a time of day for the picker.
    func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }
}

/// The shield's pause card: covers the screen when a distraction comes up during focus. Back to Work, or wait out
/// a short countdown for a few minutes of it. Nothing is closed or blocked — it's friction, not a wall.
@MainActor
final class PauseCard {
    static let shared = PauseCard()
    static let wait = 10, grant: TimeInterval = 5 * 60
    private var panel: NSPanel?
    /// What the card let through, until when (site or app → date).
    private(set) var allowed: [String: Date] = [:]
    var isShowing: Bool { panel != nil }

    func show(_ text: String, source: String, pid: pid_t?, isBrowser: Bool, model: AppModel) {
        guard panel == nil, let screen = NSScreen.main else { return }
        allowed = allowed.filter { $0.value > .now }
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: PauseCardView(text: text, back: { [weak self] in
            self?.close()
            // An app goes out of sight (⌘Tab brings it back); a browser stays — Headroom comes forward instead.
            if !isBrowser, let pid, let app = NSRunningApplication(processIdentifier: pid) { app.hide() }
            else { NSApp.activate() }
        }, allow: { [weak self] in
            self?.allowed[source] = Date().addingTimeInterval(Self.grant)
            self?.close()
        }).environmentObject(model))
        p.orderFrontRegardless()
        panel = p
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct PauseCardView: View {
    @EnvironmentObject var model: AppModel
    var text: String
    var vision: String? { model.planner.vision?.headline }
    var back: () -> Void
    var allow: () -> Void
    @State private var left = PauseCard.wait
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "pause.circle.fill").font(.system(size: 44)).foregroundStyle(Theme.accent)
                Text("Pause.").font(.system(size: 28, weight: .bold, design: .rounded))
                Text(text).font(.system(size: 15)).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = vision {
                    VStack(spacing: 4) {
                        Text("What you're becoming").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        Text(line).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
                    }
                }
                Text("Go fast, but never hurry.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                HStack(spacing: 12) {
                    Button(left > 0 ? "5 Minutes (\(left))" : "Give Me 5 Minutes", action: allow)
                        .buttonStyle(GhostButtonStyle()).disabled(left > 0)
                    Button("Back to Work", action: back).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
            .padding(36).frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.regularMaterial))
        }
        .onReceive(timer) { _ in if left > 0 { left -= 1 } }
    }
}

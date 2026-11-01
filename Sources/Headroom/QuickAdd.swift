import SwiftUI
import AppKit
import Carbon.HIToolbox
import HeadroomCore

/// ⌥N from any app: one line, Return adds it to today, ⌘Return makes it one of the Big 3, ⌥Return puts it
/// in the inbox. Capture has to be faster than forgetting.
@MainActor
final class QuickAddController {
    private var panel: QuickSearchPanel?
    private var hotKey: HotKey?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        update()
    }

    /// Registered only while the planner add-on is on.
    func update() {
        if model.plannerAddOn, hotKey == nil {
            hotKey = HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(optionKey)) { [weak self] in
                Task { @MainActor in self?.toggle() }
            }
        } else if !model.plannerAddOn {
            hotKey = nil
            panel?.orderOut(nil)
        }
    }

    func toggle() {
        if let panel, panel.isVisible { panel.orderOut(nil) } else { show() }
    }

    func show() {
        model.reloadPlannerIfChanged()
        let p = QuickSearchPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 92),
                                 styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { p.standardWindowButton($0)?.isHidden = true }
        p.contentView = NSHostingView(rootView: QuickAddView(close: { [weak p] in p?.orderOut(nil) }).environmentObject(model))
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: (f.midX - 280).rounded(), y: (f.maxY - 92 - f.height * 0.18).rounded()))
        }
        panel = p
        p.makeKeyAndOrderFront(nil)
    }
}

struct QuickAddView: View {
    @EnvironmentObject var model: AppModel
    var close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        let bigLeft = Planner.bigLimit - model.planner.bigToday().count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.accent)
                TextField("Add a task for today…", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 18)).focused($focused)
                    .onSubmit { add(big: NSEvent.modifierFlags.contains(.command), inbox: NSEvent.modifierFlags.contains(.option)) }
            }
            Text("↩ today   ⌘↩ \(bigLeft > 0 ? "one of the Big 3 (\(bigLeft) left)" : "Big 3 is full")   ⌥↩ inbox   esc close")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(width: 560, height: 92, alignment: .leading)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .onAppear { focused = true }
    }

    func add(big: Bool, inbox: Bool) {
        let title = text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { close(); return }
        model.addTask(title, big: big && !inbox, day: inbox ? nil : Planner.key(.now), source: .quickAdd)
        text = ""
        close()
    }
}

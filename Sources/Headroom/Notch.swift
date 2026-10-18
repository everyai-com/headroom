import SwiftUI
import AppKit
import HeadroomCore

/// The notch readout. Collapsed it wraps the camera housing like a Dynamic Island compact
/// view — a fill ring on the left, free space on the right. Hover and it grows into a
/// panel with the gauge, the biggest safe wins and a one-click reclaim.
struct NotchView: View {
    @EnvironmentObject var model: AppModel
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var expanded: Bool
    var openApp: () -> Void

    static let expandedSize = CGSize(width: 500, height: 228)
    static let wing: CGFloat = 74

    var body: some View {
        let v = model.volume
        let tint = Theme.color(for: v.health)
        ZStack(alignment: .top) {
            NotchShape(radius: expanded ? 28 : 11)
                .fill(Color.black)
                .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 22, y: 10)
            if expanded {
                expandedContent(v, tint: tint)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else {
                compact(v, tint: tint)
            }
        }
        .frame(width: expanded ? Self.expandedSize.width : notchWidth + Self.wing * 2,
               height: expanded ? Self.expandedSize.height : notchHeight)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: expanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // Leading ring + trailing value, either side of the camera (Yazio / Tide Guide pattern).
    func compact(_ v: VolumeStatus, tint: Color) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                GaugeRing(fraction: v.usedFraction, tint: tint, lineWidth: 3).frame(width: 15, height: 15)
                if model.safeReclaimable > 1_000_000_000 {
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.safe)
                }
            }
            .frame(width: Self.wing, alignment: .center)
            Spacer().frame(width: notchWidth)
            Text(ByteFormat.compact(v.free))
                .font(Theme.number(12.5, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: Self.wing, alignment: .center)
                .modifier(Pulse(active: v.health == .critical))
        }
        .frame(height: notchHeight)
    }

    func expandedContent(_ v: VolumeStatus, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer().frame(height: notchHeight - 6)
            HStack(spacing: 14) {
                ZStack {
                    GaugeRing(fraction: v.usedFraction, tint: tint, lineWidth: 5)
                    Text("\(Int((v.usedFraction * 100).rounded()))").font(Theme.number(12, weight: .bold))
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(v.free.gb).font(Theme.number(24, weight: .bold))
                        Text("free").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    }
                    Text("of \(v.total.gb) · \(v.health == .critical ? "critically low" : v.health == .tight ? "getting tight" : "healthy")")
                        .font(.system(size: 11.5)).foregroundStyle(v.health == .good ? Theme.textTertiary : tint)
                }
                Spacer()
                // Memory at a glance: how full RAM is, coloured by pressure.
                let m = model.memory
                let memTint = m.pressure == .critical ? Theme.critical : m.pressure == .warning ? Theme.review : Theme.textSecondary
                HStack(spacing: 5) {
                    Image(systemName: "memorychip").font(.system(size: 10, weight: .semibold))
                    Text("RAM \(Int((m.usedFraction * 100).rounded()))%").font(Theme.number(11.5, weight: .semibold))
                }
                .foregroundStyle(memTint)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(memTint.opacity(0.12)))
                .help("\(m.used.gb) of \(m.total.gb) memory in use · \(m.pressure.label.lowercased())")
                Button(action: openApp) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(GhostButtonStyle())
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.safeFindings.sorted { $0.reclaimable > $1.reclaimable }.prefix(3)) { f in
                    HStack(spacing: 8) {
                        Image(systemName: f.symbol).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.color(for: f.category)).frame(width: 14)
                        Text(f.project.map { "\($0) · \(f.title)" } ?? f.title).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Text(f.reclaimable.gb).font(Theme.number(12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    }
                }
                if model.safeFindings.isEmpty {
                    Text(model.lastScan == nil ? "Scanning…" : "Nothing safe to remove right now.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            Button {
                Task { await model.reclaim(safeOnly: true) }
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text(buttonLabel).contentTransition(.numericText())
                }
            }
            .buttonStyle(PrimaryButtonStyle(large: true))
            .disabled(model.safeReclaimable == 0 || model.isBusy)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 22).padding(.bottom, 18)
    }

    var buttonLabel: String {
        switch model.phase {
        case .reclaiming: "Reclaiming…"
        case .done(let freed): "+\(freed.gb) back"
        case .scanning: "Scanning…"
        case .idle: model.safeReclaimable > 0 ? "Free up \(model.safeReclaimable.gb) safely" : "All clean"
        }
    }
}

/// Flat top (it hangs from the screen edge), rounded bottom corners, like the notch itself.
struct NotchShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct Pulse: ViewModifier {
    var active: Bool
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .opacity(active && on ? 0.45 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

/// The borderless, always-on-top panel that sits over the notch.
@MainActor
final class NotchController {
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var monitors: [Any] = []
    private var expanded = false
    private let model: AppModel
    private let openApp: () -> Void

    init(model: AppModel, openApp: @escaping () -> Void) {
        self.model = model
        self.openApp = openApp
    }

    /// The built-in screen and its camera housing; falls back to a centred pill without a notch.
    struct Geometry {
        var screen: NSScreen
        var notchWidth: CGFloat
        var notchHeight: CGFloat
        var hasNotch: Bool
    }

    static func geometry() -> Geometry? {
        let screens = NSScreen.screens
        if let s = screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea {
            return Geometry(screen: s, notchWidth: right.minX - left.maxX, notchHeight: s.safeAreaInsets.top, hasNotch: true)
        }
        guard let main = NSScreen.main else { return nil }
        return Geometry(screen: main, notchWidth: 0, notchHeight: NSStatusBar.system.thickness, hasNotch: false)
    }

    func show() {
        guard panel == nil, let g = Self.geometry() else { return }
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = false
        self.panel = panel
        render(g)
        panel.orderFrontRegardless()

        // Expand when the pointer reaches the notch; collapse when it leaves the panel.
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.trackMouse() }
        }
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in handler(event); return event } as Any)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let g = Self.geometry() { self?.render(g) } }
        }
    }

    func hide() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    private func frame(for g: Geometry, expanded: Bool) -> NSRect {
        let size = expanded ? NotchView.expandedSize : CGSize(width: g.notchWidth + NotchView.wing * 2, height: g.notchHeight)
        let top = g.screen.frame.maxY
        return NSRect(x: g.screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }

    private func render(_ g: Geometry) {
        guard let panel else { return }
        let view = NotchView(notchWidth: g.notchWidth, notchHeight: g.notchHeight, expanded: expanded, openApp: { [weak self] in
            self?.collapse()
            self?.openApp()
        })
        .environmentObject(model)
        // The notch is black whatever the window looks like.
        .environment(\.colorScheme, .dark)
        if let hosting {
            hosting.rootView = AnyView(view)
        } else {
            let h = NSHostingView(rootView: AnyView(view))
            hosting = h
            panel.contentView = h
        }
        panel.setFrame(frame(for: g, expanded: expanded), display: true, animate: false)
    }

    private func trackMouse() {
        guard let g = Self.geometry() else { return }
        let p = NSEvent.mouseLocation
        let hot = frame(for: g, expanded: false).insetBy(dx: -6, dy: -4)
        let open = frame(for: g, expanded: true).insetBy(dx: -12, dy: -12)
        if !expanded, hot.contains(p) {
            expanded = true
            render(g)
            Task { await model.refreshVolume() }
        } else if expanded, !open.contains(p) {
            collapse()
        }
    }

    func collapse() {
        guard expanded, let g = Self.geometry() else { return }
        expanded = false
        render(g)
    }
}

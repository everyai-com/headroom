import SwiftUI
import HeadroomCore

/// Headroom's design system. Dark-first: the notch is black, so the whole app is built
/// around graphite surfaces, hairline borders, and one bright "safe" mint.
enum Theme {
    static let background = Color(hex: 0x0B0C10)
    static let surface = Color(hex: 0x14161C)
    static let surfaceRaised = Color(hex: 0x1B1E26)
    static let hairline = Color.white.opacity(0.08)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)

    static let safe = Color(hex: 0x3DF5A7)
    static let review = Color(hex: 0xFFB547)
    static let keep = Color(hex: 0x8A93A6)
    static let critical = Color(hex: 0xFF5A5F)

    static func color(for safety: Safety) -> Color {
        switch safety {
        case .safe: safe
        case .review: review
        case .keep: keep
        }
    }

    static func color(for health: VolumeStatus.Health) -> Color {
        switch health {
        case .good: safe
        case .tight: review
        case .critical: critical
        }
    }

    /// One colour per disk area — the map, the capacity bar and every legend agree.
    static func color(for area: DiskNode.Area) -> Color {
        switch area {
        case .system: Color(hex: 0x5B6475)
        case .apps: Color(hex: 0x6E7BFF)
        case .developer: Color(hex: 0xFF8A3D)
        case .projects: Color(hex: 0x2FD4C4)
        case .agents: Color(hex: 0xB07CFF)
        case .appData: Color(hex: 0x3EA6FF)
        case .caches: Color(hex: 0xF5D33D)
        case .media: Color(hex: 0xFF5FA2)
        case .documents: Color(hex: 0x8FB8FF)
        case .downloads: Color(hex: 0x9BE15D)
        case .systemData: Color(hex: 0x7C8495)
        case .other: Color(hex: 0x3A3F4B)
        case .free: Color(hex: 0x1E2027)
        }
    }

    static func color(for category: StorageCategory) -> Color {
        switch category {
        case .projectArtifacts: color(for: .projects)
        case .packageCaches: Color(hex: 0xF5D33D)
        case .developerTools: color(for: .developer)
        case .aiAgents: color(for: .agents)
        case .appCaches: Color(hex: 0x3EA6FF)
        case .browsers: Color(hex: 0x6E7BFF)
        case .logs: Color(hex: 0x7C8495)
        case .trash: Color(hex: 0xFF5FA2)
        case .userData: keep
        }
    }

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

// MARK: - Surfaces

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
            )
    }
}

struct SectionTitle: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase).kerning(0.6)
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 12)).foregroundStyle(Theme.textTertiary) }
        }
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.safe
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 16 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.88))
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 14 : 8)
            .frame(maxWidth: large ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: large ? 16 : 10, style: .continuous)
                    .fill(LinearGradient(colors: [tint, tint.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: tint.opacity(configuration.isPressed ? 0.15 : 0.35), radius: large ? 18 : 8, y: 4)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

// MARK: - Data visuals

/// The capacity ring: used fraction with a soft gradient and a glowing tip.
struct GaugeRing: View {
    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.002, min(1, fraction)))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.55), tint], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, fraction))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.45), radius: lineWidth * 0.6)
        }
    }
}

/// A horizontal bar split by segments (WhatsApp / Google One storage pattern).
struct SegmentedBar: View {
    struct Segment: Identifiable {
        var id: String
        var value: Double
        var color: Color
    }

    var segments: [Segment]
    var total: Double
    var height: CGFloat = 12

    var body: some View {
        // Never wider than the bar, whatever the inputs add up to.
        let scale = max(total, segments.reduce(0) { $0 + $1.value }, 1)
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(segments) { s in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(s.color)
                        .frame(width: max(2, geo.size.width * s.value / scale - 2))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: height / 2).fill(Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: height / 2, style: .continuous))
        }
        .frame(height: height)
    }
}

struct LegendDot: View {
    var color: Color
    var label: String
    var value: String?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if let value { Text(value).font(Theme.number(12, weight: .medium)).foregroundStyle(Theme.textPrimary) }
        }
    }
}

struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.28)))
    }
}

/// A round checkbox (PlayStation storage pattern) — a custom control so it renders everywhere.
struct CheckCircle: View {
    var on: Bool
    var tint: Color = Theme.safe
    var disabled = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? tint : Color.white.opacity(disabled ? 0.12 : 0.3), lineWidth: 1.5)
                .background(Circle().fill(on ? tint : .clear))
            if on {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black)
            }
        }
        .frame(width: 18, height: 18)
        .opacity(disabled ? 0.4 : 1)
    }
}

extension Int64 {
    var gb: String { ByteFormat.string(self) }
}

/// Wraps children onto new lines (chips that never hide offscreen).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Snapshot mode
// ImageRenderer can't draw ScrollView contents, so design renders lay scrolling content out
// flat. The live app always scrolls.

private struct SnapshotModeKey: EnvironmentKey { static let defaultValue = false }
private struct SnapshotScrollKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var snapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
    /// How far a snapshot shows scrolling content scrolled down (the demo reel).
    var snapshotScroll: CGFloat {
        get { self[SnapshotScrollKey.self] }
        set { self[SnapshotScrollKey.self] = newValue }
    }
}

struct Scrolling<Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    @Environment(\.snapshotScroll) private var scroll
    @ViewBuilder var content: Content

    var body: some View {
        if snapshot {
            // Natural height, pinned to the top, cut at the frame — like a scroll view at rest.
            // minHeight 0: take the space offered, never grow the window to fit the content.
            VStack(alignment: .leading, spacing: 0) { content }
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: -scroll)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        } else {
            ScrollView { content }.scrollIndicators(.never)
        }
    }
}

extension Date {
    var ago: String { RelativeDateTimeFormatter().localizedString(for: self, relativeTo: .now) }
}

// MARK: - Controls

/// A filter chip: white when on.
struct Pill: View {
    var title: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundStyle(on ? Color.black : Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.06)))
                .overlay(Capsule().strokeBorder(Theme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// A quiet search box that matches the dark surfaces.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            // ImageRenderer can't draw an NSTextField: snapshots show the prompt as text.
            if snapshot {
                Text(prompt).font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain).font(.system(size: 12.5))
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }
}

/// Nothing to show — said kindly, with what to try next.
struct EmptyState: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        Card {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.safe)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.safe.opacity(0.12)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The raised glass behind sticky action bars.
struct FloatingBarBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surfaceRaised.opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }
}

/// What just happened, at the bottom of the window — with Undo for anything trashed.
struct ToastView: View {
    var toast: AppModel.Toast
    var undo: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.failed ? Theme.review : Theme.safe)
            Text(toast.message).font(.system(size: 12.5, weight: .medium)).lineLimit(2)
            if toast.undo != nil {
                Button("Undo", action: undo).buttonStyle(GhostButtonStyle()).keyboardShortcut("z", modifiers: .command)
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(
            Capsule().fill(Theme.surfaceRaised)
                .overlay(Capsule().strokeBorder((toast.failed ? Theme.review : Theme.safe).opacity(0.35)))
                .shadow(color: .black.opacity(0.55), radius: 20, y: 8)
        )
        .frame(maxWidth: 640)
    }
}

import SwiftUI
import HeadroomCore

/// The two looks: colourful and friendly, or quiet black, white and grey. ⌃⌘T switches.
enum Look: String, CaseIterable, Identifiable {
    case playful, minimal
    var id: String { rawValue }
    var title: String { self == .playful ? "Playful" : "Minimal" }
}

/// Light, dark, or whatever the Mac is set to.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { self == .system ? "Match Mac" : rawValue.capitalized }
    var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
}

/// Headroom's design system. Every colour has a light and a dark value (resolved by the view's
/// colour scheme, so the notch stays dark in a light window), and the Minimal look trades the
/// colours for greys.
enum Theme {
    /// The current look. The window rebuilds when it changes, so plain reads are enough.
    nonisolated(unsafe) static var look: Look = Look(rawValue: UserDefaults.standard.string(forKey: "look") ?? "") ?? .playful
    static var minimal: Bool { look == .minimal }

    /// A colour with a value for light mode and one for dark mode.
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: dynamicNS(light, dark))
    }

    static func dynamic(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        dynamic(NSColor(hex: light, alpha: lightAlpha), NSColor(hex: dark, alpha: darkAlpha))
    }

    static func dynamicNS(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }

    static var background: Color { dynamic(light: 0xF3F3F5, dark: 0x0B0C10) }
    static var nsBackground: NSColor { dynamicNS(NSColor(hex: 0xF3F3F5), NSColor(hex: 0x0B0C10)) }
    static var surface: Color { dynamic(light: 0xFFFFFF, dark: 0x14161C) }
    static var surfaceRaised: Color { dynamic(light: 0xFFFFFF, dark: 0x1B1E26) }
    static var sidebar: Color { dynamic(light: 0xEBEBEE, dark: 0x101217) }
    static var hairline: Color { dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.08)) }
    static var textPrimary: Color { dynamic(light: 0x17181C, dark: 0xFFFFFF) }
    static var textSecondary: Color { dynamic(light: 0x17181C, dark: 0xFFFFFF, lightAlpha: 0.64, darkAlpha: 0.62) }
    static var textTertiary: Color { dynamic(light: 0x17181C, dark: 0xFFFFFF, lightAlpha: 0.44, darkAlpha: 0.38) }
    /// A quiet fill for controls and wells: white on dark, black on light.
    static func fill(_ opacity: Double) -> Color {
        dynamic(NSColor.black.withAlphaComponent(opacity * 0.75), NSColor.white.withAlphaComponent(opacity))
    }
    /// The soft shadow under cards in light mode (none in dark, where surfaces are lit instead).
    static var shadow: Color { dynamic(NSColor.black.withAlphaComponent(0.07), NSColor.clear) }

    static var safe: Color { dynamic(light: 0x0FB57E, dark: 0x3DF5A7) }
    static var review: Color { dynamic(light: 0xE8900C, dark: 0xFFB547) }
    static var keep: Color { dynamic(light: 0x6E7787, dark: 0x8A93A6) }
    static var critical: Color { dynamic(light: 0xE5484D, dark: 0xFF5A5F) }
    /// The main action colour: mint, or ink in the Minimal look.
    static var accent: Color { minimal ? textPrimary : safe }
    /// Text on a `textPrimary` fill (a selected pill).
    static var inverseText: Color { dynamic(light: 0xFFFFFF, dark: 0x0B0C10) }
    /// Text on an accent fill.
    static var onAccent: Color { minimal ? dynamic(light: 0xFFFFFF, dark: 0x0B0C10) : Color.black.opacity(0.88) }

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

    /// Greys for the Minimal look, stepped so neighbours stay apart.
    static func grey(_ step: Int) -> Color {
        let light: [UInt32] = [0x2B2D33, 0x4A4D55, 0x6B6E77, 0x8C8F97, 0xA9ACB3, 0xC4C6CB]
        let dark: [UInt32] = [0xF2F2F4, 0xC9CBD0, 0xA2A5AC, 0x7E828A, 0x60636B, 0x484B52]
        let i = ((step % light.count) + light.count) % light.count
        return dynamic(light: light[i], dark: dark[i])
    }

    /// One colour per disk area — the map, the capacity bar and every legend agree.
    static func color(for area: DiskNode.Area) -> Color {
        if minimal {
            if area == .free { return fill(0.06) }
            return grey(DiskNode.Area.allCases.firstIndex(of: area) ?? 0)
        }
        switch area {
        case .system: return Color(hex: 0x5B6475)
        case .apps: return Color(hex: 0x6E7BFF)
        case .developer: return Color(hex: 0xFF8A3D)
        case .projects: return Color(hex: 0x2FD4C4)
        case .agents: return Color(hex: 0xB07CFF)
        case .appData: return Color(hex: 0x3EA6FF)
        case .caches: return Color(hex: 0xF5D33D)
        case .media: return Color(hex: 0xFF5FA2)
        case .documents: return Color(hex: 0x8FB8FF)
        case .downloads: return Color(hex: 0x9BE15D)
        case .systemData: return Color(hex: 0x7C8495)
        case .other: return dynamic(light: 0xB9BDC6, dark: 0x3A3F4B)
        case .free: return fill(0.06)
        }
    }

    static func color(for category: StorageCategory) -> Color {
        if minimal { return grey(StorageCategory.allCases.firstIndex(of: category) ?? 0) }
        switch category {
        case .projectArtifacts: return color(for: .projects)
        case .worktrees: return Color(hex: 0xFF8A3D)
        case .packageCaches: return Color(hex: 0xF5D33D)
        case .developerTools: return color(for: .developer)
        case .aiAgents: return color(for: .agents)
        case .appCaches: return Color(hex: 0x3EA6FF)
        case .browsers: return Color(hex: 0x6E7BFF)
        case .logs: return Color(hex: 0x7C8495)
        case .trash: return Color(hex: 0xFF5FA2)
        case .userData: return keep
        }
    }

    /// Each shelf's own colour (the icon and accents).
    static func tint(for kind: FileKind) -> Color {
        if minimal { return textPrimary }
        switch kind {
        case .image: return dynamic(light: 0x7B66F0, dark: 0xA595FF)
        case .video: return dynamic(light: 0x2A86E6, dark: 0x5DB2FF)
        case .audio: return dynamic(light: 0xEC6F24, dark: 0xFF9452)
        case .document: return dynamic(light: 0x12A374, dark: 0x45D9A3)
        case .archive: return dynamic(light: 0xC99A06, dark: 0xF2C94C)
        case .app: return dynamic(light: 0xE5468A, dark: 0xFF73AE)
        case .other: return keep
        }
    }

    /// The pastel card behind a shelf (top, bottom of its gradient).
    static func shelf(for kind: FileKind) -> (Color, Color) {
        if minimal { return (dynamic(light: 0xF1F1F3, dark: 0x1F2127), dynamic(light: 0xE6E6E9, dark: 0x191B20)) }
        switch kind {
        case .image: return (dynamic(light: 0xEFEBFF, dark: 0x27223F), dynamic(light: 0xE1DAFF, dark: 0x1F1B33))
        case .video: return (dynamic(light: 0xE6F2FF, dark: 0x1A2A3F), dynamic(light: 0xD3E7FF, dark: 0x152233))
        case .audio: return (dynamic(light: 0xFFEFE5, dark: 0x3A261C), dynamic(light: 0xFFDFCC, dark: 0x2E1F17))
        case .document: return (dynamic(light: 0xE4F8EF, dark: 0x183128), dynamic(light: 0xCFF0E0, dark: 0x132820))
        case .archive: return (dynamic(light: 0xFFF7DC, dark: 0x352E17), dynamic(light: 0xFFEDB5, dark: 0x2A2513))
        case .app: return (dynamic(light: 0xFFE9F1, dark: 0x3A1D2B), dynamic(light: 0xFFD6E6, dark: 0x2E1722))
        case .other: return (fill(0.05), fill(0.08))
        }
    }

    static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
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
                    .shadow(color: Theme.shadow, radius: 14, y: 4)
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
    var tint: Color = Theme.accent
    var large = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // A flat fill, no glow: the colour alone says "this one". Press lands on press-in, short and
    // ease-out (a spring here would wobble a control you click dozens of times a day).
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: large ? 15 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.minimal ? Theme.onAccent : Color.black.opacity(0.88))
            .padding(.horizontal, large ? 24 : 16)
            .padding(.vertical, large ? 12 : 8)
            .frame(maxWidth: large ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: large ? 16 : 12, style: .continuous)
                    .fill(tint)
                    .overlay(RoundedRectangle(cornerRadius: large ? 16 : 12, style: .continuous)
                        .fill(Color.black.opacity(configuration.isPressed ? 0.12 : 0)))
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary.opacity(configuration.isPressed ? 0.6 : 0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill(configuration.isPressed ? 0.12 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Data visuals

/// The capacity ring: used fraction with a soft gradient.
struct GaugeRing: View {
    var fraction: Double
    var tint: Color
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(Theme.fill(0.07), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.002, min(1, fraction)))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.55), tint], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * max(0.01, fraction))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
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
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(s.color)
                        .frame(width: max(2, geo.size.width * s.value / scale - 2))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: height / 2).fill(Theme.fill(0.06)))
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
    var tint: Color = Theme.accent
    var disabled = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? tint : Theme.fill(disabled ? 0.12 : 0.3), lineWidth: 1.5)
                .background(Circle().fill(on ? tint : .clear))
            if on {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(Theme.minimal ? Theme.onAccent : .black)
            }
        }
        .frame(width: 18, height: 18)
        .opacity(disabled ? 0.4 : 1)
        // An empty circle is transparent: without this only its 1.5pt ring takes clicks.
        .padding(6)
        .contentShape(Rectangle())
        .padding(-6)
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
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).fixedSize()
                .foregroundStyle(on ? Theme.inverseText : Theme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(on ? Theme.textPrimary : Theme.fill(0.06)))
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
                Text(prompt).font(.system(size: 13)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textTertiary))
                    .textFieldStyle(.plain).font(.system(size: 13))
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Theme.fill(0.06)))
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
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The raised glass behind sticky action bars.
struct FloatingBarBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surfaceRaised.opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
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
            Text(toast.message).font(.system(size: 13, weight: .medium)).lineLimit(2)
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
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        )
        .frame(maxWidth: 640)
    }
}

/// A full-width action button: filled for the main action, outlined for the rest.
struct WideButtonStyle: ButtonStyle {
    var tint: Color
    var filled: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(filled ? (Theme.minimal ? Theme.onAccent : Color.black.opacity(0.88)) : tint)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.08)))
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(filled ? 0 : 0.3)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

import SwiftUI
import HeadroomCore

enum Screen: String, CaseIterable, Identifiable {
    case overview = "Overview", map = "Map", reclaim = "Reclaim", files = "Large files", apps = "Apps", activity = "Activity",
         settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .map: "square.grid.3x3.square"
        case .reclaim: "sparkles"
        case .files: "doc.text.magnifyingglass"
        case .apps: "app.badge"
        case .activity: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State var screen: Screen = .overview
    var launchAtLogin: Binding<Bool> = .constant(false)
    /// The demo reel opens screens in a set state (a drilled-in map, a selection…).
    var override: AnyView? = nil

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text(screen.rawValue).font(.system(size: 26, weight: .bold, design: .rounded))
                    Spacer()
                    statusLine
                }
                content
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(Theme.textPrimary)
        .background(
            ZStack {
                Theme.background
                RadialGradient(colors: [Theme.safe.opacity(0.07), .clear], center: .topTrailing, startRadius: 10, endRadius: 600)
            }
        )
        .preferredColorScheme(.dark)
        .task(id: screen) {
            if screen == .apps, model.apps.isEmpty { await model.scanApps() }
        }
    }

    @ViewBuilder var content: some View {
        if let override { override } else { screenContent }
    }

    @ViewBuilder var screenContent: some View {
        switch screen {
        case .overview: OverviewView(openReclaim: { screen = .reclaim }, openMap: { screen = .map })
        case .map: MapView()
        case .reclaim: ReclaimView()
        case .files: FilesView()
        case .apps: AppsView()
        case .activity: ActivityView()
        case .settings: SettingsView(launchAtLogin: launchAtLogin)
        }
    }

    var statusLine: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .scanning(let s), .reclaiming(let s):
                ProgressView().controlSize(.small)
                Text(s).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            case .done(let freed):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.safe)
                Text("Freed \(freed.gb)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.safe)
            case .idle:
                if let last = model.lastScan {
                    Text("Scanned \(last.ago)").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                Button {
                    Task { await model.scan(); await model.buildMap() }
                } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    GaugeRing(fraction: model.volume.usedFraction, tint: Theme.color(for: model.volume.health), lineWidth: 4)
                        .frame(width: 22, height: 22)
                }
                Text("Headroom").font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 10).padding(.top, 34).padding(.bottom, 22)

            ForEach(Screen.allCases.filter { $0 != .settings }) { navItem($0) }
            Spacer()
            navItem(.settings)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.volume.free.gb).font(Theme.number(15, weight: .bold)).foregroundStyle(Theme.color(for: model.volume.health))
                Text("free of \(model.volume.total.gb)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
            .padding(.top, 8)
        }
        .padding(14)
        .frame(width: 210)
        .background(Theme.surface.opacity(0.6))
    }

    func navItem(_ s: Screen) -> some View {
        Button { screen = s } label: {
            HStack(spacing: 10) {
                Image(systemName: s.symbol).font(.system(size: 13, weight: .semibold)).frame(width: 18)
                Text(s.rawValue).font(.system(size: 13.5, weight: screen == s ? .semibold : .medium))
                Spacer()
                if s == .reclaim, model.safeReclaimable > 0 {
                    Text(ByteFormat.compact(model.safeReclaimable)).font(Theme.number(11, weight: .bold))
                        .foregroundStyle(.black).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.safe))
                }
            }
            .foregroundStyle(screen == s ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(screen == s ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

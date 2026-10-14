import SwiftUI
import AppKit
import HeadroomCore

/// Renders every screen with real scan data to PNGs — how the design is reviewed without
/// clicking through the app (`Headroom --render <dir>`).
@MainActor
enum Snapshots {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await model.scan()
            await model.buildMap()
            await model.scanApps()
            done.signal()
        }
        // Drive the main run loop until the scans finish.
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let size = CGSize(width: 1180, height: 780)
        for screen in Screen.allCases {
            save(MainView(screen: screen).environmentObject(model), size: size, to: dir.appendingPathComponent("\(screen.rawValue.lowercased()).png"))
        }
        // The notch, collapsed and expanded, over a wallpaper-ish backdrop with the camera housing drawn in.
        let g = NotchController.geometry()
        let notchW = g.map { $0.notchWidth > 0 ? $0.notchWidth : 185 } ?? 185
        let notchH = g.map { $0.notchHeight } ?? 32
        for expanded in [false, true] {
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: 0x2B3A67), Color(hex: 0x6A4C93), Color(hex: 0xC06C84)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                NotchView(notchWidth: notchW, notchHeight: notchH, expanded: expanded, openApp: {})
                    .environmentObject(model)
                // The physical notch, so the composite shows how it wraps the camera.
                NotchShape(radius: 9).fill(Color.black).frame(width: notchW, height: notchH)
            }
            save(view, size: CGSize(width: 760, height: expanded ? 300 : 110),
                 to: dir.appendingPathComponent(expanded ? "notch-expanded.png" : "notch-collapsed.png"))
        }
        print("rendered to \(dir.path)")
    }

    /// The app icon: a glowing capacity ring on a graphite squircle, with the notch at the top.
    static func renderIcon(to url: URL) {
        let icon = ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1C2029), Color(hex: 0x07080B)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 230, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 6))
                .padding(100)
            GaugeRing(fraction: 0.72, tint: Theme.safe, lineWidth: 64).frame(width: 470, height: 470)
            Image(systemName: "sparkles").font(.system(size: 150, weight: .bold)).foregroundStyle(Theme.safe)
                .shadow(color: Theme.safe.opacity(0.6), radius: 30)
            NotchShape(radius: 38).fill(Color.black).frame(width: 300, height: 74).offset(y: -312)
        }
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: icon)
        renderer.scale = 1
        if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    static func save<V: View>(_ view: V, size: CGSize, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.snapshotMode, true).preferredColorScheme(.dark))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            print("could not render \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }
}

import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import HeadroomCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    private var notch: NotchController?
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var monitor: Timer?
    private var lastAlert: Date?
    private var lastAutoReclaim: Date?
    private var updateItem: NSMenuItem?
    private var notifiedVersion: String?
    private var ticks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lives in the notch & menu bar; a Dock icon only while the window is open.
        NSApp.setActivationPolicy(.accessory)

        notch = NotchController(model: model) { [weak self] in self?.openWindow() }
        if model.showNotch { notch?.show() }
        setupStatusItem()

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task {
            await model.scan()
            await model.buildMap()
            await checkForUpdates()
        }
        // Watch: free space every 30 s (cheap), the reclaim scan every 30 min.
        monitor = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if CommandLine.arguments.contains("--open") || !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            openWindow()
        }
    }

    private func tick() {
        ticks += 1
        model.refreshVolume()
        updateStatusItem()
        if model.showNotch { notch?.show() } else { notch?.hide() }
        if ticks % 60 == 0 { Task { await model.scan() } }
        // The map every 6 hours, so growth can be compared folder by folder.
        if ticks % 720 == 0, model.mapProgress == nil { Task { await model.buildMap() } }
        if ticks % 2880 == 0 { Task { await checkForUpdates() } } // daily
        checkForAlert()
    }

    /// Tell the user before it's a problem: below the threshold, or a fast drop (an agent
    /// installing dependencies, a build gone wild). At most one alert every 3 hours.
    private func checkForAlert() {
        let v = model.volume
        let threshold = Int64(model.lowSpaceThresholdGB * 1_000_000_000)
        if model.autoReclaim, v.free < threshold, model.safeReclaimable > 0, !model.isBusy,
           lastAutoReclaim.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true {
            lastAutoReclaim = .now
            Task { await autoReclaim() }
            return
        }
        guard model.notificationsEnabled else { return }
        if let last = lastAlert, Date().timeIntervalSince(last) < 3 * 3600 { return }
        let lostHour = model.history.lost(overHours: 1, now: v) ?? 0
        var title: String?
        var body = ""
        if v.free < threshold {
            title = "Only \(v.free.gb) left on your Mac"
            body = model.safeReclaimable > 0
                ? "Headroom can safely get back \(model.safeReclaimable.gb) — caches and build output only."
                : "Open Headroom to see where it went."
        } else if lostHour > 5_000_000_000 {
            // Measure first, so the alert can name the folder instead of "somewhere".
            lastAlert = .now
            Task {
                await model.buildMap()
                let top = model.growthChanges(overHours: 1).filter { $0.delta > 0 }.prefix(2)
                notify("Your disk lost \(lostHour.gb) in the last hour",
                       top.isEmpty ? "Usually an agent installing dependencies or a build cache growing. Open Headroom to see where."
                                   : "Mostly " + top.map { "\($0.name) (+\($0.delta.gb))" }.joined(separator: " and ") + ".")
            }
            return
        }
        guard let title else { return }
        lastAlert = .now
        notify(title, body)
    }

    /// Below the threshold with auto-reclaim on: the safe set only, then say exactly what went.
    private func autoReclaim() async {
        guard let result = await model.reclaim(safeOnly: true, automatic: true) else { return }
        let gone = result.plan.filter { result.report.reclaimed.contains($0.id) }
        guard model.notificationsEnabled, !gone.isEmpty else { return }
        let names = gone.sorted { $0.reclaimable > $1.reclaimable }.prefix(3).map { f in f.project.map { "\($0) \(f.title)" } ?? f.title }
        notify("Headroom freed \(result.report.freedBytes.gb) automatically",
               names.joined(separator: ", ") + (gone.count > 3 ? " and \(gone.count - 3) more" : "") + ". See Activity for the full list.")
    }

    /// A newer release: one notification per version, and a menu bar item until it's installed.
    private func checkForUpdates() async {
        guard let release = await model.checkForUpdates() else { return }
        updateItem?.title = "Update available — Headroom \(release.version)"
        updateItem?.isHidden = false
        if notifiedVersion != release.version, model.notificationsEnabled {
            notifiedVersion = release.version
            notify("Headroom \(release.version) is available", release.notes ?? "Open the menu bar item to get it.")
        }
    }

    @objc private func openUpdate() {
        if let url = model.update?.url { NSWorkspace.shared.open(url) }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { openWindow() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Headroom", action: #selector(openWindowAction), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Reclaim safely", action: #selector(reclaimAction), keyEquivalent: "r").target = self
        let update = menu.addItem(withTitle: "Update available", action: #selector(openUpdate), keyEquivalent: "")
        update.target = self
        update.isHidden = true
        updateItem = update
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Headroom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        updateStatusItem()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let v = model.volume
        button.image = NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: "Headroom")
        button.imagePosition = .imageLeading
        button.title = " " + ByteFormat.compact(v.free)
        button.contentTintColor = v.health == .critical ? .systemRed : v.health == .tight ? .systemOrange : nil
    }

    @objc private func openWindowAction() { openWindow() }
    @objc private func reclaimAction() { Task { await model.reclaim(safeOnly: true) } }

    // MARK: Window

    func openWindow() {
        if window == nil {
            let launch = Binding<Bool>(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }
            )
            let root = MainView(launchAtLogin: launch).environmentObject(model)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(Theme.background)
            w.minSize = NSSize(width: 980, height: 660)
            w.contentView = NSHostingView(rootView: root)
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

if let i = CommandLine.arguments.firstIndex(of: "--icon"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Snapshots.renderIcon(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    exit(0)
}

// Demo reel: `Headroom --reel <dir> --demo` (see scripts/make-reel.sh).
if let i = CommandLine.arguments.firstIndex(of: "--reel"), CommandLine.arguments.count > i + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Reel.make(to: dir)
    }
    exit(0)
}

// Design review: `Headroom --render <dir>` scans for real, then draws every screen to PNG.
if let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > i + 1 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        Snapshots.render(to: dir)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()

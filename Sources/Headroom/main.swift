import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
import HeadroomCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()
    lazy var library = LibraryModel(app: model)
    private var notch: NotchController?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var quickSearch: QuickSearchController?
    private var quickAdd: QuickAddController?
    private var window: NSWindow?
    private var monitor: Timer?
    private var lastAlert: Date?
    private var lastAutoReclaim: Date?
    private var notifiedVersion: String?
    private var ticks = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App Store edition: reopen the folders you granted before anything scans.
        FolderAccess.shared.restore()
        // Lives in the notch & menu bar; a Dock icon only while the window is open.
        NSApp.setActivationPolicy(.accessory)

        MainView.apply(Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system)
        notch = NotchController(model: model) { [weak self] in self?.openWindow() }
        if model.showNotch { notch?.show() }
        setupStatusItem()
        NSApp.mainMenu = mainMenu()
        quickSearch = QuickSearchController(library: library)
        quickAdd = QuickAddController(model: model)
        NotificationCenter.default.addObserver(forName: .headroomOpenWindow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openWindow() }
        }
        NotificationCenter.default.addObserver(forName: .headroomSearch, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let query = note.object as? String else { return }
                self.openWindow()
                self.library.search(query)
            }
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // The library (seconds) doesn't wait for the reclaim scan (can be a minute on a full disk).
        Task {
            await library.scan()
            // Duplicates in the background, so Home's Clean up shows them without a click.
            try? await Task.sleep(for: .seconds(20))
            await library.findDuplicates()
        }
        Task {
            await model.scan()
            library.refreshSuggestions()
            await model.buildMap()
            await checkForUpdates()
        }
        // Watch: free space every 30 s (cheap), the reclaim scan every 30 min.
        monitor = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Opened by hand (Finder, Spotlight, Launchpad): show the window. Started at login: stay quiet
        // in the notch and menu bar.
        if CommandLine.arguments.contains("--open") || !launchedAsLoginItem || !UserDefaults.standard.bool(forKey: "launchedBefore") {
            UserDefaults.standard.set(true, forKey: "launchedBefore")
            openWindow()
        }
    }

    private func tick() {
        ticks += 1
        model.refreshVolume()
        model.memory = MemoryStatus.current()
        model.refreshBattery(record: true)
        model.reloadPlannerIfChanged()
        quickAdd?.update()
        nudgeHabits()
        updateStatusItem()
        checkMemory()
        if model.showNotch { notch?.show() } else { notch?.hide() }
        if ticks % 60 == 0 { Task { await model.scan(); await library.scan() } }
        runAutoRules()
        // The map every 6 hours, so growth can be compared folder by folder.
        if ticks % 720 == 0, model.mapProgress == nil { Task { await model.buildMap() } }
        if ticks % 2880 == 0 { Task { await checkForUpdates() } } // daily
        checkForAlert()
    }

    /// A habit's nudge, once a day at its time, while it's still undone: the cue plus the two-minute
    /// version, so the easiest way to keep the streak is right there.
    private func nudgeHabits() {
        guard model.plannerAddOn, model.notificationsEnabled else { return }
        let now = Date()
        let minute = Calendar.current.component(.hour, from: now) * 60 + Calendar.current.component(.minute, from: now)
        let today = Planner.key(now)
        var nudged = UserDefaults.standard.dictionary(forKey: "habitNudged") as? [String: String] ?? [:]
        for h in model.planner.habitsDue(now) where !h.isDone(now) {
            guard let at = h.remindAt, minute >= at, minute < at + 120, nudged[h.id.uuidString] != today else { continue }
            nudged[h.id.uuidString] = today
            var body = [h.cue.map { "Cue: \($0)." }, h.twoMinute.map { "Even just: \($0)." }].compactMap { $0 }.joined(separator: " ")
            if case .missedOnce = h.streak(now) { body = "Never miss twice — today keeps the streak. " + body }
            notify(h.title, body.isEmpty ? "A vote for being \(h.identity ?? "who you want to be")." : body)
        }
        UserDefaults.standard.set(nudged.filter { $0.value == today }, forKey: "habitNudged")
    }

    private var criticalTicks = 0
    private var lastMemoryAlert: Date?

    /// Out of memory for a minute straight: say so, and name what's using it.
    private func checkMemory() {
        // The App Store edition can't see other processes, so it can't name what to quit.
        guard Edition.available(.memory) else { return }
        criticalTicks = model.memory.pressure == .critical ? criticalTicks + 1 : 0
        guard criticalTicks >= 2, model.notificationsEnabled,
              lastMemoryAlert.map({ Date().timeIntervalSince($0) > 3600 }) ?? true else { return }
        lastMemoryAlert = .now
        Task {
            await model.refreshMemory()
            let top = model.memoryGroups.filter { model.quitRefusal($0) == nil }.prefix(2)
            notify("Your Mac is out of memory",
                   top.isEmpty ? "Apps may freeze. Open Headroom to see what's using it."
                       : top.map { "\($0.name) is using \($0.footprint.gb)" }.joined(separator: ", ") + ". Open Headroom to quit what you don't need.")
        }
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
                ? "Headroom can safely get back \(model.safeReclaimable.gb) — only temporary files that come back on their own."
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

    /// The optional tidy-up rules (Settings → Automatic clean up), at most every 6 hours.
    private func runAutoRules() {
        let d = UserDefaults.standard
        let trashInstallers = d.bool(forKey: "autoTrashInstallers"), fileScreenshots = d.bool(forKey: "autoFileScreenshots")
        let last = d.object(forKey: "lastAutoRules") as? Date
        guard trashInstallers || fileScreenshots, library.hasScanned, !model.isBusy, !library.scanning,
              last.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true else { return }
        d.set(Date(), forKey: "lastAutoRules")
        let index = library.index
        let guardrail = model.guardrail
        Task {
            var notes: [String] = []
            if trashInstallers {
                let plan = AutoRules.oldInstallerPlan(index, home: HeadroomPaths.home, days: 30)
                if !plan.isEmpty {
                    let report = await Task.detached(priority: .utility) { Cleaner(guardrail: guardrail).reclaim(plan) }.value
                    let done = plan.filter { report.reclaimed.contains($0.id) }
                    if !done.isEmpty {
                        let landed = Dictionary(report.trashed.map { ($0.original.path, $0.inTrash.path) }, uniquingKeysWith: { a, _ in a })
                        model.activity.record(.init(kind: .trashed, title: done.count == 1 ? done[0].title : "\(done.count) old installers",
                                                    bytes: done.reduce(0) { $0 + $1.reclaimable },
                                                    items: done.flatMap(\.paths).map { .init(original: $0.path, inTrash: landed[$0.path]) },
                                                    automatic: true))
                        notes.append("moved \(done.count) old installer\(done.count == 1 ? "" : "s") to the Trash")
                    }
                }
            }
            if fileScreenshots {
                let moves = AutoRules.screenshotMoves(index, folder: AutoRules.screenshotFolder())
                if !moves.isEmpty {
                    let result = await Task.detached(priority: .utility) { AutoRules.perform(moves, guardrail: guardrail) }.value
                    if !result.moved.isEmpty {
                        model.activity.record(AutoRules.entry(for: result.moved, automatic: true))
                        notes.append("filed \(result.moved.count) screenshot\(result.moved.count == 1 ? "" : "s") into monthly folders")
                    }
                }
            }
            guard !notes.isEmpty else { return }
            await library.scan()
            if model.notificationsEnabled {
                notify("Headroom tidied up", notes.joined(separator: " and ").prefix(1).uppercased() + notes.joined(separator: " and ").dropFirst()
                       + ". Put anything back from Activity.")
            }
        }
    }

    /// A newer release: one notification per version (the menu bar shows it until it's installed).
    private func checkForUpdates() async {
        guard let release = await model.checkForUpdates() else { return }
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
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        updateStatusItem()
    }

    /// Free space, the safe reclaim and your newest downloads, in a popover.
    @objc private func togglePopover() {
        if let popover, popover.isShown { popover.performClose(nil); return }
        guard let button = statusItem?.button else { return }
        let p = popover ?? NSPopover()
        p.behavior = .transient
        p.animates = true
        let view = MenuBarView(openWindow: { [weak self] in self?.openWindow() },
                               quickSearch: { [weak self] in self?.quickSearch?.show() },
                               close: { [weak p] in p?.performClose(nil) })
            .environmentObject(model)
            .environmentObject(library)
        p.contentViewController = NSHostingController(rootView: view)
        popover = p
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let v = model.volume
        button.image = NSImage(systemSymbolName: "internaldrive.fill", accessibilityDescription: "Headroom")
        button.imagePosition = .imageLeading
        button.title = " " + ByteFormat.compact(v.free)
        button.contentTintColor = v.health == .critical ? .systemRed : v.health == .tight ? .systemOrange : nil
    }

    /// The menu bar while the window is open. Text fields only get ⌘C/⌘V/⌘X/⌘Z/⌘A through an Edit
    /// menu (the grid takes ⌘C/⌘A as `onCommand`, so these never steal copy from it either).
    private func mainMenu() -> NSMenu {
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = NSMenu(title: title)
            items.forEach { top.submenu?.addItem($0) }
            return top
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = modifiers
            return i
        }
        let quit = item("Quit Headroom", #selector(quitFromMenu), "q")
        quit.target = self
        let bar = NSMenu()
        bar.addItem(menu("Headroom", [
            item("Hide Headroom", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            quit,
        ]))
        bar.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        bar.addItem(window)
        NSApp.windowsMenu = window.submenu
        return bar
    }

    /// ⌘Q quits from the window — but not from Quick Search, which floats over other apps
    /// (⌘Q there was meant for the app underneath).
    @objc private func quitFromMenu() { NSApp.terminate(nil) }

    @objc private func openWindowAction() { openWindow() }
    @objc private func reclaimAction() { Task { await model.reclaim(safeOnly: true) } }

    // MARK: Window

    func openWindow() {
        if window == nil {
            let launch = Binding<Bool>(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }
            )
            let root = MainView(launchAtLogin: launch).environmentObject(model).environmentObject(library)
            let w = HeadroomWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = false
            w.backgroundColor = Theme.nsBackground
            // Small enough to tile into a third or a quarter of the screen: the cards shrink to fit.
            w.minSize = NSSize(width: 640, height: 480)
            w.setFrameAutosaveName("HeadroomMain")
            w.contentView = NSHostingView(rootView: root)
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        // Keep the window above the Dock and below the menu bar, so nothing in it is hidden.
        if let w = window, let visible = (w.screen ?? NSScreen.main)?.visibleFrame, !visible.contains(w.frame) {
            var f = w.frame.intersection(visible)
            if f.width < w.minSize.width || f.height < w.minSize.height {
                f.size = NSSize(width: min(max(w.frame.width, w.minSize.width), visible.width),
                                height: min(max(w.frame.height, w.minSize.height), visible.height))
                f.origin = NSPoint(x: visible.midX - f.width / 2, y: visible.midY - f.height / 2)
            }
            w.setFrame(f, display: true)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        library.refreshIfStale(minutes: 5)
    }

    /// macOS marks the launch event of a login item ('lgit'); there's no other signal.
    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// headroom://search?q=pdfs%20from%20gmail, headroom://open?screen=worktrees and headroom://login?on=1 — for Shortcuts, scripts and links.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "headroom" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if url.host == "search", let q = items.first(where: { $0.name == "q" })?.value {
                NotificationCenter.default.post(name: .headroomSearch, object: q)
            } else if url.host == "login", let on = items.first(where: { $0.name == "on" })?.value {
                // headroom://login?on=1 — Open at Login, exactly as Settings' toggle does it.
                do {
                    if on == "1" { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    model.show(on == "1" ? "Headroom opens at login — Quick Search is always a keypress away" : "Headroom won't open at login")
                } catch {
                    model.show("Couldn't change Open at Login: \(error.localizedDescription)", failed: true)
                }
            } else if url.host == "open", let name = items.first(where: { $0.name == "screen" })?.value,
                      let screen = Screen.allCases.first(where: { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") == name.lowercased() }),
                      Edition.available(screen) {
                // headroom://open?screen=worktrees (or build-output, dev-caches, duplicates…)
                library.requestedScreen = screen
                openWindow()
                NotificationCenter.default.post(name: .headroomShowScreen, object: screen)
            } else {
                openWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action != #selector(quitFromMenu) || !(NSApp.keyWindow is QuickSearchPanel)
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

// Made-up files for screenshots: `Headroom --seed-library <home>` (scripts/demo-seed.sh).
if let i = CommandLine.arguments.firstIndex(of: "--seed-library"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        DemoLibrary.seed(home: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
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

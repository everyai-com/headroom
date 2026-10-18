import SwiftUI
import AppKit
import HeadroomCore

/// Finder's mouse behaviour on top of a SwiftUI card: click selects (⌘ toggles, ⇧ extends),
/// a double click opens, dragging carries every selected file out to Mail, Slack or Figma,
/// and a right click shows the menu.
struct FileInteraction: NSViewRepresentable {
    var onClick: (NSEvent.ModifierFlags, Int) -> Void
    var isInMultiSelection: () -> Bool
    var dragURLs: () -> [URL]
    var menu: () -> NSMenu?
    var onHover: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> InteractionView {
        let v = InteractionView()
        update(v)
        return v
    }

    func updateNSView(_ v: InteractionView, context: Context) { update(v) }

    private func update(_ v: InteractionView) {
        v.onClick = onClick
        v.isInMultiSelection = isInMultiSelection
        v.dragURLs = dragURLs
        v.menuProvider = menu
        v.onHover = onHover
    }
}

final class InteractionView: NSView, NSDraggingSource {
    var onClick: (NSEvent.ModifierFlags, Int) -> Void = { _, _ in }
    var isInMultiSelection: () -> Bool = { false }
    var dragURLs: () -> [URL] = { [] }
    var menuProvider: () -> NSMenu? = { nil }
    var onHover: (Bool) -> Void = { _ in }

    private var down: NSEvent?
    private var dragging = false
    /// Clicking one of several selected files keeps them all selected until the mouse comes up
    /// without a drag — so a drag carries the whole selection.
    private var collapseOnUp = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        down = event
        dragging = false
        let plain = event.modifierFlags.intersection([.command, .shift]).isEmpty
        if event.clickCount == 1, plain, isInMultiSelection() {
            collapseOnUp = true
        } else {
            collapseOnUp = false
            onClick(event.modifierFlags, event.clickCount)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if collapseOnUp, !dragging { onClick([], 1) }
        collapseOnUp = false
        down = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, !dragging else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        dragging = true
        if !collapseOnUp, !isInMultiSelection() { onClick(down.modifierFlags, 1) }
        let urls = dragURLs()
        guard !urls.isEmpty else { return }
        let origin = convert(down.locationInWindow, from: nil)
        let items: [NSDraggingItem] = urls.prefix(60).enumerated().map { i, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 48, height: 48)
            let offset = CGFloat(min(i, 4)) * 6
            item.setDraggingFrame(NSRect(x: origin.x - 24 + offset, y: origin.y - 24 - offset, width: 48, height: 48), contents: icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    /// Copy only: a move (or `.generic`, which Finder and the Dock's Trash treat as one) would move or
    /// trash your file behind the library's back — no confirm, no Activity entry, no Undo.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if !isInMultiSelection() { onClick([], 1) }
        return menuProvider()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, key: String = "", modifiers: NSEvent.ModifierFlags = .command,
         enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        isEnabled = enabled
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

@MainActor
enum FileMenu {
    /// The right-click menu for one file or the selection it's part of.
    static func make(for item: LibraryItem, library: LibraryModel, revealInApp: Bool = false) -> NSMenu {
        let targets = library.targets(for: item)
        let many = targets.count > 1
        let menu = NSMenu()
        menu.autoenablesItems = false
        let openTitle = item.isFolder ? "Open" : item.kind == .audio ? "Play" : many ? "Open \(targets.count) Items" : "Open"
        menu.addItem(ActionMenuItem(openTitle, symbol: item.kind == .audio ? "play.fill" : "arrow.up.forward.app") {
            if item.isFolder || item.kind == .audio { library.open(item) } else { targets.forEach { NSWorkspace.shared.open($0.url) } }
        })
        if !item.isFolder, !many {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: item.url).prefix(10)
            if !apps.isEmpty {
                let sub = NSMenu()
                for appURL in apps {
                    let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
                    let entry = ActionMenuItem(name) {
                        NSWorkspace.shared.open([item.url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                    }
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                    sub.addItem(entry)
                }
                let holder = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                holder.submenu = sub
                menu.addItem(holder)
            }
        }
        menu.addItem(ActionMenuItem("Quick Look", symbol: "eye", key: " ", modifiers: []) {
            QuickLook.shared.show(library: library, items: library.visible.isEmpty ? targets : library.visible, current: item)
        })
        if revealInApp {
            menu.addItem(ActionMenuItem("Show in Headroom", symbol: "sidebar.left") { library.showInApp(item) })
        }
        menu.addItem(ActionMenuItem("Show in Finder", symbol: "folder", key: "r") { library.reveal(targets) })
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(many ? "Copy \(targets.count) Items" : "Copy", symbol: "doc.on.doc", key: "c") { library.copyFiles(targets) })
        menu.addItem(ActionMenuItem("Copy Path", symbol: "link", key: "c", modifiers: [.command, .option]) { library.copyPaths(targets) })
        if targets.contains(where: library.canReadText) {
            menu.addItem(ActionMenuItem("Copy Text", symbol: "text.viewfinder", key: "c", modifiers: [.command, .shift]) {
                Task { await library.copyText(targets) }
            })
        }
        menu.addItem(.separator())
        if item.isFolder {
            let pinned = library.pinned.contains(item.path)
            menu.addItem(ActionMenuItem(pinned ? "Unpin from Sidebar" : "Pin to Sidebar", symbol: pinned ? "pin.slash" : "pin") {
                if pinned { library.pinned.removeAll { $0 == item.path } } else { library.pin(item.path) }
            })
        }
        menu.addItem(workspaceMenu(for: targets.map(\.path), library: library))
        if !many {
            menu.addItem(ActionMenuItem("Get Info", symbol: "info.circle", key: "i") {
                library.focused = item.path
                library.showInspector = true
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(many ? "Move \(targets.count) Items to Trash" : "Move to Trash", symbol: "trash",
                                    key: String(UnicodeScalar(NSBackspaceCharacter)!)) {
            library.trashRequest = targets
        })
        return menu
    }

    /// "Add to Workspace ›": each workspace (ticked when it already has them all — choosing it then
    /// takes them out), then New Workspace…. Nothing is moved either way.
    static func workspaceMenu(for paths: [String], library: LibraryModel) -> NSMenuItem {
        let sub = NSMenu()
        sub.autoenablesItems = false
        for w in library.workspaces {
            let has = paths.allSatisfy(w.contains)
            let entry = ActionMenuItem(w.name, symbol: "rectangle.stack") {
                if has { library.removeFromWorkspace(w.id, paths: Set(paths)) } else { library.addToWorkspace(w.id, paths: paths) }
            }
            entry.state = has ? .on : .off
            entry.toolTip = has ? "In “\(w.name)” — choose to take \(paths.count == 1 ? "it" : "them") out" : nil
            sub.addItem(entry)
        }
        if !library.workspaces.isEmpty { sub.addItem(.separator()) }
        sub.addItem(ActionMenuItem("New Workspace…", symbol: "plus") { library.workspacePrompt = .create(paths: paths) })
        let holder = NSMenuItem(title: "Add to Workspace", action: nil, keyEquivalent: "")
        holder.image = NSImage(systemSymbolName: "rectangle.stack.badge.plus", accessibilityDescription: nil)
        holder.submenu = sub
        return holder
    }
}

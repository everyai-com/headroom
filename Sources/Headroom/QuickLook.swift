import AppKit
import Quartz
import HeadroomCore

/// The real macOS Quick Look, for the files on screen: Space opens it, arrow keys move through
/// the files (up and down jump a whole row of the grid), and the selection follows along.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []
    private var paths: [String] = []
    private weak var library: LibraryModel?
    /// Arrow keys move the window's selection only when the panel shows the window's files
    /// (not Quick Search's list, which Quick Look steps through on its own).
    private var followsSelection = true

    var isOpen: Bool { QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible }

    func show(library: LibraryModel, items: [LibraryItem], current: LibraryItem?, followsSelection: Bool = true) {
        self.library = library
        self.followsSelection = followsSelection
        let files = items.filter { !$0.isFolder }
        urls = files.map(\.url)
        paths = files.map(\.path)
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = current.flatMap { c in paths.firstIndex(of: c.path) } ?? 0
        panel.makeKeyAndOrderFront(nil)
    }

    /// Space: open on the focused file (or the selection), or close.
    func toggle(_ library: LibraryModel) {
        if isOpen { QLPreviewPanel.shared().orderOut(nil); return }
        let current = library.focused.flatMap(library.item) ?? library.selectedItems.first
        let list = library.selection.count > 1 ? library.selectedItems : library.visible
        show(library: library, items: list.isEmpty ? current.map { [$0] } ?? [] : list, current: current)
    }

    /// Keep the panel on the file the selection moved to.
    func follow(_ library: LibraryModel) {
        guard isOpen, followsSelection, let focused = library.focused else { return }
        if let i = paths.firstIndex(of: focused) {
            QLPreviewPanel.shared().currentPreviewItemIndex = i
        } else {
            show(library: library, items: library.visible, current: library.item(focused))
        }
    }

    func close() { if isOpen { QLPreviewPanel.shared().orderOut(nil) } }

    // MARK: Data source & delegate (AppKit calls these on the main thread)

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return MainActor.assumeIsolated {
            guard let library, followsSelection else {
                if event.keyCode == 49 { close(); return true } // Space still closes it
                return false
            }
            switch event.keyCode {
            case 123: library.moveSelection(by: -1)                 // ←
            case 124: library.moveSelection(by: 1)                  // →
            case 125: library.moveSelection(by: library.columns)    // ↓
            case 126: library.moveSelection(by: -library.columns)   // ↑
            case 49: close()                                         // Space
            default: return false
            }
            return true
        }
    }
}

/// The main window: it takes control of the Quick Look panel so the panel shows our files.
final class HeadroomWindow: NSWindow {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLook.shared
        panel.delegate = QuickLook.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
}

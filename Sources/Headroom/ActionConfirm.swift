import SwiftUI
import HeadroomCore

/// A destructive action waiting for your confirm (map squares, large files).
struct PendingAction: Identifiable {
    var action: AppModel.MapAction
    var node: DiskNode
    var id: String { action.rawValue + node.id }
}

/// The words of every confirm: what goes, whether it comes back, and what to watch for.
@MainActor
enum ActionText {
    static func title(_ p: PendingAction, model: AppModel) -> String {
        let name = p.node.name
        switch p.action {
        case .reclaim: return "Reclaim \(name)?"
        case .trash: return "Move “\(name)” to the Trash?"
        case .emptyContents: return "Empty “\(name)”?"
        case .delete: return "Delete “\(name)” permanently?"
        case .uninstall: return "Uninstall \(name)?"
        }
    }

    static func label(_ action: AppModel.MapAction) -> String {
        switch action {
        case .reclaim: "Reclaim"
        case .trash: "Move to Trash"
        case .emptyContents: "Empty Folder"
        case .delete: "Delete Permanently"
        case .uninstall: "Uninstall"
        }
    }

    static func message(_ p: PendingAction, model: AppModel) -> String {
        let size = p.node.bytes.gb
        let known = p.node.url.flatMap(model.knownFinding(for:))
        var text: String
        switch p.action {
        case .reclaim:
            text = "\(size). \(known?.detail ?? "")"
            if let rebuild = known?.rebuild { text += " Rebuild it with `\(rebuild)`." }
        case .trash: text = "\(size). Put it back any time from Activity (or the Trash) — the space comes back when you empty the Trash."
        case .emptyContents: text = "Everything inside (\(size)) is deleted permanently. The folder itself stays."
        case .delete: text = "Frees \(size) right away. This can't be undone."
        case .uninstall: text = "The app and the data it keeps in your Library move to the Trash. Quit it first."
        }
        if p.action != .reclaim, p.action != .uninstall {
            if let known, known.safety == .review { text += "\n\nHeadroom says review first: \(known.detail)" }
            if p.node.url?.path.contains("/Library/") == true {
                text += "\n\nApps keep their data in Library — the app that owns this may lose settings or data."
            }
        }
        return text
    }

}

extension View {
    /// Ask before acting; run only on an explicit yes.
    func confirmingAction(_ pending: Binding<PendingAction?>, run: @escaping (PendingAction) async -> Void) -> some View {
        modifier(ConfirmAction(pending: pending, run: run))
    }
}

private struct ConfirmAction: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var pending: PendingAction?
    var run: (PendingAction) async -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(pending.map { ActionText.title($0, model: model) } ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), presenting: pending) { p in
            Button(ActionText.label(p.action), role: p.action == .reclaim ? nil : .destructive) {
                Task { await run(p) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(ActionText.message(p, model: model))
        }
    }
}

import SwiftUI
import AppKit
import HeadroomCore

/// The panel beside the map: what the selected square is, what deleting it means, and every way
/// to get rid of it — up front, not behind a right-click.
struct MapInspector: View {
    @EnvironmentObject var model: AppModel
    var node: DiskNode
    var working: Bool
    var canLookInside: Bool
    var ask: (AppModel.MapAction) -> Void
    var uninstall: (InstalledApp) -> Void
    var lookInside: () -> Void
    var close: () -> Void
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        let e = model.explanation(for: node)
        let owner = model.owningApp(of: node)
        let isApp = node.url?.pathExtension == "app"
        VStack(alignment: .leading, spacing: 14) {
            header(e)
            // The explanation scrolls; the actions stay put at the bottom.
            info(e, owner: owner, isApp: isApp)
            actions(e: e, owner: owner, isApp: isApp)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        )
    }

    @ViewBuilder func info(_ e: Explanation?, owner: InstalledApp?, isApp: Bool) -> some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            if let e {
                verdict(e.verdict)
                section("What it is") {
                    Text(e.what).font(.system(size: 13, weight: .semibold))
                    Text(e.detail).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                section("If you delete it") {
                    Text(e.ifDeleted).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
                if let owner, !isApp { ownerRow(owner) }
                if let url = node.url { details(url) }
            } else {
                Text("A group of smaller items. Look inside to see and delete what's in it.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if snapshot {
            content.frame(maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { content }.scrollIndicators(.never).frame(maxHeight: .infinity)
        }
    }

    func header(_ e: Explanation?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name).font(.system(size: 15, weight: .bold)).lineLimit(2).truncationMode(.middle)
                Text(node.bytes.gb).font(Theme.number(22, weight: .bold))
                    .foregroundStyle(e.map { Theme.color(for: $0.verdict) } ?? Theme.textPrimary)
            }
            Spacer(minLength: 0)
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Close  (Esc)")
                .keyboardShortcut(.escape, modifiers: [])
        }
    }

    @ViewBuilder var icon: some View {
        if let url = node.url, !snapshot {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 40, height: 40)
        } else {
            Image(systemName: node.url == nil ? "square.grid.2x2.fill" : "folder.fill")
                .font(.system(size: 22)).foregroundStyle(Theme.color(for: node.area)).frame(width: 40, height: 40)
        }
    }

    func verdict(_ v: Safety) -> some View {
        let (text, symbol): (String, String) = switch v {
        case .safe: ("Safe to delete — it comes back on its own", "checkmark.seal.fill")
        case .review: ("Check first — it may matter", "exclamationmark.circle.fill")
        case .keep: ("Your data — gone for good once deleted", "hand.raised.fill")
        }
        return HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Theme.color(for: v))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.color(for: v).opacity(0.12)))
    }

    func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase).kerning(0.5)
            content().fixedSize(horizontal: false, vertical: true)
        }
    }

    func ownerRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            if snapshot { Image(systemName: "app.fill").frame(width: 26, height: 26) }
            else { Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 26, height: 26) }
            VStack(alignment: .leading, spacing: 1) {
                Text("Belongs to \(app.name)").font(.system(size: 13, weight: .semibold))
                Text("App \(app.appSize.allocated.gb) + data \(app.dataSize.gb) in \(app.leftovers.count) places")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill(0.04)))
    }

    func details(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(url.tildePath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                Text("Changed \(date.ago)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder func actions(e: Explanation?, owner: InstalledApp?, isApp: Bool) -> some View {
        VStack(spacing: 8) {
            if let url = node.url {
                if let known = model.knownFinding(for: url), known.method != .none, known.safety != .keep {
                    wide(.reclaim, "Free up \(node.bytes.gb) safely", symbol: "sparkles", tint: Theme.safe, filled: true)
                }
                if let owner, !owner.isApple {
                    Button { uninstall(owner) } label: {
                        VStack(spacing: 1) {
                            Label(isApp ? "Uninstall with all its data" : "Uninstall \(owner.name) completely", systemImage: "trash.slash.fill")
                                .lineLimit(1)
                            Text("app + caches, data, settings · \(owner.totalSize.gb)").font(.system(size: 11, weight: .medium)).opacity(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(WideButtonStyle(tint: Theme.critical, filled: true))
                    .disabled(working)
                    .help("The app plus its caches, data, settings and logs — to the Trash, recoverable")
                } else if isApp, let why = model.refusal(.uninstall, for: node) {
                    caption(why)
                }
                if !isApp {
                    wide(.trash, "Move to Trash", symbol: "trash.fill", tint: Theme.review,
                         filled: model.knownFinding(for: url) == nil && owner == nil)
                    HStack(spacing: 8) {
                        if model.isDirectory(url) { small(.emptyContents, "Empty folder") }
                        small(.delete, "Delete now")
                    }
                }
                if let why = model.refusal(.trash, for: node), !isApp { caption(why) }
                HStack(spacing: 8) {
                    if canLookInside { Button("Look inside", action: lookInside).buttonStyle(GhostButtonStyle()) }
                    Button("Reveal") { model.reveal([url]) }.buttonStyle(GhostButtonStyle())
                    Button("Open") { model.open(url) }.buttonStyle(GhostButtonStyle())
                    Spacer()
                    Button { model.exclude([url]); close() } label: { Image(systemName: "hand.raised") }
                        .buttonStyle(GhostButtonStyle()).help("Never touch this")
                }
            } else if canLookInside {
                Button("Look inside", action: lookInside).buttonStyle(WideButtonStyle(tint: Theme.textPrimary, filled: false))
            }
        }
    }

    func wide(_ action: AppModel.MapAction, _ title: String, symbol: String, tint: Color, filled: Bool) -> some View {
        Button { ask(action) } label: { Label(title, systemImage: symbol).frame(maxWidth: .infinity) }
            .buttonStyle(WideButtonStyle(tint: tint, filled: filled))
            .disabled(working || model.refusal(action, for: node) != nil)
    }

    func small(_ action: AppModel.MapAction, _ title: String) -> some View {
        Button { ask(action) } label: { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(WideButtonStyle(tint: Theme.critical, filled: false))
            .disabled(working || model.refusal(action, for: node) != nil)
            .help(model.refusal(action, for: node) ?? (action == .delete ? "Frees the space now — can't be undone" : "Deletes everything inside, keeps the folder"))
    }

    func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

import SwiftUI
import AppKit
import HeadroomCore

/// Headroom's notepad windows, one per file: opening a file that's already open brings its window forward.
@MainActor
final class NoteWindows: NSObject, NSWindowDelegate {
    static let shared = NoteWindows()
    private var windows: [URL: NSWindow] = [:]

    /// Open a text file in Headroom. Anything the editor can't take (not text, too big, iCloud only) opens as usual.
    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let window = windows[url] { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        guard Notes.canEdit(url) else { NSWorkspace.shared.open(url); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NoteEditor(url: url))
        window.setFrameAutosaveName("Note")
        window.center()
        window.delegate = self
        windows[url] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

/// The text, saved a moment after you stop typing (and on ⌘S or close). If another app changed the
/// file meanwhile, nothing is overwritten: you choose to load theirs or keep yours.
struct NoteEditor: View {
    let url: URL
    @State private var text = ""
    @State private var saved = ""
    @State private var modified: Date?
    @State private var loaded = false
    @State private var problem: Notes.Problem?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            if problem == .changedElsewhere {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.review)
                    Text("Changed in another app since you opened it.").font(.system(size: 12))
                    Spacer()
                    Button("Load Theirs") { load() }.buttonStyle(GhostButtonStyle())
                    Button("Keep Mine") { save(force: true) }.buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.fill(0.06))
            }
            TextEditor(text: $text)
                .font(.system(size: 14, design: url.pathExtension.lowercased() == "txt" ? .default : .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12).padding(.top, 10)
                .disabled(!loaded)
            HStack {
                Text(status).font(.system(size: 11)).foregroundStyle(failure == nil ? Theme.textTertiary : Theme.critical)
                Spacer()
                Text("\(text.split(whereSeparator: \.isWhitespace).count) words").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Button("Save") { save() }.keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .background(Theme.surface)
        .foregroundStyle(Theme.textPrimary)
        .onAppear(perform: load)
        .onDisappear { save() }
        // Typing restarts this; it saves once you pause.
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { save() }
        }
    }

    var status: String {
        if let failure { return failure }
        if !loaded { return "Opening…" }
        return text == saved ? "Saved · \(url.deletingLastPathComponent().tildePath)" : "Editing…"
    }

    func load() {
        do {
            let file = try Notes.read(url)
            text = file.text
            saved = file.text
            modified = file.modified
            problem = nil
            failure = nil
            loaded = true
        } catch {
            failure = error.localizedDescription
        }
    }

    func save(force: Bool = false) {
        guard loaded, force || text != saved, problem != .changedElsewhere || force else { return }
        do {
            modified = try Notes.save(text, to: url, expected: modified, force: force)
            saved = text
            problem = nil
            failure = nil
        } catch let p as Notes.Problem {
            problem = p
        } catch {
            failure = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

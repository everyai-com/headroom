import SwiftUI
import AppKit
import Carbon.HIToolbox
import HeadroomCore

/// A key and its modifiers, as Carbon registers it and as Settings shows it ("⌥Space").
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon's modifier bits (cmdKey, optionKey…).
    var modifiers: UInt32
    /// The key's name: "Space", "K", "F5".
    var key: String

    static let controlOptionSpace = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), key: "Space")
    static let optionSpace = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")
    static let commandSpace = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), key: "Space")
    static let shiftCommandSpace = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(shiftKey | cmdKey), key: "Space")
    static let controlSpace = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey), key: "Space")
    static let presets: [KeyCombo] = [.controlOptionSpace, .optionSpace, .commandSpace, .shiftCommandSpace]

    var title: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// The modifiers as macOS's own shortcut list stores them.
    var systemModifiers: Int {
        var m = 0
        if modifiers & UInt32(controlKey) != 0 { m |= SystemShortcuts.control }
        if modifiers & UInt32(optionKey) != 0 { m |= SystemShortcuts.option }
        if modifiers & UInt32(shiftKey) != 0 { m |= SystemShortcuts.shift }
        if modifiers & UInt32(cmdKey) != 0 { m |= SystemShortcuts.command }
        return m
    }

    /// What macOS already does with it (Spotlight, screenshots…), or nil when it's free.
    var conflict: String? { SystemShortcuts.conflict(keyCode: Int(keyCode), modifiers: systemModifiers) }

    static let names: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]

    /// A shortcut pressed in the recorder: needs ⌘, ⌥ or ⌃ (Shift alone would steal a capital letter),
    /// except a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let functionKey = (Self.names[event.keyCode] ?? "").hasPrefix("F")
        guard functionKey || !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        guard let key = Self.names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m, key: key)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

/// The keys that bring Quick Search up from any app: saved, registered, and paused while you record new ones.
@MainActor
final class QuickSearchHotKey: ObservableObject {
    static let shared = QuickSearchHotKey()

    /// nil: off (Quick Search is still in the menu bar).
    @Published private(set) var combo: KeyCombo?
    /// macOS refused to register it.
    @Published private(set) var failed = false
    /// While Settings is listening for new keys, the old ones don't open the panel.
    @Published var recording = false { didSet { if recording != oldValue { register() } } }
    var action: () -> Void = {}
    private var hotKey: HotKey?

    init() { combo = Self.load() }

    func set(_ combo: KeyCombo?) {
        self.combo = combo
        let saved = combo.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "off"
        UserDefaults.standard.set(saved, forKey: "quickSearchHotKey")
        register()
    }

    func register() {
        hotKey = nil
        failed = false
        guard !recording, let combo else { return }
        hotKey = HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in
            Task { @MainActor in self?.action() }
        }
        failed = hotKey == nil
    }

    /// ⌃⌥Space unless you chose otherwise (older builds kept one of a fixed list).
    static func load() -> KeyCombo? {
        let d = UserDefaults.standard
        if let saved = d.string(forKey: "quickSearchHotKey") {
            if saved == "off" { return nil }
            if let data = saved.data(using: .utf8), let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) { return combo }
        }
        switch d.string(forKey: "quickSearchShortcut") {
        case "shiftCommandSpace": return .shiftCommandSpace
        case "controlOptionSpace": return .controlOptionSpace
        case "optionCommandF": return KeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(optionKey | cmdKey), key: "F")
        case "off": return nil
        default: return .controlOptionSpace
        }
    }
}

/// Settings' shortcut field: click, press the keys. Says whether they'll work, and why not.
struct ShortcutRecorder: View {
    @ObservedObject var hotKey = QuickSearchHotKey.shared
    @State private var monitor: Any?
    /// Bumped when Headroom comes forward: you may have just changed Spotlight's shortcut.
    @State private var recheck = 0
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(KeyCombo.presets, id: \.title) { combo in
                    Pill(title: combo.title, on: hotKey.combo == combo && !hotKey.recording) { stop(); hotKey.set(combo) }
                }
                Button { hotKey.recording ? stop() : start() } label: {
                    Text(hotKey.recording ? "Press keys…" : (hotKey.combo.map { KeyCombo.presets.contains($0) ? "Other…" : $0.title } ?? "Off"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hotKey.recording ? Theme.accent.opacity(0.22) : Theme.fill(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(hotKey.recording ? Theme.accent : Theme.hairline))
                }
                .buttonStyle(.plain)
                .help("Click, then press the keys you want. ⌫ turns it off, esc cancels.")
            }
            status.id(recheck)
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in recheck += 1 }
    }

    @ViewBuilder var status: some View {
        if hotKey.recording {
            note("Press the keys for Quick Search — ⌫ turns it off, esc cancels.", Theme.textSecondary, "keyboard")
        } else if let combo = hotKey.combo {
            if hotKey.failed {
                note("macOS wouldn't take \(combo.title) — pick another.", Theme.critical, "exclamationmark.triangle.fill")
            } else if let taken = snapshot ? nil : combo.conflict {
                VStack(alignment: .trailing, spacing: 4) {
                    note("macOS uses \(combo.title) for \(taken), so it won't reach Headroom.", Theme.review, "exclamationmark.triangle.fill")
                    Button("Turn it off in Keyboard Shortcuts…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                    }
                    .buttonStyle(.link).font(.system(size: 12))
                }
            } else {
                note("\(combo.title) opens Quick Search from any app.", Theme.accent, "checkmark.circle.fill")
            }
        } else {
            note("Off — open Quick Search from the menu bar.", Theme.textTertiary, "keyboard")
        }
    }

    func note(_ text: String, _ color: Color, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(color)
            .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
    }

    func start() {
        hotKey.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case UInt16(kVK_Escape): stop()
            case UInt16(kVK_Delete) where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:
                stop(); hotKey.set(nil)
            default:
                guard let combo = KeyCombo(event: event) else { NSSound.beep(); return nil }
                stop(); hotKey.set(combo)
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hotKey.recording = false
    }
}

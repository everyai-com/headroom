import Foundation

/// Shortcuts macOS itself answers before any app hears them (Spotlight's ⌘Space, the Finder search
/// window's ⌥⌘Space, input sources, screenshots). Registering one of these "works" but never fires,
/// so Settings warns instead. Read from `com.apple.symbolichotkeys`; never written.
public enum SystemShortcuts {
    /// Modifier bits as macOS stores them (NSEvent's flags).
    public static let shift = 1 << 17, control = 1 << 18, option = 1 << 19, command = 1 << 20

    struct Known {
        var name: String
        var keyCode: Int
        var modifiers: Int
    }

    /// The ones on by default, by their id in the preferences file (missing there = still the default).
    static let defaults: [Int: Known] = [
        64: Known(name: "Spotlight", keyCode: 49, modifiers: command),
        65: Known(name: "the Finder search window", keyCode: 49, modifiers: command | option),
        60: Known(name: "switching input sources", keyCode: 49, modifiers: control),
        61: Known(name: "switching input sources", keyCode: 49, modifiers: control | option),
        28: Known(name: "screenshots", keyCode: 20, modifiers: command | shift),
        29: Known(name: "screenshots", keyCode: 20, modifiers: command | shift | control),
        30: Known(name: "screenshots", keyCode: 21, modifiers: command | shift),
        31: Known(name: "screenshots", keyCode: 21, modifiers: command | shift | control),
        184: Known(name: "screenshots", keyCode: 23, modifiers: command | shift),
        32: Known(name: "Mission Control", keyCode: 126, modifiers: control),
        33: Known(name: "App Exposé", keyCode: 125, modifiers: control),
    ]

    /// Keys every app keeps for itself.
    static let reserved: [(keyCode: Int, modifiers: Int, name: String)] = [
        (49, control | command, "Emoji & Symbols"),
        (48, command, "the app switcher"),
        (12, command, "Quit"),
    ]

    /// What already uses this shortcut, or nil when it's free. `hotKeys` is the preferences file's
    /// `AppleSymbolicHotKeys` (nil reads this Mac's).
    public static func conflict(keyCode: Int, modifiers: Int, hotKeys: [String: Any]? = nil) -> String? {
        let mask = shift | control | option | command
        let modifiers = modifiers & mask
        if let r = reserved.first(where: { $0.keyCode == keyCode && $0.modifiers == modifiers }) { return r.name }
        let hotKeys = hotKeys ?? load()
        var seen = Set<Int>()
        for (key, value) in hotKeys {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            seen.insert(id)
            let enabled = (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1)
            guard enabled, let params = (entry["value"] as? [String: Any])?["parameters"] as? [Int], params.count >= 3 else { continue }
            if params[1] == keyCode, params[2] & mask == modifiers { return defaults[id]?.name ?? "a macOS shortcut" }
        }
        for (id, known) in defaults where !seen.contains(id) && known.keyCode == keyCode && known.modifiers == modifiers {
            return known.name
        }
        return nil
    }

    static func load() -> [String: Any] {
        CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any] ?? [:]
    }
}

/// Arithmetic typed into Quick Search — "24*7", "(1920-80)/3", "2^10", "1,250 × 1.2". Its own small
/// parser (NSExpression throws on bad input and would crash the panel). Not a calculator for words.
public enum QuickMath {
    /// The answer, formatted, when `text` is a sum with at least one operator; otherwise nil.
    public static func evaluate(_ text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        let allowed = Set("0123456789.+-*/^() x")
        guard !cleaned.isEmpty, cleaned.allSatisfy(allowed.contains), cleaned.contains(where: \.isNumber),
              cleaned.dropFirst().contains(where: { "+-*/^x".contains($0) }) else { return nil }
        // "2024-10-18" and "555-1234" are a date and a number to search for, not sums ("10 - 3" is).
        if !cleaned.contains(where: { "+*/^x()".contains($0) }), !cleaned.contains(" ") { return nil }
        var parser = Parser(Array(cleaned.replacingOccurrences(of: "x", with: "*").filter { $0 != " " }))
        guard let value = parser.expression(), parser.atEnd, value.isFinite, abs(value) < 1e15 else { return nil }
        return format(value)
    }

    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return Int64(value).formatted() }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 8
        f.usesSignificantDigits = false
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// expression = term (("+" | "-") term)*; term = power (("*" | "/") power)*;
    /// power = unary ("^" power)?; unary = "-" unary | primary; primary = number | "(" expression ")".
    struct Parser {
        var chars: [Character]
        var i = 0
        var depth = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { i == chars.count }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while i < chars.count, chars[i] == "+" || chars[i] == "-" {
                let op = chars[i]
                i += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while i < chars.count, chars[i] == "*" || chars[i] == "/" {
                let op = chars[i]
                i += 1
                guard let rhs = power() else { return nil }
                if op == "/" && rhs == 0 { return nil }
                value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if i < chars.count, chars[i] == "^" {
                i += 1
                guard let exponent = power() else { return nil }
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if i < chars.count, chars[i] == "-" {
                i += 1
                return unary().map { -$0 }
            }
            return primary()
        }

        mutating func primary() -> Double? {
            guard i < chars.count else { return nil }
            if chars[i] == "(" {
                depth += 1
                guard depth < 32 else { return nil }
                i += 1
                guard let value = expression(), i < chars.count, chars[i] == ")" else { return nil }
                i += 1
                depth -= 1
                return value
            }
            let start = i
            while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
    }
}

/// The apps Quick Search can open: the Applications folders, listed (never measured or changed).
public struct QuickApp: Sendable, Hashable, Identifiable {
    public var name: String
    public var path: String
    public var id: String { path }

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }

    /// Where apps live, Apple's included.
    public static func defaultRoots(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
         "/System/Library/CoreServices/Applications"].map { URL(fileURLWithPath: $0) }
            + [home.appendingPathComponent("Applications")]
    }

    /// Every `.app` directly in `roots` or one folder down ("Microsoft Office/Word.app"), named as
    /// Finder shows it, one per name (the first root wins), A–Z.
    public static func list(roots: [URL] = defaultRoots()) -> [QuickApp] {
        let fm = FileManager.default
        var out: [QuickApp] = []
        var names = Set<String>()
        func add(_ url: URL) {
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            guard !names.contains(name.lowercased()) else { return }
            names.insert(name.lowercased())
            out.append(QuickApp(name: name, path: url.path))
        }
        for root in roots {
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            for child in children {
                if child.pathExtension == "app" { add(child); continue }
                guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      !["Utilities"].contains(child.lastPathComponent) else { continue }
                let inner = (try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                inner.filter { $0.pathExtension == "app" }.forEach(add)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A System Settings page Quick Search can open ("Wi‑Fi", "Battery", "Privacy & Security"): read from the
/// Settings extensions macOS ships, opened by their `x-apple.systempreferences:` link. Never changed.
public struct SettingsPane: Sendable, Hashable, Identifiable {
    public var name: String
    /// Its bundle identifier — also what the link opens.
    public var id: String
    /// Other words that find it ("dark mode" → Appearance).
    public var keywords: [String]

    public init(name: String, id: String, keywords: [String] = []) {
        self.name = name
        self.id = id
        self.keywords = keywords
    }

    public var url: URL? { URL(string: "x-apple.systempreferences:\(id)") }

    public static let defaultDirectory = URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions")

    /// Names macOS leaves technical, by bundle id.
    static let names: [String: String] = [
        "com.apple.Battery-Settings.extension": "Battery",
        "com.apple.HeadphoneSettings": "Headphones",
    ]

    /// Words people search for that the page names don't say.
    static let keywords: [String: [String]] = [
        "com.apple.wifi-settings-extension": ["wifi", "wireless", "internet"],
        "com.apple.Battery-Settings.extension": ["power", "energy", "charging"],
        "com.apple.Keyboard-Settings.extension": ["shortcuts", "input sources", "dictation"],
        "com.apple.Displays-Settings.extension": ["monitor", "resolution", "night shift", "brightness"],
        "com.apple.settings.PrivacySecurity.extension": ["permissions", "full disk access", "filevault", "firewall"],
        "com.apple.Desktop-Settings.extension": ["dock", "stage manager", "hot corners", "mission control"],
        "com.apple.Sound-Settings.extension": ["volume", "audio", "output", "microphone"],
        "com.apple.Notifications-Settings.extension": ["alerts", "badges"],
        "com.apple.settings.Storage": ["disk", "space"],
        "com.apple.Lock-Screen-Settings.extension": ["screen saver", "sleep"],
        "com.apple.BluetoothSettings": ["airpods", "devices"],
        "com.apple.Network-Settings.extension": ["ethernet", "proxy", "dns"],
        "com.apple.Appearance-Settings.extension": ["dark mode", "light mode", "accent colour", "accent color"],
        "com.apple.Users-Groups-Settings.extension": ["accounts", "users"],
        "com.apple.Software-Update-Settings.extension": ["update", "upgrade", "macos"],
        "com.apple.Time-Machine-Settings.extension": ["backup", "backups"],
        "com.apple.Print-Scan-Settings.extension": ["printer", "scanner"],
        "com.apple.Trackpad-Settings.extension": ["gestures", "tap to click", "scrolling"],
        "com.apple.Mouse-Settings.extension": ["scrolling", "pointer"],
        "com.apple.Date-Time-Settings.extension": ["clock", "time zone", "timezone"],
        "com.apple.Localization-Settings.extension": ["language", "region", "locale"],
        "com.apple.LoginItems-Settings.extension": ["startup", "launch at login", "background items"],
        "com.apple.Sharing-Settings.extension": ["screen sharing", "file sharing", "remote login", "airplay receiver"],
        "com.apple.Siri-Settings.extension": ["apple intelligence", "assistant"],
        "com.apple.Accessibility-Settings.extension": ["zoom", "voiceover", "contrast"],
        "com.apple.ControlCenter-Settings.extension": ["control center", "menu bar"],
        "com.apple.Touch-ID-Settings.extension": ["fingerprint", "password"],
        "com.apple.systempreferences.AppleIDSettings": ["icloud", "apple id"],
        "com.apple.Focus-Settings.extension": ["do not disturb"],
    ]

    /// Every Settings page that can be opened by link, named as System Settings names it, A–Z.
    public static func list(directory: URL = defaultDirectory) -> [SettingsPane] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var seen = Set<String>()
        var out: [SettingsPane] = []
        for url in urls where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url), let info = bundle.infoDictionary, let id = bundle.bundleIdentifier,
                  let attributes = info["EXAppExtensionAttributes"] as? [String: Any],
                  attributes["EXExtensionPointIdentifier"] as? String == "com.apple.Settings.extension.ui",
                  let settings = attributes["SettingsExtensionAttributes"] as? [String: Any],
                  (settings["allowsXAppleSystemPreferencesURLScheme"] as? Bool) == true || (settings["allowsXAppleSystemPreferencesURLScheme"] as? Int) == 1
            else { continue }
            let localized = bundle.localizedInfoDictionary
            let name = names[id] ?? (localized?["CFBundleDisplayName"] ?? localized?["CFBundleName"] ?? info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String
            guard let name, !name.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            out.append(SettingsPane(name: name, id: id, keywords: keywords[id] ?? []))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

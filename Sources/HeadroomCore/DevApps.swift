import Foundation

/// A terminal or code editor a folder can be opened in.
public struct DevApp: Sendable, Hashable, Identifiable {
    public var name: String
    /// Every bundle ID it ships under (stable, insiders, community editions…), preferred first.
    public var bundleIDs: [String]
    public var id: String { name }
    public init(_ name: String, _ bundleIDs: [String]) {
        self.name = name
        self.bundleIDs = bundleIDs
    }
}

/// The terminals and editors Headroom knows, and which of them are installed.
public enum DevApps {
    /// In order of preference: the first installed one opens folders.
    public static let terminals: [DevApp] = [
        DevApp("Ghostty", ["com.mitchellh.ghostty"]),
        DevApp("Warp", ["dev.warp.Warp-Stable", "dev.warp.Warp"]),
        DevApp("iTerm", ["com.googlecode.iterm2"]),
        DevApp("Terminal", ["com.apple.Terminal"]),
    ]

    /// Offered in Settings; the first installed one is the default.
    public static let editors: [DevApp] = [
        DevApp("Visual Studio Code", ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]),
        DevApp("Cursor", ["com.todesktop.230313mzl4w4u92"]),
        DevApp("Zed", ["dev.zed.Zed", "dev.zed.Zed-Preview"]),
        DevApp("Xcode", ["com.apple.dt.Xcode"]),
        DevApp("Sublime Text", ["com.sublimetext.4", "com.sublimetext.3"]),
        DevApp("Nova", ["com.panic.Nova"]),
        DevApp("BBEdit", ["com.barebones.bbedit"]),
        DevApp("IntelliJ IDEA", ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]),
        DevApp("WebStorm", ["com.jetbrains.WebStorm"]),
        DevApp("PyCharm", ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"]),
        DevApp("GoLand", ["com.jetbrains.goland"]),
        DevApp("RustRover", ["com.jetbrains.rustrover"]),
        DevApp("CLion", ["com.jetbrains.CLion"]),
        DevApp("PhpStorm", ["com.jetbrains.PhpStorm"]),
        DevApp("RubyMine", ["com.jetbrains.rubymine"]),
        DevApp("Rider", ["com.jetbrains.rider"]),
        DevApp("Fleet", ["com.jetbrains.fleet"]),
        DevApp("Android Studio", ["com.google.android.studio"]),
    ]

    /// The installed ones, in order, each narrowed to the bundle IDs actually installed.
    public static func installed(_ apps: [DevApp], has: (String) -> Bool) -> [DevApp] {
        apps.compactMap { app in
            let ids = app.bundleIDs.filter(has)
            return ids.isEmpty ? nil : DevApp(app.name, ids)
        }
    }

    /// The terminal folders open in: the first installed of Ghostty, Warp, iTerm, Terminal.
    public static func terminal(has: (String) -> Bool) -> DevApp? { installed(terminals, has: has).first }

    /// The editor folders open in: the one picked in Settings when it's still installed, else the first installed.
    public static func editor(preferred: String?, has: (String) -> Bool) -> DevApp? {
        let all = installed(editors, has: has)
        return all.first { $0.name == preferred } ?? all.first
    }
}

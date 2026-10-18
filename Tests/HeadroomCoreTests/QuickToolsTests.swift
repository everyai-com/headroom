import XCTest
@testable import HeadroomCore

/// Quick Search's helpers: shortcut conflicts, the calculator, the app list.
final class QuickToolsTests: XCTestCase {
    let s = SystemShortcuts.self

    func testMacOSShortcutsAreConflictsUntilTurnedOff() {
        XCTAssertEqual(s.conflict(keyCode: 49, modifiers: s.command, hotKeys: [:]), "Spotlight", "on by default when the file doesn't list it")
        XCTAssertEqual(s.conflict(keyCode: 49, modifiers: s.command | s.option, hotKeys: [:]), "the Finder search window")
        XCTAssertNil(s.conflict(keyCode: 49, modifiers: s.option, hotKeys: [:]), "⌥Space is free")
        XCTAssertNil(s.conflict(keyCode: 49, modifiers: s.shift | s.command, hotKeys: [:]))
        let spotlightOff: [String: Any] = ["64": ["enabled": false, "value": ["parameters": [32, 49, s.command], "type": "standard"]]]
        XCTAssertNil(s.conflict(keyCode: 49, modifiers: s.command, hotKeys: spotlightOff), "Spotlight's shortcut turned off: ⌘Space is yours")
        let moved: [String: Any] = ["64": ["enabled": true, "value": ["parameters": [32, 49, s.option], "type": "standard"]]]
        XCTAssertEqual(s.conflict(keyCode: 49, modifiers: s.option, hotKeys: moved), "Spotlight", "Spotlight moved to ⌥Space")
        XCTAssertNil(s.conflict(keyCode: 49, modifiers: s.command, hotKeys: moved))
        XCTAssertEqual(s.conflict(keyCode: 49, modifiers: s.control | s.command, hotKeys: [:]), "Emoji & Symbols")
        XCTAssertEqual(s.conflict(keyCode: 49, modifiers: s.command | (1 << 23), hotKeys: [:]), "Spotlight", "other flag bits are ignored")
    }

    func testCalculatorAnswersSumsOnly() {
        XCTAssertEqual(QuickMath.evaluate("24*7"), "168")
        XCTAssertEqual(QuickMath.evaluate("2 + 3 * 4"), "14", "× before +")
        XCTAssertEqual(QuickMath.evaluate("(2 + 3) * 4"), "20")
        XCTAssertEqual(QuickMath.evaluate("2^10"), "1,024")
        XCTAssertEqual(QuickMath.evaluate("1,250 × 1.2"), "1,500")
        XCTAssertEqual(QuickMath.evaluate("10 / 4"), "2.5")
        XCTAssertEqual(QuickMath.evaluate("-3 * -3"), "9")
        XCTAssertEqual(QuickMath.evaluate("10 - 3"), "7")
        XCTAssertEqual(QuickMath.evaluate("3x4"), "12")
        XCTAssertNil(QuickMath.evaluate("2024-10-18"), "a date to search for")
        XCTAssertNil(QuickMath.evaluate("555-1234"), "a number to search for")
        XCTAssertNil(QuickMath.evaluate("2024"), "no operator, no sum")
        XCTAssertNil(QuickMath.evaluate("report 2+2"), "words aren't sums")
        XCTAssertNil(QuickMath.evaluate("1/0"))
        XCTAssertNil(QuickMath.evaluate("(1+2"))
        XCTAssertNil(QuickMath.evaluate("1++"))
        XCTAssertNil(QuickMath.evaluate(String(repeating: "(", count: 50) + "1" + String(repeating: ")", count: 50)), "no runaway nesting")
    }

    func testAppsAreListedOnceByName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("quickapps-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for path in ["A/Safari.app/Contents", "A/Microsoft Office/Word.app/Contents", "A/notes.txt", "B/Safari.app/Contents", "B/Zed.app/Contents"] {
            if path.hasSuffix(".txt") {
                try fm.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
                try Data().write(to: root.appendingPathComponent(path))
            } else {
                try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
            }
        }
        let apps = QuickApp.list(roots: [root.appendingPathComponent("A"), root.appendingPathComponent("B")])
        XCTAssertEqual(apps.map(\.name), ["Safari", "Word", "Zed"], "one folder down counts; a name shows once")
        XCTAssertTrue(apps[0].path.contains("/A/"), "the first root wins")
    }

    func testSettingsPagesComeFromTheirExtensions() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("panes-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        func pane(_ file: String, id: String, name: String, point: String = "com.apple.Settings.extension.ui", link: Bool = true) throws {
            let contents = dir.appendingPathComponent("\(file).appex/Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleDisplayName": name, "CFBundlePackageType": "XPC!",
                                       "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": point,
                                                                    "SettingsExtensionAttributes": ["allowsXAppleSystemPreferencesURLScheme": link]]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        }
        try pane("Wi-Fi", id: "com.apple.wifi-settings-extension", name: "WiFiSettings")
        try pane("PowerPreferences", id: "com.apple.Battery-Settings.extension", name: "PowerPreferences")
        try pane("Sound", id: "com.apple.Sound-Settings.extension", name: "Sound")
        try pane("Widget", id: "com.apple.widget", name: "Widget", point: "com.apple.widgetkit-extension")
        try pane("Hidden", id: "com.apple.hidden", name: "Hidden", link: false)
        let panes = SettingsPane.list(directory: dir)
        XCTAssertEqual(panes.map(\.name), ["Battery", "Sound", "WiFiSettings"], "Settings pages that open by link; technical names fixed")
        XCTAssertEqual(panes.first?.url?.absoluteString, "x-apple.systempreferences:com.apple.Battery-Settings.extension")
        XCTAssertTrue(panes.first { $0.name == "Sound" }?.keywords.contains("volume") ?? false)
    }
}

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Headroom", targets: ["Headroom"]),
        .executable(name: "headroom-cli", targets: ["headroom-cli"]),
        .library(name: "HeadroomCore", targets: ["HeadroomCore"]),
    ],
    targets: [
        // Engine: scanning, rules, safe cleanup, app inventory. No UI, fully testable.
        .target(
            name: "HeadroomCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app: notch panel, menu bar item, main window.
        .executableTarget(
            name: "Headroom",
            dependencies: ["HeadroomCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Read-only reports from the terminal (and the engine's smoke test).
        .executableTarget(
            name: "headroom-cli",
            dependencies: ["HeadroomCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HeadroomCoreTests",
            dependencies: ["HeadroomCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)

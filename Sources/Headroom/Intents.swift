import AppIntents
import Foundation
import UniformTypeIdentifiers
import HeadroomCore

/// Shortcuts and Siri: Find Files, Get Latest Download and Search in Headroom. They read the
/// same index the window does (and never change a file).
struct FindFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Files"
    static let description = IntentDescription("Finds files the way Headroom's search does: “pdfs from last week over 5 mb”, “screenshots with wifi password”.")

    @Parameter(title: "Search", description: "Plain English: type, date, size, where it came from, or words in it.")
    var query: String

    @Parameter(title: "Limit", default: 20, inclusiveRange: (1, 500))
    var limit: Int

    static var parameterSummary: some ParameterSummary { Summary("Find files matching \(\.$query)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        var index = LibraryIndex.loadCache()
        if index == nil { index = await LibraryScanner.scan() }
        let items = index?.items ?? []
        let q = LibraryQuery.parse(query)
        let context = LibraryQuery.MatchContext(recognizedText: TextIndex().all)
        let found = items.filter { q.matches($0, in: context) }.sorted { $0.latest > $1.latest }.prefix(limit)
        return .result(value: found.map { IntentFile(fileURL: $0.url, filename: $0.name) })
    }
}

struct LatestDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Latest Download"
    static let description = IntentDescription("The newest file in your Downloads folder, by when it arrived.")

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile?> {
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let newest = LibraryScanner.list(folder: folder).filter { !$0.isFolder }.max { $0.arrived < $1.arrived }
        return .result(value: newest.map { IntentFile(fileURL: $0.url, filename: $0.name) })
    }
}

struct SearchInHeadroomIntent: AppIntent {
    static let title: LocalizedStringResource = "Search in Headroom"
    static let description = IntentDescription("Opens Headroom with this search.")
    static let openAppWhenRun = true

    @Parameter(title: "Search")
    var query: String

    static var parameterSummary: some ParameterSummary { Summary("Search Headroom for \(\.$query)") }

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .headroomSearch, object: query)
        return .result()
    }
}

struct HeadroomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindFilesIntent(), phrases: ["Find files in \(.applicationName)", "Search my files with \(.applicationName)"],
                    shortTitle: "Find Files", systemImageName: "magnifyingglass")
        AppShortcut(intent: LatestDownloadIntent(), phrases: ["Get my latest download from \(.applicationName)",
                                                              "What did I just download in \(.applicationName)"],
                    shortTitle: "Latest Download", systemImageName: "arrow.down.circle")
        AppShortcut(intent: SearchInHeadroomIntent(), phrases: ["Search in \(.applicationName)"],
                    shortTitle: "Search in Headroom", systemImageName: "rectangle.and.text.magnifyingglass")
    }
}

extension Notification.Name {
    /// Open the window with a search (Shortcuts, the headroom:// URL).
    static let headroomSearch = Notification.Name("headroomSearch")
}

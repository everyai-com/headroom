import Foundation

/// The stuff you forgot about, grouped into cards: old installers, forgotten downloads, old
/// screenshots, big old videos and apps you don't use. Every card is a suggestion to review —
/// nothing here is `.safe`, and everything goes to the Trash (through `Cleaner`), so it can come back.
public struct CleanUpSuggestion: Identifiable, Sendable, Hashable {
    public enum Kind: String, CaseIterable, Sendable, Hashable, Identifiable {
        case duplicates, oldInstallers, forgottenDownloads, oldScreenshots, oldScreenRecordings, bigOldVideos, mailAttachments, unusedApps
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .duplicates: "Duplicates"
            case .oldInstallers: "Old installers"
            case .forgottenDownloads: "Forgotten downloads"
            case .oldScreenshots: "Old screenshots"
            case .oldScreenRecordings: "Old screen recordings"
            case .bigOldVideos: "Big old videos"
            case .mailAttachments: "Mail attachments you've opened"
            case .unusedApps: "Unused apps"
            }
        }

        public var symbol: String {
            switch self {
            case .duplicates: "square.on.square"
            case .oldInstallers: "shippingbox"
            case .forgottenDownloads: "arrow.down.circle"
            case .oldScreenshots: "camera.viewfinder"
            case .oldScreenRecordings: "record.circle"
            case .bigOldVideos: "film.stack"
            case .mailAttachments: "paperclip"
            case .unusedApps: "app.dashed"
            }
        }

        /// One line on what the card holds and why it's safe to look at.
        public var detail: String {
            switch self {
            case .duplicates: "Identical copies and look-alike photos. One copy of each stays."
            case .oldInstallers: "Disk images and packages for apps you've already installed, or that sat for a month."
            case .forgottenDownloads: "Downloads nobody has opened or changed in three months."
            case .oldScreenshots: "Screenshots older than a month. Copy the text out of any you still need."
            case .oldScreenRecordings: "Screen recordings older than a month. Keep the ones you still share."
            case .bigOldVideos: "Videos over 500 MB you haven't touched in six months."
            case .mailAttachments: "Copies Mail kept when you opened an attachment, over a week ago. The original stays in the email."
            case .unusedApps: "Apps not opened in three months. They go with every file they keep."
            }
        }
    }

    public var kind: Kind
    public var items: [LibraryItem]
    public var apps: [InstalledApp]
    /// Installers whose app is already in Applications.
    public var installed: Set<String>

    public init(kind: Kind, items: [LibraryItem] = [], apps: [InstalledApp] = [], installed: Set<String> = []) {
        self.kind = kind
        self.items = items
        self.apps = apps
        self.installed = installed
    }

    public var id: String { kind.rawValue }
    public var count: Int { kind == .unusedApps ? apps.count : items.count }
    /// What trashing all of it frees.
    public var bytes: Int64 {
        kind == .unusedApps ? apps.reduce(0) { $0 + $1.totalSize } : items.reduce(0) { $0 + $1.allocated }
    }
}

public enum CleanUp {
    public struct Rules: Sendable {
        public var installerDays = 30
        public var downloadDays = 90
        public var screenshotDays = 30
        public var recordingDays = 30
        public var mailDays = 7
        public var videoDays = 180
        public var videoMinBytes: Int64 = 500_000_000
        public var appDays = 90
        public init() {}
    }

    /// Every card that has something in it (duplicates come from `Duplicates` and are added by the caller).
    /// `mailAttachments` comes from `mailAttachments(home:)` (Mail's folder isn't in the library index).
    public static func suggestions(_ index: LibraryIndex, apps: [InstalledApp], home: String = NSHomeDirectory(),
                                   lastUsed: [String: Date] = [:], mailAttachments: [LibraryItem] = [], now: Date = .now,
                                   rules: Rules = Rules()) -> [CleanUpSuggestion] {
        var out: [CleanUpSuggestion] = []
        let installers = oldInstallers(index, apps: apps, home: home, now: now, days: rules.installerDays)
        if !installers.items.isEmpty { out.append(installers) }
        let skip = Set(installers.items.map(\.path))
        let downloads = forgottenDownloads(index, home: home, lastUsed: lastUsed, now: now, days: rules.downloadDays)
            .filter { !skip.contains($0.path) }
        if !downloads.isEmpty { out.append(CleanUpSuggestion(kind: .forgottenDownloads, items: downloads)) }
        let shots = oldScreenshots(index, now: now, days: rules.screenshotDays)
        if !shots.isEmpty { out.append(CleanUpSuggestion(kind: .oldScreenshots, items: shots)) }
        let recordings = oldScreenRecordings(index, now: now, days: rules.recordingDays)
        if !recordings.isEmpty { out.append(CleanUpSuggestion(kind: .oldScreenRecordings, items: recordings)) }
        let onCard = Set(recordings.map(\.path))
        let videos = bigOldVideos(index, lastUsed: lastUsed, now: now, days: rules.videoDays, minBytes: rules.videoMinBytes)
            .filter { !onCard.contains($0.path) }
        if !videos.isEmpty { out.append(CleanUpSuggestion(kind: .bigOldVideos, items: videos)) }
        let mail = oldMailAttachments(mailAttachments, now: now, days: rules.mailDays)
        if !mail.isEmpty { out.append(CleanUpSuggestion(kind: .mailAttachments, items: mail)) }
        let unused = unusedApps(apps, now: now, days: rules.appDays)
        if !unused.isEmpty { out.append(CleanUpSuggestion(kind: .unusedApps, apps: unused)) }
        return out
    }

    /// Installers anywhere in your folders: ones whose app is installed (a day after they arrived),
    /// and any that sat untouched for `days`.
    public static func oldInstallers(_ index: LibraryIndex, apps: [InstalledApp], home: String, now: Date, days: Int) -> CleanUpSuggestion {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let dayAgo = now.addingTimeInterval(-86_400)
        let appNames = apps.map { normalized($0.name) }.filter { $0.count >= 3 }
        var installed = Set<String>()
        let items = index.items.filter { item in
            guard item.isInstaller, !item.inProject, item.path.hasPrefix(home + "/") else { return false }
            let name = normalized((item.name as NSString).deletingPathExtension)
            let isInstalled = appNames.contains { name.hasPrefix($0) || ($0.hasPrefix(name) && name.count >= 4) }
            if isInstalled { installed.insert(item.path) }
            return item.latest < cutoff || (isInstalled && item.latest < dayAgo)
        }
        return CleanUpSuggestion(kind: .oldInstallers, items: items.sorted { $0.allocated > $1.allocated }, installed: installed)
    }

    /// Files in Downloads nobody opened or changed in `days` (Spotlight's "last opened" when it knows).
    public static func forgottenDownloads(_ index: LibraryIndex, home: String, lastUsed: [String: Date], now: Date, days: Int) -> [LibraryItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let downloads = home + "/Downloads/"
        return index.items.filter { item in
            // In Downloads, arriving there counts too (even a file moved in by hand).
            guard item.path.hasPrefix(downloads), !item.inProject, max(item.latest, item.added ?? .distantPast) < cutoff else { return false }
            if let used = lastUsed[item.path], used >= cutoff { return false }
            return true
        }
        .sorted { $0.allocated > $1.allocated }
    }

    public static func oldScreenshots(_ index: LibraryIndex, now: Date, days: Int) -> [LibraryItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return index.items.filter { $0.isScreenshot && !$0.inProject && $0.latest < cutoff }.sorted { $0.arrived < $1.arrived }
    }

    /// Screen recordings (macOS's own, QuickTime's, CleanShot's…) older than `days`.
    public static func oldScreenRecordings(_ index: LibraryIndex, now: Date, days: Int) -> [LibraryItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return index.items.filter { $0.kind == .video && !$0.inProject && $0.latest < cutoff && looksLikeScreenRecording($0.name) }
            .sorted { $0.allocated > $1.allocated }
    }

    /// Names macOS (and the popular recorders) give screen recordings, in the common languages.
    public static func looksLikeScreenRecording(_ name: String) -> Bool {
        let n = name.lowercased()
        let prefixes = ["screen recording", "screenrecording", "screen capture", "cleanshot", "kapture", "bildschirmaufnahme",
                        "enregistrement de l’écran", "enregistrement de l'écran", "grabación de pantalla", "registrazione schermo",
                        "gravação de tela", "画面収録", "屏幕录制", "录屏", "화면 기록", "запись экрана", "skärminspelning",
                        "schermopname", "nagranie ekranu"]
        return prefixes.contains { n.hasPrefix($0) }
    }

    /// Where Mail keeps a copy of each attachment you open (Quick Look or double-click).
    public static func mailDownloads(home: String) -> String {
        home + "/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
    }

    /// The files in Mail Downloads, read-only (one folder per attachment, the file inside).
    /// Packages (a Pages file) are one item; hidden files and links are skipped.
    public static func mailAttachments(home: String = NSHomeDirectory()) -> [LibraryItem] {
        let fm = FileManager.default
        var out: [LibraryItem] = []
        let keys = LibraryScanner.keys
        func walk(_ dir: URL, depth: Int) {
            guard depth < 4, let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                        options: [.skipsHiddenFiles]) else { return }
            for url in children {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isSymbolicLink != true else { continue }
                let ext = url.pathExtension.lowercased()
                if v.isDirectory == true, v.isPackage != true || ext.isEmpty { walk(url, depth: depth + 1); continue }
                if let item = LibraryScanner.makeItem(url, values: v, kind: FileKind.of(extension: ext)) { out.append(item) }
            }
        }
        walk(URL(fileURLWithPath: mailDownloads(home: home)), depth: 0)
        return out
    }

    /// Opened attachments not touched in `days`, biggest first.
    public static func oldMailAttachments(_ items: [LibraryItem], now: Date, days: Int) -> [LibraryItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return items.filter { $0.latest < cutoff }.sorted { $0.allocated > $1.allocated }
    }

    public static func bigOldVideos(_ index: LibraryIndex, lastUsed: [String: Date], now: Date, days: Int, minBytes: Int64) -> [LibraryItem] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return index.items.filter { item in
            guard item.kind == .video, !item.inProject, item.bytes >= minBytes, item.latest < cutoff else { return false }
            if let used = lastUsed[item.path], used >= cutoff { return false }
            return true
        }
        .sorted { $0.allocated > $1.allocated }
    }

    /// Apps you haven't opened in `days` — only when that's known for sure (never a guess), never Apple's.
    public static func unusedApps(_ apps: [InstalledApp], now: Date, days: Int) -> [InstalledApp] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return apps.filter { app in
            guard !app.isApple, app.lastUsedIsExact, let used = app.lastUsed else { return false }
            return used < cutoff
        }
        .sorted { $0.totalSize > $1.totalSize }
    }

    /// "Google Chrome 120.0 (arm64)" → "googlechrome": letters only, for matching installers to apps.
    static func normalized(_ s: String) -> String {
        let noise = ["installer", "install", "setup", "universal", "arm64", "x64", "intel", "macos", "mac", "osx", "darwin",
                     "aarch64", "apple", "silicon", "latest", "release", "stable", "beta", "x86"]
        var t = s.lowercased()
        for w in noise { t = t.replacingOccurrences(of: w, with: " ") }
        return String(t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(Character.init))
    }
}

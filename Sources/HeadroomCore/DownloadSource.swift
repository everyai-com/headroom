import Foundation

/// Where a download came from: Gmail, Google Drive, ChatGPT, Slack… or the website's own domain.
/// Read from the file's `kMDItemWhereFroms` attribute and the app that downloaded it (quarantine flag).
public struct DownloadSource: Hashable, Codable, Sendable, Identifiable {
    /// "gmail", "chatgpt"… for a known source; "site:example.com" for any other website.
    public var id: String
    public var name: String
    public var symbol: String
    public var isKnown: Bool

    public init(id: String, name: String, symbol: String, isKnown: Bool) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.isKnown = isKnown
    }

    /// A website that isn't one of the named sources.
    public static func site(_ domain: String) -> DownloadSource {
        DownloadSource(id: "site:" + domain, name: domain, symbol: "globe", isKnown: false)
    }

    /// The domain, for a website source.
    public var domain: String? { id.hasPrefix("site:") ? String(id.dropFirst(5)) : nil }
}

public enum DownloadSources {
    struct Known {
        var id: String
        var name: String
        var symbol: String
        /// Host suffixes: "google.com" matches "mail.google.com" but not "notgoogle.com".
        var hosts: [String]
        /// Apps that download straight to disk without a URL (quarantine agent names).
        var agents: [String] = []
        /// Words people use for it ("from twitter").
        var aliases: [String] = []

        var source: DownloadSource { DownloadSource(id: id, name: name, symbol: symbol, isKnown: true) }
    }

    /// Checked in order: more specific hosts come before the broad ones they'd also match.
    static let known: [Known] = [
        Known(id: "gmail", name: "Gmail", symbol: "envelope.fill",
              hosts: ["mail.google.com", "mail-attachment.googleusercontent.com", "gmail.com"], aliases: ["gmail", "google mail"]),
        Known(id: "gemini", name: "Gemini", symbol: "sparkle", hosts: ["gemini.google.com", "bard.google.com"], aliases: ["gemini", "bard"]),
        Known(id: "youtube", name: "YouTube", symbol: "play.rectangle.fill", hosts: ["youtube.com", "youtu.be", "googlevideo.com", "ytimg.com"],
              aliases: ["youtube", "yt"]),
        Known(id: "drive", name: "Google Drive", symbol: "externaldrive.fill.badge.icloud",
              hosts: ["drive.google.com", "docs.google.com", "drive.usercontent.google.com", "googleusercontent.com", "sheets.google.com",
                      "slides.google.com"],
              aliases: ["google drive", "drive", "google docs", "gdrive", "google sheets", "google slides"]),
        Known(id: "chatgpt", name: "ChatGPT", symbol: "bubble.left.and.text.bubble.right.fill",
              hosts: ["chatgpt.com", "chat.openai.com", "oaiusercontent.com", "openai.com", "oaistatic.com"],
              agents: ["ChatGPT"], aliases: ["chatgpt", "chat gpt", "openai", "gpt"]),
        Known(id: "claude", name: "Claude", symbol: "sparkles", hosts: ["claude.ai", "anthropic.com", "claudeusercontent.com"],
              agents: ["Claude"], aliases: ["claude", "anthropic"]),
        Known(id: "perplexity", name: "Perplexity", symbol: "magnifyingglass.circle.fill", hosts: ["perplexity.ai"], aliases: ["perplexity"]),
        Known(id: "canva", name: "Canva", symbol: "paintpalette.fill", hosts: ["canva.com"], aliases: ["canva"]),
        Known(id: "figma", name: "Figma", symbol: "pencil.and.outline", hosts: ["figma.com"], agents: ["Figma"], aliases: ["figma"]),
        Known(id: "x", name: "X", symbol: "xmark", hosts: ["x.com", "twitter.com", "twimg.com", "t.co"], aliases: ["x", "twitter", "tweet", "tweets"]),
        Known(id: "slack", name: "Slack", symbol: "number", hosts: ["slack.com", "slack-files.com", "slack-edge.com"], agents: ["Slack"],
              aliases: ["slack"]),
        Known(id: "whatsapp", name: "WhatsApp", symbol: "phone.bubble.fill", hosts: ["whatsapp.com", "whatsapp.net"], agents: ["WhatsApp"],
              aliases: ["whatsapp", "whats app", "wa"]),
        Known(id: "telegram", name: "Telegram", symbol: "paperplane.fill", hosts: ["telegram.org", "t.me", "telegram.me"],
              agents: ["Telegram"], aliases: ["telegram"]),
        Known(id: "discord", name: "Discord", symbol: "gamecontroller.fill", hosts: ["discord.com", "discordapp.com", "discordapp.net", "discord.gg"],
              agents: ["Discord"], aliases: ["discord"]),
        Known(id: "github", name: "GitHub", symbol: "chevron.left.forwardslash.chevron.right",
              hosts: ["github.com", "githubusercontent.com", "github.io"], aliases: ["github", "gh"]),
        Known(id: "dropbox", name: "Dropbox", symbol: "shippingbox.fill", hosts: ["dropbox.com", "dropboxusercontent.com", "db.tt"],
              agents: ["Dropbox"], aliases: ["dropbox"]),
        Known(id: "onedrive", name: "OneDrive", symbol: "cloud.fill", hosts: ["onedrive.live.com", "1drv.ms", "sharepoint.com", "onedrive.com"],
              aliases: ["onedrive", "sharepoint"]),
        Known(id: "outlook", name: "Outlook", symbol: "envelope.badge.fill",
              hosts: ["outlook.live.com", "outlook.office.com", "outlook.office365.com", "attachments.office.net"],
              agents: ["Microsoft Outlook"], aliases: ["outlook", "hotmail"]),
        Known(id: "icloud", name: "iCloud", symbol: "icloud.fill", hosts: ["icloud.com", "icloud-content.com"], aliases: ["icloud"]),
        Known(id: "notion", name: "Notion", symbol: "doc.richtext.fill", hosts: ["notion.so", "notion.site", "notion-static.com", "notion.com"],
              agents: ["Notion"], aliases: ["notion"]),
        Known(id: "instagram", name: "Instagram", symbol: "camera.fill", hosts: ["instagram.com", "cdninstagram.com"], aliases: ["instagram", "insta", "ig"]),
        Known(id: "facebook", name: "Facebook", symbol: "person.2.fill", hosts: ["facebook.com", "fbcdn.net", "fb.com", "messenger.com"],
              aliases: ["facebook", "fb", "messenger"]),
        Known(id: "linkedin", name: "LinkedIn", symbol: "briefcase.fill", hosts: ["linkedin.com", "licdn.com"], aliases: ["linkedin"]),
        Known(id: "reddit", name: "Reddit", symbol: "bubble.left.and.bubble.right.fill", hosts: ["reddit.com", "redd.it", "redditmedia.com"],
              aliases: ["reddit"]),
        Known(id: "pinterest", name: "Pinterest", symbol: "pin.fill", hosts: ["pinterest.com", "pinimg.com"], aliases: ["pinterest"]),
        Known(id: "zoom", name: "Zoom", symbol: "video.fill", hosts: ["zoom.us", "zoom.com"], agents: ["zoom.us"], aliases: ["zoom"]),
        Known(id: "apple", name: "Apple", symbol: "apple.logo", hosts: ["apple.com", "mzstatic.com"], aliases: ["apple"]),
        Known(id: "mail", name: "Mail", symbol: "envelope", hosts: [], agents: ["Mail"], aliases: ["mail", "apple mail", "email", "e-mail"]),
        Known(id: "messages", name: "Messages", symbol: "message.fill", hosts: [], agents: ["Messages"], aliases: ["messages", "imessage", "imessages"]),
        Known(id: "airdrop", name: "AirDrop", symbol: "airplayaudio", hosts: [], agents: ["AirDrop", "sharingd"], aliases: ["airdrop", "air drop"]),
        Known(id: "extensions", name: "Extensions", symbol: "puzzlepiece.extension.fill", hosts: [], aliases: ["extension", "extensions"]),
    ]

    /// Browsers: downloading with one says nothing about where from.
    static let browsers: Set<String> = ["safari", "google chrome", "chrome", "arc", "firefox", "brave browser", "microsoft edge",
                                        "opera", "vivaldi", "orion", "dia", "zen", "chromium", "comet", "atlas", "chatgpt atlas"]

    public static var all: [DownloadSource] { known.map(\.source) }

    /// The source for one of the named sources' ids ("gmail").
    public static func named(_ id: String) -> DownloadSource? { known.first { $0.id == id }?.source }

    /// Where a library item came from, or nil when it wasn't downloaded (or nothing says).
    public static func source(of item: LibraryItem) -> DownloadSource? {
        source(urls: item.whereFrom ?? [], agent: item.downloadedBy)
    }

    public static func source(urls: [String], agent: String?) -> DownloadSource? {
        // Extensions and Mail have their own URL schemes.
        for raw in urls {
            let lower = raw.lowercased()
            if ["chrome-extension:", "moz-extension:", "safari-web-extension:", "safari-extension:"].contains(where: lower.hasPrefix) {
                return named("extensions")
            }
            if lower.hasPrefix("message:") { return named("mail") }
        }
        let hosts = urls.compactMap(host)
        // A named source anywhere wins — the page (second) usually says it best, so look there first.
        for h in hosts.reversed() {
            if let k = known.first(where: { k in k.hosts.contains { h == $0 || h.hasSuffix("." + $0) } }) { return k.source }
        }
        if let agent, let k = known.first(where: { k in k.agents.contains { $0.caseInsensitiveCompare(agent) == .orderedSame } }) {
            return k.source
        }
        // Any other website: the page's domain, else the file's.
        if let h = hosts.count > 1 ? hosts[1] : hosts.first, !h.isEmpty { return .site(registrableDomain(h)) }
        return nil
    }

    /// The host of a where-from URL ("blob:https://web.whatsapp.com/…" → "web.whatsapp.com"); nil for non-web URLs.
    static func host(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("blob:") { s = String(s.dropFirst(5)) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// "files.example.co.uk" → "example.co.uk"; "www.example.com" → "example.com".
    public static func registrableDomain(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return h }
        // An IP address stays whole.
        if labels.allSatisfy({ Int($0) != nil }) { return h }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let secondLevel: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "co.in", "co.jp", "co.nz", "co.za", "co.kr",
                                        "com.au", "net.au", "org.au", "com.br", "com.sg", "com.mx", "com.tr", "com.cn",
                                        "com.hk", "com.tw", "co.id", "com.my", "com.ar", "com.co", "co.il"]
        return labels.suffix(secondLevel.contains(lastTwo) ? 3 : 2).joined(separator: ".")
    }

    /// The source a word names ("gmail", "twitter", "google drive", "example.com"), for "from …" in search.
    public static func lookup(_ words: String) -> DownloadSource? {
        let w = words.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return nil }
        if let k = known.first(where: { $0.id == w || $0.name.lowercased() == w || $0.aliases.contains(w) }) { return k.source }
        // A domain: "from example.com".
        if w.contains("."), !w.contains(" "), w.split(separator: ".").count >= 2,
           w.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) {
            if let k = known.first(where: { k in k.hosts.contains { w == $0 || w.hasSuffix("." + $0) } }) { return k.source }
            return .site(registrableDomain(w))
        }
        return nil
    }

    /// True when the downloading app is a browser (no source of its own).
    public static func isBrowser(_ agent: String) -> Bool { browsers.contains(agent.lowercased()) }
}

import Foundation

/// A search typed the way people talk — "pdfs from last week over 5 mb" — read into filters
/// (type, date, size, source, device, folder, words) that the UI shows as chips you can remove.
/// `parse` is deterministic (every date comes from the `now` and `calendar` passed in) and does the
/// work once, so `matches` stays cheap enough to run over every file on each keystroke.
public struct LibraryQuery: Sendable, Hashable {
    /// What was typed.
    public var raw: String
    /// Kinds to show. With `extensions` also empty, any kind.
    public var kinds: Set<FileKind> = []
    /// Extensions to show (lowercased, no dot), on top of `kinds`.
    public var extensions: Set<String> = []
    /// Screenshots and screen recordings only.
    public var screenshotsOnly = false
    /// Created, modified or received (downloaded) inside this interval (start included, end not).
    public var dateRange: DateInterval?
    /// Nothing has happened to it since this date (`LibraryItem.latest` is earlier).
    public var olderThan: Date?
    /// Something happened to it on or after this date.
    public var newerThan: Date?
    /// Size bounds (both included) in decimal units, like Finder: 1 KB = 1000 bytes.
    public var minBytes: Int64?
    public var maxBytes: Int64?
    /// Downloaded from this source (Gmail, Slack, a website…).
    public var source: DownloadSource?
    /// Downloaded from anywhere.
    public var anyDownload = false
    /// Shot on this device ("iPhone", "Canon"), matched against `MatchContext.devices`.
    public var device: String? { didSet { deviceRule = DeviceRule(device) } }
    /// Somewhere inside this folder of your home.
    public var folder: Folder?
    /// Words and phrases that must all appear (lowercased, accents dropped).
    public var terms: [String] = [] { didSet { needles = terms.map(Needle.init) } }
    /// What was understood, in the order it was typed.
    public var chips: [Chip] = []

    /// `terms`, folded once for matching.
    var needles: [Needle] = []
    /// `device`, as names to look for.
    var deviceRule: DeviceRule?

    init(raw: String) { self.raw = raw }

    /// No filters and no words: everything matches.
    public var isEmpty: Bool {
        kinds.isEmpty && extensions.isEmpty && !screenshotsOnly && dateRange == nil && olderThan == nil && newerThan == nil
            && minBytes == nil && maxBytes == nil && source == nil && !anyDownload && device == nil && folder == nil
            && terms.isEmpty
    }

    /// The folders of your home a search can be limited to.
    public enum Folder: String, Sendable, Hashable, CaseIterable {
        case desktop, documents, downloads, pictures, movies, music, icloud

        public var title: String {
            switch self {
            case .desktop: "Desktop"
            case .documents: "Documents"
            case .downloads: "Downloads"
            case .pictures: "Pictures"
            case .movies: "Movies"
            case .music: "Music"
            case .icloud: "iCloud Drive"
            }
        }

        /// Where it lives inside home.
        var relativePath: String { self == .icloud ? "Library/Mobile Documents/com~apple~CloudDocs" : title }

        public func path(home: String) -> String {
            var h = home
            while h.count > 1, h.hasSuffix("/") { h.removeLast() }
            return h + "/" + relativePath
        }
    }

    /// One thing the parser understood, shown as a removable chip.
    public struct Chip: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable, Hashable { case type, date, size, source, device, folder, text }
        public var kind: Kind
        /// "PDFs", "Last week", "Over 5 MB", "From Gmail", "“wifi password”"…
        public var label: String
        /// An SF Symbol that fits.
        public var symbol: String
        /// The typed text without this chip's words: what the search field becomes when the chip is removed.
        public var removing: String
        public var id: String

        public init(kind: Kind, label: String, symbol: String, removing: String, id: String) {
            self.kind = kind
            self.label = label
            self.symbol = symbol
            self.removing = removing
            self.id = id
        }
    }

    /// What matching needs beyond the item itself.
    public struct MatchContext: Sendable {
        public var home: String
        /// Path → text found in the image or PDF.
        public var recognizedText: [String: String]
        /// Paths Spotlight says contain the free-text words.
        public var contentHits: Set<String>
        /// Path → the camera or device that made it ("Apple iPhone 15 Pro").
        public var devices: [String: String]

        public init(home: String = NSHomeDirectory(), recognizedText: [String: String] = [:], contentHits: Set<String> = [],
                    devices: [String: String] = [:]) {
            self.home = home
            self.recognizedText = recognizedText
            self.contentHits = contentHits
            self.devices = devices
        }
    }

    /// Read typed text into filters. Dates are worked out from `now` in `calendar`.
    public static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> LibraryQuery {
        var parser = QueryParser(text, now: now, calendar: calendar)
        return parser.run()
    }

    /// True when the item passes every filter and contains every word. Cheap: no formatters, no
    /// allocation for ASCII names — it runs over the whole library on each keystroke.
    public func matches(_ item: LibraryItem, in context: MatchContext) -> Bool {
        if !kinds.isEmpty || !extensions.isEmpty {
            guard kinds.contains(item.kind) || (!extensions.isEmpty && TextMatch.hasExtension(item.path, in: extensions))
            else { return false }
        }
        if screenshotsOnly, !item.isScreenshot { return false }
        if let minBytes, item.bytes < minBytes { return false }
        if let maxBytes, item.bytes > maxBytes { return false }
        if let range = dateRange {
            let start = range.start, end = range.end
            func inside(_ d: Date) -> Bool { d >= start && d < end }
            guard inside(item.created) || inside(item.modified) || (item.received.map(inside) ?? false) else { return false }
        }
        if olderThan != nil || newerThan != nil {
            let latest = item.latest
            if let olderThan, latest >= olderThan { return false }
            if let newerThan, latest < newerThan { return false }
        }
        if anyDownload, item.whereFrom == nil, item.downloadedBy == nil { return false }
        if let folder, !TextMatch.isInside(item.path, home: context.home, folder: folder.relativePath) { return false }
        if let deviceRule {
            guard let name = context.devices[item.path], deviceRule.matches(name) else { return false }
        }
        if let source {
            guard item.whereFrom != nil || item.downloadedBy != nil, DownloadSources.source(of: item)?.id == source.id
            else { return false }
        }
        if !needles.isEmpty, !termsMatch(item, context) { return false }
        return true
    }

    /// Every word appears in the name, one of the two nearest folders, a tag or the recognised text —
    /// or Spotlight found them inside the file.
    func termsMatch(_ item: LibraryItem, _ context: MatchContext) -> Bool {
        if !context.contentHits.isEmpty, context.contentHits.contains(item.path) { return true }
        let start = TextMatch.nameStart(item.path, home: context.home)
        let text = context.recognizedText.isEmpty ? nil : context.recognizedText[item.path]
        for needle in needles {
            if TextMatch.find(needle, in: item.path, from: start) { continue }
            if item.tags.contains(where: { TextMatch.find(needle, in: $0) }) { continue }
            if let text, TextMatch.find(needle, in: text) { continue }
            return false
        }
        return true
    }
}

// MARK: - Matching helpers

/// A search word folded for matching: letters and digits only, lowercased, accents dropped.
struct Needle: Sendable, Hashable {
    var units: [UInt32]

    init(_ term: String) {
        units = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter(TextMatch.isAlphanumeric).map(\.value)
    }
}

/// Which device names a device filter accepts.
enum DeviceRule: Sendable, Hashable {
    /// Any of these, case-insensitively.
    case any([String])
    /// A camera: anything that isn't a phone or a tablet.
    case camera

    static let android = ["android", "pixel", "samsung", "galaxy", "oneplus", "xiaomi", "redmi", "huawei", "motorola",
                          "oppo", "vivo", "nokia"]
    static let phones = ["iphone", "ipad", "ipod"] + android

    init?(_ device: String?) {
        guard let d = device?.trimmingCharacters(in: .whitespaces).lowercased(), !d.isEmpty else { return nil }
        switch d {
        case "camera": self = .camera
        case "android": self = .any(Self.android)
        case "iphone", "phone": self = .any(["iphone"])
        case "fujifilm", "fuji": self = .any(["fuji"])
        default: self = .any([d])
        }
    }

    func matches(_ name: String) -> Bool {
        switch self {
        case .any(let marks): marks.contains { name.range(of: $0, options: .caseInsensitive) != nil }
        case .camera: !Self.phones.contains { name.range(of: $0, options: .caseInsensitive) != nil }
        }
    }
}

/// Substring search that ignores case, accents and separators ("wifi" finds "Wi-Fi_Password.png").
/// A match that skips a separator must start a word, so "wifi" doesn't turn up in "show if it".
enum TextMatch {
    static let separator: UInt32 = 0
    /// "/": a match never runs from one folder name into the next.
    static let barrier = UInt32.max

    static func isAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        s.properties.isAlphabetic || s.properties.numericType != nil
    }

    static func find(_ needle: Needle, in s: String, from lo: Int = 0) -> Bool {
        if needle.units.isEmpty { return true }
        if let found = s.utf8.withContiguousStorageIfAvailable({ find(needle, in: $0, from: lo) }) { return found }
        var copy = s
        copy.makeContiguousUTF8()
        return copy.utf8.withContiguousStorageIfAvailable { find(needle, in: $0, from: lo) } ?? false
    }

    static func find(_ needle: Needle, in buf: UnsafeBufferPointer<UInt8>, from lo: Int) -> Bool {
        let hi = buf.count
        guard lo >= 0, lo < hi else { return false }
        var k = lo
        while k < hi, buf[k] < 0x80 { k += 1 }
        if k == hi { return asciiFind(needle.units, buf, lo, hi) }
        // Accents and other scripts: fold the text first (rare in file names, so it may allocate).
        let text = String(decoding: UnsafeBufferPointer(rebasing: buf[lo..<hi]), as: UTF8.self)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var units: [UInt32] = [], starts: [Bool] = []
        var previous = false
        for s in text.unicodeScalars {
            if s == "/" {
                units.append(barrier); starts.append(false); previous = false
                continue
            }
            let a = isAlphanumeric(s)
            units.append(a ? s.value : separator)
            starts.append(a && !previous)
            previous = a
        }
        return foldedFind(needle.units, units, starts)
    }

    /// ASCII text, straight from its bytes: only positions whose first byte fits are looked at closely.
    static func asciiFind(_ n: [UInt32], _ buf: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> Bool {
        let m = n.count
        guard m > 0, m <= hi - lo, n[0] < 0x80 else { return false }
        let lower = UInt8(n[0])
        let upper = lower >= 0x61 && lower <= 0x7A ? lower - 32 : lower
        var i = lo
        while i < hi {
            let b = buf[i]
            if b == lower || b == upper {
                var j = i + 1, k = 1, skipped = false
                while k < m, j < hi {
                    let u = asciiUnit(buf[j])
                    if u == separator { skipped = true; j += 1; continue }
                    if u != n[k] { break }
                    k += 1; j += 1
                }
                if k == m, !skipped || asciiWordStart(buf, i, lo) { return true }
            }
            i += 1
        }
        return false
    }

    /// Folded text: `units` are scalars (`separator`, `barrier`), `starts` marks where words begin.
    static func foldedFind(_ n: [UInt32], _ units: [UInt32], _ starts: [Bool]) -> Bool {
        let m = n.count, count = units.count
        guard m > 0, m <= count else { return false }
        var i = 0
        while i < count {
            if units[i] == n[0] {
                var j = i + 1, k = 1, skipped = false
                while k < m, j < count {
                    let u = units[j]
                    if u == separator { skipped = true; j += 1; continue }
                    if u != n[k] { break }
                    k += 1; j += 1
                }
                if k == m, !skipped || starts[i] { return true }
            }
            i += 1
        }
        return false
    }

    @inline(__always)
    static func asciiUnit(_ b: UInt8) -> UInt32 {
        switch b {
        case 0x41...0x5A: UInt32(b) + 32
        case 0x61...0x7A, 0x30...0x39: UInt32(b)
        case 0x2F: barrier
        default: separator
        }
    }

    /// Start of the text, after a separator, a lower→upper change ("WiFi") or a letter↔digit change.
    static func asciiWordStart(_ buf: UnsafeBufferPointer<UInt8>, _ i: Int, _ lo: Int) -> Bool {
        guard i > lo else { return true }
        let c = buf[i], p = buf[i - 1]
        let pu = asciiUnit(p)
        if pu == separator || pu == barrier { return true }
        if (0x41...0x5A).contains(c), (0x61...0x7A).contains(p) { return true }
        return (0x30...0x39).contains(c) != (0x30...0x39).contains(p)
    }

    /// Where the name and its two nearest folders start (UTF-8 offset), never before the end of home itself —
    /// so your user name doesn't match every file.
    static func nameStart(_ path: String, home: String) -> Int {
        let homeLength = home.utf8.last == 0x2F ? home.utf8.count - 1 : home.utf8.count
        return path.utf8.withContiguousStorageIfAvailable { buf -> Int in
            var start = 0, slashes = 0, i = buf.count - 1
            while i >= 0 {
                if buf[i] == 0x2F {
                    slashes += 1
                    if slashes == 3 { start = i + 1; break }
                }
                i -= 1
            }
            if homeLength > 0, homeLength < buf.count, start <= homeLength, buf[homeLength] == 0x2F {
                let underHome = home.utf8.withContiguousStorageIfAvailable { h -> Bool in
                    var k = 0
                    while k < homeLength, h[k] == buf[k] { k += 1 }
                    return k == homeLength
                } ?? path.utf8.starts(with: home.utf8.prefix(homeLength))
                if underHome { start = homeLength + 1 }
            }
            return start
        } ?? 0
    }

    /// The path is somewhere inside `home/folder/`.
    static func isInside(_ path: String, home: String, folder: String) -> Bool {
        let p = path.utf8
        let homeLength = home.utf8.last == 0x2F ? home.utf8.count - 1 : home.utf8.count
        let rel = folder.utf8
        let total = homeLength + 1 + rel.count
        guard p.count > total + 1, p.starts(with: home.utf8.prefix(homeLength)) else { return false }
        var idx = p.index(p.startIndex, offsetBy: homeLength)
        guard p[idx] == 0x2F else { return false }
        idx = p.index(after: idx)
        guard p[idx...].starts(with: rel) else { return false }
        idx = p.index(idx, offsetBy: rel.count)
        return p[idx] == 0x2F
    }

    /// The file's extension (case-insensitive) is one of `exts` — without building strings.
    static func hasExtension(_ path: String, in exts: Set<String>) -> Bool {
        let p = path.utf8
        var i = p.endIndex
        while i > p.startIndex {
            let prev = p.index(before: i)
            let b = p[prev]
            if b == 0x2F { return false }
            if b == 0x2E {
                guard prev > p.startIndex, p[p.index(before: prev)] != 0x2F else { return false }
                let ext = p[i...]
                let length = ext.count
                for e in exts where e.utf8.count == length {
                    if zip(e.utf8, ext).allSatisfy({ $0 == ((0x41...0x5A).contains($1) ? $1 + 32 : $1) }) { return true }
                }
                return false
            }
            i = prev
        }
        return false
    }
}

// MARK: - Parser

/// Reads typed words into a `LibraryQuery`, one recognised phrase at a time. Anything it doesn't
/// recognise (and isn't filler like "show me all") becomes a search word.
struct QueryParser {
    struct Token {
        /// Lowercased, outer punctuation trimmed.
        var word: String
        /// As typed, outer punctuation trimmed.
        var display: String
        /// The characters it takes in the typed text (with a trailing comma).
        var range: Range<Int>
        var quoted: Bool
    }

    enum Slot {
        case type, date, size, source, download, device, folder, text

        var chipKind: LibraryQuery.Chip.Kind {
            switch self {
            case .type: .type
            case .date: .date
            case .size: .size
            case .source, .download: .source
            case .device: .device
            case .folder: .folder
            case .text: .text
            }
        }
    }

    struct Draft {
        var slot: Slot
        var label: String
        var symbol: String
        var tokens: [Int]
        /// A later phrase of the same single-valued slot took over (and took its words).
        var replaced = false
    }

    enum Unit {
        case hour, day, week, month, year

        var component: Calendar.Component {
            switch self {
            case .hour: .hour
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }

        var name: String {
            switch self {
            case .hour: "hour"
            case .day: "day"
            case .week: "week"
            case .month: "month"
            case .year: "year"
            }
        }

        /// "a week", "an hour", "6 months".
        func phrase(_ n: Int) -> String { n == 1 ? (self == .hour ? "an hour" : "a \(name)") : "\(n) \(name)s" }
    }

    enum SizeUnit {
        case b, kb, mb, gb, tb

        var factor: Double {
            switch self {
            case .b: 1
            case .kb: 1e3
            case .mb: 1e6
            case .gb: 1e9
            case .tb: 1e12
            }
        }

        func text(_ n: Double) -> String {
            let number = QueryParser.format(n)
            switch self {
            case .b: return number + (n == 1 ? " byte" : " bytes")
            case .kb: return number + " KB"
            case .mb: return number + " MB"
            case .gb: return number + " GB"
            case .tb: return number + " TB"
            }
        }
    }

    struct Amount {
        var number: Double
        var unit: SizeUnit?
        var unitText: String
        /// Tokens it takes.
        var count: Int
        /// Written "5gb+".
        var plus: Bool

        func bytes(_ fallback: SizeUnit) -> Int64? {
            let value = number * (unit ?? fallback).factor
            guard value.isFinite, value >= 0, value < 9e18 else { return nil }
            return Int64(value.rounded())
        }
    }

    struct TypeSpec: Hashable {
        var label: String
        var symbol: String
        var kinds: Set<FileKind> = []
        var exts: Set<String> = []
        var screenshots = false
        /// Written as an extension (".png"): never mistaken for an ordinary word.
        var explicit = false

        var isAnyType: Bool { kinds.isEmpty && exts.isEmpty }

        /// Everything this matches, `other` matches too ("png" inside "images", "keynote" inside "presentations").
        func isNarrower(than other: TypeSpec) -> Bool {
            let types: Bool
            if other.isAnyType { types = true } else if isAnyType { types = false } else {
                types = kinds.isSubset(of: other.kinds)
                    && exts.allSatisfy { other.exts.contains($0) || other.kinds.contains(FileKind.of(extension: $0)) }
            }
            return types && (screenshots || !other.screenshots)
        }
    }

    enum DateEffect {
        case range(DateInterval)
        case newer(Date)
        case older(Date)
    }

    struct DateCore {
        var effect: DateEffect
        /// "Last week", "August 2026".
        var label: String
        /// How it reads inside another label: "Since last week", "Since March".
        var inline: String
        var count: Int
        /// A lone word ("august", "2023", "monday") that could just as well be a search word.
        var weak: Bool
    }

    enum MonthMode { case latest, beforeThisMonth, thisYear }

    let chars: [Character]
    let tokens: [Token]
    let now: Date
    let cal: Calendar
    var query: LibraryQuery
    var drafts: [Draft] = []
    var terms: [String] = []
    var used: [Bool]
    /// After "with", "named", "about"…: the introducing tokens and the drafts of the words that follow.
    var group: (introducer: [Int], drafts: [Int])?

    init(_ text: String, now: Date, calendar: Calendar) {
        chars = Array(text)
        tokens = Self.tokenize(chars)
        self.now = now
        cal = calendar
        query = LibraryQuery(raw: text)
        used = Array(repeating: false, count: tokens.count)
    }

    mutating func run() -> LibraryQuery {
        var i = 0
        while i < tokens.count {
            if tokens[i].quoted {
                addTerm(i)
                i += 1
                continue
            }
            if let n = matchFilter(i, inText: group != nil) {
                closeGroup()
                i += n
                continue
            }
            if let n = introducer(i) {
                closeGroup()
                for k in i..<i + n { used[k] = true }
                group = (Array(i..<i + n), [])
                i += n
                continue
            }
            leftover(i)
            i += 1
        }
        closeGroup()
        query.terms = terms
        query.chips = chips()
        return query
    }

    // MARK: Tokens

    static let quotes: Set<Character> = ["\"", "“", "”", "„", "«", "»", "＂"]
    static let leadingTrim: Set<Character> = ["'", "‘", "’", "(", "[", "{", "¿", "¡", "`"]
    static let trailingTrim: Set<Character> = ["'", "‘", "’", ".", ":", "!", "?", ")", "]", "}", "…", "`"]

    static func tokenize(_ chars: [Character]) -> [Token] {
        var out: [Token] = []
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if quotes.contains(c) {
                // A quoted phrase is one word, kept whole; an unclosed one runs to the end (still typing).
                var j = i + 1
                while j < n, !quotes.contains(chars[j]) { j += 1 }
                let inner = String(chars[min(i + 1, j)..<j]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let end = min(j + 1, n)
                if !inner.isEmpty {
                    out.append(Token(word: normalize(inner), display: inner, range: i..<end, quoted: true))
                }
                i = end
                continue
            }
            var j = i
            while j < n, !chars[j].isWhitespace, !quotes.contains(chars[j]) { j += 1 }
            // "pdfs,images": commas and semicolons split words too, and go with the word before them.
            var s = i
            while s < j {
                var e = s
                while e < j, chars[e] != ",", chars[e] != ";" { e += 1 }
                let pieceEnd = e < j ? e + 1 : e
                var a = s, b = e
                while a < b, leadingTrim.contains(chars[a]) { a += 1 }
                while b > a, trailingTrim.contains(chars[b - 1]) { b -= 1 }
                if a < b {
                    let display = String(chars[a..<b])
                    out.append(Token(word: normalize(display), display: display, range: s..<pieceEnd, quoted: false))
                }
                s = pieceEnd
            }
            i = j
        }
        return out
    }

    static func normalize(_ s: String) -> String {
        var w = s.lowercased()
        if w.contains(where: { $0 == "’" || $0 == "‘" || $0 == "–" || $0 == "—" }) {
            w = w.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        }
        return w
    }

    func word(_ i: Int) -> String? { i >= 0 && i < tokens.count && !tokens[i].quoted ? tokens[i].word : nil }

    // MARK: Words

    static let stopwords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "all", "any", "some", "of", "for", "to", "show", "find", "search", "get", "list",
        "everything", "stuff", "file", "files", "item", "items", "thing", "things", "that", "which", "were", "was", "are",
        "is", "and", "or", "please", "where", "what", "in", "on", "at", "by", "with", "from", "via", "through", "thru",
        "into", "inside", "within", "during", "than", "ago", "since", "before", "after", "until", "between", "this",
        "these", "those", "did", "do", "does", "have", "has", "had", "i've", "i'm", "can", "could", "would", "you", "your",
        "our", "we", "it", "its", "them", "there", "here", "just", "only", "every", "each", "who", "whose", "be", "been",
        "may", "might", "will", "should", "must",
        "give", "open", "see", "look", "looking", "want", "need", "pls", "plz", "folder", "folders", "taken", "shot", "made",
        "saved", "created", "modified", "edited", "changed", "added", "received", "got", "sent", "uploaded", "dated",
        "&", "+", "-", "|", "/", "plus",
    ]
    /// Words that start a filter: dropped when they're the last word (the rest is still being typed).
    static let danglers: Set<String> = [
        "over", "under", "above", "below", "bigger", "larger", "smaller", "greater", "heavier", "lighter", "more", "less",
        "least", "most", "older", "newer", "younger", "last", "past", "previous", "up", "exceeding", "min", "max", "no",
        "not", ">", "<", ">=", "<=", "≥", "≤", "named", "called", "titled",
    ]
    static let connectors: Set<String> = ["and", "or", "&", "+", "-", "plus", ",", ";"]
    static let determiners: Set<String> = ["my", "the", "a", "an", "our", "your"]
    static let introducers: Set<String> = [
        "with", "containing", "contains", "contain", "say", "says", "saying", "said", "mentioning", "mentions", "mention",
        "about", "named", "called", "titled", "labeled", "labelled", "tagged", "including",
    ]
    static let sayWords: Set<String> = [
        "say", "says", "said", "mention", "mentions", "contain", "contains", "have", "has", "include", "includes",
        "read", "reads",
    ]

    mutating func leftover(_ i: Int) {
        let w = tokens[i].word
        if Self.stopwords.contains(w) { return }
        if i == tokens.count - 1, Self.danglers.contains(w) { return }
        addTerm(i)
    }

    mutating func addTerm(_ i: Int) {
        let t = tokens[i]
        let folded = t.word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !Needle(folded).units.isEmpty else { return }
        terms.append(folded)
        drafts.append(Draft(slot: .text, label: "“\(t.display)”", symbol: "text.magnifyingglass", tokens: [i]))
        used[i] = true
        group?.drafts.append(drafts.count - 1)
    }

    func introducer(_ i: Int) -> Int? {
        guard let w = word(i) else { return nil }
        if ["that", "which", "who"].contains(w), let v = word(i + 1), Self.sayWords.contains(v) { return 2 }
        return Self.introducers.contains(w) ? 1 : nil
    }

    /// "with wifi": a lone word takes the introducer with it, so removing its chip leaves no stray "with".
    mutating func closeGroup() {
        guard let g = group else { return }
        if g.drafts.count == 1 { drafts[g.drafts[0]].tokens += g.introducer }
        group = nil
    }

    mutating func add(_ slot: Slot, _ label: String, _ symbol: String, _ range: Range<Int>) {
        add(slot, label, symbol, Array(range))
    }

    mutating func add(_ slot: Slot, _ label: String, _ symbol: String, _ toks: [Int]) {
        var toks = toks
        // One source, device, folder: a later phrase wins, and its chip takes the earlier words with it.
        if [.source, .download, .device, .folder].contains(slot),
           let k = drafts.firstIndex(where: { $0.slot == slot && !$0.replaced }) {
            drafts[k].replaced = true
            toks = drafts[k].tokens + toks
        }
        for t in toks { used[t] = true }
        drafts.append(Draft(slot: slot, label: label, symbol: symbol, tokens: toks))
    }

    func chips() -> [LibraryQuery.Chip] {
        drafts.filter { !$0.replaced }
            .sorted { ($0.tokens.min() ?? 0) < ($1.tokens.min() ?? 0) }
            .map { d in
                let kind = d.slot.chipKind
                let start = d.tokens.map { tokens[$0].range.lowerBound }.min() ?? 0
                return LibraryQuery.Chip(kind: kind, label: d.label, symbol: d.symbol, removing: removing(d.tokens),
                                         id: "\(kind.rawValue)-\(start)")
            }
    }

    /// The typed text without these tokens, whitespace collapsed, with no stray "and" or comma at either end.
    func removing(_ toks: [Int]) -> String {
        var drop = [Bool](repeating: false, count: chars.count)
        for t in toks { for k in tokens[t].range { drop[k] = true } }
        var s = ""
        for (k, c) in chars.enumerated() where !drop[k] { s.append(c) }
        var parts = s.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 != "," && $0 != ";" }
        while let f = parts.first, Self.connectors.contains(f.lowercased()) { parts.removeFirst() }
        while let l = parts.last, Self.connectors.contains(l.lowercased()) { parts.removeLast() }
        var out = parts.joined(separator: " ")
        while let c = out.last, c == "," || c == ";" { out.removeLast() }
        while let c = out.first, c == "," || c == ";" { out.removeFirst() }
        return out.trimmingCharacters(in: .whitespaces)
    }

    mutating func matchFilter(_ i: Int, inText: Bool) -> Int? {
        if let n = matchDate(i, inText) { return n }
        if let n = matchFolder(i) { return n }
        if let n = matchDevice(i, inText) { return n }
        if let n = matchDownload(i, inText) { return n }
        if let n = matchSource(i, inText) { return n }
        if let n = matchSize(i, inText) { return n }
        if let n = matchType(i, inText) { return n }
        return nil
    }

    // MARK: Dates

    static let datePreps: Set<String> = ["in", "from", "during", "on", "for", "within"]
    static let unitWords: [String: Unit] = [
        "hour": .hour, "hours": .hour, "hr": .hour, "hrs": .hour, "day": .day, "days": .day, "week": .week, "weeks": .week,
        "wk": .week, "wks": .week, "month": .month, "months": .month, "mo": .month, "mos": .month, "mth": .month,
        "mths": .month, "year": .year, "years": .year, "yr": .year, "yrs": .year,
    ]
    static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "few": 3, "several": 3,
    ]
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                             "October", "November", "December"]
    static let months: [String: Int] = {
        var m: [String: Int] = [:]
        for (k, name) in monthNames.enumerated() { m[name.lowercased()] = k + 1 }
        for (k, abbr) in ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].enumerated() {
            m[abbr] = k + 1
        }
        m["sept"] = 9
        return m
    }()
    /// Months that are also verbs: alone after "I"/"you"…, they're the verb ("files I may need").
    static let verbMonths: Set<String> = ["may", "march"]
    static let pronouns: Set<String> = ["i", "you", "we", "they", "it", "he", "she", "that", "which", "who", "might"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]
    /// Short weekday names read as days only after "on", "last" or "this" ("sun" alone is the sun).
    static let weekdayAbbreviations: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7,
    ]
    static let recentWords: Set<String> = ["recent", "recently", "latest", "new", "newest", "lately"]
    static let oldWords: Set<String> = ["old", "older", "oldest"]

    mutating func matchDate(_ i: Int, _ inText: Bool) -> Int? {
        guard let w = word(i) else { return nil }

        // since / before / after <a date>
        if w == "since" || w == "before" || w == "after" || w == "until" || w == "till" {
            guard let core = dateCore(i + 1, prep: true, the: false) else { return nil }
            let n = 1 + core.count
            switch (w, core.effect) {
            case ("since", .range(let r)): setNewer(r.start, "Since \(core.inline)", i..<i + n)
            case ("since", .newer(let d)): setNewer(d, "Since \(core.inline)", i..<i + n)
            case ("before", .range(let r)): setOlder(r.start, "Before \(core.inline)", i..<i + n)
            case ("after", .range(let r)): setNewer(r.end, "After \(core.inline)", i..<i + n)
            case ("until", .range(let r)), ("till", .range(let r)): setOlder(r.end, "Until \(core.inline)", i..<i + n)
            default: return nil
            }
            return n
        }

        // from march to june, between 2023 and 2024
        if w == "from" || w == "between", let a = dateCore(i + 1, prep: true, the: false), case .range(let first) = a.effect,
           let joiner = word(i + 1 + a.count),
           (w == "from" ? ["to", "until", "till", "through", "thru", "-"] : ["and", "to", "-", "&"]).contains(joiner),
           let b = dateCore(i + 2 + a.count, prep: true, the: false), case .range(let second) = b.effect {
            let n = 2 + a.count + b.count
            let range = DateInterval(start: min(first.start, second.start), end: max(first.end, second.end))
            setRange(range, a.inline.prefix(1).uppercased() + a.inline.dropFirst() + "–" + b.inline, i..<i + n)
            return n
        }

        // older than / newer than <a duration or a date>
        if w == "older" || w == "newer" || w == "younger", word(i + 1) == "than" {
            if let d = duration(i + 2) {
                let n = 2 + d.count
                if w == "older" {
                    setOlder(back(d.n, d.unit), "Older than \(d.unit.phrase(d.n))", i..<i + n)
                } else {
                    setNewer(back(d.n, d.unit), "Newer than \(d.unit.phrase(d.n))", i..<i + n)
                }
                return n
            }
            if let core = dateCore(i + 2, prep: true, the: false), case .range(let r) = core.effect {
                let n = 2 + core.count
                if w == "older" { setOlder(r.start, "Before \(core.inline)", i..<i + n) } else {
                    setNewer(r.end, "After \(core.inline)", i..<i + n)
                }
                return n
            }
            // "older than 6": the unit is still being typed — understood, but nothing to filter by yet.
            if let c = count(i + 2) {
                for k in i..<i + 2 + c.used { used[k] = true }
                return 2 + c.used
            }
            // Otherwise "older" alone, below.
        }

        // more than / over / less than / under <duration> old|ago
        if let (more, c) = ageComparator(i), let d = duration(i + c), let tail = word(i + c + d.count),
           tail == "old" || tail == "ago" {
            let n = c + d.count + 1
            if more {
                setOlder(back(d.n, d.unit), "Older than \(d.unit.phrase(d.n))", i..<i + n)
            } else {
                setNewer(back(d.n, d.unit), "Newer than \(d.unit.phrase(d.n))", i..<i + n)
            }
            return n
        }

        // <duration> old
        if let d = duration(i), word(i + d.count) == "old" {
            setOlder(back(d.n, d.unit), "Older than \(d.unit.phrase(d.n))", i..<i + d.count + 1)
            return d.count + 1
        }

        // within <duration>
        if w == "within", let d = duration(i + 1) {
            setNewer(back(d.n, d.unit), rollingLabel(d.n, d.unit, past: false), i..<i + 1 + d.count)
            return 1 + d.count
        }

        // [in|from|during|on…] [the] <date>
        var j = i
        let prep = Self.datePreps.contains(w) || (w == "over" && word(i + 1) == "the")
        if prep { j += 1 }
        var the = false
        if word(j) == "the" { the = true; j += 1 }
        if let core = dateCore(j, prep: prep, the: the), !(core.weak && inText) {
            let n = j - i + core.count
            switch core.effect {
            case .range(let r): setRange(r, core.label, i..<i + n)
            case .newer(let d): setNewer(d, core.label, i..<i + n)
            case .older(let d): setOlder(d, core.label, i..<i + n)
            }
            return n
        }

        guard !inText else { return nil }
        if Self.oldWords.contains(w) {
            setOlder(back(1, .year), "Older than a year", i..<i + 1)
            return 1
        }
        if Self.recentWords.contains(w) {
            setNewer(back(7, .day), "Recent", i..<i + 1)
            return 1
        }
        return nil
    }

    /// A date on its own: "today", "last week", "past 3 days", "2 weeks ago", "monday", "aug 2024", "2023".
    func dateCore(_ j: Int, prep: Bool, the: Bool) -> DateCore? {
        guard let w = word(j) else { return nil }
        switch w {
        case "today", "tonight":
            return dayCore(now, "Today", "today", count: 1)
        case "yesterday":
            guard let d = cal.date(byAdding: .day, value: -1, to: now) else { return nil }
            return dayCore(d, "Yesterday", "yesterday", count: 1)
        case "this", "current":
            if let u = Self.unitWords[word(j + 1) ?? ""], [.week, .month, .year].contains(u),
               let r = cal.dateInterval(of: u.component, for: now) {
                return DateCore(effect: .range(r), label: "This \(u.name)", inline: "this \(u.name)", count: 2, weak: false)
            }
            if let wd = weekday(j + 1, abbreviated: true) { return weekdayCore(wd, strict: false, count: 2) }
            if var m = monthCore(j + 1, mode: .thisYear, prep: true) {
                m.count += 1
                return m
            }
            return nil
        case "last", "past", "previous", "prev":
            if let d = duration(j + 1) {
                return DateCore(effect: .newer(back(d.n, d.unit)), label: rollingLabel(d.n, d.unit, past: w == "past"),
                                inline: rollingLabel(d.n, d.unit, past: w == "past").lowercased(), count: 1 + d.count,
                                weak: false)
            }
            if let u = Self.unitWords[word(j + 1) ?? ""] {
                if w == "past" || the || u == .day || u == .hour {
                    let label = "Past \(u.name)"
                    return DateCore(effect: .newer(back(1, u)), label: label, inline: label.lowercased(), count: 2, weak: false)
                }
                guard let previous = cal.date(byAdding: u.component, value: -1, to: now),
                      let r = cal.dateInterval(of: u.component, for: previous) else { return nil }
                return DateCore(effect: .range(r), label: "Last \(u.name)", inline: "last \(u.name)", count: 2, weak: false)
            }
            if w != "past", let wd = weekday(j + 1, abbreviated: true) { return weekdayCore(wd, strict: true, count: 2) }
            if w != "past", var m = monthCore(j + 1, mode: .beforeThisMonth, prep: true) {
                m.count += 1
                return m
            }
            return nil
        default:
            break
        }
        // 3 days ago, a week ago
        if let d = duration(j), word(j + d.count) == "ago" {
            guard let then = cal.date(byAdding: d.unit.component, value: -d.n, to: now),
                  let r = cal.dateInterval(of: d.unit.component, for: then) else { return nil }
            let label = d.n == 1 ? (d.unit == .hour ? "An hour ago" : "A \(d.unit.name) ago") : "\(d.n) \(d.unit.name)s ago"
            return DateCore(effect: .range(r), label: label, inline: label.lowercased(), count: d.count + 1, weak: false)
        }
        if let wd = weekday(j, abbreviated: prep) {
            var core = weekdayCore(wd, strict: false, count: 1)
            core?.weak = !prep
            return core
        }
        if let m = monthCore(j, mode: .latest, prep: prep) { return m }
        if let y = Self.yearValue(w), !isSizeUnit(word(j + 1)), Self.unitWords[word(j + 1) ?? ""] == nil,
           let start = cal.date(from: DateComponents(year: y, month: 1, day: 1)),
           let r = cal.dateInterval(of: .year, for: start) {
            return DateCore(effect: .range(r), label: "\(y)", inline: "\(y)", count: 1, weak: !prep)
        }
        return nil
    }

    func dayCore(_ date: Date, _ label: String, _ inline: String, count: Int) -> DateCore? {
        guard let r = cal.dateInterval(of: .day, for: date) else { return nil }
        return DateCore(effect: .range(r), label: label, inline: inline, count: count, weak: false)
    }

    func weekday(_ j: Int, abbreviated: Bool) -> Int? {
        guard let w = word(j) else { return nil }
        return Self.weekdays[w] ?? (abbreviated ? Self.weekdayAbbreviations[w] : nil)
    }

    /// The most recent such weekday (today counts, unless `strict`: "last friday" on a Friday is a week ago).
    func weekdayCore(_ weekday: Int, strict: Bool, count: Int) -> DateCore? {
        let today = cal.component(.weekday, from: now)
        var daysBack = (today - weekday + 7) % 7
        if strict, daysBack == 0 { daysBack = 7 }
        guard let date = cal.date(byAdding: .day, value: -daysBack, to: now),
              let r = cal.dateInterval(of: .day, for: date) else { return nil }
        let name = Self.weekdayNames[weekday - 1]
        return DateCore(effect: .range(r), label: strict ? "Last \(name)" : name, inline: strict ? "last \(name)" : name,
                        count: count, weak: false)
    }

    /// "august", "aug 2024", "march 3", "march 3rd 2024", "may of 2023". Without a year: the most recent
    /// one that isn't in the future (this month counts).
    func monthCore(_ j: Int, mode: MonthMode, prep: Bool) -> DateCore? {
        guard let w = word(j), let month = Self.months[w] else { return nil }
        var k = j + 1
        var day: Int?
        if let d = dayOfMonth(k), !isSizeUnit(word(k + 1)) {
            day = d
            k += 1
        }
        var year: Int?
        if word(k) == "of", let y = Self.yearValue(word(k + 1)) {
            year = y
            k += 2
        } else if let y = Self.yearValue(word(k)) {
            year = y
            k += 1
        }
        let bare = year == nil && day == nil && mode == .latest && !prep
        if bare, Self.verbMonths.contains(w), let p = word(j - 1), Self.pronouns.contains(p) { return nil }
        let today = cal.dateComponents([.year, .month, .day], from: now)
        guard let thisYear = today.year, let thisMonth = today.month, let thisDay = today.day else { return nil }
        var y = year ?? thisYear
        if year == nil {
            switch mode {
            case .latest: if month > thisMonth || (month == thisMonth && (day ?? 0) > thisDay) { y -= 1 }
            case .beforeThisMonth: if month >= thisMonth { y -= 1 }
            case .thisYear: break
            }
        }
        guard let start = cal.date(from: DateComponents(year: y, month: month, day: day ?? 1)),
              cal.component(.month, from: start) == month,
              let r = cal.dateInterval(of: day == nil ? .month : .day, for: start) else { return nil }
        let name = Self.monthNames[month - 1]
        let short = day.map { "\(name) \($0)" } ?? name
        let full = day.map { "\(name) \($0), \(y)" } ?? "\(name) \(y)"
        return DateCore(effect: .range(r), label: full, inline: year == nil && y == thisYear ? short : full,
                        count: k - j, weak: bare)
    }

    func dayOfMonth(_ j: Int) -> Int? {
        guard var w = word(j) else { return nil }
        for suffix in ["st", "nd", "rd", "th"] where w.hasSuffix(suffix) {
            w.removeLast(2)
            break
        }
        guard !w.isEmpty, w.count <= 2, w.allSatisfy({ $0.isASCII && $0.isNumber }), let d = Int(w), (1...31).contains(d)
        else { return nil }
        return d
    }

    static func yearValue(_ w: String?) -> Int? {
        guard let w, w.count == 4, w.allSatisfy({ $0.isASCII && $0.isNumber }), let y = Int(w), (1970...2099).contains(y)
        else { return nil }
        return y
    }

    /// "3 days", "a week", "a couple of months", "6months".
    func duration(_ j: Int) -> (n: Int, unit: Unit, count: Int)? {
        guard let w = word(j) else { return nil }
        let digits = w.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count < w.count, let n = Int(digits), let u = Self.unitWords[String(w.dropFirst(digits.count))] {
            return (n, u, 1)
        }
        if let c = count(j), let unitWord = word(j + c.used), let u = Self.unitWords[unitWord] {
            return (c.value, u, c.used + 1)
        }
        return nil
    }

    /// "3", "a", "a couple of", "a few", "two".
    func count(_ j: Int) -> (value: Int, used: Int)? {
        guard let w = word(j) else { return nil }
        if !w.isEmpty, w.count <= 4, w.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(w) { return (n, 1) }
        if w == "a" || w == "an" {
            if word(j + 1) == "couple" { return (2, word(j + 2) == "of" ? 3 : 2) }
            if word(j + 1) == "few" { return (3, 2) }
            return (1, 1)
        }
        if w == "couple" { return (2, word(j + 1) == "of" ? 2 : 1) }
        if let n = Self.numberWords[w] { return (n, 1) }
        return nil
    }

    func ageComparator(_ i: Int) -> (more: Bool, count: Int)? {
        if let c = phrase(i, [["more", "than"], ["over"], ["at", "least"], ["longer", "than"]]) { return (true, c) }
        if let c = phrase(i, [["less", "than"], ["under"], ["at", "most"], ["fewer", "than"]]) { return (false, c) }
        return nil
    }

    /// The length of the longest of `phrases` starting at `i`.
    func phrase(_ i: Int, _ phrases: [[String]]) -> Int? {
        var best: Int?
        for p in phrases where p.count > (best ?? 0) {
            if p.indices.allSatisfy({ word(i + $0) == p[$0] }) { best = p.count }
        }
        return best
    }

    func back(_ n: Int, _ unit: Unit) -> Date { cal.date(byAdding: unit.component, value: -n, to: now) ?? now }

    func rollingLabel(_ n: Int, _ unit: Unit, past: Bool) -> String {
        n == 1 ? "Past \(unit.name)" : "\(past ? "Past" : "Last") \(n) \(unit.name)s"
    }

    mutating func setRange(_ r: DateInterval, _ label: String, _ toks: Range<Int>) {
        if let old = query.dateRange {
            let start = max(old.start, r.start), end = min(old.end, r.end)
            query.dateRange = DateInterval(start: start, end: max(start, end))
        } else {
            query.dateRange = r
        }
        add(.date, label, "calendar", toks)
    }

    mutating func setNewer(_ d: Date, _ label: String, _ toks: Range<Int>) {
        query.newerThan = max(query.newerThan ?? d, d)
        add(.date, label, "calendar", toks)
    }

    mutating func setOlder(_ d: Date, _ label: String, _ toks: Range<Int>) {
        query.olderThan = min(query.olderThan ?? d, d)
        add(.date, label, "clock.arrow.circlepath", toks)
    }

    // MARK: Folders

    static let folderPreps: Set<String> = ["in", "on", "inside", "from", "within", "at", "into"]
    static let folderWords: [String: LibraryQuery.Folder] = [
        "desktop": .desktop, "documents": .documents, "docs": .documents, "downloads": .downloads,
        "download": .downloads, "pictures": .pictures, "movies": .movies, "music": .music, "icloud": .icloud,
    ]

    mutating func matchFolder(_ i: Int) -> Int? {
        guard let w = word(i) else { return nil }
        // "downloads folder", "desktop folder"
        if let f = Self.folderWords[w], let x = word(i + 1), x == "folder" || x == "directory" {
            query.folder = f
            add(.folder, "In \(f.title)", f == .icloud ? "icloud" : "folder", i..<i + 2)
            return 2
        }
        guard Self.folderPreps.contains(w) else { return nil }
        var j = i + 1
        if let d = word(j), Self.determiners.contains(d) { j += 1 }
        guard let f = word(j).flatMap({ Self.folderWords[$0] }) else { return nil }
        j += 1
        if f == .icloud, word(j) == "drive" { j += 1 }
        if let x = word(j), x == "folder" || x == "directory" { j += 1 }
        query.folder = f
        add(.folder, "In \(f.title)", f == .icloud ? "icloud" : "folder", i..<j)
        return j - i
    }

    // MARK: Devices

    static let devicePreps: Set<String> = ["from", "on", "by", "via", "with"]
    static let devices: [String: String] = [
        "iphone": "iPhone", "iphones": "iPhone", "phone": "iPhone", "phones": "iPhone", "ipad": "iPad", "ipads": "iPad",
        "camera": "Camera", "cameras": "Camera", "canon": "Canon", "nikon": "Nikon", "sony": "Sony", "fuji": "Fujifilm",
        "fujifilm": "Fujifilm", "gopro": "GoPro", "dji": "DJI", "drone": "DJI", "pixel": "Pixel", "samsung": "Samsung",
        "galaxy": "Samsung", "android": "Android",
    ]

    mutating func matchDevice(_ i: Int, _ inText: Bool) -> Int? {
        guard let w = word(i) else { return nil }
        if Self.devicePreps.contains(w) {
            var j = i + 1
            var determiner = false
            if let d = word(j), Self.determiners.contains(d) {
                j += 1
                determiner = true
            }
            // "with iphone" reads as words to find; "taken with my iphone" is the camera.
            if w == "with", !determiner { return nil }
            guard let (name, c) = deviceWord(j) else { return nil }
            setDevice(name, i..<j + c)
            return j + c - i
        }
        // "iphone photos"
        if !inText, let (name, c) = deviceWord(i), typeSpec(i + c) != nil {
            setDevice(name, i..<i + c)
            return c
        }
        return nil
    }

    func deviceWord(_ j: Int) -> (String, Int)? {
        guard let w = word(j) else { return nil }
        if w == "go", word(j + 1) == "pro" { return ("GoPro", word(j + 2) == "camera" ? 3 : 2) }
        guard let name = Self.devices[w] else { return nil }
        return (name, name != "Camera" && word(j + 1) == "camera" ? 2 : 1)
    }

    mutating func setDevice(_ name: String, _ toks: Range<Int>) {
        query.device = name
        let symbol = name == "iPhone" || name == "Pixel" || name == "Samsung" || name == "Android" ? "iphone"
            : name == "iPad" ? "ipad" : "camera"
        add(.device, name == "Camera" ? "From a camera" : "From \(name)", symbol, toks)
    }

    // MARK: Downloads and sources

    static let webWords: Set<String> = ["web", "internet", "browser", "online", "net", "interwebs"]
    static let downloadWords: Set<String> = ["downloads", "downloaded", "download"]
    static let sourcePreps: Set<String> = ["from", "via", "on", "through", "thru", "by", "off"]
    /// Words after a source that belong to it: "from my gmail account", "slack attachments".
    static let sourceTails: Set<String> = ["attachments", "attachment", "account", "app", "files", "downloads", "uploads"]

    mutating func matchDownload(_ i: Int, _ inText: Bool) -> Int? {
        guard let w = word(i) else { return nil }
        if Self.downloadWords.contains(w) {
            // "downloaded from gmail": the source says it all.
            if let n = matchSource(i + 1, true) {
                drafts[drafts.count - 1].tokens.insert(i, at: 0)
                used[i] = true
                return n + 1
            }
            if let n = webPhrase(i + 1) {
                setDownload(i..<i + 1 + n)
                return 1 + n
            }
            guard !inText else { return nil }
            setDownload(i..<i + 1)
            return 1
        }
        if let n = webPhrase(i) {
            setDownload(i..<i + n)
            return n
        }
        if !inText, Self.webWords.contains(w), let d = word(i + 1), Self.downloadWords.contains(d) {
            setDownload(i..<i + 2)
            return 2
        }
        return nil
    }

    /// "from the web", "off the internet", "online".
    func webPhrase(_ j: Int) -> Int? {
        guard let w = word(j), ["from", "off", "on", "via"].contains(w) else { return nil }
        var k = j + 1
        if word(k) == "the" { k += 1 }
        guard let x = word(k), Self.webWords.contains(x) else { return nil }
        return k + 1 - j
    }

    mutating func setDownload(_ toks: Range<Int>) {
        query.anyDownload = true
        add(.download, "Downloads", "arrow.down.circle", toks)
    }

    mutating func matchSource(_ i: Int, _ inText: Bool) -> Int? {
        guard let w = word(i) else { return nil }
        if Self.sourcePreps.contains(w) {
            var j = i + 1
            if let d = word(j), ["my", "the", "our", "your"].contains(d) { j += 1 }
            for length in stride(from: 3, through: 1, by: -1) {
                guard let s = source(j, length, knownOnly: false) else { continue }
                var end = j + length
                if let x = word(end), Self.sourceTails.contains(x) { end += 1 }
                setSource(s, i..<end)
                return end - i
            }
            return nil
        }
        // "gmail attachments", "slack pdfs"
        guard !inText else { return nil }
        for length in [2, 1] {
            guard let s = source(i, length, knownOnly: true) else { continue }
            let next = i + length
            if let x = word(next), Self.sourceTails.contains(x) {
                setSource(s, i..<next + 1)
                return length + 1
            }
            if typeSpec(next) != nil {
                setSource(s, i..<next)
                return length
            }
        }
        return nil
    }

    /// A source named by `length` words at `j`. A website must look like one: "example.com", never "notes.pdf".
    func source(_ j: Int, _ length: Int, knownOnly: Bool) -> DownloadSource? {
        guard j + length <= tokens.count, (j..<j + length).allSatisfy({ !tokens[$0].quoted }) else { return nil }
        let words = (j..<j + length).map { tokens[$0].word }
        if words.contains(where: { Self.stopwords.contains($0) }) { return nil }
        let text = words.joined(separator: " ")
        if knownOnly, text.count < 3 { return nil }
        guard let s = DownloadSources.lookup(text) else { return nil }
        if s.isKnown { return s }
        guard !knownOnly, let tld = text.split(separator: ".").last.map(String.init), tld.count >= 2,
              tld.allSatisfy({ $0.isASCII && $0.isLetter }),
              FileKind.of(extension: tld) == .other || tld == "ai" || tld == "app" else { return nil }
        return s
    }

    mutating func setSource(_ s: DownloadSource, _ toks: Range<Int>) {
        query.source = s
        add(.source, "From \(s.name)", s.symbol, toks)
    }

    // MARK: Sizes

    static let sizeUnits: [String: SizeUnit] = [
        "b": .b, "byte": .b, "bytes": .b, "k": .kb, "kb": .kb, "kbs": .kb, "kilobyte": .kb, "kilobytes": .kb,
        "m": .mb, "mb": .mb, "mbs": .mb, "meg": .mb, "megs": .mb, "megabyte": .mb, "megabytes": .mb,
        "g": .gb, "gb": .gb, "gbs": .gb, "gig": .gb, "gigs": .gb, "gigabyte": .gb, "gigabytes": .gb,
        "tb": .tb, "tbs": .tb, "terabyte": .tb, "terabytes": .tb,
    ]
    static let minComparators: [[String]] = [
        ["over"], ["above"], ["bigger", "than"], ["larger", "than"], ["more", "than"], ["greater", "than"],
        ["heavier", "than"], ["at", "least"], ["exceeding"], ["exceeds"], ["min"], ["minimum"], [">"], [">="], ["≥"],
    ]
    static let maxComparators: [[String]] = [
        ["under"], ["below"], ["smaller", "than"], ["less", "than"], ["lighter", "than"], ["at", "most"], ["up", "to"],
        ["no", "more", "than"], ["no", "bigger", "than"], ["no", "larger", "than"], ["not", "over"], ["max"],
        ["maximum"], ["<"], ["<="], ["≤"],
    ]
    /// Lengths of time a video or song could have — not sizes (and not something the library knows).
    static let timeWords: Set<String> = ["minute", "minutes", "min", "mins", "second", "seconds", "sec", "secs"]
    static let bigWords: Set<String> = ["big", "large", "bigger", "larger", "biggest", "largest", "heavy"]
    static let hugeWords: Set<String> = ["huge", "massive", "giant", "enormous", "gigantic", "humongous"]
    static let smallWords: Set<String> = ["small", "tiny", "smaller", "smallest", "little"]

    mutating func matchSize(_ i: Int, _ inText: Bool) -> Int? {
        guard let w = word(i) else { return nil }

        // between 1 and 5 gb
        if w == "between" {
            guard let a = amount(i + 1, unitOptional: true), let joiner = word(i + 1 + a.count),
                  ["and", "to", "-", "&"].contains(joiner),
                  let b = amount(i + 2 + a.count, unitOptional: true) else { return nil }
            let n = 2 + a.count + b.count
            setBetween(a, b, i..<i + n)
            return n
        }

        // 1-5gb, 1-5 gb
        if let dash = w.firstIndex(of: "-"), dash != w.startIndex {
            let left = String(w[..<dash]), right = String(w[w.index(after: dash)...])
            if let a = amount(text: left, next: i + 1, unitOptional: true, lookAhead: false),
               let b = amount(text: right, next: i + 1, unitOptional: false, lookAhead: true) {
                setBetween(a, b, i..<i + b.count)
                return b.count
            }
        }

        // >5mb, <=2gb
        for (prefix, isMin) in [(">=", true), ("<=", false), ("≥", true), ("≤", false), (">", true), ("<", false)]
        where w.hasPrefix(prefix) && w.count > prefix.count {
            let rest = String(w.dropFirst(prefix.count))
            guard let first = rest.first, first.isNumber || first == "." else { break } // ">=" alone: a comparison word
            guard let a = amount(text: rest, next: i + 1, unitOptional: true, lookAhead: true) else { return nil }
            setBound(a, isMin: isMin, i..<i + a.count)
            return a.count
        }

        // over 5 mb, less than 10mb (a number alone is in MB)
        if let c = phrase(i, Self.minComparators) ?? phrase(i, Self.maxComparators),
           let a = amount(i + c, unitOptional: true) {
            setBound(a, isMin: phrase(i, Self.minComparators) == c, i..<i + c + a.count)
            return c + a.count
        }

        // 5gb, 5 gb, 5gb+ (but "4k" is a resolution, not a size)
        if let a = amount(i, unitOptional: false), !(a.unitText == "k" && !a.plus) {
            setBound(a, isMin: true, i..<i + a.count)
            return a.count
        }

        guard !inText else { return nil }
        if Self.bigWords.contains(w) {
            setBound(Amount(number: 100, unit: .mb, unitText: "mb", count: 1, plus: false), isMin: true, i..<i + 1)
            return 1
        }
        if Self.hugeWords.contains(w) {
            setBound(Amount(number: 1, unit: .gb, unitText: "gb", count: 1, plus: false), isMin: true, i..<i + 1)
            return 1
        }
        if Self.smallWords.contains(w) {
            setBound(Amount(number: 1, unit: .mb, unitText: "mb", count: 1, plus: false), isMin: false, i..<i + 1)
            return 1
        }
        return nil
    }

    func amount(_ i: Int, unitOptional: Bool) -> Amount? {
        guard let w = word(i) else { return nil }
        return amount(text: w, next: i + 1, unitOptional: unitOptional, lookAhead: true)
    }

    /// "5", "1.5gb", "5gb+", "5 gb" (the unit in the next token when `lookAhead`).
    func amount(text: String, next: Int, unitOptional: Bool, lookAhead: Bool) -> Amount? {
        var s = Substring(text)
        var plus = false
        if s.hasSuffix("+") {
            plus = true
            s = s.dropLast()
        }
        let numberPart = s.prefix { ($0.isASCII && $0.isNumber) || $0 == "." }
        // Up to a million TB: anything bigger is no size anyone means (and would overflow).
        guard numberPart.contains(where: \.isNumber), let n = Double(numberPart), n.isFinite, n >= 0, n < 1e6 else { return nil }
        let rest = String(s.dropFirst(numberPart.count))
        if rest.isEmpty {
            if lookAhead, var u = word(next) {
                var unitPlus = false
                if u.hasSuffix("+") {
                    unitPlus = true
                    u.removeLast()
                }
                if let unit = Self.sizeUnits[u] {
                    return Amount(number: n, unit: unit, unitText: u, count: 2, plus: plus || unitPlus)
                }
            }
            guard unitOptional else { return nil }
            // "more than 3 days", "over 2 minutes": no size.
            if lookAhead, let u = word(next), Self.unitWords[u] != nil || Self.timeWords.contains(u) { return nil }
            return Amount(number: n, unit: nil, unitText: "", count: 1, plus: plus)
        }
        guard let unit = Self.sizeUnits[rest] else { return nil }
        return Amount(number: n, unit: unit, unitText: rest, count: 1, plus: plus)
    }

    func isSizeUnit(_ w: String?) -> Bool {
        guard var w else { return false }
        if w.hasSuffix("+") { w.removeLast() }
        return Self.sizeUnits[w] != nil
    }

    mutating func setBound(_ a: Amount, isMin: Bool, _ toks: Range<Int>) {
        let unit = a.unit ?? .mb
        guard let bytes = a.bytes(unit) else { return }
        if isMin {
            query.minBytes = max(query.minBytes ?? bytes, bytes)
            add(.size, "Over \(unit.text(a.number))", "scalemass", toks)
        } else {
            query.maxBytes = min(query.maxBytes ?? bytes, bytes)
            add(.size, "Under \(unit.text(a.number))", "scalemass", toks)
        }
    }

    mutating func setBetween(_ a: Amount, _ b: Amount, _ toks: Range<Int>) {
        let unitB = b.unit ?? a.unit ?? .mb
        let unitA = a.unit ?? unitB
        guard var low = a.bytes(unitA), var high = b.bytes(unitB) else { return }
        var lowText = (a.number, unitA), highText = (b.number, unitB)
        if low > high {
            swap(&low, &high)
            swap(&lowText, &highText)
        }
        query.minBytes = max(query.minBytes ?? low, low)
        query.maxBytes = min(query.maxBytes ?? high, high)
        let label = lowText.1 == highText.1
            ? "\(Self.format(lowText.0))–\(highText.1.text(highText.0))"
            : "\(lowText.1.text(lowText.0))–\(highText.1.text(highText.0))"
        add(.size, label, "scalemass", toks)
    }

    /// 5 → "5", 1.5 → "1.5".
    static func format(_ x: Double) -> String {
        if x == x.rounded(), abs(x) < 1e15 { return String(Int64(x)) }
        return String(x)
    }

    // MARK: Types

    static let typePhrases: [String: TypeSpec] = {
        var table: [String: TypeSpec] = [:]
        func add(_ words: [String], _ spec: TypeSpec) { for w in words { table[w] = spec } }
        add(["image", "images", "picture", "pictures", "pic", "pics", "img", "imgs", "pix"],
            TypeSpec(label: "Images", symbol: "photo", kinds: [.image]))
        add(["photo", "photos", "photograph", "photographs"], TypeSpec(label: "Photos", symbol: "photo", kinds: [.image]))
        add(["screenshot", "screenshots", "screen shot", "screen shots", "screencap", "screencaps", "screen cap",
             "screen caps", "screen capture", "screen captures", "screengrab", "screengrabs", "screen grab", "screen grabs"],
            TypeSpec(label: "Screenshots", symbol: "camera.viewfinder", screenshots: true))
        add(["screen recording", "screen recordings", "screencast", "screencasts", "screen video", "screen videos"],
            TypeSpec(label: "Screen recordings", symbol: "record.circle", kinds: [.video], screenshots: true))
        add(["video", "videos", "movie", "movies", "clip", "clips", "film", "films", "recording", "recordings", "footage"],
            TypeSpec(label: "Videos", symbol: "film", kinds: [.video]))
        add(["music", "song", "songs", "track", "tracks"], TypeSpec(label: "Music", symbol: "music.note", kinds: [.audio]))
        add(["audio", "audios", "sound", "sounds", "audio file", "audio files"],
            TypeSpec(label: "Audio", symbol: "waveform", kinds: [.audio]))
        add(["podcast", "podcasts"], TypeSpec(label: "Podcasts", symbol: "waveform", kinds: [.audio]))
        add(["voice memo", "voice memos", "voice note", "voice notes", "voice recording", "voice recordings"],
            TypeSpec(label: "Voice memos", symbol: "waveform", kinds: [.audio]))
        add(["document", "documents", "doc", "docs"], TypeSpec(label: "Documents", symbol: "doc.text", kinds: [.document]))
        add(["pdf", "pdfs"], TypeSpec(label: "PDFs", symbol: "doc.richtext", exts: ["pdf"]))
        add(["word doc", "word docs", "word document", "word documents", "word file", "word files", "docx", "docxs"],
            TypeSpec(label: "Word documents", symbol: "doc.text", exts: ["doc", "docx"]))
        add(["spreadsheet", "spreadsheets", "sheet", "sheets", "excel", "excel sheet", "excel sheets", "xls", "xlsx",
             "xlsxs", "csv", "csvs", "numbers", "ods"],
            TypeSpec(label: "Spreadsheets", symbol: "tablecells", exts: ["xls", "xlsx", "csv", "tsv", "numbers", "ods"]))
        add(["presentation", "presentations", "slide", "slides", "slideshow", "slideshows", "slide deck", "slide decks",
             "deck", "decks", "keynote", "keynotes", "powerpoint", "powerpoints", "ppt", "ppts", "pptx", "odp"],
            TypeSpec(label: "Presentations", symbol: "rectangle.on.rectangle", exts: ["key", "ppt", "pptx", "odp"]))
        add(["ebook", "ebooks", "e-book", "e-books", "book", "books", "epub", "epubs", "mobi", "azw3"],
            TypeSpec(label: "Ebooks", symbol: "book", exts: ["epub", "mobi", "azw3"]))
        add(["text file", "text files", "text document", "text documents", "plain text", "txt", "txts"],
            TypeSpec(label: "Text files", symbol: "doc.plaintext", exts: ["txt", "md", "rtf"]))
        add(["archive", "archives", "compressed", "compressed file", "compressed files"],
            TypeSpec(label: "Archives", symbol: "archivebox", kinds: [.archive]))
        add(["zip", "zips", "zip file", "zip files", "zipped"], TypeSpec(label: "Zips", symbol: "doc.zipper", exts: ["zip"]))
        add(["rar", "rars"], TypeSpec(label: "RARs", symbol: "doc.zipper", exts: ["rar"]))
        add(["7z", "7zip", "7-zip", "7zs"], TypeSpec(label: "7z archives", symbol: "doc.zipper", exts: ["7z"]))
        add(["tarball", "tarballs", "tar", "tars", "tar.gz", "tgz"],
            TypeSpec(label: "Tarballs", symbol: "doc.zipper", exts: ["tar", "gz", "tgz", "bz2", "tbz", "xz", "txz"]))
        add(["installer", "installers", "dmg", "dmgs", "pkg", "pkgs", "disk image", "disk images"],
            TypeSpec(label: "Installers", symbol: "shippingbox", exts: FileKind.installers))
        add(["app", "apps", "application", "applications", "program", "programs"],
            TypeSpec(label: "Apps", symbol: "app", kinds: [.app]))
        add(["raw photo", "raw photos", "raw image", "raw images", "raw file", "raw files", "raws"],
            TypeSpec(label: "RAW photos", symbol: "camera.aperture",
                     exts: ["raw", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf"]))
        return table
    }()

    /// Extensions that are also everyday words: only read as a type when written ".key" or "key files".
    static let ambiguousExtensions: Set<String> = ["key", "pages", "mid", "ai", "raw", "opus", "fig", "ts", "img", "eps",
                                                   "sketch", "xd", "cab", "sit"]
    /// Spellings of the same format.
    static let extensionGroups: [String: [String]] = [
        "jpg": ["jpg", "jpeg"], "jpeg": ["jpg", "jpeg"], "tif": ["tif", "tiff"], "tiff": ["tif", "tiff"],
        "mpg": ["mpg", "mpeg"], "mpeg": ["mpg", "mpeg"], "aif": ["aif", "aiff"], "aiff": ["aif", "aiff"],
        "md": ["md", "markdown"], "markdown": ["md", "markdown"], "mid": ["mid", "midi"], "midi": ["mid", "midi"],
    ]
    static let extensionLabels: [String: String] = [
        "jpg": "JPEGs", "jpeg": "JPEGs", "tif": "TIFFs", "tiff": "TIFFs", "mpg": "MPEGs", "mpeg": "MPEGs",
        "aif": "AIFFs", "aiff": "AIFFs", "md": "Markdown files", "markdown": "Markdown files", "mid": "MIDI files",
        "midi": "MIDI files", "key": "Keynote files", "pages": "Pages documents", "ai": "Illustrator files",
        "fig": "Figma files", "sketch": "Sketch files", "psd": "Photoshop files", "ts": "TS videos",
    ]

    /// A type named at `j`: a word from the table, any extension FileKind knows ("pngs"), or ".ext".
    func typeSpec(_ j: Int) -> (spec: TypeSpec, count: Int)? {
        guard let w = word(j) else { return nil }
        if w.hasPrefix(".") || w.hasPrefix("*.") {
            let ext = String(w.drop { $0 == "*" || $0 == "." })
            guard !ext.isEmpty, ext.count <= 10, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { return nil }
            return (Self.extensionSpec(ext, explicit: true), 1)
        }
        for length in stride(from: 3, through: 1, by: -1) where j + length <= tokens.count {
            let words = (j..<j + length).compactMap { word($0) }
            guard words.count == length else { continue }
            if let spec = Self.typePhrases[words.joined(separator: " ")] { return (spec, length) }
        }
        if let ext = Self.knownExtension(w) {
            if Self.ambiguousExtensions.contains(ext) {
                guard let f = word(j + 1), f == "file" || f == "files" else { return nil }
                return (Self.extensionSpec(ext, explicit: false), 2)
            }
            return (Self.extensionSpec(ext, explicit: false), 1)
        }
        return nil
    }

    /// "png", "pngs" → "png".
    static func knownExtension(_ w: String) -> String? {
        guard w.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        if FileKind.of(extension: w) != .other { return w }
        if w.count > 2, w.hasSuffix("s") {
            let stem = String(w.dropLast())
            if FileKind.of(extension: stem) != .other, !ambiguousExtensions.contains(stem) { return stem }
        }
        return nil
    }

    static func extensionSpec(_ ext: String, explicit: Bool) -> TypeSpec {
        let kind = FileKind.of(extension: ext)
        let label = extensionLabels[ext]
            ?? (kind == .other ? ".\(ext) files" : ext.count <= 4 ? ext.uppercased() + "s" : ext.uppercased() + " files")
        return TypeSpec(label: label, symbol: kind == .other ? "doc" : kind.symbol, exts: Set(extensionGroups[ext] ?? [ext]),
                        explicit: explicit)
    }

    mutating func matchType(_ i: Int, _ inText: Bool) -> Int? {
        guard var (spec, n) = typeSpec(i), !inText || spec.explicit else { return nil }
        // "keynote presentations", "png images", "pdf documents": one chip, the narrower filter.
        if let (head, m) = typeSpec(i + n), !inText || head.explicit {
            if spec.isNarrower(than: head) {
                if head.isNarrower(than: spec) {
                    spec.label = head.label
                    spec.symbol = head.symbol
                }
                n += m
            } else if head.isNarrower(than: spec) {
                spec = head
                n += m
            }
        }
        query.kinds.formUnion(spec.kinds)
        query.extensions.formUnion(spec.exts)
        if spec.screenshots { query.screenshotsOnly = true }
        var toks = Array(i..<i + n)
        // "pdfs and images": the "and" goes with the second chip, so removing either leaves a clean query.
        if i >= 2, let c = word(i - 1), Self.connectors.contains(c), !used[i - 1],
           let last = drafts.last, last.slot == .type, last.tokens.contains(i - 2) {
            toks.insert(i - 1, at: 0)
        }
        add(.type, spec.label, spec.symbol, toks)
        return n
    }
}

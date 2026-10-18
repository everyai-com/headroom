import Foundation

/// Quick Search's ranking, the way Raycast and Sol do it: first how well the name says what you typed
/// (exact, prefix, a word start, anywhere), then what you open most and lately (`Frecency`), then the
/// newest. Use only reorders files inside one tier, so a loose fuzzy hit never beats a name that says it.
public enum QuickRank {
    public enum Tier: Int, Sendable, Comparable {
        /// The name (without its extension) is what you typed.
        case exact
        /// The name starts with it.
        case prefix
        /// Every word starts a word of the name: "rep" in "Tax Report", "2024" in "report2024".
        case wordStart
        /// Every word is somewhere in the name.
        case substring
        /// The words were found in a folder name, a tag or the text inside, not all in the name.
        case elsewhere
        /// The letters appear in order, starting at a word: "dnld" → "Downloads", "txrpt" → "Tax Report".
        case fuzzy

        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Match: Sendable, Equatable {
        public var tier: Tier
        /// The matched letters, as offsets into the name's unicode scalars (for bold).
        public var ranges: [Range<Int>]

        public init(tier: Tier, ranges: [Range<Int>]) {
            self.tier = tier
            self.ranges = ranges
        }
    }

    /// Search words folded like `LibraryQuery`'s: letters and digits only, lowercased, accents dropped.
    public static func needles(_ terms: [String]) -> [[UInt32]] {
        terms.map { Needle($0).units }.filter { !$0.isEmpty }
    }

    /// How well `name` says the words. `.elsewhere` when it doesn't hold them all, even loosely;
    /// the ranges still mark what it does hold.
    public static func match(_ name: String, needles: [[UInt32]]) -> Match {
        guard !needles.isEmpty else { return Match(tier: .elsewhere, ranges: []) }
        let f = Folded(name)
        // The words typed together: "tax report" is exactly "Tax Report.pdf".
        let joined = needles.flatMap { $0 }
        if f.units.count >= joined.count, f.units.starts(with: joined) {
            let tier: Tier = joined.count == f.baseCount ? .exact : .prefix
            return Match(tier: tier, ranges: f.ranges(0..<joined.count))
        }
        var worst = Tier.exact
        var ranges: [Range<Int>] = []
        var missing = false
        for needle in needles {
            guard let (at, tier) = f.bestOccurrence(of: needle) else { missing = true; continue }
            worst = max(worst, tier)
            ranges += f.ranges(at..<(at + needle.count))
        }
        if !missing { return Match(tier: worst, ranges: merged(ranges)) }
        var loose: [Range<Int>] = []
        for needle in needles {
            guard let hits = f.fuzzy(needle) else { return Match(tier: .elsewhere, ranges: merged(ranges)) }
            loose += hits.flatMap { f.ranges($0..<($0 + 1)) }
        }
        return Match(tier: .fuzzy, ranges: merged(loose))
    }

    /// A cheap first look, with no allocation for ASCII names: could the letters appear in order?
    /// False means `match` can't come back `.fuzzy` or better.
    public static func mightMatch(_ name: String, needles: [[UInt32]]) -> Bool {
        var name = name
        return name.withUTF8 { buf -> Bool in
            for needle in needles {
                var i = 0 // each word on its own: "report tax" still finds "Tax Report"
                for u in needle {
                    guard u < 0x80 else { return true }
                    var found = false
                    while i < buf.count {
                        var b = buf[i]
                        i += 1
                        if b >= 0x80 { return true } // accents or another script: let `match` fold it
                        if b >= 0x41 && b <= 0x5A { b += 0x20 }
                        if UInt32(b) == u { found = true; break }
                    }
                    if !found { return false }
                }
            }
            return true
        }
    }

    /// The name cut into runs of matched and unmatched text (accent marks stay with their letter).
    public static func segments(_ name: String, ranges: [Range<Int>]) -> [(text: String, matched: Bool)] {
        guard !ranges.isEmpty else { return [(name, false)] }
        var out: [(text: String, matched: Bool)] = []
        var run = String.UnicodeScalarView()
        var runMatched = false
        for (offset, scalar) in name.unicodeScalars.enumerated() {
            let mark = scalar.properties.generalCategory == .nonspacingMark && !run.isEmpty
            let matched = mark ? runMatched : ranges.contains { $0.contains(offset) }
            if matched != runMatched, !run.isEmpty {
                out.append((String(run), runMatched))
                run = String.UnicodeScalarView()
            }
            runMatched = matched
            run.append(scalar)
        }
        if !run.isEmpty { out.append((String(run), runMatched)) }
        return out
    }

    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// A name's letters and digits, folded, with where each one sits and whether it starts a word.
    struct Folded {
        var units: [UInt32] = []
        /// Scalar offset in the name of each unit.
        var offsets: [Int] = []
        var wordStart: [Bool] = []
        /// Units before the extension.
        var baseCount = 0

        init(_ name: String) {
            let scalars = Array(name.unicodeScalars)
            let dot = scalars.lastIndex(of: ".").flatMap { $0 > 0 ? $0 : nil } ?? scalars.count
            var previous: Unicode.Scalar?
            for (offset, s) in scalars.enumerated() {
                defer { previous = s }
                guard TextMatch.isAlphanumeric(s) else { continue }
                let start: Bool = {
                    guard let p = previous, TextMatch.isAlphanumeric(p) else { return true }
                    if p.properties.isLowercase && s.properties.isUppercase { return true } // camelCase
                    return (p.properties.numericType != nil) != (s.properties.numericType != nil) // report2024
                }()
                let folded: [UInt32] = s.isASCII
                    ? [s.properties.isUppercase ? s.value + 0x20 : s.value]
                    : String(s).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                        .unicodeScalars.filter(TextMatch.isAlphanumeric).map(\.value)
                for (k, u) in folded.enumerated() {
                    units.append(u)
                    offsets.append(offset)
                    wordStart.append(start && k == 0)
                    if offset < dot { baseCount += 1 }
                }
            }
        }

        /// Scalar ranges for units `r` (adjacent units of one scalar collapse).
        func ranges(_ r: Range<Int>) -> [Range<Int>] {
            QuickRank.merged(r.map { offsets[$0]..<(offsets[$0] + 1) })
        }

        /// The best place `needle` occurs: at the start, at a word start, or anywhere.
        func bestOccurrence(of needle: [UInt32]) -> (Int, Tier)? {
            guard !needle.isEmpty, needle.count <= units.count else { return nil }
            var anywhere: Int?
            for i in 0...(units.count - needle.count) where units[i] == needle[0] {
                guard units[i..<(i + needle.count)].elementsEqual(needle) else { continue }
                if i == 0 { return (0, .prefix) }
                if wordStart[i] { return (i, .wordStart) }
                if anywhere == nil { anywhere = i }
            }
            return anywhere.map { ($0, .substring) }
        }

        /// The letters in order, starting at a word. Prefers the next letter in a row, then a word start,
        /// then anywhere — and backs up when a choice leads nowhere ("txrpt" bolds T·x·R·p·t in
        /// "Tax Report.pdf", not the p of "pdf"). Two letters at least: one letter is a prefix or nothing.
        func fuzzy(_ needle: [UInt32]) -> [Int]? {
            guard needle.count >= 2 else { return nil }
            let starts = units.indices.filter { wordStart[$0] && units[$0] == needle[0] }
            // Earliest letters first: finds a match whenever there is one, so a miss is cheap.
            func earliest(from s: Int) -> [Int]? {
                var hits = [s], pos = s + 1
                for u in needle.dropFirst() {
                    guard let next = (pos..<units.count).first(where: { units[$0] == u }) else { return nil }
                    hits.append(next)
                    pos = next + 1
                }
                return hits
            }
            guard let fallback = starts.lazy.compactMap(earliest).first else { return nil }
            var budget = 500
            var hits: [Int] = []
            func place(_ k: Int, from pos: Int) -> Bool {
                if k == needle.count { return true }
                budget -= 1
                if budget < 0 { return false }
                let u = needle[k], rest = pos..<units.count
                var candidates = pos < units.count && units[pos] == u ? [pos] : []
                candidates += rest.filter { $0 != pos && wordStart[$0] && units[$0] == u }
                candidates += rest.filter { $0 != pos && !wordStart[$0] && units[$0] == u }
                for c in candidates {
                    hits.append(c)
                    if place(k + 1, from: c + 1) { return true }
                    hits.removeLast()
                }
                return false
            }
            for s in starts {
                hits = [s]
                if place(1, from: s + 1) { return hits }
            }
            return fallback
        }
    }
}

/// What you open from Quick Search, and what you typed to find it: counts that fade with a two-week
/// half-life, so last month's project gives way to this week's. Kept in Application Support
/// (`quicksearch.json`), on this Mac only.
public struct Frecency: Codable, Sendable, Equatable {
    public struct Use: Codable, Sendable, Equatable {
        public var score: Double
        public var last: Date
    }

    /// Path → how often and how lately it was opened.
    public var files: [String: Use] = [:]
    /// What was typed (folded) → path → how often it was picked for that.
    public var queries: [String: [String: Use]] = [:]

    public static let halfLife: TimeInterval = 14 * 86_400
    public static var defaultURL: URL { HeadroomPaths.support.appendingPathComponent("quicksearch.json") }

    public init() {}

    /// A use's weight now: each one counts 1 when it happens and half that two weeks later.
    static func weight(_ use: Use, now: Date) -> Double {
        use.score * pow(0.5, max(0, now.timeIntervalSince(use.last)) / halfLife)
    }

    /// "  Tax  Report " and "tax report" are one query.
    public static func key(_ query: String) -> String {
        query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// You opened `path` after typing `query`.
    public mutating func record(_ path: String, query: String, now: Date = .now) {
        Self.bump(&files[path], now: now)
        let k = Self.key(query)
        if !k.isEmpty { Self.bump(&queries[k, default: [:]][path], now: now) }
        prune(now: now)
    }

    static func bump(_ use: inout Use?, now: Date) {
        use = Use(score: (use.map { weight($0, now: now) } ?? 0) + 1, last: now)
    }

    /// Path → how strongly to prefer it for `query`: how much you use it, plus three times as much
    /// for files picked after typing exactly this, and once more for longer queries it starts
    /// ("inv" finds what "invoice" found).
    public func boosts(for query: String, now: Date = .now) -> [String: Double] {
        var out = files.mapValues { Self.weight($0, now: now) }
        let k = Self.key(query)
        guard !k.isEmpty else { return out }
        for (typed, picks) in queries where typed.hasPrefix(k) {
            let factor = typed == k ? 3.0 : 1.0
            for (path, use) in picks { out[path, default: 0] += factor * Self.weight(use, now: now) }
        }
        return out
    }

    /// A file that's gone (or you don't want suggested) stops counting.
    public mutating func forget(_ path: String) {
        files[path] = nil
        for k in Array(queries.keys) {
            queries[k]?[path] = nil
            if queries[k]?.isEmpty == true { queries[k] = nil }
        }
    }

    /// Bounded: the strongest 2000 files, 500 queries, 10 picks each.
    mutating func prune(now: Date, maxFiles: Int = 2000, maxQueries: Int = 500, maxPicks: Int = 10) {
        func strongest(_ uses: [String: Use], _ n: Int) -> [String: Use] {
            guard uses.count > n else { return uses }
            return Dictionary(uniqueKeysWithValues: uses.sorted { Self.weight($0.value, now: now) > Self.weight($1.value, now: now) }.prefix(n)
                .map { ($0.key, $0.value) })
        }
        files = strongest(files, maxFiles)
        queries = queries.mapValues { strongest($0, maxPicks) }
        if queries.count > maxQueries {
            let newest = queries.sorted { ($0.value.values.map(\.last).max() ?? .distantPast) > ($1.value.values.map(\.last).max() ?? .distantPast) }
            queries = Dictionary(uniqueKeysWithValues: newest.prefix(maxQueries).map { ($0.key, $0.value) })
        }
    }

    public static func load(from url: URL = defaultURL) -> Frecency {
        guard let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Frecency.self, from: data) else { return Frecency() }
        return saved
    }

    public func save(to url: URL = defaultURL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

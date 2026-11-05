import Foundation

// The practical part of Wallace Wattles' "The Science of Getting Rich" (1910): a clear, definite picture of what
// you want to have, do and become, looked at often; gratitude every day; every day all that can be done that day,
// each thing done well and without hurry; and more use value given to everyone than the cash value taken.
// The book's metaphysics stays in the book — here it's a vision you read, a list you write and a day you score.

/// What you want, written down specifically enough to picture.
public struct Vision: Codable, Sendable, Equatable {
    public var have: [String] = []
    public var doing: [String] = []
    public var become: [String] = []
    /// The detailed picture, as if it were already yours ("I wake up in…").
    public var picture: String = ""
    /// "When in doubt, wait": decisions parked until you've given them a day or two of vision and gratitude.
    public var waiting: [Decision] = []
    public var updated: Date?

    public init(have: [String] = [], doing: [String] = [], become: [String] = [], picture: String = "", updated: Date? = nil) {
        self.have = have; self.doing = doing; self.become = become; self.picture = picture; self.updated = updated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        have = (try? c.decodeIfPresent([String].self, forKey: .have)) ?? []
        doing = (try? c.decodeIfPresent([String].self, forKey: .doing)) ?? []
        become = (try? c.decodeIfPresent([String].self, forKey: .become)) ?? []
        picture = (try? c.decodeIfPresent(String.self, forKey: .picture)) ?? ""
        waiting = (try? c.decodeIfPresent([Decision].self, forKey: .waiting)) ?? []
        updated = try? c.decodeIfPresent(Date.self, forKey: .updated)
    }

    public var isEmpty: Bool { have.isEmpty && doing.isEmpty && become.isEmpty && picture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// One line for small places (the pause card, the coach): who you're becoming first.
    public var headline: String? {
        become.first ?? doing.first ?? have.first
            ?? picture.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    /// "a; b; c" lines from an editor field, blanks and bullets dropped.
    public static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-•* ")) }
            .filter { !$0.isEmpty }
    }
}

/// A decision you're in doubt about: never acted on in a hurry, looked at again after `Decision.days`.
public struct Decision: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var title: String
    public var parked: String
    public static let days = 2
    public init(title: String, parked: String) { self.title = title; self.parked = parked }
    /// The day it's ready to be decided.
    public func ready(calendar: Calendar = .current) -> String {
        Planner.date(parked, calendar: calendar).map { Planner.key(daysFrom: $0, Self.days, calendar: calendar) } ?? parked
    }
}

/// The book's practices as a daily checklist. Some are read from what you did; the rest only you can say.
public enum CertainWay {
    public enum Item: String, Codable, Sendable, CaseIterable {
        // Read from the day.
        case vision, gratitude, allDone, value
        // Yours to tick.
        case wellDone, noHurry, creative, attention, increase, now

        public var title: String {
            switch self {
            case .vision: "Looked at my vision with faith that it's coming"
            case .gratitude: "Gave thanks for three things"
            case .allDone: "Did all that could be done today"
            case .value: "Gave someone more use value than I took"
            case .wellDone: "Did each thing well, one at a time"
            case .noHurry: "Went fast, but never hurried, worried or feared"
            case .creative: "Created instead of competing: what I want for myself, I want for everybody"
            case .attention: "Kept my attention off lack, gloom and argument"
            case .increase: "Spoke only of increase, never of failure or hard times"
            case .now: "Acted now, where I am, not waiting for a better place"
            }
        }
        public var isSelfReported: Bool { ![.vision, .gratitude, .allDone, .value].contains(self) }
    }

    /// Which items the day meets. `allDone` needs something planned and every planned thing done.
    public static func met(_ log: DayLog?, score: DayScore) -> Set<Item> {
        var out = Set((log?.ways ?? []).compactMap(Item.init(rawValue:)).filter(\.isSelfReported))
        if log?.visioned == true { out.insert(.vision) }
        if log?.isGrateful == true { out.insert(.gratitude) }
        if log?.gaveValue == true { out.insert(.value) }
        if score.planned > 0 && score.done == score.planned { out.insert(.allDone) }
        return out
    }

    /// The book's syllabus, in short (paraphrased from its closing summary).
    public static let summary = [
        "Hold a clear, definite picture of what you want to have, do and become.",
        "Look at it often in your spare time, with faith that it is coming and thanks as if it already has.",
        "Be grateful, every day, for everything — gratitude keeps you creative, not competitive.",
        "Create; don't compete. Nothing you want has to be taken from anyone.",
        "Act now, where you are, on the people and things around you.",
        "Do every day all that can be done that day, each thing well — fast, but never in a hurry.",
        "Give everyone more in use value than you take in cash value; leave them with a sense of increase.",
        "Use your will on yourself only: guard your attention and your speech.",
        "When in doubt, wait: look at the vision, give thanks, then act.",
    ]
}

extension DayLog {
    /// Three things, written: a habit of gratitude, not a mood.
    public static let gratitudeCount = 3
    public var isGrateful: Bool { (gratitude ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= Self.gratitudeCount }
    public var gaveValue: Bool { !(gave ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension Planner {
    /// Ledger lines for the vision, gratitude and value given (added in with the journal's).
    func visionEntries(calendar: Calendar) -> [LedgerEntry] {
        logs.flatMap { l -> [LedgerEntry] in
            let evening = Self.date(l.day, calendar: calendar)?.addingTimeInterval(20 * 3600) ?? l.updated
            var out: [LedgerEntry] = []
            if l.isGrateful { out.append(LedgerEntry(id: "g" + l.day, date: evening, kind: .gratitude, title: "Gratitude", xp: 5, coins: 5, area: nil)) }
            if l.gaveValue { out.append(LedgerEntry(id: "v" + l.day, date: evening, kind: .value, title: "Gave more than you took", xp: 5, coins: 5, area: nil)) }
            if l.visioned == true { out.append(LedgerEntry(id: "e" + l.day, date: evening, kind: .vision, title: "Read your vision", xp: 5, coins: 5, area: nil)) }
            let ways = Set((l.ways ?? []).compactMap(CertainWay.Item.init(rawValue:)))
            if ways.count >= 3 { out.append(LedgerEntry(id: "w" + l.day, date: evening, kind: .vision, title: "Lived in the certain way", xp: 10, coins: 10, area: nil)) }
            return out
        }
    }
}

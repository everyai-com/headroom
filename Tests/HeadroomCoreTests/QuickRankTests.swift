import XCTest
@testable import HeadroomCore

/// Quick Search's ranking: match tiers, the letters to bold, and what you open most and lately.
final class QuickRankTests: XCTestCase {
    func match(_ name: String, _ query: String) -> QuickRank.Match {
        QuickRank.match(name, needles: QuickRank.needles(query.split(separator: " ").map(String.init)))
    }

    func testTiersFromExactToFuzzy() {
        XCTAssertEqual(match("Invoice.pdf", "invoice").tier, .exact, "the extension doesn't count")
        XCTAssertEqual(match("Tax Report.pdf", "tax report").tier, .exact, "words typed together")
        XCTAssertEqual(match("Invoice 2024.pdf", "invoice").tier, .prefix)
        XCTAssertEqual(match("Tax Report.pdf", "rep").tier, .wordStart)
        XCTAssertEqual(match("TaxReport.pdf", "report").tier, .wordStart, "camelCase starts a word")
        XCTAssertEqual(match("report2024.pdf", "2024").tier, .wordStart, "so does a number after letters")
        XCTAssertEqual(match("Tax Report.pdf", "port").tier, .substring)
        XCTAssertEqual(match("Tax Report.pdf", "report tax").tier, .wordStart, "word order doesn't matter")
        XCTAssertEqual(match("Downloads Folder", "dnld").tier, .fuzzy)
        XCTAssertEqual(match("Tax Report.pdf", "txrpt").tier, .fuzzy)
        XCTAssertEqual(match("Tax Report.pdf", "xyz").tier, .elsewhere)
        XCTAssertEqual(match("Tax Report.pdf", "aport").tier, .elsewhere, "fuzzy starts at a word")
        XCTAssertEqual(match("Tax Report.pdf", "tax 2024").tier, .elsewhere, "every word, or it's elsewhere")
        XCTAssertEqual(match("Résumé final.pdf", "resume").tier, .prefix, "accents and case fold away")
        XCTAssertEqual(match("Tax-Report_v2.pdf", "taxreport").tier, .prefix, "punctuation is ignored, like the library's search")
    }

    func testTiersSortBestFirst() {
        let tiers: [QuickRank.Tier] = [.fuzzy, .elsewhere, .substring, .wordStart, .prefix, .exact]
        XCTAssertEqual(tiers.sorted(), [.exact, .prefix, .wordStart, .substring, .elsewhere, .fuzzy],
                       "a name that says it beats a folder or text match, and a loose letter match comes last")
    }

    func testMatchedLettersAreMarked() {
        XCTAssertEqual(match("Tax Report.pdf", "rep").ranges, [4..<7])
        XCTAssertEqual(match("Tax Report.pdf", "tax report").ranges, [0..<3, 4..<10])
        XCTAssertEqual(match("Tax Report.pdf", "txrpt").ranges, [0..<1, 2..<3, 4..<5, 6..<7, 9..<10])
        XCTAssertEqual(match("Tax Report.pdf", "tax 2024").ranges, [0..<3], "what the name holds is still marked")
        let segments = QuickRank.segments("Tax Report.pdf", ranges: [4..<7])
        XCTAssertEqual(segments.map(\.text), ["Tax ", "Rep", "ort.pdf"])
        XCTAssertEqual(segments.map(\.matched), [false, true, false])
    }

    func testAccentMarksStayWithTheirLetter() {
        let decomposed = "Re\u{301}sume\u{301}.pdf" // how older Macs store "Résumé"
        let m = match(decomposed, "res")
        XCTAssertEqual(m.tier, .prefix)
        let segments = QuickRank.segments(decomposed, ranges: m.ranges)
        XCTAssertEqual(segments.first?.text, "Re\u{301}s")
        XCTAssertEqual(segments.map(\.text).joined(), decomposed)
    }

    func testCheapPrecheckNeverDropsAMatch() {
        let needles = QuickRank.needles(["report", "tax"])
        XCTAssertTrue(QuickRank.mightMatch("Tax Report.pdf", needles: needles), "word order doesn't matter")
        XCTAssertTrue(QuickRank.mightMatch("Résumé.pdf", needles: QuickRank.needles(["resume"])), "non-ASCII is left to match()")
        XCTAssertFalse(QuickRank.mightMatch("Invoice.pdf", needles: QuickRank.needles(["xyz"])))
    }

    func testUseFadesWithATwoWeekHalfLife() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var f = Frecency()
        f.record("/a", query: "inv", now: now.addingTimeInterval(-Frecency.halfLife))
        f.record("/b", query: "", now: now)
        let boosts = f.boosts(for: "", now: now)
        XCTAssertEqual(boosts["/a"] ?? 0, 0.5, accuracy: 0.001, "opened once, two weeks ago")
        XCTAssertEqual(boosts["/b"] ?? 0, 1, accuracy: 0.001)
        f.record("/b", query: "", now: now)
        XCTAssertEqual(f.boosts(for: "", now: now)["/b"] ?? 0, 2, accuracy: 0.001)
    }

    func testWhatYouPickedForAQueryComesFirstForIt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var f = Frecency()
        for _ in 0..<3 { f.record("/used-a-lot", query: "report", now: now) }
        f.record("/picked-for-invoice", query: "Invoice ", now: now)
        let exact = f.boosts(for: "invoice", now: now)
        XCTAssertGreaterThan(exact["/picked-for-invoice"] ?? 0, 3.5, "1 for use + 3 for this exact query")
        XCTAssertEqual(f.boosts(for: "inv", now: now)["/picked-for-invoice"] ?? 0, 2, accuracy: 0.001, "a query it starts counts once")
        XCTAssertEqual(f.boosts(for: "voice", now: now)["/picked-for-invoice"] ?? 0, 1, accuracy: 0.001, "not one it doesn't")
        f.forget("/picked-for-invoice")
        XCTAssertNil(f.boosts(for: "invoice", now: now)["/picked-for-invoice"])
        XCTAssertTrue(f.queries.isEmpty || f.queries["invoice"] == nil, "an empty query entry goes too")
    }

    func testStoreStaysSmallAndRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var f = Frecency()
        for i in 0..<30 { f.record("/f\(i)", query: "q", now: now.addingTimeInterval(Double(i))) }
        XCTAssertEqual(f.queries["q"]?.count, 10, "ten picks per query")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quicksearch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        f.save(to: url)
        XCTAssertEqual(Frecency.load(from: url), f)
        XCTAssertEqual(Frecency.load(from: url.appendingPathExtension("missing")), Frecency(), "no file, no history")
    }
}

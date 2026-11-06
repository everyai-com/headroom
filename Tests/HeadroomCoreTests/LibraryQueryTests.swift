import XCTest
@testable import HeadroomCore

/// DeveloperToolsSupport has a `LibraryItem` too.
private typealias LibraryItem = HeadroomCore.LibraryItem

/// The library's natural-language search: what it understands, the chips it shows, and what it matches.
/// Every date is worked out from a fixed "now" in a fixed time zone, with weeks starting on Monday.
final class LibraryQueryTests: XCTestCase {
    typealias Context = LibraryQuery.MatchContext

    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt
        c.firstWeekday = 2
        return c
    }()
    let home = "/Users/homy"

    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
    }

    /// Wednesday 14 October 2026, 15:30 in New York.
    var now: Date { date(2026, 10, 14, 15, 30) }
    var context: Context { Context(home: home) }

    func parse(_ s: String, at time: Date? = nil) -> LibraryQuery { LibraryQuery.parse(s, now: time ?? now, calendar: cal) }
    func interval(_ a: Date, _ b: Date) -> DateInterval { DateInterval(start: a, end: b) }
    func labels(_ s: String) -> [String] { parse(s).chips.map(\.label) }

    /// A file in Homy's home (or at an absolute path), created and changed long ago unless told otherwise.
    fileprivate func item(_ rel: String, kind: FileKind? = nil, bytes: Int64 = 1000, created: Date? = nil, modified: Date? = nil,
              added: Date? = nil, whereFrom: [String]? = nil, by agent: String? = nil, screenshot: Bool = false,
              tags: [String] = []) -> LibraryItem {
        let path = rel.hasPrefix("/") ? rel : home + "/" + rel
        let old = date(2020, 1, 1)
        return LibraryItem(path: path, kind: kind ?? FileKind.of(extension: (path as NSString).pathExtension), bytes: bytes,
                           created: created ?? old, modified: modified ?? old, added: added, whereFrom: whereFrom,
                           downloadedBy: agent, isScreenshot: screenshot, tags: tags)
    }

    // MARK: Homy's examples

    func testPDFsFromLastWeekOver5MB() {
        let q = parse("pdfs from last week over 5 mb")
        XCTAssertEqual(q.kinds, [])
        XCTAssertEqual(q.extensions, ["pdf"])
        XCTAssertEqual(q.dateRange, interval(date(2026, 10, 5), date(2026, 10, 12)), "the calendar week before this one, Monday to Monday")
        XCTAssertEqual(q.minBytes, 5_000_000)
        XCTAssertNil(q.maxBytes)
        XCTAssertTrue(q.terms.isEmpty)
        XCTAssertEqual(q.chips.map(\.label), ["PDFs", "Last week", "Over 5 MB"])
        XCTAssertEqual(q.chips.map(\.kind), [.type, .date, .size])
        XCTAssertEqual(q.chips.map(\.removing), ["from last week over 5 mb", "pdfs over 5 mb", "pdfs from last week"])
        XCTAssertEqual(q.chips.map(\.symbol), ["doc.richtext", "calendar", "scalemass"])

        let hit = item("Downloads/Invoice.pdf", bytes: 6_000_000, created: date(2026, 10, 7, 9))
        XCTAssertTrue(q.matches(hit, in: context))
        XCTAssertFalse(q.matches(item("Downloads/Invoice.pdf", bytes: 4_000_000, created: date(2026, 10, 7)), in: context))
        XCTAssertFalse(q.matches(item("Downloads/Invoice.png", bytes: 6_000_000, created: date(2026, 10, 7)), in: context))
        XCTAssertFalse(q.matches(item("Downloads/Invoice.pdf", bytes: 6_000_000, created: date(2026, 10, 12)), in: context),
                       "Monday midnight already belongs to this week")
        XCTAssertTrue(q.matches(item("Downloads/REPORT.PDF", bytes: 6_000_000, created: date(2026, 10, 11, 23)), in: context),
                      "extensions match in any case")
    }

    func testVideosFromMyIPhoneInAugust() {
        let q = parse("videos from my iphone in august")
        XCTAssertEqual(q.kinds, [.video])
        XCTAssertEqual(q.device, "iPhone")
        XCTAssertEqual(q.dateRange, interval(date(2026, 8, 1), date(2026, 9, 1)))
        XCTAssertEqual(q.chips.map(\.label), ["Videos", "From iPhone", "August 2026"])
        XCTAssertEqual(q.chips.map(\.kind), [.type, .device, .date])
        XCTAssertEqual(q.chips[1].removing, "videos in august")
        XCTAssertEqual(q.chips[1].symbol, "iphone")

        let clip = item("Movies/IMG_0042.MOV", created: date(2026, 8, 20))
        XCTAssertTrue(q.matches(clip, in: Context(home: home, devices: [clip.path: "Apple iPhone 15 Pro"])))
        XCTAssertFalse(q.matches(clip, in: context), "no device known for the file: no match")
        XCTAssertFalse(q.matches(clip, in: Context(home: home, devices: [clip.path: "Canon EOS R5"])))
    }

    func testScreenshotsWithWifiPassword() {
        let q = parse("screenshots with wifi password")
        XCTAssertTrue(q.screenshotsOnly)
        XCTAssertEqual(q.terms, ["wifi", "password"])
        XCTAssertEqual(q.chips.map(\.label), ["Screenshots", "“wifi”", "“password”"])
        XCTAssertEqual(q.chips.map(\.kind), [.type, .text, .text])
        XCTAssertEqual(q.chips[1].removing, "screenshots with password")
        XCTAssertEqual(q.chips[2].removing, "screenshots with wifi")
        XCTAssertEqual(parse("screenshots with wifi").chips[1].removing, "screenshots", "a lone word takes its “with” along")

        XCTAssertTrue(q.matches(item("Desktop/Wi-Fi_Password.png", screenshot: true), in: context))
        XCTAssertFalse(q.matches(item("Desktop/Wi-Fi_Password.png"), in: context), "not a screenshot")
        XCTAssertFalse(q.matches(item("Desktop/Wi-Fi.png", screenshot: true), in: context), "every word must match")
        let plain = item("Desktop/Screenshot 2026-10-01 at 10.00.00.png", screenshot: true)
        XCTAssertFalse(q.matches(plain, in: context))
        XCTAssertTrue(q.matches(plain, in: Context(home: home, recognizedText: [plain.path: "Network: Home Wi-Fi\nPassword: hunter2"])),
                      "words can come from the text recognised in the image")
    }

    func testZipsBiggerThan1GBOlderThan6Months() {
        let q = parse("zips bigger than 1gb older than 6 months")
        XCTAssertEqual(q.extensions, ["zip"])
        XCTAssertEqual(q.minBytes, 1_000_000_000)
        XCTAssertEqual(q.olderThan, date(2026, 4, 14, 15, 30))
        XCTAssertNil(q.dateRange)
        XCTAssertEqual(q.chips.map(\.label), ["Zips", "Over 1 GB", "Older than 6 months"])
        XCTAssertEqual(q.chips[2].removing, "zips bigger than 1gb")

        let zip = item("Downloads/backup.zip", bytes: 2_000_000_000, created: date(2026, 1, 3), modified: date(2026, 2, 1))
        XCTAssertTrue(q.matches(zip, in: context))
        XCTAssertFalse(q.matches(item("Downloads/backup.zip", bytes: 2_000_000_000, modified: date(2026, 9, 1)), in: context),
                       "changed recently: not old")
        XCTAssertFalse(q.matches(item("Downloads/backup.zip", bytes: 2_000_000_000, added: date(2026, 9, 1),
                                      whereFrom: ["https://example.com/backup.zip"]), in: context),
                       "downloaded recently: not old")
        XCTAssertTrue(q.matches(item("Downloads/backup.zip", bytes: 2_000_000_000, added: date(2026, 9, 1)), in: context),
                      "only moved into a folder recently: still old")
    }

    func testPDFsFromGmail() {
        let q = parse("pdfs from gmail")
        XCTAssertEqual(q.source?.id, "gmail")
        XCTAssertFalse(q.anyDownload)
        XCTAssertEqual(q.chips.map(\.label), ["PDFs", "From Gmail"])
        XCTAssertEqual(q.chips[1].kind, .source)
        XCTAssertEqual(q.chips[1].symbol, "envelope.fill")
        XCTAssertEqual(q.chips[1].removing, "pdfs")

        let attachment = item("Downloads/statement.pdf", whereFrom: [
            "https://mail-attachment.googleusercontent.com/attachment/u/0/?ui=2&ik=abc&attid=0.1",
            "https://mail.google.com/",
        ])
        XCTAssertTrue(q.matches(attachment, in: context))
        XCTAssertFalse(q.matches(item("Downloads/statement.pdf", whereFrom: ["https://drive.google.com/uc?id=1"]), in: context))
        XCTAssertFalse(q.matches(item("Downloads/statement.pdf"), in: context), "not downloaded")
    }

    // MARK: Basics

    func testEmptyAndFillerOnly() {
        for text in ["", "   ", "show me all my files", "find everything please"] {
            let q = parse(text)
            XCTAssertTrue(q.isEmpty, text)
            XCTAssertTrue(q.chips.isEmpty, text)
            XCTAssertTrue(q.matches(item("Desktop/anything.bin"), in: context), text)
        }
        XCTAssertEqual(parse("Find").raw, "Find")
    }

    func testPlainWord() {
        let q = parse("invoice")
        XCTAssertFalse(q.isEmpty)
        XCTAssertEqual(q.terms, ["invoice"])
        XCTAssertEqual(q.chips.map(\.label), ["“invoice”"])
        XCTAssertEqual(q.chips[0].kind, .text)
        XCTAssertEqual(q.chips[0].symbol, "text.magnifyingglass")
        XCTAssertEqual(q.chips[0].removing, "")

        XCTAssertTrue(q.matches(item("Documents/2024-INVOICE-acme.pdf"), in: context))
        XCTAssertTrue(q.matches(item("Documents/Invoices/scan.pdf"), in: context), "the folder it's in")
        XCTAssertTrue(q.matches(item("Documents/Invoices/2024/scan.pdf"), in: context), "the folder above that")
        XCTAssertFalse(q.matches(item("Documents/Invoices/2024/march/scan.pdf"), in: context), "three folders up is too far")
        XCTAssertFalse(q.matches(item("Documents/receipt.pdf"), in: context))
        XCTAssertFalse(q.matches(item("/Users/invoice/Desktop/x.pdf"), in: Context(home: "/Users/invoice")),
                       "your home folder's own name never matches")
    }

    func testQuotedPhrases() {
        let q = parse("\"wifi password\" screenshots")
        XCTAssertEqual(q.terms, ["wifi password"])
        XCTAssertTrue(q.screenshotsOnly)
        XCTAssertEqual(q.chips.map(\.label), ["“wifi password”", "Screenshots"])
        XCTAssertEqual(q.chips[0].removing, "screenshots")
        XCTAssertEqual(q.chips[1].removing, "\"wifi password\"")
        XCTAssertTrue(q.matches(item("Desktop/Wi-Fi Password.png", screenshot: true), in: context))
        XCTAssertFalse(q.matches(item("Desktop/password for the wifi.png", screenshot: true), in: context),
                       "a phrase keeps its words together and in order")
        XCTAssertTrue(parse("wifi password").matches(item("Desktop/password for the wifi.png"), in: context),
                      "unquoted words can be anywhere")

        let curly = parse("“Tax Return” pdfs from 2024")
        XCTAssertEqual(curly.terms, ["tax return"])
        XCTAssertEqual(curly.extensions, ["pdf"])
        XCTAssertEqual(curly.chips.map(\.label), ["“Tax Return”", "PDFs", "2024"])
        XCTAssertEqual(curly.chips[1].removing, "“Tax Return” from 2024")

        let quotedFilter = parse("\"today\"")
        XCTAssertEqual(quotedFilter.terms, ["today"], "a quoted filter word is just a word")
        XCTAssertNil(quotedFilter.dateRange)
        XCTAssertEqual(parse("pdfs \"tax ret").terms, ["tax ret"], "an unclosed quote runs to the end while typing")
        XCTAssertTrue(parse("\"\"").isEmpty)
    }

    // MARK: Types

    func testTypes() {
        XCTAssertEqual(parse("photos").kinds, [.image])
        XCTAssertEqual(parse("pics").kinds, [.image])
        XCTAssertEqual(parse("movies").kinds, [.video])
        XCTAssertEqual(parse("clips").kinds, [.video])
        XCTAssertEqual(parse("songs").kinds, [.audio])
        XCTAssertEqual(parse("podcasts").kinds, [.audio])
        XCTAssertEqual(parse("voice memos").kinds, [.audio])
        XCTAssertEqual(labels("voice memos"), ["Voice memos"])
        XCTAssertEqual(parse("docs").kinds, [.document])
        XCTAssertEqual(parse("word documents").extensions, ["doc", "docx"])
        XCTAssertEqual(labels("word docs"), ["Word documents"])
        XCTAssertEqual(parse("spreadsheets").extensions, ["xls", "xlsx", "csv", "tsv", "numbers", "ods"])
        XCTAssertEqual(parse("excel").extensions, parse("spreadsheets").extensions)
        XCTAssertEqual(parse("ebooks").extensions, ["epub", "mobi", "azw3"])
        XCTAssertEqual(parse("text files").extensions, ["txt", "md", "rtf"])
        XCTAssertEqual(parse("archives").kinds, [.archive])
        XCTAssertEqual(parse("rars").extensions, ["rar"])
        XCTAssertEqual(parse("tarballs").extensions, ["tar", "gz", "tgz", "bz2", "tbz", "xz", "txz"])
        XCTAssertEqual(parse("apps").kinds, [.app])
        XCTAssertEqual(parse("applications").kinds, [.app])
        XCTAssertEqual(parse("installers").extensions, FileKind.installers)

        let recordings = parse("screen recordings")
        XCTAssertEqual(recordings.kinds, [.video])
        XCTAssertTrue(recordings.screenshotsOnly)
        XCTAssertEqual(recordings.chips.map(\.label), ["Screen recordings"])
        for s in ["screen shots", "screencaps", "screen captures", "screenshot"] {
            XCTAssertTrue(parse(s).screenshotsOnly, s)
            XCTAssertEqual(labels(s), ["Screenshots"], s)
        }
    }

    func testKeynotePresentationsIsOneChip() {
        let q = parse("keynote presentations")
        XCTAssertEqual(q.extensions, ["key", "ppt", "pptx", "odp"])
        XCTAssertEqual(q.chips.map(\.label), ["Presentations"])
        XCTAssertEqual(q.chips[0].removing, "")
        XCTAssertTrue(q.matches(item("Documents/Pitch.key"), in: context))

        let png = parse("png images")
        XCTAssertEqual(png.extensions, ["png"], "the narrower of the two")
        XCTAssertEqual(png.kinds, [])
        XCTAssertEqual(png.chips.map(\.label), ["PNGs"])
        XCTAssertEqual(labels("pdf documents"), ["PDFs"])
    }

    func testDMGs() {
        let q = parse("dmgs")
        XCTAssertEqual(q.extensions, FileKind.installers)
        XCTAssertEqual(q.chips.map(\.label), ["Installers"])
        XCTAssertEqual(q.chips[0].symbol, "shippingbox")
        XCTAssertTrue(q.matches(item("Downloads/Setup.dmg"), in: context))
        XCTAssertTrue(q.matches(item("Downloads/Driver.pkg"), in: context))
        XCTAssertFalse(q.matches(item("Downloads/photos.zip"), in: context))
    }

    func testPDFsAndImages() {
        let q = parse("pdfs and images")
        XCTAssertEqual(q.extensions, ["pdf"])
        XCTAssertEqual(q.kinds, [.image])
        XCTAssertTrue(q.terms.isEmpty)
        XCTAssertEqual(q.chips.map(\.label), ["PDFs", "Images"])
        XCTAssertEqual(q.chips.map(\.removing), ["images", "pdfs"], "the “and” goes with the chip that's removed")
        XCTAssertTrue(q.matches(item("Desktop/a.pdf"), in: context))
        XCTAssertTrue(q.matches(item("Desktop/a.png"), in: context))
        XCTAssertFalse(q.matches(item("Desktop/a.mp4"), in: context))

        let commas = parse("pdfs, images")
        XCTAssertEqual(commas.chips.map(\.removing), ["images", "pdfs"])
        XCTAssertEqual(parse("pdfs,images").chips.map(\.label), ["PDFs", "Images"])
    }

    func testAnyExtensionFileKindKnows() {
        XCTAssertEqual(parse("pngs").extensions, ["png"])
        XCTAssertEqual(parse("movs").extensions, ["mov"])
        XCTAssertEqual(parse("gifs").extensions, ["gif"])
        XCTAssertEqual(parse("heics").extensions, ["heic"])
        XCTAssertEqual(parse("jpgs").extensions, ["jpg", "jpeg"])
        XCTAssertEqual(parse("jpegs").extensions, ["jpg", "jpeg"])
        XCTAssertEqual(labels("jpgs"), ["JPEGs"])
        XCTAssertEqual(labels("mp4s"), ["MP4s"])
        XCTAssertEqual(parse("flac").extensions, ["flac"])
        XCTAssertEqual(parse("3gp").extensions, ["3gp"])
        XCTAssertEqual(parse("7z").extensions, ["7z"])

        // Extensions that are everyday words need a dot or "files".
        XCTAssertEqual(parse("key").terms, ["key"])
        XCTAssertTrue(parse("key").extensions.isEmpty)
        XCTAssertEqual(parse(".key").extensions, ["key"])
        XCTAssertEqual(parse("key files").extensions, ["key"])
        XCTAssertEqual(parse("pages").terms, ["pages"])

        let python = parse("*.py")
        XCTAssertEqual(python.extensions, ["py"])
        XCTAssertEqual(python.chips.map(\.label), [".py files"])
        XCTAssertTrue(python.matches(item("Documents/script.py"), in: context))
        XCTAssertFalse(python.matches(item("Documents/script.pyc"), in: context))
    }

    // MARK: Dates

    func testTodayAndYesterday() {
        let today = parse("today")
        XCTAssertEqual(today.dateRange, interval(date(2026, 10, 14), date(2026, 10, 15)))
        XCTAssertEqual(today.chips.map(\.label), ["Today"])
        XCTAssertEqual(today.chips[0].kind, .date)

        let yesterday = parse("yesterday")
        XCTAssertEqual(yesterday.dateRange, interval(date(2026, 10, 13), date(2026, 10, 14)))
        XCTAssertEqual(yesterday.chips.map(\.label), ["Yesterday"])
    }

    func testDateRangeMatchesCreatedModifiedOrReceived() {
        let q = parse("yesterday")
        let noon = date(2026, 10, 13, 12)
        XCTAssertTrue(q.matches(item("Desktop/a.txt", created: noon), in: context))
        XCTAssertTrue(q.matches(item("Desktop/a.txt", modified: noon), in: context))
        XCTAssertTrue(q.matches(item("Downloads/a.pdf", added: noon, whereFrom: ["https://mail.google.com/"]), in: context), "downloaded yesterday")
        XCTAssertTrue(q.matches(item("Downloads/a.pdf", added: noon, by: "AirDrop"), in: context), "AirDropped yesterday")
        XCTAssertFalse(q.matches(item("Desktop/a.txt", added: noon), in: context), "an old file copied into a folder yesterday isn't from yesterday")
        XCTAssertFalse(q.matches(item("Desktop/a.txt"), in: context))
        XCTAssertFalse(q.matches(item("Desktop/a.txt", created: date(2026, 10, 14)), in: context), "midnight today isn't yesterday")
    }

    func testRollingDays() {
        let q = parse("last 3 days")
        XCTAssertEqual(q.newerThan, date(2026, 10, 11, 15, 30))
        XCTAssertNil(q.dateRange)
        XCTAssertEqual(q.chips.map(\.label), ["Last 3 days"])

        let inThe = parse("pdfs in the last 3 days")
        XCTAssertEqual(inThe.newerThan, date(2026, 10, 11, 15, 30))
        XCTAssertEqual(inThe.chips.map(\.label), ["PDFs", "Last 3 days"])
        XCTAssertEqual(inThe.chips[0].removing, "in the last 3 days")
        XCTAssertEqual(inThe.chips[1].removing, "pdfs")

        XCTAssertEqual(parse("past 7 days").newerThan, date(2026, 10, 7, 15, 30))
        XCTAssertEqual(labels("past 7 days"), ["Past 7 days"])
        XCTAssertEqual(parse("past week").newerThan, date(2026, 10, 7, 15, 30), "past week is rolling, not the calendar week")
        XCTAssertEqual(labels("past week"), ["Past week"])
        XCTAssertEqual(parse("in the last week").newerThan, date(2026, 10, 7, 15, 30))
        XCTAssertEqual(parse("last two weeks").newerThan, date(2026, 9, 30, 15, 30))
        XCTAssertEqual(parse("in the last couple of months").newerThan, date(2026, 8, 14, 15, 30))
        XCTAssertEqual(parse("within 2 hours").newerThan, date(2026, 10, 14, 13, 30))

        let shot = item("Desktop/a.png", modified: date(2026, 10, 12))
        XCTAssertTrue(q.matches(shot, in: context))
        XCTAssertFalse(q.matches(item("Desktop/a.png", modified: date(2026, 10, 11, 15)), in: context))
    }

    func testCalendarMathAcrossDaylightSaving() {
        // Clocks went back an hour on 1 November 2026 in New York.
        let after = date(2026, 11, 2, 12)
        let q = parse("last 3 days", at: after)
        XCTAssertEqual(q.newerThan, date(2026, 10, 30, 12), "the same wall-clock time three days ago")
        XCTAssertEqual(q.newerThan.map { after.timeIntervalSince($0) }, 3 * 86_400 + 3_600)
        let yesterday = parse("yesterday", at: after).dateRange
        XCTAssertEqual(yesterday, interval(date(2026, 11, 1), date(2026, 11, 2)))
        XCTAssertEqual(yesterday?.duration, 25 * 3_600)
    }

    func testCalendarPeriods() {
        XCTAssertEqual(parse("this week").dateRange, interval(date(2026, 10, 12), date(2026, 10, 19)))
        XCTAssertEqual(parse("this month").dateRange, interval(date(2026, 10, 1), date(2026, 11, 1)))
        XCTAssertEqual(parse("last month").dateRange, interval(date(2026, 9, 1), date(2026, 10, 1)))
        XCTAssertEqual(parse("this year").dateRange, interval(date(2026, 1, 1), date(2027, 1, 1)))
        XCTAssertEqual(parse("last year").dateRange, interval(date(2025, 1, 1), date(2026, 1, 1)))
        XCTAssertEqual(labels("last month"), ["Last month"])
        XCTAssertEqual(labels("this week"), ["This week"])

        var sundayStart = cal
        sundayStart.firstWeekday = 1
        let sunday = LibraryQuery.parse("last week", now: now, calendar: sundayStart)
        XCTAssertEqual(sunday.dateRange, interval(date(2026, 10, 4), date(2026, 10, 11)), "weeks follow the calendar's first weekday")
    }

    func testAgo() {
        XCTAssertEqual(parse("3 days ago").dateRange, interval(date(2026, 10, 11), date(2026, 10, 12)))
        XCTAssertEqual(labels("3 days ago"), ["3 days ago"])
        XCTAssertEqual(parse("2 weeks ago").dateRange, interval(date(2026, 9, 28), date(2026, 10, 5)))
        XCTAssertEqual(parse("a month ago").dateRange, interval(date(2026, 9, 1), date(2026, 10, 1)))
        XCTAssertEqual(labels("a month ago"), ["A month ago"])
    }

    func testRecentAndOld() {
        let recent = parse("recent downloads")
        XCTAssertEqual(recent.newerThan, date(2026, 10, 7, 15, 30))
        XCTAssertTrue(recent.anyDownload)
        XCTAssertEqual(recent.chips.map(\.label), ["Recent", "Downloads"])
        XCTAssertEqual(parse("new photos").newerThan, date(2026, 10, 7, 15, 30))

        let old = parse("old pdfs")
        XCTAssertEqual(old.olderThan, date(2025, 10, 14, 15, 30))
        XCTAssertEqual(old.chips.map(\.label), ["Older than a year", "PDFs"])
        XCTAssertEqual(old.chips[0].symbol, "clock.arrow.circlepath")
    }

    func testOlderAndNewerThan() {
        XCTAssertEqual(parse("older than a year").olderThan, date(2025, 10, 14, 15, 30))
        XCTAssertEqual(labels("older than a year"), ["Older than a year"])
        XCTAssertEqual(parse("more than 2 years old").olderThan, date(2024, 10, 14, 15, 30))
        XCTAssertEqual(labels("more than 2 years old"), ["Older than 2 years"])
        XCTAssertEqual(parse("over 3 months old").olderThan, date(2026, 7, 14, 15, 30))
        XCTAssertEqual(parse("6 months old").olderThan, date(2026, 4, 14, 15, 30))
        XCTAssertEqual(parse("older than 6mo").olderThan, date(2026, 4, 14, 15, 30))
        XCTAssertEqual(parse("newer than 3 days").newerThan, date(2026, 10, 11, 15, 30))
        XCTAssertEqual(labels("newer than 3 days"), ["Newer than 3 days"])
        XCTAssertEqual(parse("less than a week old").newerThan, date(2026, 10, 7, 15, 30))
        XCTAssertNil(parse("over 3 months old").minBytes, "an age, not a size")
    }

    func testSinceBeforeAfter() {
        let march = parse("since march")
        XCTAssertEqual(march.newerThan, date(2026, 3, 1))
        XCTAssertEqual(march.chips.map(\.label), ["Since March"])
        XCTAssertEqual(march.chips[0].kind, .date)

        XCTAssertEqual(parse("since december").newerThan, date(2025, 12, 1))
        XCTAssertEqual(labels("since december"), ["Since December 2025"])
        XCTAssertEqual(parse("since 2023").newerThan, date(2023, 1, 1))
        XCTAssertEqual(labels("since 2023"), ["Since 2023"])
        XCTAssertEqual(parse("since last week").newerThan, date(2026, 10, 5))
        XCTAssertEqual(labels("since last week"), ["Since last week"])
        XCTAssertEqual(parse("since yesterday").newerThan, date(2026, 10, 13))

        XCTAssertEqual(parse("before june").olderThan, date(2026, 6, 1))
        XCTAssertEqual(labels("before june"), ["Before June"])
        XCTAssertEqual(parse("before june 2024").olderThan, date(2024, 6, 1))
        XCTAssertEqual(parse("before 2024").olderThan, date(2024, 1, 1))
        XCTAssertEqual(parse("after june").newerThan, date(2026, 7, 1))
        XCTAssertEqual(labels("after june"), ["After June"])
        XCTAssertEqual(parse("after 2023").newerThan, date(2024, 1, 1))
        XCTAssertEqual(parse("until june").olderThan, date(2026, 7, 1), "until includes June itself")
        XCTAssertEqual(labels("until june"), ["Until June"])
    }

    func testDateSpans() {
        let years = parse("photos from 2023 to 2024")
        XCTAssertEqual(years.dateRange, interval(date(2023, 1, 1), date(2025, 1, 1)))
        XCTAssertEqual(years.chips.map(\.label), ["Photos", "2023–2024"])
        XCTAssertEqual(years.chips[0].removing, "from 2023 to 2024")
        XCTAssertEqual(parse("between march and june").dateRange, interval(date(2026, 3, 1), date(2026, 7, 1)))
        XCTAssertEqual(labels("between march and june"), ["March–June"])
        XCTAssertEqual(parse("from november to february").dateRange, interval(date(2025, 11, 1), date(2026, 3, 1)),
                       "each end is its most recent past month")
        XCTAssertEqual(parse("between 1 and 5 gb").maxBytes, 5_000_000_000, "numbers stay sizes")
        XCTAssertNil(parse("between 1 and 5 gb").dateRange)
    }

    func testMonthsResolveToTheMostRecentPastOne() {
        let december = parse("december")
        XCTAssertEqual(december.dateRange, interval(date(2025, 12, 1), date(2026, 1, 1)), "in October, december means last December")
        XCTAssertEqual(december.chips.map(\.label), ["December 2025"])
        XCTAssertEqual(parse("october").dateRange, interval(date(2026, 10, 1), date(2026, 11, 1)), "this month counts")
        XCTAssertEqual(parse("in nov").dateRange, interval(date(2025, 11, 1), date(2025, 12, 1)))
        XCTAssertEqual(parse("during sept").dateRange, interval(date(2026, 9, 1), date(2026, 10, 1)))
        XCTAssertEqual(parse("aug 2024").dateRange, interval(date(2024, 8, 1), date(2024, 9, 1)))
        XCTAssertEqual(labels("from march 2023"), ["March 2023"])
        XCTAssertEqual(parse("last october").dateRange, interval(date(2025, 10, 1), date(2025, 11, 1)))
        XCTAssertEqual(parse("aug 15").dateRange, interval(date(2026, 8, 15), date(2026, 8, 16)))
        XCTAssertEqual(labels("aug 15"), ["August 15, 2026"])
        XCTAssertEqual(parse("in may").dateRange, interval(date(2026, 5, 1), date(2026, 6, 1)))

        let verb = parse("photos i may delete")
        XCTAssertNil(verb.dateRange, "“may” after “I” is the verb")
        XCTAssertEqual(verb.terms, ["delete"])
    }

    func testYearsAndWeekdays() {
        XCTAssertEqual(parse("in 2023").dateRange, interval(date(2023, 1, 1), date(2024, 1, 1)))
        XCTAssertEqual(parse("2023").chips.map(\.label), ["2023"])

        // Wednesday 14 October.
        XCTAssertEqual(parse("monday").dateRange, interval(date(2026, 10, 12), date(2026, 10, 13)))
        XCTAssertEqual(labels("on monday"), ["Monday"])
        XCTAssertEqual(parse("on wednesday").dateRange, interval(date(2026, 10, 14), date(2026, 10, 15)), "today counts")
        XCTAssertEqual(parse("last wednesday").dateRange, interval(date(2026, 10, 7), date(2026, 10, 8)))
        XCTAssertEqual(parse("last friday").dateRange, interval(date(2026, 10, 9), date(2026, 10, 10)))
        XCTAssertEqual(labels("last friday"), ["Last Friday"])
        XCTAssertEqual(parse("on fri").dateRange, interval(date(2026, 10, 9), date(2026, 10, 10)))
        XCTAssertEqual(parse("sun").terms, ["sun"], "a short weekday alone is a word")
        XCTAssertNil(parse("photos of the sun").dateRange)
    }

    // MARK: Sizes

    func testBigVideos() {
        let q = parse("big videos")
        XCTAssertEqual(q.minBytes, 100_000_000)
        XCTAssertEqual(q.kinds, [.video])
        XCTAssertEqual(q.chips.map(\.label), ["Over 100 MB", "Videos"])
        XCTAssertEqual(parse("huge files").minBytes, 1_000_000_000)
        XCTAssertEqual(parse("massive videos").minBytes, 1_000_000_000)
        XCTAssertEqual(parse("tiny images").maxBytes, 1_000_000)
        XCTAssertEqual(labels("small pdfs"), ["Under 1 MB", "PDFs"])
    }

    func testMusicUnder10MB() {
        let q = parse("music under 10mb")
        XCTAssertEqual(q.kinds, [.audio])
        XCTAssertEqual(q.maxBytes, 10_000_000)
        XCTAssertNil(q.folder, "music without “in” is the kind")
        XCTAssertEqual(q.chips.map(\.label), ["Music", "Under 10 MB"])
        XCTAssertTrue(q.matches(item("Music/song.mp3", bytes: 10_000_000), in: context))
        XCTAssertFalse(q.matches(item("Music/song.mp3", bytes: 10_000_001), in: context))
    }

    func testBetween1And5GB() {
        let q = parse("between 1 and 5 gb")
        XCTAssertEqual(q.minBytes, 1_000_000_000)
        XCTAssertEqual(q.maxBytes, 5_000_000_000)
        XCTAssertEqual(q.chips.map(\.label), ["1–5 GB"])
        XCTAssertEqual(q.chips[0].removing, "")
        XCTAssertEqual(labels("between 500mb and 2gb"), ["500 MB–2 GB"])
        XCTAssertEqual(parse("1-5gb").maxBytes, 5_000_000_000)
        XCTAssertEqual(parse("1–5 gb").minBytes, 1_000_000_000)
        XCTAssertEqual(labels("1–5 gb"), ["1–5 GB"])
    }

    func testSizeSpellings() {
        let plus = parse("5gb+ videos")
        XCTAssertEqual(plus.minBytes, 5_000_000_000)
        XCTAssertEqual(plus.kinds, [.video])
        XCTAssertEqual(plus.chips.map(\.label), ["Over 5 GB", "Videos"])

        XCTAssertEqual(parse("5gb videos").minBytes, 5_000_000_000, "a bare size is a minimum")
        XCTAssertEqual(parse("5 gb videos").minBytes, 5_000_000_000)
        XCTAssertEqual(parse("1.5gb").minBytes, 1_500_000_000)
        XCTAssertEqual(labels("over 1.5 gigs"), ["Over 1.5 GB"])
        XCTAssertEqual(parse(">2gb").minBytes, 2_000_000_000)
        XCTAssertEqual(parse("<500kb").maxBytes, 500_000)
        XCTAssertEqual(parse("at least 2 tb").minBytes, 2_000_000_000_000)
        XCTAssertEqual(parse("smaller than 300 k").maxBytes, 300_000)
        XCTAssertEqual(parse("less than 20 megabytes").maxBytes, 20_000_000)
        XCTAssertEqual(parse("over 100").minBytes, 100_000_000, "a number alone after a comparison is MB")
        XCTAssertEqual(parse("under 512 bytes").maxBytes, 512)
        XCTAssertEqual(parse("files >= 500 mb").chips.map(\.removing), ["files"], "a comparison written apart")
        XCTAssertEqual(parse("files >= 500 mb").minBytes, 500_000_000)
        XCTAssertNil(parse("videos over 2 minutes").minBytes, "a length of time is no size")

        let fourK = parse("4k videos")
        XCTAssertNil(fourK.minBytes, "4k is a resolution")
        XCTAssertEqual(fourK.terms, ["4k"])

        let both = parse("big videos over 5 gb")
        XCTAssertEqual(both.minBytes, 5_000_000_000, "every size chip applies")
        XCTAssertEqual(both.chips.map(\.label), ["Over 100 MB", "Videos", "Over 5 GB"])
    }

    // MARK: Sources, devices, folders

    func testSources() {
        let twitter = parse("images from twitter")
        XCTAssertEqual(twitter.source?.id, "x")
        XCTAssertEqual(twitter.chips.map(\.label), ["Images", "From X"])
        XCTAssertTrue(twitter.matches(item("Downloads/meme.jpg", whereFrom: ["https://pbs.twimg.com/media/abc.jpg"]), in: context))

        let gpt = parse("from chatgpt")
        XCTAssertEqual(gpt.source?.id, "chatgpt")
        XCTAssertEqual(gpt.chips.map(\.label), ["From ChatGPT"])
        XCTAssertTrue(gpt.matches(item("Downloads/plot.png", whereFrom: ["https://files.oaiusercontent.com/file-abc"]), in: context))
        XCTAssertTrue(gpt.matches(item("Downloads/plot.png", by: "ChatGPT"), in: context), "the app that saved it")
        XCTAssertFalse(gpt.matches(item("Downloads/plot.png", whereFrom: ["https://example.com/plot.png"]), in: context))

        XCTAssertEqual(parse("via slack").source?.id, "slack")
        XCTAssertEqual(parse("on whatsapp").source?.id, "whatsapp")
        XCTAssertEqual(parse("from google drive").source?.id, "drive")
        XCTAssertEqual(parse("from my gmail account").chips.map(\.removing), [""])
        XCTAssertEqual(parse("from github").source?.id, "github")
        XCTAssertEqual(parse("slack attachments").source?.id, "slack")
        XCTAssertEqual(parse("gmail pdfs").chips.map(\.label), ["From Gmail", "PDFs"])
        XCTAssertNil(parse("x").source, "a lone x is a word")
        XCTAssertEqual(parse("from x").source?.id, "x")

        let site = parse("from example.com")
        XCTAssertEqual(site.source?.id, "site:example.com")
        XCTAssertEqual(site.chips.map(\.label), ["From example.com"])
        XCTAssertTrue(site.matches(item("Downloads/a.zip", whereFrom: ["https://files.example.com/a.zip"]), in: context))
        XCTAssertNil(parse("from notes.pdf").source, "a file name isn't a website")

        let later = parse("from gmail from slack")
        XCTAssertEqual(later.source?.id, "slack", "one source: the last one wins")
        XCTAssertEqual(later.chips.map(\.label), ["From Slack"])
        XCTAssertEqual(later.chips[0].removing, "", "and its chip removes both")
    }

    func testDownloads() {
        let q = parse("downloads")
        XCTAssertTrue(q.anyDownload)
        XCTAssertNil(q.folder)
        XCTAssertEqual(q.chips.map(\.label), ["Downloads"])
        XCTAssertEqual(q.chips[0].kind, .source)
        XCTAssertTrue(q.matches(item("Desktop/a.zip", whereFrom: ["https://example.com/a.zip"]), in: context))
        XCTAssertTrue(q.matches(item("Desktop/a.zip", by: "AirDrop"), in: context))
        XCTAssertFalse(q.matches(item("Downloads/a.zip"), in: context), "in the Downloads folder but nothing says it was downloaded")

        XCTAssertTrue(parse("pdfs from the web").anyDownload)
        XCTAssertEqual(labels("pdfs from the internet"), ["PDFs", "Downloads"])
        XCTAssertEqual(labels("web downloads"), ["Downloads"])
        XCTAssertEqual(parse("downloaded yesterday").chips.map(\.label), ["Downloads", "Yesterday"])

        let fromSlack = parse("downloaded from slack")
        XCTAssertEqual(fromSlack.source?.id, "slack")
        XCTAssertEqual(fromSlack.chips.map(\.label), ["From Slack"], "the source says it was downloaded")
        XCTAssertEqual(fromSlack.chips[0].removing, "")

        XCTAssertEqual(parse("from downloads").folder, .downloads, "from downloads is the folder")
        XCTAssertFalse(parse("from downloads").anyDownload)
    }

    func testDevices() {
        let canon = parse("photos from my canon")
        XCTAssertEqual(canon.device, "Canon")
        XCTAssertEqual(canon.chips.map(\.label), ["Photos", "From Canon"])
        XCTAssertEqual(canon.chips[1].symbol, "camera")
        let photo = item("Pictures/IMG_1.CR3", kind: .image)
        XCTAssertTrue(canon.matches(photo, in: Context(home: home, devices: [photo.path: "Canon EOS R5"])))
        XCTAssertFalse(canon.matches(photo, in: Context(home: home, devices: [photo.path: "Apple iPhone 15 Pro"])))

        let camera = parse("from a camera")
        XCTAssertEqual(camera.device, "Camera")
        XCTAssertTrue(camera.matches(photo, in: Context(home: home, devices: [photo.path: "FUJIFILM X-T4"])))
        XCTAssertFalse(camera.matches(photo, in: Context(home: home, devices: [photo.path: "Apple iPhone 15 Pro"])),
                       "a phone isn't a camera")

        XCTAssertEqual(parse("from my phone").device, "iPhone")
        XCTAssertEqual(parse("on the ipad").device, "iPad")
        XCTAssertEqual(parse("from my fuji").device, "Fujifilm")
        XCTAssertEqual(parse("taken with my gopro").device, "GoPro")
        let android = parse("from my android")
        XCTAssertTrue(android.matches(photo, in: Context(home: home, devices: [photo.path: "Google Pixel 8"])))

        let bare = parse("iphone videos")
        XCTAssertEqual(bare.device, "iPhone")
        XCTAssertEqual(bare.kinds, [.video])
        XCTAssertEqual(bare.chips.map(\.label), ["From iPhone", "Videos"])

        let words = parse("screenshots with iphone settings")
        XCTAssertNil(words.device, "“with iphone” reads as words to find")
        XCTAssertEqual(words.terms, ["iphone", "settings"])

        var custom = parse("photos")
        custom.device = "EOS R5"
        XCTAssertTrue(custom.matches(photo, in: Context(home: home, devices: [photo.path: "Canon EOS R5"])),
                      "a device set by hand matches by name")
    }

    func testDocumentsInDownloads() {
        let q = parse("documents in downloads")
        XCTAssertEqual(q.kinds, [.document])
        XCTAssertEqual(q.folder, .downloads)
        XCTAssertFalse(q.anyDownload, "in downloads is the folder")
        XCTAssertEqual(q.chips.map(\.label), ["Documents", "In Downloads"])
        XCTAssertEqual(q.chips[1].kind, .folder)
        XCTAssertEqual(q.chips[1].removing, "documents")

        XCTAssertTrue(q.matches(item("Downloads/report.docx"), in: context))
        XCTAssertTrue(q.matches(item("Downloads/2026/report.docx"), in: context), "subfolders count")
        XCTAssertFalse(q.matches(item("Documents/report.docx"), in: context))
        XCTAssertFalse(q.matches(item("Downloadsx/report.docx"), in: context))
        XCTAssertFalse(q.matches(item("/Users/other/Downloads/report.docx"), in: context))
        XCTAssertTrue(q.matches(item("Downloads/report.docx"), in: Context(home: home + "/")), "home with a trailing slash")
    }

    func testFolders() {
        XCTAssertEqual(parse("on my desktop").folder, .desktop)
        XCTAssertEqual(parse("in documents").folder, .documents)
        XCTAssertEqual(parse("in my pictures folder").folder, .pictures)
        XCTAssertEqual(parse("in music").folder, .music)
        XCTAssertEqual(parse("in music").kinds, [], "in music is the folder")
        let named = parse("pdfs in the downloads folder")
        XCTAssertEqual(named.folder, .downloads)
        XCTAssertEqual(named.chips.map(\.removing), ["in the downloads folder", "pdfs"])
        XCTAssertEqual(parse("downloads folder").folder, .downloads, "a folder named without “in”")
        XCTAssertFalse(parse("downloads folder").anyDownload)
        XCTAssertEqual(labels("pdfs in my icloud drive folder"), ["PDFs", "In iCloud Drive"])

        let iCloud = parse("in icloud")
        XCTAssertEqual(LibraryQuery.Folder.icloud.path(home: home), home + "/Library/Mobile Documents/com~apple~CloudDocs")
        XCTAssertEqual(LibraryQuery.Folder.desktop.path(home: home + "/"), home + "/Desktop")
        XCTAssertTrue(iCloud.matches(item("Library/Mobile Documents/com~apple~CloudDocs/Taxes/2024.pdf"), in: context))
        XCTAssertFalse(iCloud.matches(item("Documents/2024.pdf"), in: context))
        XCTAssertEqual(LibraryQuery.Folder.allCases.map(\.title),
                       ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "iCloud Drive"])

        let later = parse("in desktop in documents")
        XCTAssertEqual(later.folder, .documents)
        XCTAssertEqual(later.chips.count, 1)
    }

    // MARK: Words

    func testWordsAfterIntroducers() {
        let about = parse("documents about music")
        XCTAssertEqual(about.kinds, [.document])
        XCTAssertEqual(about.terms, ["music"], "after “about”, a type word is a word to find")
        XCTAssertEqual(about.chips.map(\.label), ["Documents", "“music”"])
        XCTAssertEqual(about.chips[1].removing, "documents")

        let named = parse("pdfs named tax return from last year")
        XCTAssertEqual(named.terms, ["tax", "return"])
        XCTAssertEqual(named.dateRange, interval(date(2025, 1, 1), date(2026, 1, 1)), "a filter ends the words")
        XCTAssertEqual(named.chips.map(\.label), ["PDFs", "“tax”", "“return”", "Last year"])

        XCTAssertEqual(parse("files that say hello world").terms, ["hello", "world"])
        XCTAssertEqual(parse("photos containing the new logo").terms, ["new", "logo"], "“new” is a word here, not “recent”")
        XCTAssertEqual(parse("photos tagged vacation").terms, ["vacation"])
        XCTAssertTrue(parse("pdfs with").terms.isEmpty, "nothing after “with” yet")
    }

    func testStillTyping() {
        for text in ["pdfs from", "pdfs over", "pdfs older than", "pdfs older than 6", "pdfs bigger than", "pdfs in the"] {
            let q = parse(text)
            XCTAssertTrue(q.terms.isEmpty, text)
            XCTAssertEqual(q.extensions, ["pdf"], text)
        }
        XCTAssertNil(parse("pdfs older than 6").olderThan, "the unit isn't typed yet")
        XCTAssertEqual(parse("pdfs over 5").minBytes, 5_000_000)
    }

    func testTermsMatchNamesFoldersTagsTextAndContent() {
        let q = parse("budget")
        XCTAssertTrue(q.matches(item("Documents/2026 Budget.numbers"), in: context), "name")
        XCTAssertTrue(q.matches(item("Documents/Budget/q1.numbers"), in: context), "parent folder")
        XCTAssertTrue(q.matches(item("Documents/scan.pdf", tags: ["Budget"]), in: context), "tag")
        let scan = item("Documents/scan.pdf")
        XCTAssertFalse(q.matches(scan, in: context))
        XCTAssertTrue(q.matches(scan, in: Context(home: home, recognizedText: [scan.path: "Household BUDGET 2026"])),
                      "recognised text")
        XCTAssertTrue(q.matches(scan, in: Context(home: home, contentHits: [scan.path])), "Spotlight found it inside")

        let two = parse("budget 2026q")
        XCTAssertTrue(two.matches(item("Documents/budget.pdf", tags: ["2026Q1"]), in: context), "each word can match somewhere else")
        XCTAssertTrue(two.matches(scan, in: Context(home: home, contentHits: [scan.path])), "a content hit matches outright")
    }

    func testTermsIgnoreCaseAccentsAndSeparators() {
        let wifi = parse("wifi")
        XCTAssertTrue(wifi.matches(item("Desktop/Wi-Fi_Password.png"), in: context))
        XCTAssertTrue(wifi.matches(item("Desktop/WIFI.png"), in: context))
        XCTAssertTrue(wifi.matches(item("Desktop/HomeWiFiSetup.png"), in: context))
        XCTAssertTrue(wifi.matches(item("Desktop/wi fi.png"), in: context))
        XCTAssertFalse(wifi.matches(item("Desktop/show if it works.png"), in: context),
                       "skipping separators only from the start of a word")

        XCTAssertTrue(parse("cafe").matches(item("Documents/Café Menu.pdf"), in: context))
        XCTAssertTrue(parse("Résumé").matches(item("Documents/resume-2026.pdf"), in: context))
        XCTAssertEqual(parse("Résumé").terms, ["resume"])
        XCTAssertTrue(parse("münchen").matches(item("Pictures/München/IMG_1.jpg"), in: context))
        XCTAssertTrue(parse("東京").matches(item("Pictures/東京タワー.jpg"), in: context))
        XCTAssertTrue(parse("tax-return").matches(item("Documents/Tax Return 2024.pdf"), in: context))
        XCTAssertFalse(parse("taxreturns").matches(item("Documents/Tax Return 2024.pdf"), in: context))
    }

    // MARK: Chips and the struct itself

    func testChipsComeInTypedOrderWithUniqueIDs() {
        let q = parse("over 5 mb pdfs from gmail last week invoice")
        XCTAssertEqual(q.chips.map(\.label), ["Over 5 MB", "PDFs", "From Gmail", "Last week", "“invoice”"])
        XCTAssertEqual(Set(q.chips.map(\.id)).count, q.chips.count)
        XCTAssertEqual(q.chips[2].removing, "over 5 mb pdfs last week invoice")
        // Removing a chip and parsing again leaves the other chips.
        for chip in q.chips {
            let again = parse(chip.removing)
            XCTAssertEqual(again.chips.map(\.label), q.chips.filter { $0.id != chip.id }.map(\.label), chip.label)
        }
    }

    func testChangingFieldsKeepsMatchingInStep() {
        var q = parse("pdfs")
        q.terms = ["invoice"]
        XCTAssertTrue(q.matches(item("Documents/invoice.pdf"), in: context))
        XCTAssertFalse(q.matches(item("Documents/receipt.pdf"), in: context))
        q.terms = []
        XCTAssertTrue(q.matches(item("Documents/receipt.pdf"), in: context))
        q.device = nil
        XCTAssertTrue(q.matches(item("Documents/receipt.pdf"), in: context))
        XCTAssertEqual(parse("pdfs from gmail"), parse("pdfs from gmail"), "parsing is deterministic")
    }

    func testMatchingFiftyThousandFilesIsQuick() {
        let q = parse("screenshots with wifi password from last week")
        let old = date(2020, 1, 1), lastWeek = date(2026, 10, 7)
        let items = (0..<50_000).map { k in
            LibraryItem(path: home + "/Desktop/Folder \(k % 50)/Screenshot \(k) Wi-Fi \(k % 7 == 0 ? "Password" : "notes").png",
                        kind: .image, bytes: 1000, created: old, modified: lastWeek, isScreenshot: k % 2 == 0)
        }
        let ctx = context
        let start = Date()
        let hits = items.filter { q.matches($0, in: ctx) }.count
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(hits, (0..<50_000).filter { $0 % 2 == 0 && $0 % 7 == 0 }.count)
        // About 0.02 s in a release build and 0.15 s in a debug one; the bound leaves room for a busy machine.
        XCTAssertLessThan(elapsed, 1.5, "runs on every keystroke")
    }

    func testOddInputNeverTraps() {
        let odd = ["-", "--", ".", "*", "*.", ">", "<", ",,,", "\"", "“”", "a\"b", "from from from", "between and", "between 5 and",
                   "last 0 days", "last 9999 years", "0 bytes", "feb 30", "feb 29 2024", "1.2.3gb", "..5mb", "🐶 photos",
                   "x\ty\nz", "\u{0}x", "99999999999999999999 tb"]
        for q in odd {
            let p = parse(q)
            _ = p.matches(item("Desktop/a.png"), in: context)
            for chip in p.chips { _ = parse(chip.removing) }
        }
        XCTAssertEqual(parse("99999999999999999999 tb").terms, ["99999999999999999999", "tb"], "no size that big: just words")
        XCTAssertEqual(parse("feb 29 2024").dateRange, interval(date(2024, 2, 29), date(2024, 3, 1)))

        // Word salad from the vocabulary, the same every run: never traps, ids stay unique, every removal parses.
        let vocab = ["pdfs", "from", "last", "week", "over", "5", "mb", "in", "downloads", "my", "iphone", "with", "\"wifi", "and",
                     "images", "between", "1", "gb", "since", "march", "older", "than", "6", "months", "the", ",", "named", "x",
                     "today", "big", "on", "monday", "via", "slack", "screenshots", "2023", "ago", "a", "couple", "of", "days",
                     ">5gb", "to", "“tax", "return”"]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        let file = item("Downloads/wifi.pdf", bytes: 6_000_000, created: now)
        for _ in 0..<500 {
            let q = (0...next(8)).map { _ in vocab[next(vocab.count)] }.joined(separator: " ")
            let p = parse(q)
            _ = p.matches(file, in: context)
            XCTAssertEqual(Set(p.chips.map(\.id)).count, p.chips.count, q)
            for chip in p.chips { _ = parse(chip.removing) }
        }
    }
}

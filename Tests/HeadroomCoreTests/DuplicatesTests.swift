import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import HeadroomCore

/// HeadroomCore's, not DeveloperToolsSupport's (which PDFKit pulls in).
private typealias LibraryItem = HeadroomCore.LibraryItem

/// Duplicate files and look-alike photos, each test in its own throwaway "home".
final class DuplicatesTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("headroom-dupes-\(UUID().uuidString)").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: home) }

    @discardableResult
    func write(_ rel: String, _ data: Data) throws -> URL {
        let url = home.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Bytes that differ from any other seed's.
    func content(_ seed: UInt8, count: Int) -> Data {
        let block = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &* 7) ^ seed })
        var data = Data(capacity: count)
        while data.count < count { data.append(block.prefix(count - data.count)) }
        return data
    }

    private func item(_ url: URL, created: Date? = nil) throws -> LibraryItem {
        let v = try url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey])
        return LibraryItem(path: url.path, kind: FileKind.of(extension: url.pathExtension), bytes: Int64(v.fileSize ?? 0),
                           allocated: Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0),
                           created: created ?? v.creationDate ?? .now, modified: v.contentModificationDate ?? .now)
    }

    private func items(_ urls: [URL]) throws -> [LibraryItem] { try urls.map { try item($0) } }

    private func fake(_ path: String, bytes: Int64 = 1000, created: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> LibraryItem {
        LibraryItem(path: path, kind: FileKind.of(extension: (path as NSString).pathExtension), bytes: bytes, created: created,
                    modified: created)
    }

    // MARK: - Identical

    func testIdenticalFilesAreFoundAcrossFolders() async throws {
        let data = content(1, count: 300_000)
        let a = try write("Documents/report.pdf", data)
        let b = try write("Pictures/old/report.pdf", data)
        let c = try write("Desktop/report final.pdf", data)
        let other = try write("Documents/other.pdf", content(2, count: 300_000))
        let small = content(3, count: 5_000) // small enough that the cheap pass reads it whole
        let s1 = try write("Documents/notes.txt", small)
        let s2 = try write("Documents/archive/notes.txt", small)

        let groups = await Duplicates.identical(in: try items([a, b, c, other, s1, s2]))
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups[0].items.map(\.path)), [a.path, b.path, c.path], "biggest waste first")
        XCTAssertEqual(groups[0].kind, .identical)
        XCTAssertEqual(Set(groups[1].items.map(\.path)), [s1.path, s2.path])
        XCTAssertFalse(groups.contains { $0.items.contains { $0.path == other.path } })
    }

    func testSameSizeDifferentContentIsNotADuplicate() async throws {
        let a = try write("Documents/a.bin", content(1, count: 4_096))
        let b = try write("Documents/b.bin", content(2, count: 4_096))
        let big1 = try write("Documents/c.bin", content(3, count: 500_000))
        let big2 = try write("Documents/d.bin", content(4, count: 500_000))
        let groups = await Duplicates.identical(in: try items([a, b, big1, big2]))
        XCTAssertTrue(groups.isEmpty)
    }

    func testSameEdgesButDifferentMiddleIsNotADuplicate() async throws {
        var data = content(5, count: 400_000) // > 2 × 64 KB, so the cheap pass can't tell
        let a = try write("Documents/a.mov", data)
        data[200_000] ^= 0xFF
        let b = try write("Documents/b.mov", data)
        let groups = await Duplicates.identical(in: try items([a, b]))
        XCTAssertTrue(groups.isEmpty, "the full hash tells them apart")

        let c = try write("Documents/c.mov", data)
        let found = await Duplicates.identical(in: try items([a, b, c]))
        XCTAssertEqual(found.map { Set($0.items.map(\.path)) }, [[b.path, c.path]])
    }

    func testHardLinksAreNotDuplicates() async throws {
        let a = try write("Pictures/a.jpg", content(6, count: 200_000))
        let link = home.appendingPathComponent("Documents/a-link.jpg")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.linkItem(at: a, to: link)
        let none = await Duplicates.identical(in: try items([a, link]))
        XCTAssertTrue(none.isEmpty, "deleting a hard link frees nothing")

        // A real copy next to them is a duplicate — of the file, listed once.
        let copy = try write("Downloads/a.jpg", content(6, count: 200_000))
        let groups = await Duplicates.identical(in: try items([a, link, copy]))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.count, 2)
        XCTAssertTrue(groups[0].items.contains { $0.path == copy.path })
    }

    func testEmptyFilesAppsAndFoldersAreIgnored() async throws {
        let e1 = try write("Documents/empty1.txt", Data())
        let e2 = try write("Documents/empty2.txt", Data())
        let empty = await Duplicates.identical(in: try items([e1, e2]))
        XCTAssertTrue(empty.isEmpty, "empty files free nothing")
        let emptyToo = await Duplicates.identical(in: try items([e1, e2]), minBytes: 0)
        XCTAssertTrue(emptyToo.isEmpty, "even when asked")

        let d1 = try write("Documents/A.key/Index.zip", content(7, count: 2_000)).deletingLastPathComponent()
        let d2 = try write("Documents/B.key/Index.zip", content(7, count: 2_000)).deletingLastPathComponent()
        let packages = [fake(d1.path, bytes: 2_000), fake(d2.path, bytes: 2_000)]
        let folders = await Duplicates.identical(in: packages)
        XCTAssertTrue(folders.isEmpty, "packages are folders, not files")

        let x1 = try write("Applications/X.app", content(8, count: 2_000))
        let x2 = try write("Downloads/X.app", content(8, count: 2_000))
        let apps = try items([x1, x2])
        XCTAssertEqual(apps.map(\.kind), [.app, .app])
        let appGroups = await Duplicates.identical(in: apps)
        XCTAssertTrue(appGroups.isEmpty, "apps are uninstalled whole, never deduplicated")

        let small1 = try write("Documents/s1.bin", content(9, count: 100))
        let small2 = try write("Documents/s2.bin", content(9, count: 100))
        let under = await Duplicates.identical(in: try items([small1, small2]), minBytes: 101)
        XCTAssertTrue(under.isEmpty)
        let at = await Duplicates.identical(in: try items([small1, small2]), minBytes: 100)
        XCTAssertEqual(at.count, 1)
    }

    func testMissingFilesAreSkipped() async throws {
        let data = content(10, count: 10_000)
        let a = try write("Documents/a.pdf", data)
        let b = try write("Documents/b.pdf", data)
        let gone = try item(try write("Documents/c.pdf", data))
        try fm.removeItem(atPath: gone.path)
        let groups = await Duplicates.identical(in: try items([a, b]) + [gone])
        XCTAssertEqual(groups.map { Set($0.items.map(\.path)) }, [[a.path, b.path]])
    }

    func testTheOriginalIsKeptOverDownloadsAndCopies() async throws {
        let data = content(11, count: 150_000)
        let original = try write("Pictures/photo.jpg", data)
        let downloaded = try write("Downloads/photo.jpg", data)
        let copy = try write("Pictures/photo copy.jpg", data)
        let browser = try write("Pictures/photo (1).jpg", data)
        let groups = await Duplicates.identical(in: try items([downloaded, copy, browser, original]))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].keep, original.path)
        XCTAssertEqual(groups[0].items.first?.path, original.path)
        XCTAssertEqual(groups[0].items.count, 4)
    }

    func testRanking() {
        let base = "/Users/me"
        func order(_ paths: [String], _ kind: DuplicateGroup.Kind = .identical) -> [String] {
            Duplicates.ranked(paths.map { fake($0) }, kind: kind).map(\.path)
        }
        XCTAssertEqual(order(["\(base)/Downloads/a.pdf", "\(base)/Documents/a.pdf"]).first, "\(base)/Documents/a.pdf")
        XCTAssertEqual(order(["\(base)/Desktop/a.pdf", "\(base)/Documents/deep/er/a.pdf"]).first, "\(base)/Documents/deep/er/a.pdf",
                       "Desktop loses even to a deeper folder")
        XCTAssertEqual(order(["\(base)/.Trash/a.pdf", "\(base)/Downloads/a.pdf"]).first, "\(base)/Downloads/a.pdf")
        XCTAssertEqual(order(["\(base)/Documents/Copy of a.pdf", "\(base)/Documents/a - Copy.pdf", "\(base)/Documents/a copy 2.pdf",
                              "\(base)/Documents/a(3).pdf", "\(base)/Documents/a.pdf"]).first, "\(base)/Documents/a.pdf")
        XCTAssertEqual(order(["\(base)/Documents/a 2.pdf", "\(base)/Documents/a.pdf"]).first, "\(base)/Documents/a.pdf")
        XCTAssertEqual(order(["\(base)/Documents/a-1.pdf", "\(base)/Documents/a.pdf"]).first, "\(base)/Documents/a.pdf")
        // A trailing number alone is a name, not a copy marker.
        XCTAssertEqual(order(["\(base)/Documents/Chapter 2 copy.pdf", "\(base)/Documents/Chapter 2.pdf"]).first,
                       "\(base)/Documents/Chapter 2.pdf")
        XCTAssertEqual(order(["\(base)/Documents/x/y/a.pdf", "\(base)/Documents/z/a.pdf"]).first, "\(base)/Documents/z/a.pdf",
                       "shallowest next")

        // Then the oldest, then the path — always the same answer.
        let old = fake("\(base)/Documents/b/a.pdf", created: Date(timeIntervalSince1970: 1_000))
        let new = fake("\(base)/Documents/a/a.pdf", created: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(Duplicates.ranked([new, old], kind: .identical).map(\.path), [old.path, new.path])
        XCTAssertEqual(order(["\(base)/Documents/b/a.pdf", "\(base)/Documents/a/a.pdf"]), ["\(base)/Documents/a/a.pdf", "\(base)/Documents/b/a.pdf"])
        XCTAssertEqual(order(["\(base)/Documents/a/a.pdf", "\(base)/Documents/b/a.pdf"]), ["\(base)/Documents/a/a.pdf", "\(base)/Documents/b/a.pdf"])

        // Look-alikes: the camera original over its same-size conversion, bigger files over smaller.
        let heic = LibraryItem(path: "\(base)/Pictures/IMG_1.HEIC", kind: .image, bytes: 2_000_000, created: .now, modified: .now)
        let jpeg = LibraryItem(path: "\(base)/Pictures/IMG_1.JPG", kind: .image, bytes: 4_000_000, created: .now, modified: .now)
        XCTAssertEqual(Duplicates.ranked([jpeg, heic], kind: .lookAlike, pixels: [heic.path: 12_000_000, jpeg.path: 12_000_000]).first?.path,
                       heic.path)
        XCTAssertEqual(Duplicates.ranked([heic, jpeg], kind: .lookAlike, pixels: [heic.path: 3_000_000, jpeg.path: 12_000_000]).first?.path,
                       jpeg.path, "but never a smaller picture")
        let sharp = LibraryItem(path: "\(base)/Pictures/b.jpg", kind: .image, bytes: 3_000_000, created: .now, modified: .now)
        let soft = LibraryItem(path: "\(base)/Pictures/a.jpg", kind: .image, bytes: 2_500_000, created: .now, modified: .now)
        XCTAssertEqual(Duplicates.ranked([soft, sharp], kind: .lookAlike, pixels: [:]).first?.path, sharp.path)
        let bigInDownloads = LibraryItem(path: "\(base)/Downloads/c.jpg", kind: .image, bytes: 9_000_000, created: .now, modified: .now)
        XCTAssertEqual(Duplicates.ranked([bigInDownloads, soft], kind: .lookAlike, pixels: [bigInDownloads.path: 20_000_000, soft.path: 4_000_000])
            .first?.path, bigInDownloads.path, "full resolution wins over a tidier folder")
        XCTAssertEqual(Duplicates.ranked([bigInDownloads, soft], kind: .lookAlike, pixels: [bigInDownloads.path: 4_000_000, soft.path: 4_000_000])
            .first?.path, soft.path, "same picture: the one outside Downloads")
    }

    func testWastedIsWhatTrashingTheOthersFrees() async throws {
        let items = [fake("/Users/me/Pictures/a.jpg", bytes: 1_000), fake("/Users/me/Downloads/a.jpg", bytes: 3_000),
                     fake("/Users/me/Desktop/a.jpg", bytes: 5_000)]
        let group = DuplicateGroup(kind: .identical, items: items)
        XCTAssertEqual(group.keep, "/Users/me/Pictures/a.jpg")
        XCTAssertEqual(group.wasted, 8_000)
        XCTAssertEqual(group.wasted(keeping: "/Users/me/Pictures/a.jpg"), 8_000)
        XCTAssertEqual(group.wasted(keeping: "/Users/me/Desktop/a.jpg"), 4_000)
        XCTAssertEqual(group.wasted(keeping: "/elsewhere"), 9_000, "keeping nothing frees everything")
        XCTAssertEqual(group.id, DuplicateGroup(kind: .identical, items: items.reversed()).id, "the id doesn't depend on order")
        XCTAssertNotEqual(group.id, DuplicateGroup(kind: .lookAlike, items: items).id)

        // From real files: the allocated sizes of every copy but the keeper.
        let data = content(12, count: 100_000)
        let real = try [write("Documents/x.bin", data), write("Downloads/x.bin", data), write("Desktop/x.bin", data)]
        let groups = await Duplicates.identical(in: try self.items(real))
        let found = try XCTUnwrap(groups.first)
        XCTAssertEqual(found.keep, real[0].path)
        XCTAssertEqual(found.wasted, found.items.dropFirst().reduce(0) { $0 + $1.allocated })
        XCTAssertGreaterThanOrEqual(found.wasted, 200_000)
    }

    func testCancellationReturnsPromptly() async throws {
        var urls: [URL] = []
        for i in 0..<40 {
            let data = content(UInt8(i % 20), count: 300_000)
            urls.append(try write("Documents/f\(i).bin", data))
        }
        let all = try items(urls)
        let start = Date()
        let none = await Duplicates.identical(in: all, isCancelled: { true })
        XCTAssertTrue(none.isEmpty)
        let noLookAlikes = await Duplicates.lookAlikes(in: all, isCancelled: { true })
        XCTAssertTrue(noLookAlikes.isEmpty)

        // Cancelled part-way: as soon as the first progress arrives.
        let flag = Flag()
        let partial = await Duplicates.identical(in: all, isCancelled: { flag.value }, progress: { _ in flag.value = true })
        XCTAssertTrue(partial.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)

        let complete = await Duplicates.identical(in: all)
        XCTAssertEqual(complete.count, 20, "and without cancelling, every pair is found")
    }

    func testProgressEndsAtOne() async throws {
        let data = content(13, count: 200_000)
        let urls = try [write("a/x.bin", data), write("b/x.bin", data)]
        let seen = Values()
        _ = await Duplicates.identical(in: try items(urls), progress: { seen.append($0) })
        XCTAssertEqual(seen.all.last, 1)
        XCTAssertEqual(seen.all, seen.all.sorted(), "never goes backwards")
    }

    // MARK: - Look-alikes

    func testSameNameHEICAndJPEGPairUp() async throws {
        let picture = scene(width: 800, height: 600, variant: 0)
        let heic = home.appendingPathComponent("Pictures/IMG_0001.HEIC")
        let jpeg = home.appendingPathComponent("Pictures/IMG_0001.JPG")
        try save(picture, to: heic, type: canEncodeHEIC ? Self.heic : Self.jpeg)
        try save(picture, to: jpeg, type: Self.jpeg, quality: 0.95)
        let alone = home.appendingPathComponent("Pictures/IMG_0002.JPG")
        try save(scene(width: 800, height: 600, variant: 1), to: alone, type: Self.jpeg)
        let elsewhere = home.appendingPathComponent("Documents/IMG_0001.PNG")
        try save(picture, to: elsewhere, type: Self.png)

        // A day apart, so only the names can pair them.
        let day: TimeInterval = 86_400
        let all = [try item(heic, created: Date(timeIntervalSince1970: 1_700_000_000)),
                   try item(jpeg, created: Date(timeIntervalSince1970: 1_700_000_000 + day)),
                   try item(alone, created: Date(timeIntervalSince1970: 1_700_000_000 + 2 * day)),
                   try item(elsewhere, created: Date(timeIntervalSince1970: 1_700_000_000 + 3 * day))]
        let groups = await Duplicates.lookAlikes(in: all)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.kind, .lookAlike)
        XCTAssertEqual(Set(group.items.map(\.path)), [heic.path, jpeg.path], "same folder only")
        XCTAssertEqual(group.keep, heic.path, "the camera original stays")

        // Already shown as exact duplicates: left out.
        let excluded = await Duplicates.lookAlikes(in: all, excluding: [jpeg.path])
        XCTAssertTrue(excluded.isEmpty)
    }

    func testLookAlikesWithVision() async throws {
        try XCTSkipUnless(Self.visionWorks, "Vision feature prints aren't available in this test runner")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let original = home.appendingPathComponent("Pictures/burst/IMG_0100.jpg")
        let burst = home.appendingPathComponent("Pictures/burst/IMG_0101.jpg")
        let edit = home.appendingPathComponent("Pictures/burst/IMG_0100 edited.png")
        let different = home.appendingPathComponent("Pictures/burst/IMG_0102.jpg")
        let later = home.appendingPathComponent("Pictures/burst/IMG_0900.jpg")
        let base = scene(width: 1200, height: 900, variant: 0)
        try save(base, to: original, type: Self.jpeg, quality: 0.9)
        try save(scene(width: 1200, height: 900, variant: 0, shift: 14), to: burst, type: Self.jpeg, quality: 0.8)
        try save(try XCTUnwrap(base.cropping(to: CGRect(x: 40, y: 30, width: 1120, height: 840))), to: edit, type: Self.png)
        try save(scene(width: 1200, height: 900, variant: 1), to: different, type: Self.jpeg, quality: 0.9)
        try save(base, to: later, type: Self.jpeg, quality: 0.6) // the same picture, but a day later: not a neighbour

        let all = [try item(original, created: t0), try item(burst, created: t0 + 2), try item(edit, created: t0 + 60),
                   try item(different, created: t0 + 5), try item(later, created: t0 + 86_400)]
        let groups = await Duplicates.lookAlikes(in: all)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(Set(group.items.map(\.path)), [original.path, burst.path, edit.path])
        XCTAssertEqual(group.keep, original.path, "full size and a plain name")
        XCTAssertFalse(group.items.contains { $0.path == different.path }, "a different picture taken at the same moment stays apart")
        XCTAssertEqual(group.wasted, group.items.dropFirst().reduce(0) { $0 + $1.allocated })

        // A wider window reaches the copy made a day later.
        let wide = await Duplicates.lookAlikes(in: all, window: 2 * 86_400)
        XCTAssertEqual(wide.first.map { Set($0.items.map(\.path)) }, [original.path, burst.path, edit.path, later.path])

        // Same name, clearly different pictures (two cameras both at IMG_0100): not paired.
        let otherCamera = home.appendingPathComponent("Pictures/burst/IMG_0100.HEIC")
        try save(scene(width: 1200, height: 900, variant: 1), to: otherCamera, type: canEncodeHEIC ? Self.heic : Self.jpeg)
        let mixed = [try item(original, created: t0), try item(otherCamera, created: t0 + 86_400 * 30)]
        let twoCameras = await Duplicates.lookAlikes(in: mixed)
        XCTAssertTrue(twoCameras.isEmpty)
    }

    func testLookAlikeLimitsAndKinds() async throws {
        let picture = scene(width: 400, height: 300, variant: 0)
        let a = home.appendingPathComponent("Pictures/a.HEIC")
        let b = home.appendingPathComponent("Pictures/a.JPG")
        try save(picture, to: a, type: canEncodeHEIC ? Self.heic : Self.jpeg)
        try save(picture, to: b, type: Self.jpeg)
        var notImage = try item(b)
        notImage.kind = .document
        let documents = await Duplicates.lookAlikes(in: [try item(a), notImage])
        XCTAssertTrue(documents.isEmpty, "images only")
        let limited = await Duplicates.lookAlikes(in: [try item(a), try item(b)], limit: 1)
        XCTAssertTrue(limited.isEmpty, "at most `limit` images")
        var huge = try item(b)
        huge.bytes = 61 * 1024 * 1024
        let tooBig = await Duplicates.lookAlikes(in: [try item(a), huge])
        XCTAssertTrue(tooBig.isEmpty, "skips images over 60 MB")
        let pair = await Duplicates.lookAlikes(in: [try item(a), try item(b)])
        XCTAssertEqual(pair.count, 1)
    }

    func testExifDates() {
        let date = Duplicates.exifDate("2024:05:01 13:45:10")
        let c = date.map { Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) }
        XCTAssertEqual(c?.year, 2024)
        XCTAssertEqual(c?.hour, 13)
        XCTAssertEqual(c?.second, 10)
        XCTAssertNil(Duplicates.exifDate("0000:00:00 00:00:00"))
        XCTAssertNil(Duplicates.exifDate("garbage"))
    }

    // MARK: - Images

    /// A picture: a gradient with shapes. `variant` changes everything; `shift` nudges the shapes like the next burst frame.
    func scene(width: Int, height: Int, variant: Int, shift: CGFloat = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        if variant == 0 {
            let colors = [CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1), CGColor(red: 0.95, green: 0.7, blue: 0.3, alpha: 1)]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: h), options: [])
            ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h * 0.3)) // a field
            ctx.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.6, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w * 0.7 + shift, y: h * 0.65, width: w * 0.15, height: w * 0.15)) // a sun
            ctx.setFillColor(CGColor(red: 0.45, green: 0.25, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: w * 0.2 + shift, y: h * 0.3, width: w * 0.25, height: h * 0.25)) // a house
            ctx.setFillColor(CGColor(red: 0.7, green: 0.1, blue: 0.1, alpha: 1))
            ctx.move(to: CGPoint(x: w * 0.17 + shift, y: h * 0.55))
            ctx.addLine(to: CGPoint(x: w * 0.325 + shift, y: h * 0.72))
            ctx.addLine(to: CGPoint(x: w * 0.48 + shift, y: h * 0.55))
            ctx.fillPath() // its roof
        } else {
            // Something else entirely: a dark checkerboard with bright stripes.
            ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.08, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let cell = w / 12
            for row in 0..<Int(h / cell) + 1 {
                for col in 0..<12 where (row + col) % 2 == 0 {
                    ctx.setFillColor(CGColor(red: 0.9, green: 0.1 * CGFloat(row % 3), blue: 0.6, alpha: 1))
                    ctx.fill(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            ctx.setStrokeColor(CGColor(red: 0.2, green: 1, blue: 0.9, alpha: 1))
            ctx.setLineWidth(9)
            for i in 0..<8 {
                ctx.move(to: CGPoint(x: CGFloat(i) * w / 8, y: 0))
                ctx.addLine(to: CGPoint(x: CGFloat(i) * w / 8 + w / 3, y: h))
            }
            ctx.strokePath()
        }
        return ctx.makeImage()!
    }

    func save(_ image: CGImage, to url: URL, type: String, quality: Double = 0.85) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "writing \(url.lastPathComponent)")
    }

    static let heic = "public.heic", jpeg = "public.jpeg", png = "public.png"

    var canEncodeHEIC: Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(Self.heic)
    }

    /// Whether Vision can make feature prints here (it can't in some sandboxes and VMs without a GPU).
    static let visionWorks: Bool = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-vision-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, png as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return false }
        return Duplicates.FeaturePrint(path: url.path) != nil
    }()

/// A flag the hashing tasks can read while a progress callback sets it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

final class Values: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
    var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}
}

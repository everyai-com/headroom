import SwiftUI
import AppKit
import AVFoundation
import HeadroomCore

/// Made-up files for screenshots and the demo reel (`Headroom --seed-library <home>`, run by
/// scripts/demo-seed.sh): photos, screenshots with text in them, PDFs, songs, videos and zips,
/// with "downloaded from" notes — so the camera never shows anyone's real files.
@MainActor
enum DemoLibrary {
    static func seed(home: URL) {
        let fm = FileManager.default
        for dir in ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"] {
            try? fm.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let now = Date()
        func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

        // Photos: little landscapes, a burst pair and an exact copy in Downloads.
        let palettes: [(UInt32, UInt32, UInt32)] = [(0xFF9A8B, 0xFF6A88, 0x4B3F72), (0x7AD7F0, 0x3A7BD5, 0x1E3C72), (0xFDE68A, 0xF59E0B, 0x7C2D12),
                                                    (0xA7F3D0, 0x10B981, 0x064E3B), (0xC4B5FD, 0x8B5CF6, 0x312E81), (0xFBCFE8, 0xEC4899, 0x831843),
                                                    (0xBAE6FD, 0x0EA5E9, 0x0C4A6E), (0xFED7AA, 0xFB923C, 0x7C2D12), (0xD9F99D, 0x84CC16, 0x365314)]
        var photos: [URL] = []
        for (i, p) in palettes.enumerated() {
            let url = home.appendingPathComponent("Pictures/IMG_\(4012 + i * 7).jpg")
            write(image(landscape(p, seed: i)), to: url, type: .jpeg)
            stamp(url, days(Double(2 + i * 9)))
            photos.append(url)
        }
        // A burst: the same scene, nudged.
        let burst = home.appendingPathComponent("Pictures/IMG_4013.jpg")
        write(image(landscape(palettes[0], seed: 0, shift: 6)), to: burst, type: .jpeg)
        stamp(burst, days(2))
        let copy = home.appendingPathComponent("Downloads/IMG_4019 copy.jpg")
        try? fm.copyItem(at: photos[1], to: copy)
        stamp(copy, days(4))
        from(copy, ["https://web.whatsapp.com/"], agent: "WhatsApp")

        // Screenshots with words worth finding.
        let shots: [(String, [String], Double)] = [
            ("Wi-Fi", ["Network  Studio-Guest", "Password  sunflower-42", "Security  WPA3 Personal"], 1),
            ("Order shipped", ["Your order #84721 is on its way", "Tracking number 1Z999AA10123456784", "Arrives Thursday"], 6),
            ("Flight", ["BLR → SFO  ·  Gate 14", "Boarding 21:35", "Seat 32A"], 18),
            ("Quote", ["Ambition without action", "becomes anxiety."], 44),
            ("Standup", ["Ship the onboarding flow", "Fix the export bug", "Review pricing page"], 70),
        ]
        for (i, s) in shots.enumerated() {
            let date = days(s.2)
            let stampText = date.formatted(.iso8601.year().month().day())
            let url = home.appendingPathComponent("Desktop/Screenshot \(stampText) at 10.\(12 + i).33.png")
            write(image(screenshot(title: s.0, lines: s.1, accent: palettes[i].1)), to: url, type: .png)
            stamp(url, date)
        }

        // Documents, downloaded from somewhere.
        let docs: [(String, String, [String], Double, [String], String?)] = [
            ("Documents/Q3 Board Deck.pdf", "Q3 Board Deck", ["Revenue up 38% quarter on quarter", "Three launches shipped", "Hiring plan for Q4"], 5,
             ["https://drive.usercontent.google.com/download?id=demo", "https://drive.google.com/"], nil),
            ("Downloads/Invoice-2026-0912.pdf", "Invoice 2026-0912", ["Design retainer — September", "Total due  ₹48,000", "Due in 14 days"], 9,
             ["https://mail-attachment.googleusercontent.com/attachment/demo", "https://mail.google.com/"], nil),
            ("Downloads/Lease agreement.pdf", "Lease Agreement", ["12-month term starting November", "Deposit: two months", "Signed by both parties"], 120,
             ["https://mail-attachment.googleusercontent.com/attachment/lease", "https://mail.google.com/"], nil),
            ("Documents/Thesis draft v4.pdf", "Thesis draft v4", ["Chapter 3: Methods", "Chapter 4: Results", "Appendix"], 30,
             ["https://files.oaiusercontent.com/file-demo", "https://chatgpt.com/"], nil),
            ("Downloads/Brand guidelines.pdf", "Brand Guidelines", ["Logo clear space", "Colour palette", "Type scale"], 160,
             ["https://export-download.canva.com/demo", "https://www.canva.com/"], nil),
            ("Documents/Tax summary 2025.pdf", "Tax Summary 2025", ["Income", "Deductions", "Refund"], 200, [], nil),
        ]
        for d in docs {
            let url = home.appendingPathComponent(d.0)
            pdf(title: d.1, lines: d.2, to: url)
            stamp(url, days(d.3))
            if !d.4.isEmpty { from(url, d.4, agent: d.5) }
        }
        try? "Passport\nChargers\nSunscreen\nCamera\n".write(to: home.appendingPathComponent("Documents/Packing list.md"), atomically: true, encoding: .utf8)
        stamp(home.appendingPathComponent("Documents/Packing list.md"), days(3))

        // Music: short tones (real, playable WAV files).
        for (i, name) in ["Morning Run", "Deep Focus", "Late Night Drive", "Sunday Coffee", "Rain on Glass"].enumerated() {
            let url = home.appendingPathComponent("Music/\(name).wav")
            wav(frequency: 220 * pow(1.26, Double(i)), seconds: 6, to: url)
            stamp(url, days(Double(10 + i * 20)))
        }

        // Videos: a few seconds each, so Quick Look and thumbnails have frames.
        for (i, name) in ["Beach day", "Product demo", "Birthday"].enumerated() {
            let url = home.appendingPathComponent("Movies/\(name).mov")
            video(landscape(palettes[i + 3], seed: i + 3), to: url)
            stamp(url, days(Double(8 + i * 90)))
        }

        // Archives and an installer.
        let zip = home.appendingPathComponent("Downloads/design-assets.zip")
        _ = Shell.run("/usr/bin/zip", ["-jq", zip.path, photos[2].path, photos[3].path])
        stamp(zip, days(100))
        from(zip, ["https://files.slack.com/files-pri/demo/download/design-assets.zip", "https://app.slack.com/"], agent: "Slack")
        let export = home.appendingPathComponent("Downloads/Photos export.zip")
        _ = Shell.run("/usr/bin/zip", ["-jq", export.path, photos[4].path, photos[5].path, photos[6].path])
        stamp(export, days(40))
        from(export, ["https://github.com/demo/photos/archive/main.zip", "https://github.com/demo/photos"], agent: "Safari")
        print("demo library in \(home.path)")
    }

    // MARK: Drawing

    static func landscape(_ p: (UInt32, UInt32, UInt32), seed: Int, shift: CGFloat = 0) -> some View {
        ZStack {
            LinearGradient(colors: [Color(hex: p.0), Color(hex: p.1)], startPoint: .top, endPoint: .bottom)
            Circle().fill(Color.white.opacity(0.85)).frame(width: 120, height: 120)
                .offset(x: CGFloat(seed % 3 - 1) * 180 + shift, y: -110)
            Mountains(seed: seed).fill(Color(hex: p.2).opacity(0.75)).offset(x: shift)
            Mountains(seed: seed + 7).fill(Color(hex: p.2)).offset(x: shift * 1.5, y: 70)
        }
        .frame(width: 800, height: 600)
    }

    struct Mountains: Shape {
        var seed: Int
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            let peaks = 5 + seed % 3
            for i in 0...peaks {
                let x = r.minX + r.width * CGFloat(i) / CGFloat(peaks)
                let h = r.height * (0.32 + 0.18 * CGFloat((i * 37 + seed * 11) % 7) / 7)
                p.addLine(to: CGPoint(x: x, y: r.maxY - h))
            }
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }

    static func screenshot(title: String, lines: [String], accent: UInt32) -> some View {
        ZStack {
            Color(hex: 0xEEF0F4)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 14, height: 14) }
                    Spacer()
                }
                Text(title).font(.system(size: 40, weight: .bold)).foregroundStyle(Color(hex: 0x111318))
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.system(size: 30, weight: .medium)).foregroundStyle(Color(hex: 0x30343C))
                }
                RoundedRectangle(cornerRadius: 10).fill(Color(hex: accent)).frame(width: 220, height: 52)
                    .overlay(Text("Done").font(.system(size: 24, weight: .semibold)).foregroundStyle(.white))
            }
            .padding(40)
            .background(RoundedRectangle(cornerRadius: 22).fill(.white).shadow(color: .black.opacity(0.12), radius: 20, y: 8))
            .padding(60)
        }
        .frame(width: 1280, height: 800)
    }

    static func image<V: View>(_ view: V) -> CGImage? {
        let r = ImageRenderer(content: view.environment(\.colorScheme, .light))
        r.scale = 1
        return r.cgImage
    }

    static func write(_ image: CGImage?, to url: URL, type: NSBitmapImageRep.FileType) {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: type, properties: [.compressionFactor: 0.85]) else { return }
        try? data.write(to: url)
    }

    static func pdf(title: String, lines: [String], to url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for page in 0..<2 {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSColor(hex: 0x3A7BD5).setFill()
            NSRect(x: 54, y: 700, width: 120, height: 8).fill()
            let heading = page == 0 ? title : "\(title) — notes"
            NSAttributedString(string: heading, attributes: [.font: NSFont.boldSystemFont(ofSize: 26)]).draw(at: NSPoint(x: 54, y: 650))
            for (i, line) in lines.enumerated() {
                NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray])
                    .draw(at: NSPoint(x: 54, y: 600 - CGFloat(i) * 26))
            }
            NSColor(white: 0.9, alpha: 1).setFill()
            for i in 0..<8 { NSRect(x: 54, y: 460 - CGFloat(i) * 22, width: CGFloat(440 - (i * 37) % 160), height: 9).fill() }
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    static func wav(frequency: Double, seconds: Double, to url: URL) {
        let rate = 22_050, count = Int(Double(rate) * seconds)
        var samples = Data(capacity: count * 2)
        for n in 0..<count {
            let t = Double(n) / Double(rate)
            let fade = min(1, t * 4, (seconds - t) * 4)
            let v = Int16(sin(2 * .pi * frequency * t) * 9000 * fade)
            withUnsafeBytes(of: v.littleEndian) { samples.append(contentsOf: $0) }
        }
        var header = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + samples.count).littleEndian)
        header.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian); put(UInt16(1).littleEndian)
        put(UInt16(1).littleEndian); put(UInt32(rate).littleEndian); put(UInt32(rate * 2).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        header.append(contentsOf: Array("data".utf8)); put(UInt32(samples.count).littleEndian)
        try? (header + samples).write(to: url)
    }

    /// A few seconds of a slowly panning picture.
    static func video<V: View>(_ view: V, to url: URL) {
        guard let frame = image(view) else { return }
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let size = CGSize(width: 640, height: 360)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<48 {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32ARGB, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                let pan = CGFloat(i) * 2
                ctx.draw(frame, in: CGRect(x: -pan, y: -60, width: 800, height: 600))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 16))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }

    // MARK: Attributes

    static func stamp(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    /// The "where from" note Safari and Chrome leave on a download.
    static func from(_ url: URL, _ urls: [String], agent: String?) {
        if let data = try? PropertyListSerialization.data(fromPropertyList: urls, format: .binary, options: 0) {
            _ = data.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, data.count, 0, 0) }
        }
        if let agent {
            let value = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));\(agent);"
            _ = value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        }
    }
}

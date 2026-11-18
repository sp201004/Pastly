import AppKit
import AVFoundation
import SwiftUI

/// Renders the real Pastly views with demo data to PNGs for the website.
/// Usage: Pastly --render-screenshots <output-dir>
/// Uses a throwaway store in a temp folder; your own history is never read or shown.
enum Screenshots {
    static func run(outputDir: String) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let out = URL(fileURLWithPath: outputDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PastlyShots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = ClipStore(directory: tmp.appendingPathComponent("store"))
        let demo = DemoData.populate(store, filesDir: tmp.appendingPathComponent("files"))

        var ok = true
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let looks = NSAppearance(named: appearance)!

            let listState = PanelState(store: store)
            listState.select(store.items.first?.id)
            ok = render(PanelView(state: listState, store: store, prefs: .shared).frame(width: 470, height: 560),
                        size: NSSize(width: 470, height: 560), appearance: looks,
                        to: out.appendingPathComponent("list-\(suffix).png")) && ok

            let paletteClip = store.items.first { $0.plainText?.hasPrefix("Poster colors") == true }!
            for (name, item) in [("code", demo.code), ("image", demo.image), ("color", demo.color), ("palette", paletteClip)] {
                let st = PanelState(store: store)
                st.select(item.id)
                let view = HStack(spacing: 10) {
                    PreviewPane(item: item, store: store, isCode: store.isCode(item))
                        .frame(width: 400, height: 560)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    PanelView(state: st, store: store, prefs: .shared)
                        .frame(width: 470, height: 560)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                ok = render(view, size: NSSize(width: 880, height: 560), appearance: looks, transparent: true,
                            to: out.appendingPathComponent("preview-\(name)-\(suffix).png")) && ok
            }

            let multi = PanelState(store: store)
            multi.select(store.items[0].id)
            multi.extendSelection(to: store.items[2].id)
            ok = render(PanelView(state: multi, store: store, prefs: .shared).frame(width: 470, height: 560),
                        size: NSSize(width: 470, height: 560), appearance: looks,
                        to: out.appendingPathComponent("multi-\(suffix).png")) && ok

            let search = PanelState(store: store)
            search.query = "#F9"
            ok = render(PanelView(state: search, store: store, prefs: .shared).frame(width: 470, height: 560),
                        size: NSSize(width: 470, height: 560), appearance: looks,
                        to: out.appendingPathComponent("search-\(suffix).png")) && ok

            let smart = PanelState(store: store)
            if let l = store.smartLists.first(where: { $0.name.hasPrefix("From") }) { smart.collection = .smart(l.id) }
            ok = render(PanelView(state: smart, store: store, prefs: .shared).frame(width: 470, height: 560),
                        size: NSSize(width: 470, height: 560), appearance: looks,
                        to: out.appendingPathComponent("smart-\(suffix).png")) && ok

        }
        // Drag cards for every kind of clip (what follows the cursor while dragging).
        let files = tmp.appendingPathComponent("cardfiles")
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let video = files.appendingPathComponent("Launch teaser.mp4"), song = files.appendingPathComponent("Focus loop.m4a")
        _ = DemoData.makeVideo(at: video); _ = DemoData.makeAudio(at: song)
        let jpg = files.appendingPathComponent("Poster.jpg")
        if let d = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil),
           let cg = NSBitmapImageRep(data: DemoData.makeArtwork(width: 800, height: 450))?.cgImage { CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d) }
        let pdf = files.appendingPathComponent("Brand guidelines.pdf")
        let pdfData = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        if let c = CGDataConsumer(data: pdfData), let ctx = CGContext(consumer: c, mediaBox: &box, nil) { ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF() }
        pdfData.write(to: pdf, atomically: true)
        func fileClip(_ u: URL) -> ClipItem {
            store.ingest(ClipItemParser.parse(RawClip(types: [], fileURLs: [u]), trimWhitespace: false)!, bundleID: "com.apple.finder", appName: "Finder")
        }
        var vThumb: NSImage?
        MediaSupport.thumbnail(for: video, pixels: 120) { vThumb = $0 }
        let until = Date().addingTimeInterval(6)
        while vThumb == nil && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let long = store.ingest(ClipItemParser.parseText(String(repeating: "This is a long paragraph copied from a document, with many words so the card has to wrap and truncate cleanly. ", count: 6),
                                                         rtf: nil, html: nil, trimWhitespace: false), bundleID: "com.apple.TextEdit", appName: "TextEdit")
        let cards: [(String, ClipItem, Int)] = [
            ("text", store.items.first { $0.plainText?.hasPrefix("Release notes") == true }!, 1), ("longtext", long, 1),
            ("code", demo.code, 1), ("url", store.items.first { $0.type == .url }!, 1), ("color", demo.color, 1),
            ("image", demo.image, 1), ("jpgfile", fileClip(jpg), 1), ("video", fileClip(video), 1),
            ("music", fileClip(song), 1), ("pdf", fileClip(pdf), 1), ("multi", demo.code, 3),
        ]
        for (name, clip, count) in cards {
            if let img = MainActor.assumeIsolated({ DragCardView.render(clip, store: store, width: 454, count: count, scale: 2) }),
               let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let pngData = rep.representation(using: .png, properties: [:]) {
                try? pngData.write(to: out.appendingPathComponent("dragcard-\(name).png"))
                print("  ✓ dragcard-\(name).png  \(rep.pixelsWide)×\(rep.pixelsHigh)")
            } else { ok = false; print("  ✗ dragcard-\(name)") }
        }
        print(ok ? "Screenshots written to \(out.path)" : "Some screenshots failed")
        return ok
    }

    /// Developer check: renders the Settings window (General tab, scrolled to top) to a PNG.
    static func renderSettings(to path: String) -> Bool {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let base = URL(fileURLWithPath: path).deletingPathExtension().path
        var ok = true
        // Real width; `--tall` renders the full scroll height to inspect every row for clipping.
        let size = NSSize(width: SettingsWindowController.contentSize.width,
                          height: CommandLine.arguments.contains("--tall") ? 2600 : SettingsWindowController.contentSize.height)
        for tab in SettingsTab.allCases {
            ok = render(SettingsWindowController.content(for: tab).frame(width: size.width, height: size.height),
                        size: size, appearance: NSAppearance(named: .aqua)!,
                        to: URL(fileURLWithPath: "\(base)-\(tab.title.lowercased()).png")) && ok
        }
        // The whole panel exactly as it appears (tab bar + content), once per section.
        for tab in SettingsTab.allCases {
            let router = SettingsRouter()
            router.tab = tab
            ok = render(SettingsView(router: router), size: SettingsWindowController.contentSize,
                        appearance: NSAppearance(named: .aqua)!,
                        to: URL(fileURLWithPath: "\(base)-panel-\(tab.title.lowercased()).png")) && ok
        }
        // Lists tab detail with a Smart List open, at the real detail width (panel minus sidebar).
        let demo = SmartList(name: "From Terminal", rules: [SmartRule(field: .app, op: .is, value: "com.apple.Terminal"),
                                                         SmartRule(field: .text, op: .notContains, value: "TODO")])
        ok = render(SmartListEditor(list: demo, store: ClipStore(directory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("PastlySettingsRender-\(UUID().uuidString)")))
                        .frame(width: SettingsWindowController.contentSize.width - 221, height: SettingsWindowController.contentSize.height),
                    size: NSSize(width: SettingsWindowController.contentSize.width - 221, height: SettingsWindowController.contentSize.height),
                    appearance: NSAppearance(named: .aqua)!, to: URL(fileURLWithPath: "\(base)-smartlist.png")) && ok
        return ok
    }

    @discardableResult
    private static func render<V: View>(_ view: V, size: NSSize, appearance: NSAppearance, transparent: Bool = false,
                                        to url: URL) -> Bool {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        let root = view
            .background(transparent ? Color.clear : Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))   // let SwiftUI lay out and load images
        host.layoutSubtreeIfNeeded()
        host.display()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url) } catch { return false }
        print("  ✓ \(url.lastPathComponent)  \(rep.pixelsWide)×\(rep.pixelsHigh)")
        return true
    }
}

/// Original demo content used only for screenshots.
enum DemoData {
    struct Result { let code: ClipItem; let image: ClipItem; let color: ClipItem }

    static func populate(_ store: ClipStore, filesDir: URL) -> Result {
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        let now = Date()
        func add(_ p: ParsedClip, _ app: String, _ name: String, minutesAgo: Double, pinned: Bool = false) -> ClipItem {
            var item = store.ingest(p, bundleID: app, appName: name, date: now.addingTimeInterval(-minutesAgo * 60))
            if pinned { store.togglePin(item.id); item.isPinned = true }
            return item
        }
        func text(_ s: String) -> ParsedClip { ClipItemParser.parseText(s, rtf: nil, html: nil, trimWhitespace: false) }

        // Original demo content (oldest first so the newest ends up on top).
        _ = add(text("© 2026 Pastly contributors — released under the MIT License"), "com.apple.TextEdit", "TextEdit",
                minutesAgo: 420, pinned: true)
        _ = add(text("Pasta night: 400 g spaghetti, 3 garlic cloves, chili flakes, lemon zest, parmesan"),
                "com.apple.Notes", "Notes", minutesAgo: 260)
        let guide = filesDir.appendingPathComponent("Brand guidelines.pdf")
        FileManager.default.createFile(atPath: guide.path, contents: Data("demo".utf8))
        _ = add(ParsedClip(type: .file, primaryUTI: "public.file-url", fileURLs: [guide],
                           contentHash: ContentHasher.fileHash([guide])), "com.apple.finder", "Finder", minutesAgo: 150)
        let orange = add(text("#F97316"), "com.apple.Safari", "Safari", minutesAgo: 95)
        _ = add(text("https://www.swift.org/getting-started/"), "com.apple.Safari", "Safari", minutesAgo: 70)
        let image = add(ClipItemParser.parseImage(makeArtwork(), isPNG: true)!, "com.apple.Preview", "Preview", minutesAgo: 48)
        let code = add(text("""
        extension Array where Element: Hashable {
            /// Removes duplicates, keeping the first occurrence.
            func uniqued() -> [Element] {
                var seen = Set<Element>()
                return filter { seen.insert($0).inserted }
            }
        }
        """), "com.apple.dt.Xcode", "Xcode", minutesAgo: 31)
        _ = add(text("git commit -m \"Show the whole clip while dragging\""), "com.apple.Terminal", "Terminal", minutesAgo: 22)
        _ = add(text("#22C55E"), "com.apple.Safari", "Safari", minutesAgo: 15)
        _ = add(text("Poster colors: sunrise #F97316, meadow #22C55E, sky #0EA5E9, night #1E293B"),
                "com.apple.Notes", "Notes", minutesAgo: 9)
        _ = add(text("Book club pick for March: The Left Hand of Darkness"), "com.apple.MobileSMS", "Messages", minutesAgo: 4)
        _ = add(text("Release notes draft: drag cards now show the whole clip, and Finder images get real thumbnails."),
                "com.apple.Notes", "Notes", minutesAgo: 1)

        store.createSmartList(name: "From Terminal", symbol: "terminal", rules: [SmartRule(field: .app, op: .is, value: "com.apple.Terminal")])
        let list = store.createList(name: "Snippets")
        store.add(code.id, toList: list.id)
        let teal = orange
        return Result(code: store.item(id: code.id)!, image: store.item(id: image.id)!, color: store.item(id: teal.id)!)
    }

    /// A short H.264 test video (moving color bars), written with AVAssetWriter.
    static func makeVideo(at url: URL, seconds: Double = 1.5, width: Int = 320, height: Int = 180) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let fps = 15, frames = Int(seconds * Double(fps))
        for f in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let buffer = pb else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                ctx.setFillColor(CGColor(srgbRed: 0.36, green: 0.36, blue: 0.94, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.72, blue: 0.65, alpha: 1))
                ctx.fill(CGRect(x: (f * 12) % width, y: 0, width: 60, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }

    /// A short AAC music file (a soft tone).
    static func makeAudio(at url: URL, seconds: Double = 2) -> Bool {
        try? FileManager.default.removeItem(at: url)
        let rate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                       AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)) else { return false }
        buffer.frameLength = buffer.frameCapacity
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(buffer.frameLength) { data[i] = 0.2 * sinf(Float(i) * 2 * .pi * 440 / Float(rate)) }
        return (try? file.write(from: buffer)) != nil
    }

    /// Original artwork for demo image clips: a mountain lake at sunrise with a pine forest,
    /// drawn in code (no photo files). Deterministic, so screenshots and tests are repeatable.
    static func makeArtwork(width: Int = 1600, height: Int = 900) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
            CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locs)!
        }
        let horizon = h * 0.36                         // lake line (CG origin is bottom-left)

        // Sky: soft blue to a warm sunrise at the horizon.
        ctx.drawLinearGradient(gradient([c(0x8EC5E8), c(0xC9E3F0), c(0xFBE2BE)], [0, 0.55, 1]),
                               start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: horizon), options: [.drawsAfterEndLocation])
        // Sun and its glow.
        let sun = CGPoint(x: w * 0.6, y: horizon + h * 0.31)   // rising in the dip between peaks
        ctx.drawRadialGradient(gradient([c(0xFFF1CF, 0.95), c(0xFFD99A, 0.45), c(0xFFD99A, 0)], [0, 0.35, 1]),
                               startCenter: sun, startRadius: 0, endCenter: sun, endRadius: h * 0.42, options: [])
        ctx.setFillColor(c(0xFFF4D8)); ctx.fillEllipse(in: CGRect(x: sun.x - h * 0.065, y: sun.y - h * 0.065, width: h * 0.13, height: h * 0.13))

        /// A mountain ridge through (x, height) points, filled down to the horizon.
        @discardableResult func ridge(_ pts: [(CGFloat, CGFloat)], _ color: CGColor) -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: horizon))
            for (x, y) in pts { path.addLine(to: CGPoint(x: w * x, y: horizon + h * y)) }
            path.addLine(to: CGPoint(x: w, y: horizon)); path.closeSubpath()
            ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
            return path
        }
        let far: [(CGFloat, CGFloat)] = [(0, 0.2), (0.1, 0.3), (0.2, 0.24), (0.32, 0.42), (0.42, 0.3), (0.52, 0.36),
                                         (0.6, 0.27), (0.74, 0.45), (0.86, 0.3), (0.94, 0.34), (1, 0.26)]
        let mid: [(CGFloat, CGFloat)] = [(0, 0.12), (0.12, 0.22), (0.24, 0.13), (0.36, 0.26), (0.47, 0.15), (0.58, 0.21),
                                         (0.7, 0.12), (0.82, 0.24), (0.92, 0.14), (1, 0.18)]
        ridge(far, c(0xA8C4D9))
        // Snow on the two highest peaks.
        ctx.setFillColor(c(0xF4F8FB))
        for (px, py) in [(0.32, 0.42), (0.74, 0.45)] as [(CGFloat, CGFloat)] {
            let top = CGPoint(x: w * px, y: horizon + h * py)
            ctx.move(to: top)
            ctx.addLine(to: CGPoint(x: top.x - w * 0.035, y: top.y - h * 0.07))
            ctx.addLine(to: CGPoint(x: top.x - w * 0.012, y: top.y - h * 0.055))
            ctx.addLine(to: CGPoint(x: top.x + w * 0.004, y: top.y - h * 0.075))
            ctx.addLine(to: CGPoint(x: top.x + w * 0.03, y: top.y - h * 0.06))
            ctx.closePath(); ctx.fillPath()
        }
        // Haze between the ranges.
        ctx.drawLinearGradient(gradient([c(0xFFFFFF, 0), c(0xF3F1E6, 0.55)], [0, 1]),
                               start: CGPoint(x: 0, y: horizon + h * 0.3), end: CGPoint(x: 0, y: horizon), options: [])
        ridge(mid, c(0x6F9C8B))

        // Pine forest along the shore (deterministic sizes).
        var seed: UInt32 = 7
        func rnd() -> CGFloat { seed = seed &* 1_103_515_245 &+ 12_345; return CGFloat(seed >> 16 & 0x7FFF) / 32767 }
        func pine(_ x: CGFloat, _ base: CGFloat, _ height: CGFloat, _ color: CGColor) {
            let half = height * 0.24
            ctx.setFillColor(color)
            for tier in 0..<3 {                         // three stacked tiers per tree
                let t = CGFloat(tier)
                let bottom = base + height * 0.12 + t * height * 0.26
                let tierHalf = half * (1 - t * 0.24)
                ctx.move(to: CGPoint(x: x - tierHalf, y: bottom))
                ctx.addLine(to: CGPoint(x: x + tierHalf, y: bottom))
                ctx.addLine(to: CGPoint(x: x, y: bottom + height * (0.5 - t * 0.08)))
                ctx.closePath(); ctx.fillPath()
            }
        }
        var x: CGFloat = -w * 0.01
        while x < w * 1.01 {                            // back row, lighter
            pine(x, horizon, h * (0.1 + rnd() * 0.06), c(0x4E8664)); x += w * (0.012 + rnd() * 0.012)
        }
        x = -w * 0.005
        while x < w * 1.01 {                            // front row, darker and taller
            let near = abs(x / w - 0.5) * 2             // taller trees towards the edges
            pine(x, horizon - h * 0.005, h * (0.1 + near * 0.08 + rnd() * 0.05), c(0x2F6446)); x += w * (0.016 + rnd() * 0.016)
        }
        // Morning mist over the treeline.
        ctx.drawLinearGradient(gradient([c(0xFFFFFF, 0.5), c(0xFFFFFF, 0)], [0, 1]),
                               start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: horizon + h * 0.09), options: [])

        // Lake: deep at the bottom, reflecting the sky and the mountains.
        ctx.drawLinearGradient(gradient([c(0xF6DDB8), c(0x9CC9DE), c(0x4F8FAE)], [0, 0.4, 1]),
                               start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 0), options: [])
        ctx.saveGState()                               // mirrored ranges, faded
        ctx.translateBy(x: 0, y: horizon * 2); ctx.scaleBy(x: 1, y: -1)
        ctx.setAlpha(0.32); _ = ridge(far, c(0x9BB8CC))
        ctx.setAlpha(0.42); _ = ridge(mid, c(0x4F7F6E))
        ctx.restoreGState()
        ctx.setFillColor(c(0xFFF3D6, 0.55))             // sun glitter on the water
        for i in 0..<9 {
            let y = horizon - h * (0.03 + CGFloat(i) * 0.03)
            let len = w * (0.09 - CGFloat(i) * 0.007)
            ctx.fill(CGRect(x: sun.x - len / 2, y: y, width: len, height: max(1, h * 0.004)))
        }
        ctx.setFillColor(c(0xFFFFFF, 0.18))             // gentle ripples
        for i in 0..<14 {
            let y = h * 0.02 + CGFloat(i) * horizon * 0.068
            ctx.fill(CGRect(x: w * (0.05 + rnd() * 0.6), y: y, width: w * (0.08 + rnd() * 0.18), height: max(1, h * 0.003)))
        }
        let img = ctx.makeImage()!
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
    }

}

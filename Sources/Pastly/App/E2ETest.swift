import AppKit
import ApplicationServices

/// Developer end-to-end check with real mouse events (needs Accessibility permission):
///   open build/Pastly.app --args --e2e /tmp/report.txt
/// Drags a test clip into TextEdit, then double-clicks a clip to paste it, and reads TextEdit's
/// text back through Accessibility to see what actually arrived. Removes its test clips afterwards.
enum E2ETest {
    private static var report: [String] = []
    private static func log(_ s: String) { report.append(s); NSLog("Pastly E2E: %@", s) }

    static func run(panel: PanelController, reportPath: String) {
        let store = ClipStore.shared
        let marker = "PSDRAG\(Int.random(in: 1000...9999))"
        let marker2 = "PSPASTE\(Int.random(in: 1000...9999))"
        let docURL = URL(fileURLWithPath: "/tmp/pastly-e2e.txt")
        try? "".write(to: docURL, atomically: true, encoding: .utf8)

        func finish() {
            for m in [marker, marker2] {
                store.delete(store.items.filter { $0.plainText?.contains(m) == true }.map(\.id))
            }
            try? report.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        guard AXIsProcessTrusted() else { log("FAIL: not trusted for Accessibility"); finish(); return }

        // Test clips (newest first). Line break included to check it survives.
        _ = store.ingest(ClipItemParser.parseText("second \(marker2)", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: "E2E")
        _ = store.ingest(ClipItemParser.parseText("drag \(marker)\nline two", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: "E2E")

        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([docURL], withApplicationAt: textEdit, configuration: config) { app, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                guard let app, let window = firstWindow(of: app.processIdentifier) else {
                    log("FAIL: TextEdit window not found"); finish(); return
                }
                // Put TextEdit on the right, Pastly on the left.
                let screen = NSScreen.main!.frame
                setFrame(window, origin: CGPoint(x: screen.width * 0.55, y: 120), size: CGSize(width: 520, height: 420))
                app.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    dragTest(panel: panel, textEditPID: app.processIdentifier, window: window, marker: marker) {
                        pasteTest(panel: panel, textEdit: app, window: window, marker: marker2) {
                            selectThenPasteTest(panel: panel, textEdit: app, window: window) {
                                copyABCScenario(panel: panel, textEdit: app, window: window) {
                                    pasteModesTest(panel: panel) {
                                        listDropTest(panel: panel, marker: marker) { finish() }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Browsers (real drops into a local test page in Safari / Chrome / Firefox)

    static func runBrowsers(panel: PanelController, reportPath: String) {
        let store = ClipStore.shared
        let page = URL(fileURLWithPath: "/tmp/pastly-browser/test.html")
        let tag = "B\(Int.random(in: 1000...9999))"
        let dir = URL(fileURLWithPath: "/tmp/pastly-browser", isDirectory: true)
        let png = DemoData.makeArtwork(width: 64, height: 36)
        let jpegURL = dir.appendingPathComponent("photo.jpg")
        if let d = CGImageDestinationCreateWithURL(jpegURL as CFURL, "public.jpeg" as CFString, 1, nil),
           let cg = NSBitmapImageRep(data: png)?.cgImage { CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d) }
        let pdfURL = dir.appendingPathComponent("report.pdf")
        let pdfData = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        if let c = CGDataConsumer(data: pdfData), let ctx = CGContext(consumer: c, mediaBox: &box, nil) { ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF() }
        pdfData.write(to: pdfURL, atomically: true)
        let rtf = NSAttributedString(string: "rich \(tag)", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
            .rtf(from: NSRange(location: 0, length: 5 + tag.count), documentAttributes: [:])

        // (name, clip, band index 0 input / 1 textarea / 2 rich editor / 3 drop zone, expected substring in title)
        func clip(_ p: ParsedClip, _ name: String) -> ClipItem {
            let c = store.ingest(p, bundleID: nil, appName: "Browser test")
            store.setCustomTitle(c.id, "PSB \(tag) \(name)")
            return c
        }
        let text = clip(ClipItemParser.parseText("plain \(tag)", rtf: nil, html: nil, trimWhitespace: false), "text")
        let code = clip(ClipItemParser.parseText("let \(tag) = 1;\nprint(\(tag))", rtf: nil, html: nil, trimWhitespace: false), "code")
        let url = clip(ClipItemParser.parseText("https://example.com/\(tag)", rtf: nil, html: nil, trimWhitespace: false), "url")
        let rich = clip(ClipItemParser.parseText("rich \(tag)", rtf: rtf, html: nil, trimWhitespace: false), "rich")
        let pngClip = clip(ClipItemParser.parseImage(png, type: "public.png")!, "png")
        let jpgClip = clip(ClipItemParser.parseImage(try! Data(contentsOf: jpegURL), type: "public.jpeg")!, "jpeg")
        let pdfClip = clip(ParsedClip(type: .file, primaryUTI: "public.file-url", fileURLs: [pdfURL], contentHash: ContentHasher.fileHash([pdfURL])), "pdf")
        let cases: [(String, ClipItem, Int, String)] = [
            ("text → search field", text, 0, "input=\"plain \(tag)"),
            ("link → search field", url, 0, "https://example.com/\(tag)"),
            ("code → text area", code, 1, "ta=\"let \(tag) = 1;\\nprint(\(tag))"),
            ("rich text → rich editor", rich, 2, "rich \(tag)"),
            ("text → upload zone (stays text)", text, 3, "files[] text[plain \(tag)]"),
            ("PNG → upload zone", pngClip, 3, ".png:image/png"),
            ("JPEG → upload zone", jpgClip, 3, ".jpeg:image/jpeg"),
            ("PDF → upload zone", pdfClip, 3, "report.pdf:application/pdf"),
        ]
        let only = ProcessInfo.processInfo.environment["PS_BROWSER"] ?? (CommandLine.arguments.firstIndex(of: "--only").map { CommandLine.arguments[$0 + 1] })
        let browsers: [(String, String, [String])] = [
            ("Safari", "/Applications/Safari.app", []),
            ("Chrome", "/Applications/Google Chrome.app", ["--new-window"]),
            ("Firefox", "/Applications/Firefox.app", ["-new-window"]),
        ].filter { FileManager.default.fileExists(atPath: $0.1) && (only == nil || $0.0 == only) }
        let created = [text, code, url, rich, pngClip, jpgClip, pdfClip].map(\.id)

        func finish() {
            store.delete(created)
            try? report.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        var queue = browsers
        func nextBrowser() {
            guard !queue.isEmpty else { finish(); return }
            let (name, path, args) = queue.removeFirst()
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            cfg.arguments = args
            NSWorkspace.shared.open([page], withApplicationAt: URL(fileURLWithPath: path), configuration: cfg) { app, err in
                func findWindow(_ tries: Int, _ found: @escaping (AXUIElement?) -> Void) {
                    if let app, let w = window(of: app.processIdentifier, titlePrefix: "PSB") { found(w); return }
                    if tries == 0 { found(nil); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { findWindow(tries - 1, found) }
                }
                findWindow(15) { found in
                    guard let app, let win = found else {
                        log("\(name): FAIL couldn't open the test page (\(err?.localizedDescription ?? "no window"))"); nextBrowser(); return
                    }
                    let screen = NSScreen.main!.frame
                    setFrame(win, origin: CGPoint(x: screen.width * 0.42, y: 40), size: CGSize(width: 760, height: min(900, screen.height - 80)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        var pending = cases
                        func nextCase() {
                            guard !pending.isEmpty else {
                                app.activate()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { sendCommand(key: "w") }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { nextBrowser() }
                                return
                            }
                            let (label, item, band, expect) = pending.removeFirst()
                            panel.show(from: .hotkey)
                            movePanelLeft(panel)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                guard let title = store.item(id: item.id)?.customTitle,
                                      let row = findElement(exactly: title, pid: ProcessInfo.processInfo.processIdentifier),
                                      let r = frame(of: row), let wf = frame(of: win) else {
                                    log("\(name): \(label): FAIL row or window not found"); panel.hide(); nextCase(); return
                                }
                                // Content starts below the browser toolbar (~80–130 pt); bands are 160 pt tall.
                                let toolbar: CGFloat = name == "Safari" ? 92 : (name == "Chrome" ? 88 : 86)
                                let target = CGPoint(x: wf.midX, y: wf.minY + toolbar + CGFloat(band) * 160 + 70)
                                performDrag(from: CGPoint(x: r.midX - r.width * 0.25, y: r.midY), to: target) {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        let title = attr(win, kAXTitleAttribute) ?? ""
                                        log(title.contains(expect) ? "\(name): \(label): PASS" : "\(name): \(label): FAIL — page saw \(title.prefix(240))")
                                        panel.hide()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { nextCase() }
                                    }
                                }
                            }
                        }
                        nextCase()
                    }
                }
            }
        }
        guard AXIsProcessTrusted() else { log("FAIL: not trusted"); finish(); return }
        nextBrowser()
    }

    private static func window(of pid: pid_t, titlePrefix: String) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { (attr($0, kAXTitleAttribute) ?? "").hasPrefix(titlePrefix) }
    }

    // MARK: What a drag actually offers (the data a browser sees on drag-enter)

    final class DropProbe: NSView {
        var onEnter: ((NSPasteboard) -> Void)?
        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            onEnter?(sender.draggingPasteboard); return .copy
        }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    }

    static func runDragTypes(panel: PanelController, reportPath: String) {
        let store = ClipStore.shared
        let dir = URL(fileURLWithPath: "/tmp/pastly-dragtypes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = DemoData.makeArtwork(width: 64, height: 36)
        let jpegURL = dir.appendingPathComponent("p.jpg")
        if let d = CGImageDestinationCreateWithURL(jpegURL as CFURL, "public.jpeg" as CFString, 1, nil),
           let cg = NSBitmapImageRep(data: png)?.cgImage { CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d) }
        let pdfURL = dir.appendingPathComponent("doc.pdf")
        let pdfData = NSMutableData(); var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        if let c = CGDataConsumer(data: pdfData), let ctx = CGContext(consumer: c, mediaBox: &box, nil) { ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF() }
        pdfData.write(to: pdfURL, atomically: true)
        let rtf = NSAttributedString(string: "Bold DT").rtf(from: NSRange(location: 0, length: 7), documentAttributes: [:])

        let tag = "DT\(Int.random(in: 1000...9999))"
        let samples: [(String, ParsedClip)] = [
            ("text", ClipItemParser.parseText("plain \(tag)", rtf: nil, html: nil, trimWhitespace: false)),
            ("rich", ClipItemParser.parseText("rich \(tag)", rtf: rtf, html: nil, trimWhitespace: false)),
            ("url", ClipItemParser.parseText("https://example.com/\(tag)", rtf: nil, html: nil, trimWhitespace: false)),
            ("code", ClipItemParser.parseText("let \(tag) = 1;\nprint(\(tag));", rtf: nil, html: nil, trimWhitespace: false)),
            ("png", ClipItemParser.parseImage(png, type: "public.png")!),
            ("jpeg", ClipItemParser.parseImage(try! Data(contentsOf: jpegURL), type: "public.jpeg")!),
            ("color", ClipItemParser.parseText("#14B8A6", rtf: nil, html: nil, trimWhitespace: false)),
            ("pdf", ParsedClip(type: .file, primaryUTI: "public.file-url", fileURLs: [pdfURL], contentHash: ContentHasher.fileHash([pdfURL]))),
        ]
        var created: [(String, ClipItem)] = []
        for (name, p) in samples { created.append((name, store.ingest(p, bundleID: nil, appName: "DT \(tag) \(name)"))) }
        for (_, c) in created { store.setCustomTitle(c.id, "DT \(tag) \(c.type.rawValue) \(c.id.prefix(4))") }

        let probeWin = NSWindow(contentRect: NSRect(x: 900, y: 300, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        probeWin.title = "Drop probe"
        let probe = DropProbe(frame: probeWin.contentView!.bounds)
        probe.registerForDraggedTypes([.string, .URL, .fileURL, .png, .tiff, .rtf, .html, .pdf,
            NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.utf8-plain-text"),
            NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"), NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"), NSPasteboard.PasteboardType("io.github.sp201004.pastly.clip-ids"),
            NSPasteboard.PasteboardType("public.data"), NSPasteboard.PasteboardType("public.item")])
        probeWin.contentView = probe
        probeWin.level = .floating
        probeWin.orderFrontRegardless()

        func finish() {
            store.delete(created.map(\.1.id))
            probeWin.orderOut(nil)
            try? report.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        var queue = created
        func next() {
            guard !queue.isEmpty else { finish(); return }
            let (name, clip) = queue.removeFirst()
            var seen: String?
            probe.onEnter = { pb in
                let items = (pb.pasteboardItems ?? []).enumerated().map { i, it -> String in
                    "item\(i)[" + it.types.map(\.rawValue).joined(separator: ", ") + "]"
                }
                let text = pb.string(forType: .string).map { "text=\($0.debugDescription)" } ?? "text=nil"
                let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.map(\.lastPathComponent) ?? []
                seen = "\(items.joined(separator: " ")) | \(text) | fileURLs=\(files)"
            }
            panel.show(from: .hotkey)
            movePanelLeft(panel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let me = ProcessInfo.processInfo.processIdentifier
                guard let row = findElement(containing: "DT \(tag) \(clip.type.rawValue) \(clip.id.prefix(4))", pid: me),
                      let r = frame(of: row) else {
                    log("\(name): row not found"); panel.hide(); next(); return
                }
                let pr = probeWin.frame
                let screenH = NSScreen.screens[0].frame.height
                let target = CGPoint(x: pr.midX, y: screenH - pr.midY)
                performDrag(from: CGPoint(x: r.midX - r.width * 0.25, y: r.midY), to: target) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        log("\(name): card \(panel.lastDragImageSizes.map { "\(Int($0.width))×\(Int($0.height))" }) | \(seen ?? "drag never reached the target")")
                        panel.hide()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { next() }
                    }
                }
            }
        }
        next()
    }

    // MARK: Drag source = the row under the pointer (every row, edges, scrolled, filtered, look-alikes)

    static func runDragSource(panel: PanelController, reportPath: String) {
        let store = ClipStore.shared
        let me = ProcessInfo.processInfo.processIdentifier
        let tag = "DS\(Int.random(in: 1000...9999))"
        var created: [ClipItem] = []
        for n in (1...24).reversed() {   // 01 ends up on top
            created.append(store.ingest(ClipItemParser.parseText("DS \(tag) item \(String(format: "%02d", n))", rtf: nil, html: nil, trimWhitespace: false),
                                        bundleID: nil, appName: "E2E", date: Date().addingTimeInterval(Double(-n))))
        }
        // Two clips that look identical (one has a trailing space) but are different items.
        let twinA = store.ingest(ClipItemParser.parseText("DS \(tag) twin", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: "E2E")
        let twinB = store.ingest(ClipItemParser.parseText("DS \(tag) twin ", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: "E2E")
        created += [twinA, twinB]
        let probeWin = NSWindow(contentRect: NSRect(x: 900, y: 300, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        probeWin.title = "Drop probe"
        let probe = DropProbe(frame: probeWin.contentView!.bounds)
        probe.registerForDraggedTypes([.string, NSPasteboard.PasteboardType("io.github.sp201004.pastly.clip-ids")])
        probeWin.contentView = probe
        probeWin.level = .floating
        probeWin.orderFrontRegardless()
        var mismatches = 0, checked = 0
        func finish() {
            log(mismatches == 0 ? "PASS hit-test: all \(checked) points resolved to the row under them"
                                : "FAIL hit-test: \(mismatches) of \(checked) points resolved to another row")
            store.delete(created.map(\.id))
            probeWin.orderOut(nil)
            try? report.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        func after(_ t: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: body) }
        /// Global top-left screen point → panel window point (what a real mouse event reports).
        func windowPoint(_ p: CGPoint) -> CGPoint {
            let screenH = NSScreen.screens[0].frame.height
            return panel.panel.convertPoint(fromScreen: CGPoint(x: p.x, y: screenH - p.y))
        }
        /// Every visible test row: its id (from the store) and its on-screen frame (from Accessibility).
        func visibleRows() -> [(id: String, text: String, rect: CGRect)] {
            // Rows that look the same (the twins) are matched to items by their on-screen order.
            var used: [String: Int] = [:]
            return panel.state.visibleItems.filter { $0.plainText?.contains(tag) == true }.compactMap { item in
                guard let text = item.plainText else { return nil }
                let label = text.trimmingCharacters(in: .whitespaces)
                let matches = findAllElements(exactly: label, pid: me).compactMap { frame(of: $0) }
                    .filter { $0.height > 0 }.sorted { $0.minY < $1.minY }
                let n = used[label, default: 0]; used[label] = n + 1
                return n < matches.count ? (item.id, text, matches[n]) : nil
            }
        }
        func short(_ id: String?) -> String {
            guard let id, let t = store.item(id: id)?.plainText else { return id.map { String($0.prefix(8)) } ?? "nil" }
            return String(t.prefix(28)).debugDescription
        }
        /// The list's on-screen area, from Accessibility (the scroll area in the Pastly panel).
        func listArea() -> CGRect? {
            func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
                if depth > 20 { return nil }
                if attr(el, kAXRoleAttribute) == kAXScrollAreaRole, let r = frame(of: el), r.height > 150 { return el }
                for c in children(el) { if let hit = search(c, depth: depth + 1) { return hit } }
                return nil
            }
            return search(AXUIElementCreateApplication(me), depth: 0).flatMap { frame(of: $0) }
        }
        func sweep(_ label: String) {
            let area = listArea() ?? .infinite
            let rows = visibleRows().filter { area.contains(CGPoint(x: $0.rect.midX, y: $0.rect.minY + 1)) && area.contains(CGPoint(x: $0.rect.midX, y: $0.rect.maxY - 1)) }
            var bad: [String] = []
            for row in rows {
                for f in [0.05, 0.5, 0.95] as [CGFloat] {
                    let p = CGPoint(x: row.rect.midX, y: row.rect.minY + row.rect.height * f)
                    let got = panel.dragSourceID(atWindowPoint: windowPoint(p))
                    checked += 1
                    if got != row.id {
                        mismatches += 1
                        bad.append("\(row.text.suffix(7))@\(f) → \(short(got))")
                    }
                }
            }
            if rows.isEmpty { log("FAIL \(label): no rows visible to Accessibility"); mismatches += 1; return }
            log(bad.isEmpty ? "PASS \(label): \(rows.count) rows, every point resolves to its own row"
                            : "FAIL \(label): \(bad.prefix(6).joined(separator: "; "))")
        }
        /// A real mouse drag from the row's text to the probe; the probe reads the dragged clip ids.
        func realDrag(_ id: String, _ label: String, _ then: @escaping () -> Void) {
            guard let item = store.item(id: id), let text = item.plainText,
                  let row = visibleRows().first(where: { $0.id == id }) else { log("FAIL \(label): row not visible"); then(); return }
            var dropped: [String]?
            probe.onEnter = { pb in
                dropped = pb.pasteboardItems?.compactMap { $0.data(forType: NSPasteboard.PasteboardType("io.github.sp201004.pastly.clip-ids")).flatMap { String(data: $0, encoding: .utf8) } }
                    .flatMap { $0.split(separator: "\n").map(String.init) }
            }
            let pr = probeWin.frame, screenH = NSScreen.screens[0].frame.height
            let from = CGPoint(x: row.rect.minX + 30, y: row.rect.minY + row.rect.height * 0.8)   // lower part of the row
            performDrag(from: from, to: CGPoint(x: pr.midX, y: screenH - pr.midY)) {
                after(0.6) {
                    let ok = dropped == [id]
                    log(ok ? "PASS \(label): dragged exactly \(text.debugDescription) (id \(id.prefix(8)))"
                           : "FAIL \(label): grabbed \(text.debugDescription) but dragged \((dropped ?? []).map { short($0) })")
                    then()
                }
            }
        }

        /// Accessibility sometimes needs a moment before it exposes a freshly shown panel.
        func whenRowsVisible(_ tries: Int = 12, _ body: @escaping () -> Void) {
            if !visibleRows().isEmpty || tries == 0 { body() } else { after(0.7) { whenRowsVisible(tries - 1, body) } }
        }
        panel.show(from: .hotkey)
        movePanelLeft(panel)
        after(1.0) { whenRowsVisible {
            sweep("unscrolled list")
            let ids = panel.state.visibleItems.filter { $0.plainText?.contains(tag) == true }.map(\.id)
            let order = { (n: Int) in created.first { $0.plainText == "DS \(tag) item \(String(format: "%02d", n))" }!.id }
            realDrag(twinB.id, "1st item (look-alike twin)") {
            realDrag(twinA.id, "2nd item (identical-looking twin)") {
            realDrag(order(1), "3rd item") {
                panel.state.clickRow(order(3), opensPreview: false)            // change the selection first
                after(0.4) {
                realDrag(order(2), "after selecting another item") {
                    // Scroll: select the last test row so the list scrolls to it.
                    panel.state.select(ids.last); after(0.8) {
                    sweep("scrolled list")
                    realDrag(ids.last!, "last item (after scrolling)") {
                        panel.state.query = "\(tag) twin"; after(0.8) {            // filtered: just the two twins
                        sweep("filtered list")
                        let f = panel.state.visibleItems.map(\.id)
                        realDrag(f.count > 1 ? f[1] : f[0], "filtered list (\(f.count) results), 2nd result") {
                            panel.state.query = ""
                            panel.hide(); after(0.4) { finish() }
                        }}
                    }}
                }}
            }}}
        } }
    }

    // MARK: Finder ⌘C

    /// Real Finder copy: reveal each test file in Finder, press ⌘C there, and check what Pastly saved.
    static func runFinder(panel: PanelController, reportPath: String) {
        let store = ClipStore.shared
        let dir = URL(fileURLWithPath: "/tmp/pastly-finder-test", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cg = NSBitmapImageRep(data: DemoData.makeArtwork(width: 640, height: 360))!.cgImage!
        func write(_ name: String, _ type: String) -> URL {
            let url = dir.appendingPathComponent(name)
            if let d = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
            }
            return url
        }
        let pdf = dir.appendingPathComponent("document.pdf")
        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        if let c = CGDataConsumer(data: pdfData), let ctx = CGContext(consumer: c, mediaBox: &box, nil) { ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF() }
        pdfData.write(to: pdf, atomically: true)
        let video = dir.appendingPathComponent("finder-test.mp4"), song = dir.appendingPathComponent("finder-test.m4a")
        _ = DemoData.makeVideo(at: video)
        _ = DemoData.makeAudio(at: song)
        var cases: [(URL, Bool)] = [(pdf, false), (video, false), (song, false), (write("finder-test.png", "public.png"), true),
                                    (write("finder-test.jpg", "public.jpeg"), true), (write("finder-test.heic", "public.heic"), true)]
        var created: [String] = []

        func finish() {
            store.delete(created)
            try? report.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        func next() {
            guard !cases.isEmpty else { finish(); return }
            let (url, isImage) = cases.removeFirst()
            NSWorkspace.shared.activateFileViewerSelecting([url])
            let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            // Wait until Finder really is frontmost (other apps may grab focus after Pastly hides).
            func whenFinderFront(_ tries: Int, _ body: @escaping () -> Void) {
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" || tries == 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: body); return
                }
                _ = finder
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), configuration: cfg)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { whenFinderFront(tries - 1, body) }
            }
            whenFinderFront(12) {
                let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                sendCommand(key: "c")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    guard let clip = store.items.first(where: { $0.fileURLs.map(\.standardizedFileURL) == [url.standardizedFileURL] }) else {
                        log("FAIL \(url.lastPathComponent): nothing saved (frontmost was \(front))"); next(); return
                    }
                    created.append(clip.id)
                    let thumb = clip.imagePath.flatMap { store.images.thumbnail(for: $0) }
                    if isImage {
                        log(clip.type == .file && thumb != nil && clip.imageWidth == 640
                            ? "PASS \(url.lastPathComponent): saved from Finder with a real thumbnail (\(clip.imageWidth)×\(clip.imageHeight), \(clip.imagePath ?? ""))"
                            : "FAIL \(url.lastPathComponent): type \(clip.type) image \(clip.imagePath ?? "none") thumb \(thumb != nil)")
                        panel.show(from: .hotkey)
                        panel.state.select(clip.id)
                        panel.state.openPreview()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            let shown = panel.state.previewItem?.id == clip.id
                            let previewWindow = NSApp.windows.contains { $0 is PreviewPanel && $0.isVisible }
                            log(shown && previewWindow ? "PASS \(url.lastPathComponent): preview open with the image"
                                                       : "FAIL \(url.lastPathComponent): preview shown \(shown), window \(previewWindow)")
                            panel.hide()
                            next()
                        }
                    } else if let kind = MediaSupport.kind(of: url) {
                        let okType = clip.type == .file && clip.imagePath == nil
                        MediaSupport.thumbnail(for: url, pixels: 120) { thumb in
                            MediaSupport.info(for: url) { info in
                                log(okType && info?.duration ?? 0 > 0 && (kind == .audio || thumb != nil)
                                    ? "PASS \(url.lastPathComponent): saved as a \(kind == .video ? "video" : "music") file, \(info?.durationText ?? "?")\(kind == .video ? ", poster frame ready" : "")"
                                    : "FAIL \(url.lastPathComponent): type \(clip.type), image \(clip.imagePath ?? "none"), thumb \(thumb != nil), duration \(info?.durationText ?? "nil")")
                                panel.show(from: .hotkey)
                                panel.state.select(clip.id)
                                panel.state.openPreview()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    let window = NSApp.windows.contains { $0 is PreviewPanel && $0.isVisible }
                                    log(panel.state.previewItem?.id == clip.id && window
                                        ? "PASS \(url.lastPathComponent): preview open with the \(kind == .video ? "video player" : "music player")"
                                        : "FAIL \(url.lastPathComponent): preview window \(window)")
                                    panel.hide()
                                    next()
                                }
                            }
                        }
                    } else {
                        log(clip.type == .file && clip.imagePath == nil
                            ? "PASS \(url.lastPathComponent): saved as a file, not as an image"
                            : "FAIL \(url.lastPathComponent): image \(clip.imagePath ?? "none")")
                        next()
                    }
                }
            }
        }
        guard AXIsProcessTrusted() else { log("FAIL: not trusted for Accessibility"); finish(); return }
        next()
    }

    private static func sendCommand(key: String) {
        let code = KeyboardLayout.keyCode(for: key) ?? 8
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Drag

    private static func dragTest(panel: PanelController, textEditPID: pid_t, window: AXUIElement, marker: String,
                                 then next: @escaping () -> Void) {
        setText(window, "")
        panel.show(from: .hotkey)
        movePanelLeft(panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard let row = findElement(containing: marker, pid: ProcessInfo.processInfo.processIdentifier),
                  let rowRect = frame(of: row), let winRect = frame(of: window) else {
                let rowFound = findElement(containing: marker, pid: ProcessInfo.processInfo.processIdentifier) != nil
                log("FAIL drag: couldn't locate the clip row or TextEdit window (row: \(rowFound), window frame: \(frame(of: window).map { "\($0)" } ?? "nil"), panel visible: \(panel.panel.isVisible), first visible: \(panel.state.visibleItems.prefix(3).map { $0.plainText?.prefix(20) ?? "-" }), tab: \(panel.state.collection), query: '\(panel.state.query)')")
                next(); return
            }
            let from = CGPoint(x: rowRect.midX - rowRect.width * 0.25, y: rowRect.midY)
            let to = CGPoint(x: winRect.midX, y: winRect.midY)
            let panelBefore = panel.panel.frame
            performDrag(from: from, to: to) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    log("drag session started: \(DragProvider.lastDragTypes != nil), types offered: \(DragProvider.lastDragTypes ?? [])")
                    log("row frame \(rowRect), drag \(from) → \(to), TextEdit window \(winRect)")
                    let text = textValue(window) ?? "<no text>"
                    let windowMoved = panel.panel.frame.origin != panelBefore.origin
                    log(text.contains("drag \(marker)\nline two")
                        ? "PASS drag: text inserted into TextEdit with line break (\(text.debugDescription))"
                        : "FAIL drag: TextEdit contains \(text.debugDescription)")
                    log(windowMoved ? "FAIL drag: Pastly window moved" : "PASS drag: Pastly window stayed still")
                    next()
                }
            }
        }
    }

    // MARK: Double-click paste

    private static func pasteTest(panel: PanelController, textEdit: NSRunningApplication, window: AXUIElement, marker: String,
                                  then next: @escaping () -> Void) {
        panel.hide()
        setText(window, "")
        textEdit.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            panel.show(from: .hotkey)   // remembers TextEdit as the app to paste into
            movePanelLeft(panel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let row = findElement(containing: marker, pid: ProcessInfo.processInfo.processIdentifier),
                      let rect = frame(of: row) else {
                    log("FAIL paste: couldn't locate the clip row"); next(); return
                }
                doubleClick(at: CGPoint(x: rect.midX - rect.width * 0.25, y: rect.midY))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    let text = textValue(window) ?? "<no text>"
                    log(text.contains("second \(marker)")
                        ? "PASS double-click: pasted into TextEdit (\(text.debugDescription))"
                        : "FAIL double-click: TextEdit contains \(text.debugDescription)")
                    next()
                }
            }
        }
    }

    // MARK: One click selects an old clip, then ⌘V / ↩ paste it — history order unchanged

    private static func selectThenPasteTest(panel: PanelController, textEdit: NSRunningApplication, window: AXUIElement,
                                            then next: @escaping () -> Void) {
        let store = ClipStore.shared
        let tag = "PSORD\(Int.random(in: 1000...9999))"
        let names = ["Old item C \(tag)", "Old item B \(tag)", "Old item A \(tag)", "Latest copied text \(tag)"]
        for (n, name) in names.enumerated() {
            _ = store.ingest(ClipItemParser.parseText(name, rtf: nil, html: nil, trimWhitespace: false),
                             bundleID: nil, appName: "E2E", date: Date().addingTimeInterval(Double(n) * 0.01))
        }
        let ours = { store.items.filter { $0.plainText?.contains(tag) == true } }
        let order = { store.items.map(\.id) }
        let orderBefore = order(), datesBefore = ours().map(\.lastUsedAt), countBefore = store.items.count
        let prefs = Preferences.shared
        let originalMode = prefs.singleClickPreview
        func cleanup() { prefs.singleClickPreview = originalMode; store.delete(ours().map(\.id)); next() }
        func checkHistory(_ step: String) {
            log(order() == orderBefore && ours().map(\.lastUsedAt) == datesBefore && store.items.count == countBefore
                ? "PASS \(step): history order, timestamps and count unchanged"
                : "FAIL \(step): history changed (count \(countBefore) → \(store.items.count))")
        }

        let me = ProcessInfo.processInfo.processIdentifier
        func clickRow(_ name: String) -> Bool {
            guard let row = findElement(containing: name, pid: me), let rect = frame(of: row) else { return false }
            let p = CGPoint(x: rect.midX - rect.width * 0.25, y: rect.midY)
            post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p)            // one real click
            return true
        }
        func openPanel(_ then: @escaping () -> Void) {
            panel.hide()
            setText(window, "")
            textEdit.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                panel.show(from: .hotkey)
                movePanelLeft(panel)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: then)
            }
        }

        // Mode 1 — Single Click to Preview: a click opens the preview; its Paste button pastes.
        prefs.singleClickPreview = true
        openPanel {
            guard clickRow(names[1]) else { log("FAIL preview mode: couldn't locate item B"); cleanup(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let previewing = panel.state.isPreviewVisible && panel.state.previewItem?.plainText == names[1]
                log(previewing ? "PASS preview mode: one click opened item B's preview" : "FAIL preview mode: preview not shown")
                checkHistory("preview mode click")
                guard let button = findButton(titled: "Paste", pid: me), let r = frame(of: button) else {
                    log("FAIL preview mode: Paste button not found"); selectMode(); return
                }
                let p = CGPoint(x: r.midX, y: r.midY)
                post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    let text = textValue(window) ?? "<no text>"
                    log(text == names[1] ? "PASS preview mode: Paste button pasted item B into TextEdit"
                                         : "FAIL preview mode: TextEdit contains \(text.debugDescription)")
                    checkHistory("preview Paste button")
                    selectMode()
                }
            }
        }

        // Mode 2 — Single Click to Select (switched live, no restart): a click only selects; ⌘V pastes.
        func selectMode() {
        prefs.singleClickPreview = false
        openPanel {
                guard clickRow(names[1]) else { log("FAIL select: couldn't locate item B"); cleanup(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let selected = panel.state.selectedIDs
                    log(selected.count == 1 && store.item(id: selected.first!)?.plainText == names[1]
                        ? "PASS select: one click selected item B only" : "FAIL select: selection is \(selected)")
                    log(!panel.state.isPreviewVisible ? "PASS select mode: the click did not open a preview"
                                                      : "FAIL select mode: a preview opened")
                    checkHistory("select")
                    sendKey(KeyboardLayout.keyCode(for: "v") ?? 9, flags: .maskCommand)                                        // real ⌘V
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        let text = textValue(window) ?? "<no text>"
                        log(text == names[1] ? "PASS ⌘V: TextEdit received item B (\(text.debugDescription))"
                                             : "FAIL ⌘V: TextEdit contains \(text.debugDescription)")
                        let general = NSPasteboard.general.string(forType: .string)
                        log(general == names[1] ? "PASS ⌘V: system clipboard holds item B"
                                                : "FAIL ⌘V: system clipboard holds \(general.debugDescription)")
                        checkHistory("⌘V")
                        log(store.items.first(where: { $0.plainText?.contains(tag) == true })?.plainText == names[3]
                            ? "PASS ⌘V: latest copied item is still on top" : "FAIL ⌘V: latest item moved")
                        keyboardThenEnter()
                    }
                }
        }
        }

        // ↓/↑ move the selection, ↩ pastes it.
        func keyboardThenEnter() {
            setText(window, "")
            textEdit.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                panel.show(from: .hotkey)
                movePanelLeft(panel)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let ids = order()
                    guard let cIndex = ids.firstIndex(where: { store.item(id: $0)?.plainText == names[0] }) else {
                        log("FAIL keys: item C not found"); cleanup(); return
                    }
                    // Start on item B (the previous selection or wherever it is), then ↓ to C, ↑ back, ↓ again.
                    panel.state.select(ids[cIndex - 1])
                    sendKey(125); sendKey(126); sendKey(125)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        log(panel.state.selectedID == ids[cIndex] ? "PASS keys: ↓/↑ moved the selection to item C"
                                                                   : "FAIL keys: selection is \(panel.state.selectedID ?? "nil")")
                        sendKey(36)                                                          // ↩
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            let text = textValue(window) ?? "<no text>"
                            log(text == names[0] ? "PASS ↩: TextEdit received item C" : "FAIL ↩: TextEdit contains \(text.debugDescription)")
                            checkHistory("↩")
                            doubleClickOld()
                        }
                    }
                }
            }
        }

        // Double-click pastes too, without moving the clip.
        func doubleClickOld() {
            setText(window, "")
            textEdit.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                panel.show(from: .hotkey)
                movePanelLeft(panel)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard let row = findElement(containing: names[2], pid: ProcessInfo.processInfo.processIdentifier),
                          let rect = frame(of: row) else { log("FAIL double-click old: item A not found"); cleanup(); return }
                    doubleClick(at: CGPoint(x: rect.midX - rect.width * 0.25, y: rect.midY))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        let text = textValue(window) ?? "<no text>"
                        log(text == names[2] ? "PASS double-click old: TextEdit received item A" : "FAIL double-click old: TextEdit contains \(text.debugDescription)")
                        checkHistory("double-click")
                        cleanup()
                    }
                }
            }
        }
    }

    // MARK: Real ⌘C of A, B, C in TextEdit → select / ⌘V / reopen / double-click / plain ⌘V

    private static func copyABCScenario(panel: PanelController, textEdit: NSRunningApplication, window: AXUIElement,
                                        then next: @escaping () -> Void) {
        let store = ClipStore.shared, prefs = Preferences.shared
        let me = ProcessInfo.processInfo.processIdentifier
        let tag = "PSABC\(Int.random(in: 1000...9999))"
        let A = "Clip A \(tag)", B = "Clip B \(tag)", C = "Clip C \(tag)", D = "Clip D \(tag)"
        let originalMode = prefs.singleClickPreview
        let originalClipboard = NSPasteboard.general.string(forType: .string)
        let ours = { store.items.filter { $0.plainText?.contains(tag) == true } }
        let v = KeyboardLayout.keyCode(for: "v") ?? 9, a = KeyboardLayout.keyCode(for: "a") ?? 0, c = KeyboardLayout.keyCode(for: "c") ?? 8
        func after(_ t: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: body) }
        func cleanup() {
            prefs.singleClickPreview = originalMode
            store.delete(ours().map(\.id))
            if let s = originalClipboard {          // put the user's clipboard back (not captured)
                let pb = NSPasteboard.general
                let n = pb.clearContents(); SelfWriteRegistry.shared.register(n, pasteboard: pb.name)
                pb.setString(s, forType: .string)
            }
            next()
        }
        func realCopy(_ text: String, _ then: @escaping () -> Void) {     // type into TextEdit, ⌘A, ⌘C
            panel.hide(); setText(window, text); textEdit.activate()
            after(0.6) { sendKey(a, flags: .maskCommand); after(0.2) { sendKey(c, flags: .maskCommand); after(1.0, then) } }
        }
        func openPanel(_ then: @escaping () -> Void) {
            setText(window, ""); textEdit.activate()
            after(0.7) { panel.show(from: .hotkey); movePanelLeft(panel); after(0.9, then) }
        }
        func click(_ p: CGPoint) { post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p) }
        func clickRow(_ text: String) -> Bool {
            guard let row = findElement(containing: text, pid: me), let r = frame(of: row) else { return false }
            click(CGPoint(x: r.midX - r.width * 0.25, y: r.midY)); return true
        }
        func clickIntoTextEdit() { if let r = frame(of: window) { click(CGPoint(x: r.midX, y: r.midY + 40)) } }
        func textIs(_ want: String, _ step: String) {
            let got = textValue(window) ?? "<no text>"
            log(got == want ? "PASS \(step): TextEdit received \(want.components(separatedBy: " ").prefix(2).joined(separator: " "))"
                            : "FAIL \(step): TextEdit contains \(got.debugDescription)")
        }
        func historyOK(_ step: String) {
            let names = ours().map { $0.plainText ?? "" }
            log(names == [C, B, A] ? "PASS \(step): history is C, B, A (latest C on top), no duplicates"
                                   : "FAIL \(step): history is \(names)")
        }

        realCopy(A) { realCopy(B) { realCopy(C) {
            historyOK("real ⌘C of A, B, C")
            prefs.singleClickPreview = false                                    // your current mode: Select
            // 1. Single-click A, switch to TextEdit, ⌘V there.
            openPanel {
                guard clickRow(A) else { log("FAIL: row A not found"); cleanup(); return }
                after(0.4) {
                    clickIntoTextEdit()
                    after(0.8) {
                        log(!panel.panel.isVisible ? "PASS select mode: panel closed when switching to TextEdit" : "FAIL: panel still open")
                        sendKey(v, flags: .maskCommand)
                        after(1.2) {
                            textIs(A, "single-click A → ⌘V in TextEdit")
                            // 2. Reopen: A restored as the selection; order and latest unchanged.
                            openPanel {
                                let sel = panel.state.selectedItems.map { $0.plainText ?? "" }
                                log(sel == [A] ? "PASS reopen: A is still the selected item (not the latest)"
                                               : "FAIL reopen: selected \(sel)")
                                historyOK("after pasting A")
                                // 3. Select B, ⌘V while the panel is open.
                                guard clickRow(B) else { log("FAIL: row B not found"); cleanup(); return }
                                after(0.5) {
                                    sendKey(v, flags: .maskCommand)
                                    after(1.5) {
                                        textIs(B, "single-click B → ⌘V in Pastly")
                                        historyOK("after pasting B")
                                        // 4. Double-click A pastes directly.
                                        openPanel {
                                            guard let row = findElement(containing: A, pid: me), let r = frame(of: row) else { cleanup(); return }
                                            doubleClick(at: CGPoint(x: r.midX - r.width * 0.25, y: r.midY))
                                            after(1.5) {
                                                textIs(A, "double-click A")
                                                historyOK("after double-click")
                                                previewModeSwitchAway()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } } }

        // 5. Preview mode: single-click C, switch to TextEdit, ⌘V there.
        func previewModeSwitchAway() {
            prefs.singleClickPreview = true
            openPanel {
                guard clickRow(B) else { log("FAIL: row B not found"); cleanup(); return }
                after(0.5) {
                    log(panel.state.isPreviewVisible ? "PASS preview mode: click opened the preview" : "FAIL preview mode: no preview")
                    clickIntoTextEdit()
                    after(0.8) {
                        sendKey(v, flags: .maskCommand)
                        after(1.2) { textIs(B, "preview mode: click B → ⌘V in TextEdit"); historyOK("preview mode"); plainPaste() }
                    }
                }
            }
        }

        // 6. Nothing selected: a real copy of D, open and close Pastly, ⌘V pastes D.
        func plainPaste() {
            realCopy(D) {
                openPanel {
                    let sel = panel.state.selectedItems.map { $0.plainText ?? "" }
                    log(sel == [D] ? "PASS new copy: the latest copied item D is selected on open" : "FAIL new copy: selected \(sel)")
                    sendKey(53)                                                         // esc closes
                    after(0.6) {
                        clickIntoTextEdit()
                        after(0.5) {
                            sendKey(v, flags: .maskCommand)
                            after(1.2) { textIs(D, "no selection → normal ⌘V"); cleanup() }
                        }
                    }
                }
            }
        }
    }

    // MARK: One paste mode for every path: preview Paste, ⌘V, double-click, drag & drop — real TextEdit

    private static func pasteModesTest(panel: PanelController, then next: @escaping () -> Void) {
        let store = ClipStore.shared, prefs = Preferences.shared, me = ProcessInfo.processInfo.processIdentifier
        let tag = "PSRICH\(Int.random(in: 1000...9999))"
        let originalMode = prefs.pastePlainByDefault, originalClick = prefs.singleClickPreview
        func after(_ t: Double, _ body: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: body) }
        // Rich clip: bold, italic, red and a hyperlink.
        let rich = NSMutableAttributedString(string: "Bold\(tag)", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
        rich.append(NSAttributedString(string: " italic words", attributes: [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 15), toHaveTrait: .italicFontMask)]))
        rich.append(NSAttributedString(string: " red", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 15)]))
        rich.append(NSAttributedString(string: " link", attributes: [.link: URL(string: "https://example.com/\(tag)")!, .font: NSFont.systemFont(ofSize: 15)]))
        let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!
        let richClip = store.ingest(ClipItemParser.parseText(rich.string, rtf: rtf, html: nil, trimWhitespace: false), bundleID: "com.apple.TextEdit", appName: "E2E")
        let wantText = "Bold\(tag) italic words red link"
        let others = [("plain text", "Plain \(tag) note"), ("code", "let \(tag) = [1, 2, 3]\nprint(\(tag).count)"), ("URL", "https://example.com/\(tag)")]
            .map { ($0.0, store.ingest(ClipItemParser.parseText($0.1, rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: "E2E")) }
        let orderBefore = store.items.map(\.id)
        func cleanup() {
            prefs.pastePlainByDefault = originalMode; prefs.singleClickPreview = originalClick
            store.delete([richClip.id] + others.map(\.1.id)); next()
        }
        let te = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        let screen = NSScreen.main!.frame

        func pasteButtonOK(_ label: String) {
            guard let b = findButton(titled: "Paste", pid: me), let r = frame(of: b) else { log("FAIL \(label): Paste button not found"); return }
            log(r.width >= r.height * 1.6 && r.height <= 30 ? "PASS \(label): Paste button is a normal button (\(Int(r.width))×\(Int(r.height)) pt), no blue bar"
                                                          : "FAIL \(label): Paste button squeezed to \(Int(r.width))×\(Int(r.height)) pt")
        }
        func modeMenu() -> (el: AXUIElement, mode: String)? {
            for mode in ["Formatted", "Plain"] { if let el = findAllElements(exactly: "Paste mode: \(mode)", pid: me).first { return (el, mode) } }
            return nil
        }
        /// What landed in a TextEdit document, read back through Accessibility.
        func pasted(_ window: AXUIElement) -> (text: String, bold: Bool, italic: Bool, red: Bool, link: Bool) {
            guard let area = textArea(window) else { return ("", false, false, false, false) }
            let text = attr(area, kAXValueAttribute) ?? ""
            var range = CFRange(location: 0, length: (text as NSString).length)
            var value: CFTypeRef?
            if let axRange = AXValueCreate(.cfRange, &range) {
                AXUIElementCopyParameterizedAttributeValue(area, kAXAttributedStringForRangeParameterizedAttribute as CFString, axRange, &value)
            }
            var bold = false, italic = false, red = false, link = false
            (value as? NSAttributedString)?.enumerateAttributes(in: NSRange(location: 0, length: (value as! NSAttributedString).length)) { a, _, _ in
                if let f = a[NSAttributedString.Key("AXFont")] as? [String: Any], let n = (f["AXFontName"] as? String)?.lowercased() {
                    if n.contains("bold") { bold = true }
                    if n.contains("italic") || n.contains("oblique") { italic = true }
                }
                if let c = a[NSAttributedString.Key("AXForegroundColor")], let rgb = NSColor(cgColor: c as! CGColor)?.usingColorSpace(.sRGB),
                   rgb.redComponent > 0.7, rgb.greenComponent < 0.4 { red = true }
                if a[NSAttributedString.Key("AXLink")] != nil { link = true }
            }
            return (text.trimmingCharacters(in: .whitespacesAndNewlines), bold, italic, red, link)
        }
        func verify(_ window: AXUIElement, plain: Bool, _ how: String) {
            let r = pasted(window)
            let mode = plain ? "Plain" : "Formatted"
            let ok = r.text.contains(wantText) && (plain ? (!r.bold && !r.italic && !r.red && !r.link) : (r.bold && r.italic && r.red && r.link))
            log(ok ? "PASS \(mode) · \(how): TextEdit got \(plain ? "plain text (no bold, italic, color or link)" : "bold, italic, red and a link")"
                   : "FAIL \(mode) · \(how): text \(String(r.text.prefix(44)).debugDescription) bold \(r.bold) italic \(r.italic) red \(r.red) link \(r.link)")
        }

        /// Opens a fresh rich TextEdit document so earlier pastes' typing style can't leak in.
        func freshDoc(_ name: String, _ then: @escaping (NSRunningApplication, AXUIElement) -> Void) {
            let url = URL(fileURLWithPath: "/tmp/pastly-e2e-\(name).rtf")
            try? NSAttributedString(string: "").rtf(from: NSRange(location: 0, length: 0), documentAttributes: [:])?.write(to: url)
            NSWorkspace.shared.open([url], withApplicationAt: te, configuration: config) { app, _ in
                after(2.0) {
                    guard let app, let w = self.window(of: app.processIdentifier, titlePrefix: "pastly-e2e-\(name)") else {
                        log("FAIL \(name): TextEdit document not found"); cleanup(); return
                    }
                    setFrame(w, origin: CGPoint(x: screen.width * 0.55, y: 120), size: CGSize(width: 520, height: 420))
                    then(app, w)
                }
            }
        }
        func openPanel(_ app: NSRunningApplication, _ window: AXUIElement, _ then: @escaping () -> Void) {
            panel.hide(); setText(window, ""); app.activate()
            after(0.7) { panel.show(from: .hotkey); movePanelLeft(panel); after(0.9, then) }
        }
        func rowPoint() -> CGPoint? {
            guard let row = findAllElements(exactly: wantText, pid: me).compactMap({ frame(of: $0) }).first(where: { $0.minX < panel.panel.frame.maxX }) else { return nil }
            return CGPoint(x: row.minX + 30, y: row.midY)
        }

        /// All four paste paths in one mode. `setMode` nil = keep whatever the saved setting is (startup).
        func runMode(_ plain: Bool, label: String, setMode: Bool, _ done: @escaping () -> Void) {
            if setMode { prefs.pastePlainByDefault = plain }           // exactly what Settings' picker does
            freshDoc(label) { app, window in
                let mode = plain ? "Plain" : "Formatted"
                // 0. Right after switching: ⌘V in TextEdit without touching Pastly pastes the new way.
                func step0(_ then: @escaping () -> Void) {
                    guard setMode else { then(); return }
                    panel.hide(); setText(window, ""); app.activate()
                    after(0.8) {
                        sendKey(KeyboardLayout.keyCode(for: "v") ?? 9, flags: .maskCommand)
                        after(1.5) { verify(window, plain: plain, "⌘V in TextEdit right after switching (no reselect)"); then() }
                    }
                }
                step0 {
                // 1. Preview Paste button — no reselecting in the menu.
                prefs.singleClickPreview = true
                openPanel(app, window) {
                    panel.state.select(richClip.id); panel.state.openPreview()
                    after(0.9) {
                        log(modeMenu()?.mode == mode ? "PASS \(mode) · preview menu shows \(mode) without reselecting" : "FAIL \(mode) · preview menu shows \(modeMenu()?.mode ?? "nothing")")
                        guard let b = findButton(titled: "Paste", pid: me), let r = frame(of: b) else { log("FAIL \(mode): no Paste button"); done(); return }
                        click(CGPoint(x: r.midX, y: r.midY))
                        after(1.8) {
                            verify(window, plain: plain, "preview Paste button")
                            // 2. ⌘V on the selected clip.
                            prefs.singleClickPreview = false
                            openPanel(app, window) {
                                guard let p = rowPoint() else { log("FAIL \(mode): row not found"); done(); return }
                                click(p)
                                after(0.5) {
                                    sendKey(KeyboardLayout.keyCode(for: "v") ?? 9, flags: .maskCommand)
                                    after(1.8) {
                                        verify(window, plain: plain, "⌘V in Pastly")
                                        // 2b. Select, switch to TextEdit, ⌘V there.
                                        openPanel(app, window) {
                                        guard let p = rowPoint(), let w = frame(of: window) else { log("FAIL \(mode): row not found"); done(); return }
                                        click(p)
                                        after(0.5) {
                                        click(CGPoint(x: w.midX, y: w.midY + 40))
                                        after(0.7) {
                                        sendKey(KeyboardLayout.keyCode(for: "v") ?? 9, flags: .maskCommand)
                                        after(1.5) {
                                        verify(window, plain: plain, "⌘V in TextEdit after selecting")
                                        // 3. Double-click.
                                        openPanel(app, window) {
                                            guard let p = rowPoint() else { log("FAIL \(mode): row not found"); done(); return }
                                            doubleClick(at: p)
                                            after(1.8) {
                                                verify(window, plain: plain, "double-click")
                                                // 4. Drag & drop into the document.
                                                openPanel(app, window) {
                                                    guard let p = rowPoint(), let w = frame(of: window) else { log("FAIL \(mode): row not found"); done(); return }
                                                    performDrag(from: p, to: CGPoint(x: w.midX, y: w.midY + 30)) {
                                                        after(1.5) {
                                                            verify(window, plain: plain, "drag & drop")
                                                            panel.hide(); done()
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        }}}}
                                    }
                                }
                            }
                        }
                    }
                }
                }
            }
        }
        func click(_ p: CGPoint) { post(.mouseMoved, p); post(.leftMouseDown, p); post(.leftMouseUp, p) }

        // No blue bar: the Paste button keeps its shape for every kind of clip.
        var kinds = [("rich text", richClip)] + others
        func checkKinds(_ app: NSRunningApplication, _ window: AXUIElement, _ then: @escaping () -> Void) {
            guard !kinds.isEmpty else { then(); return }
            let (label, clip) = kinds.removeFirst()
            openPanel(app, window) {
                panel.state.select(clip.id); panel.state.openPreview()
                after(0.9) {
                    pasteButtonOK("preview \(label)")
                    log(modeMenu() != nil ? "PASS preview \(label): Formatted/Plain ▾ menu next to Paste" : "FAIL preview \(label): menu missing")
                    checkKinds(app, window, then)
                }
            }
        }

        let startedPlain = prefs.pastePlainByDefault
        log("INFO paste mode at launch (saved setting): \(startedPlain ? "Plain" : "Formatted")")
        freshDoc("kinds") { app, window in
            checkKinds(app, window) {
                // Launch mode first, untouched (the saved setting after a restart), then live switches.
                runMode(startedPlain, label: "startup", setMode: false) {
                    runMode(!startedPlain, label: "switch1", setMode: true) {
                        runMode(startedPlain, label: "switch2", setMode: true) {
                            let kept = store.item(id: richClip.id)
                            log(kept?.rtfData == rtf && kept?.plainText == rich.string && store.items.map(\.id).filter(orderBefore.contains) == orderBefore
                                ? "PASS stored clip unchanged after switching modes (same RTF, text and order)"
                                : "FAIL stored clip or order changed")
                            cleanup()
                        }
                    }
                }
            }
        }
    }

    private static func findButton(titled title: String, pid: pid_t) -> AXUIElement? {
        func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 25 { return nil }
            if attr(el, kAXRoleAttribute) == kAXButtonRole,
               attr(el, kAXTitleAttribute) == title || attr(el, kAXDescriptionAttribute) == title { return el }
            for c in children(el) { if let hit = search(c, depth: depth + 1) { return hit } }
            return nil
        }
        return search(AXUIElementCreateApplication(pid), depth: 0)
    }

    private static func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Drop onto a list tab (inside Pastly)

    private static func listDropTest(panel: PanelController, marker: String, then next: @escaping () -> Void) {
        let store = ClipStore.shared
        let listName = "E2E List \(Int.random(in: 100...999))"
        let list = store.createList(name: listName)
        func cleanup() { store.deleteList(list.id); next() }
        panel.show(from: .hotkey)
        movePanelLeft(panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            panel.state.collection = .list(list.id)      // scroll its tab into view
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { panel.state.collection = .all }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let me = ProcessInfo.processInfo.processIdentifier
                guard let row = findElement(containing: marker, pid: me), let rowRect = frame(of: row),
                      let clipID = store.items.first(where: { $0.plainText?.contains(marker) == true })?.id else {
                    log("FAIL list drop: couldn't find the clip row"); cleanup(); return
                }
                DragProvider.lastDragTypes = nil
                DragProvider.lastDropNote = "no drop received"
                let start = CGPoint(x: rowRect.midX - rowRect.width * 0.25, y: rowRect.midY)
                // Start the drag, give the tab bar a moment to bring the list tabs into view, then aim.
                performDrag(from: start, to: { () -> CGPoint? in
                    guard let tab = findElement(containing: listName, pid: me), let r = frame(of: tab) else { return nil }
                    return CGPoint(x: r.midX, y: r.midY)
                }) { target in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        log("list drop diag: target \(target.map { "\($0)" } ?? "none"), panel \(panel.panel.frame), \(DragProvider.lastDropNote)")
                        let ok = store.lists.first { $0.id == list.id }?.itemIDs.contains(clipID) == true
                        log(ok ? "PASS list drop: clip added to the list by dragging onto its tab"
                               : "FAIL list drop: list items \(store.lists.first { $0.id == list.id }?.itemIDs ?? [])")
                        cleanup()
                    }
                }
            }
        }
    }

    /// Drag that picks its destination after the drag has started (UI may scroll in response).
    private static func performDrag(from a: CGPoint, to target: @escaping () -> CGPoint?, done: @escaping (CGPoint?) -> Void) {
        post(.mouseMoved, a)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            post(.leftMouseDown, a)
            var p = a
            func nudge(_ i: Int) {           // small moves to start the drag
                if i == 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard let b = target() else { post(.leftMouseUp, p); done(nil); return }
                        let steps = 30
                        let from = p
                        func step(_ j: Int) {
                            if j > steps {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { post(.leftMouseUp, b); done(b) }
                                return
                            }
                            let t = CGFloat(j) / CGFloat(steps)
                            p = CGPoint(x: from.x + (b.x - from.x) * t, y: from.y + (b.y - from.y) * t)
                            post(.leftMouseDragged, p)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { step(j + 1) }
                        }
                        step(1)
                    }
                    return
                }
                p = CGPoint(x: p.x + 3, y: p.y + 1)
                post(.leftMouseDragged, p)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { nudge(i + 1) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nudge(0) }
        }
    }

    // MARK: Mouse events (CG coordinates: origin top-left)

    private static func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: clicks)
        e?.flags = []          // a plain click — never inherit ⌘ from a synthetic ⌘C/⌘V just before
        e?.post(tap: .cghidEventTap)
    }

    static func performDrag(from a: CGPoint, to b: CGPoint, done: @escaping () -> Void) {
        post(.mouseMoved, a)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            post(.leftMouseDown, a)
            let steps = 40
            func step(_ i: Int) {
                if i > steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { post(.leftMouseUp, b); done() }
                    return
                }
                let t = CGFloat(i) / CGFloat(steps)
                post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { step(i + 1) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { step(1) }
        }
    }

    private static func doubleClick(at p: CGPoint) {
        post(.mouseMoved, p)
        post(.leftMouseDown, p, clicks: 1); post(.leftMouseUp, p, clicks: 1)
        post(.leftMouseDown, p, clicks: 2); post(.leftMouseUp, p, clicks: 2)
    }

    // MARK: Accessibility helpers

    private static func movePanelLeft(_ panel: PanelController) {
        let vf = NSScreen.main!.visibleFrame
        var f = panel.panel.frame
        f.origin = CGPoint(x: vf.minX + 60, y: vf.maxY - f.height - 60)
        panel.panel.setFrame(f, display: true)
    }

    private static func firstWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        // The test document's window (TextEdit may have other documents open).
        return windows.first { (attr($0, kAXTitleAttribute) ?? "").contains("pastly-e2e") } ?? windows.first
    }

    private static func setFrame(_ el: AXUIElement, origin: CGPoint, size: CGSize) {
        var o = origin, s = size
        if let v = AXValueCreate(.cgPoint, &o) { AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, v) }
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, v) }
    }

    /// Frame in CG (top-left origin) screen coordinates.
    private static func frame(of el: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success else { return [] }
        return v as? [AXUIElement] ?? []
    }

    private static func findElement(exactly text: String, pid: pid_t) -> AXUIElement? {
        func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 25 { return nil }
            for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] as [String] where attr(el, key) == text { return el }
            for c in children(el) { if let hit = search(c, depth: depth + 1) { return hit } }
            return nil
        }
        return search(AXUIElementCreateApplication(pid), depth: 0)
    }

    private static func findAllElements(exactly text: String, pid: pid_t) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func search(_ el: AXUIElement, depth: Int) {
            if depth > 25 { return }
            if [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { attr(el, $0 as String) == text }) { out.append(el) }
            for c in children(el) { search(c, depth: depth + 1) }
        }
        search(AXUIElementCreateApplication(pid), depth: 0)
        return out
    }

    private static func findElement(containing text: String, pid: pid_t) -> AXUIElement? {
        func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 25 { return nil }
            for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] as [String] {
                if let s = attr(el, key), s.contains(text) { return el }
            }
            for c in children(el) { if let hit = search(c, depth: depth + 1) { return hit } }
            return nil
        }
        return search(AXUIElementCreateApplication(pid), depth: 0)
    }

    private static func textArea(_ window: AXUIElement) -> AXUIElement? {
        func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > 12 { return nil }
            if attr(el, kAXRoleAttribute) == (kAXTextAreaRole as String) { return el }
            for c in children(el) { if let hit = search(c, depth: depth + 1) { return hit } }
            return nil
        }
        return search(window, depth: 0)
    }

    private static func textValue(_ window: AXUIElement) -> String? {
        textArea(window).flatMap { attr($0, kAXValueAttribute) }
    }

    private static func setText(_ window: AXUIElement, _ text: String) {
        guard let area = textArea(window) else { return }
        AXUIElementSetAttributeValue(area, kAXValueAttribute as CFString, text as CFString)
    }
}

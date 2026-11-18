import AppKit

/// Developer check: times the code paths the clipboard window runs on every redraw, keystroke,
/// copy and paste, on a temporary copy of a history folder (never the user's own data).
/// Usage: PASTLY_DEMO=1 Pastly --benchmark <history-folder>
enum Benchmark {
    static func run(source: String) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("PastlyBench-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tmp) }
        do { try fm.copyItem(at: URL(fileURLWithPath: source, isDirectory: true), to: tmp) } catch {
            print("Can't copy \(source): \(error)"); return false
        }

        func ms(_ block: () -> Void) -> Double {
            let t = CFAbsoluteTimeGetCurrent(); block(); return (CFAbsoluteTimeGetCurrent() - t) * 1000
        }
        func avg(_ n: Int, _ block: () -> Void) -> Double { (0..<n).map { _ in ms(block) }.reduce(0, +) / Double(n) }
        func f(_ v: Double) -> String { String(format: v < 10 ? "%.2f ms" : "%.0f ms", v) }

        var store: ClipStore!
        let load = ms { store = ClipStore(directory: tmp) }
        let state = PanelState(store: store)
        print("Benchmark: \(store.items.count) clips, \(store.smartLists.count) Smart Lists, \(store.lists.count) lists")
        print("  load history                         \(f(load))")

        // First window open after launch, once the background cache pre-build (if any) has had 3 s.
        do {
            let fresh = ClipStore(directory: tmp)
            let freshState = PanelState(store: fresh)
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            print("  first window open, 3 s after launch  \(f(ms { _ = freshState.tabs; _ = freshState.visibleItems }))")
        }

        // One panel redraw evaluates the tab bar and the visible list (several times per body pass).
        let tabsCold = ms { _ = state.tabs }
        let tabsWarm = avg(10) { _ = state.tabs }
        print("  tab bar (counts), first / repeated   \(f(tabsCold)) / \(f(tabsWarm))")
        let redraw = avg(10) { _ = state.tabs; _ = state.visibleItems; _ = state.visibleItems; _ = state.selectedItems }
        print("  one panel redraw (tabs + list)       \(f(redraw))")

        // Search while typing "invoice", one keystroke at a time (first pass builds the search index).
        var perKey: [Double] = []
        for i in 1...7 { let q = String("invoice".prefix(i)); perKey.append(ms { state.query = q; _ = state.tabs; _ = state.visibleItems }) }
        print("  typing 'invoice' (per key, redraw)   \(perKey.map { f($0) }.joined(separator: ", "))")
        let again = ms { state.query = "design"; _ = state.tabs; _ = state.visibleItems }
        print("  later query 'design' (redraw)        \(f(again))")
        state.query = ""

        // Switching tabs while searching.
        state.query = "client"
        var tabSwitch: [String] = []
        for c in state.allCollections.prefix(12) { tabSwitch.append(f(ms { state.collection = c; _ = state.tabs; _ = state.visibleItems })) }
        print("  switch tab while searching           \(tabSwitch.joined(separator: ", "))")
        state.query = ""; state.collection = .all

        // Selection / preview: changing the selection redraws the panel.
        let ids = store.items.prefix(20).map(\.id)
        let select = avg(20) { state.select(ids.randomElement()); _ = state.tabs; _ = state.visibleItems }
        print("  move selection / open preview        \(f(select))")

        // Capture: a new text clip, then a large image (4000×3000).
        let text = ms { store.ingest(ClipItemParser.parseText("Benchmark clip \(UUID())", rtf: nil, html: nil, trimWhitespace: false),
                                     bundleID: nil, appName: "Bench"); _ = state.tabs; _ = state.visibleItems }
        print("  capture text clip (+ redraw)         \(f(text))")
        if let big = bigImage(), let parsed = ClipItemParser.parseImage(big, isPNG: true) {
            let image = ms { store.ingest(parsed, bundleID: nil, appName: "Bench"); _ = state.tabs; _ = state.visibleItems }
            print("  capture 4000×3000 image (+ redraw)   \(f(image))")
        }
        // Paste bookkeeping (count the use) + redraw.
        let paste = avg(10) { if let id = store.items.dropFirst(5).first?.id { store.markUsed(id, pasted: true) }; _ = state.tabs; _ = state.visibleItems }
        print("  paste bookkeeping (+ redraw)         \(f(paste))")

        // Row thumbnail of a large stored image (what scrolling a new image row costs).
        if let name = store.items.first(where: { $0.type == .image && $0.imageWidth >= 4000 })?.imagePath {
            let thumb = ms { _ = store.images.thumbnail(for: name) }
            print("  row thumbnail, large image (sync)    \(f(thumb))")
        }
        // Cache memory: load the row thumbnail and the preview of every image clip (like scrolling the whole
        // history and previewing each image), then compare the process footprint.
        let imageNames = store.items.compactMap(\.imagePath)
        if !imageNames.isEmpty {
            let before = footprintMB()
            let t = ms {
                let group = DispatchGroup()
                for name in imageNames {
                    for px in [160, ItemPreviewPixels.value] {
                        group.enter()
                        Task.detached { _ = await store.images.loadThumbnail(name: name, file: nil, maxPixel: px); group.leave() }
                    }
                }
                group.wait()
            }
            print("  cache stress: \(imageNames.count) images × (row + preview) in \(f(t)); footprint \(before) MB → \(footprintMB()) MB")
        }
        return true
    }

    /// Physical memory footprint of this process, in MB (what Activity Monitor's "Memory" shows).
    private static func footprintMB() -> Int {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    /// A 4000×3000 PNG with real pixel content, made in memory.
    private static func bigImage() -> Data? {
        let w = 4000, h = 3000
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for i in 0..<40 {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
            ctx.fill(CGRect(x: i * 100, y: (i * 73) % h, width: 300, height: 900))
        }
        guard let cg = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// Preview decode size, shared with the preview view.
enum ItemPreviewPixels { static let value = 1600 }

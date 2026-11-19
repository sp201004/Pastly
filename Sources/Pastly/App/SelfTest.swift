import AppKit
import UniformTypeIdentifiers

/// Runs core-logic checks without touching the user's real clipboard or history.
/// Usage: Pastly --self-test
enum SelfTest {
    private static var failures = 0

    private static func check(_ cond: Bool, _ name: String) {
        print(cond ? "  ✅ \(name)" : "  ❌ \(name)")
        if !cond { failures += 1 }
    }

    static func run() -> Bool {
        print("Pastly self-test")

        print("Hashing / normalization")
        check(ContentHasher.textHash("caf\u{00E9}", trimWhitespace: false) == ContentHasher.textHash("cafe\u{0301}", trimWhitespace: false),
              "Unicode NFC: composed == decomposed")
        check(ContentHasher.textHash("a\r\nb", trimWhitespace: false) == ContentHasher.textHash("a\nb", trimWhitespace: false),
              "CRLF == LF")
        check(ContentHasher.textHash("foo", trimWhitespace: false) != ContentHasher.textHash("foo ", trimWhitespace: false),
              "Whitespace kept distinct by default")
        check(ContentHasher.textHash("foo", trimWhitespace: true) == ContentHasher.textHash("foo ", trimWhitespace: true),
              "Whitespace trimmed when enabled")
        let white = ["#fff", "#FFFFFF", "#ffffffff", "rgb(255,255,255)", "rgba(255, 255, 255, 1)"].compactMap(ColorParser.parse)
        check(white.count == 5 && Set(white) == ["#FFFFFF"], "Color forms normalize to #FFFFFF")
        check(ColorParser.parse("#FFFFFF80") == "#FFFFFF80", "Alpha kept when not opaque")
        check(ColorParser.parse("123456") == nil && ColorParser.parse("#12345") == nil, "Non-colors rejected")
        check(ContentHasher.urlHash("HTTPS://Example.com/") == ContentHasher.urlHash("https://example.com"), "URL scheme/host/slash normalized")
        check(ClipItemParser.parseText("https://apple.com", rtf: nil, html: nil, trimWhitespace: false).type == .url, "URL detected")
        check(ClipItemParser.parseText("hello world https://apple.com", rtf: nil, html: nil, trimWhitespace: false).type == .text, "Sentence with URL is text")
        check(ContentHasher.textHash("abc", trimWhitespace: false) != ContentHasher.urlHash("abc"), "Different UTIs give different hashes")

        print("Image pixel hashing")
        if let cg = makeTestImage() {
            let rep = NSBitmapImageRep(cgImage: cg)
            let png = rep.representation(using: .png, properties: [:])!
            let tiff = rep.representation(using: .tiff, properties: [:])!
            let a = ClipItemParser.parseImage(png, isPNG: true)
            let b = ClipItemParser.parseImage(tiff, isPNG: false)
            check(a != nil && a?.contentHash == b?.contentHash, "PNG and TIFF of same image → same hash")
        } else {
            check(false, "Create test image")
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PastlySelfTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = ClipStore(directory: tmp)

        print("Dedup upsert")
        let p = ClipItemParser.parseText("Hello dedup", rtf: nil, html: nil, trimWhitespace: false)
        let first = store.ingest(p, bundleID: "com.apple.Notes", appName: "Notes")
        store.ingest(ClipItemParser.parseText("other", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
        let second = store.ingest(p, bundleID: "com.apple.Safari", appName: "Safari")
        check(store.items.count == 2, "Same text twice → one row (2 rows total)")
        check(first.id == second.id && second.useCount == 2, "Existing row reused, useCount = 2")
        check(store.items.first?.id == first.id, "Re-copied item moved to top")
        check(store.items.first?.sourceAppBundleID == "com.apple.Safari", "Source app updated to latest")
        let reloaded = ClipStore(directory: tmp)
        check(reloaded.items.count == 2 && reloaded.items.first?.useCount == 2, "Persisted to SQLite and reloaded")

        print("Lists, pins, limits")
        let list = store.createList(name: "Snippets")
        store.add(first.id, toList: list.id)
        check(store.filtered(collection: .list(list.id), query: "").count == 1, "Item added to list")
        check(store.filtered(collection: .all, query: "DEDUP").count == 1, "Case-insensitive search")
        if case .conflict = store.updateText(store.items.last!.id, text: "Hello dedup", title: nil) {
            check(true, "Edit that duplicates another item reports conflict")
        } else {
            check(false, "Edit that duplicates another item reports conflict")
        }

        print("Self-capture protection")
        let pb = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let monitor = ClipboardMonitor(pasteboard: pb)
        monitor.isPaused = { false }
        monitor.ignoredApps = { [] }
        var captured: [RawClip] = []
        monitor.onCapture = { raw, _, _ in captured.append(raw) }

        pb.clearContents(); pb.setString("external copy", forType: .string); monitor.tick()
        check(captured.count == 1, "External copy is captured")

        let expected = PasteService.shared.write(first, images: store.images, to: pb)
        check(pb.changeCount == expected, "Write keeps the expected changeCount")
        monitor.tick()
        check(captured.count == 1, "PasteService write is NOT captured")

        // Registry alone (no marker): simulate a write registered but without marker type.
        let c = pb.clearContents()
        SelfWriteRegistry.shared.register(c, pasteboard: pb.name)
        pb.setString("registered only", forType: .string)
        monitor.tick()
        check(captured.count == 1, "Registered changeCount skipped even without marker")

        pb.clearContents()
        pb.setString("secret", forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        monitor.tick()
        check(captured.count == 1, "Concealed (password) content ignored")

        pb.clearContents(); pb.setString("another external copy", forType: .string); monitor.tick()
        check(captured.count == 2, "Next external copy captured again")

        print("Backup round-trip")
        let backupURL = tmp.appendingPathComponent("backup.pastly")
        do {
            try BackupService.export(store, to: backupURL)
            let store2 = ClipStore(directory: tmp.appendingPathComponent("second"))
            let r = try BackupService.importBackup(from: backupURL, into: store2)
            check(r.added == store.items.count && store2.lists.first?.itemIDs.count == 1, "Export → import restores items and lists")
            let r2 = try BackupService.importBackup(from: backupURL, into: store2)
            check(r2.added == 0 && r2.skipped == store.items.count, "Re-import skips duplicates")
        } catch {
            check(false, "Backup round-trip (\(error))")
        }

        print("Selection, multi-delete, undo")
        do {
            let dir = tmp.appendingPathComponent("selection")
            let st = ClipStore(directory: dir)
            for n in 1...5 {
                st.ingest(ClipItemParser.parseText("item \(n)", rtf: nil, html: nil, trimWhitespace: false),
                          bundleID: nil, appName: nil, date: Date().addingTimeInterval(Double(n)))
            }
            let ps = PanelState(store: st)
            ps.selectFirst()
            check(ps.selectedItems.map(\.plainText!) == ["item 5"], "Starts with newest item selected")
            ps.moveSelection(2)
            check(ps.selectedItems.map(\.plainText!) == ["item 3"], "Arrow keys move selection")
            ps.moveSelection(1, extend: true)
            check(ps.selectedItems.map(\.plainText!) == ["item 3", "item 2"], "⇧↓ extends selection")
            ps.select(st.items[0].id); ps.extendSelection(to: st.items[3].id)
            check(ps.selectedIDs.count == 4, "⇧-click selects a range")
            ps.toggleSelection(st.items[1].id)
            check(ps.selectedIDs.count == 3 && !ps.selectedIDs.contains(st.items[1].id), "⌘-click removes one item")
            ps.selectAll()
            check(ps.selectedIDs.count == 5, "⌘A selects all")
            ps.select(st.items[2].id)
            let chosen = ps.selectedItems.first?.plainText
            st.ingest(ClipItemParser.parseText("new copy while open", rtf: nil, html: nil, trimWhitespace: false),
                      bundleID: nil, appName: nil)
            ps.validateSelection()
            check(ps.selectedItems.first?.plainText == chosen, "New copy does not steal the user's selection")
            ps.selectAll()
            let n = st.deleteUndoable(ps.selectedItems.map(\.id))
            check(n == 6 && st.items.isEmpty, "Delete removes every selected item")
            let restored = st.undoDelete()
            check(restored.count == 6 && st.items.count == 6, "⌘Z restores all deleted items")
            check(ClipStore(directory: dir).items.count == 6, "Restored items are saved to disk")
            let combined = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.multi.\(UUID().uuidString)"))
            PasteService.shared.write(Array(st.items.prefix(2)), images: st.images, to: combined)
            let got = combined.string(forType: .string) ?? "nil"; let want = st.items.prefix(2).compactMap(\.plainText).joined(separator: "\n")
            check(got == want && got.contains("\n"), "Multiple text items paste as one text, in order (got: \(got.debugDescription))")
            combined.releaseGlobally()
        }

        print("Code detection & Smart Lists")
        do {
            let swift = "extension Array where Element: Hashable {\n    func uniqued() -> [Element] {\n        var seen = Set<Element>()\n        return filter { seen.insert($0).inserted }\n    }\n}"
            check(CodeDetector.isCode(swift), "Swift snippet detected as code")
            check(CodeDetector.isCode("{\"name\": \"Pastly\", \"local\": true}"), "JSON detected as code")
            check(!CodeDetector.isCode("Thanks for the update. I will review it tomorrow. Let me know if anything changes."), "Prose is not code")
            check(!CodeDetector.isCode("https://example.com"), "URL is not code")

            let dir = tmp.appendingPathComponent("smart")
            let st = ClipStore(directory: dir)
            check(st.smartLists.map(\.name) == ["Today", "This Week"], "Default Smart Lists created by migration")
            let old = st.ingest(ClipItemParser.parseText("old note", rtf: nil, html: nil, trimWhitespace: false),
                                bundleID: "com.apple.Notes", appName: "Notes", date: Date().addingTimeInterval(-10 * 86_400))
            st.ingest(ClipItemParser.parseText(swift, rtf: nil, html: nil, trimWhitespace: false), bundleID: "com.apple.dt.Xcode", appName: "Xcode")
            st.ingest(ClipItemParser.parseText("https://swift.org", rtf: nil, html: nil, trimWhitespace: false), bundleID: "com.apple.Safari", appName: "Safari")
            check(st.filtered(collection: .code, query: "").count == 1, "Code tab shows only code")
            let xcode = st.createSmartList(name: "From Xcode", rules: [SmartRule(field: .app, op: .is, value: "com.apple.dt.Xcode")])
            check(st.filtered(collection: .smart(xcode.id), query: "").count == 1, "Smart List: app rule")
            let week = st.smartLists.first { $0.name == "This Week" }!
            check(st.count(in: week) == 2, "Smart List: age rule excludes 10-day-old clip")
            var any = SmartList(name: "Links or Notes", matchAll: false, rules: [
                SmartRule(field: .type, op: .is, value: "url"), SmartRule(field: .app, op: .is, value: "Notes")])
            check(st.items.filter { any.matches($0) }.count == 2, "Smart List: match any")
            any.matchAll = true
            check(st.items.filter { any.matches($0) }.isEmpty, "Smart List: match all")
            check(SmartList(name: "Code", rules: [SmartRule(field: .type, op: .is, value: SmartRule.codeKind)]).matches(st.items.first { st.isCode($0) }!),
                  "Smart List: kind = code")
            st.markUsed(old.id, pasted: true)
            let reopened = ClipStore(directory: dir)
            check(reopened.item(id: old.id)?.pasteCount == 1, "Paste count saved (database v2)")
            check(reopened.smartLists.contains { $0.name == "From Xcode" }, "Smart Lists saved to disk")
            let ps = PanelState(store: reopened)
            check(ps.tabs.contains { $0.collection == .code } && ps.tabs.contains { $0.title == "From Xcode" },
                  "Tabs include Code and Smart Lists")
            check(!ps.tabs.contains { $0.collection == .type(.image) }, "Empty kind tabs are hidden")
        }

        print("History order when pasting an old item")
        do {
            let dir = tmp.appendingPathComponent("order")
            let st = ClipStore(directory: dir)
            for (n, name) in ["Old item C", "Old item B", "Old item A", "Latest copied text"].enumerated() {
                st.ingest(ClipItemParser.parseText(name, rtf: nil, html: nil, trimWhitespace: false),
                          bundleID: nil, appName: nil, date: Date().addingTimeInterval(Double(n - 10)))
            }
            let orderBefore = st.items.map(\.id)
            let datesBefore = st.items.map(\.lastUsedAt)
            let ps = PanelState(store: st)
            let b = st.items[2]
            ps.clickRow(b.id, opensPreview: false)
            check(ps.selectedID == b.id && ps.selectedIDs == [b.id], "One click selects only that item")
            check(st.items.map(\.id) == orderBefore, "Selecting doesn't change the history order")
            ps.clickRow(st.items[1].id, opensPreview: false)
            check(ps.selectedIDs == [st.items[1].id], "Clicking another item moves the selection")
            ps.clickRow(b.id, opensPreview: false)

            // ⌘V / ↩ path: write the selection to a pasteboard, then count the paste.
            let pb2 = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.order.\(UUID().uuidString)"))
            defer { pb2.releaseGlobally() }
            let mon = ClipboardMonitor(pasteboard: pb2)
            mon.isPaused = { false }; mon.ignoredApps = { [] }
            var caught = 0
            mon.onCapture = { _, _, _ in caught += 1 }
            PasteService.shared.write(ps.selectedItems, images: st.images, to: pb2)
            for item in ps.selectedItems { st.markUsed(item.id, pasted: true) }
            mon.tick()
            check(pb2.string(forType: .string) == "Old item B", "The selected old item's content is what gets pasted")
            check(caught == 0 && st.items.count == 4, "Pasting it creates no new or duplicate entry")
            check(st.items.map(\.id) == orderBefore, "Pasting an old item keeps the history order")
            check(st.items.map(\.lastUsedAt) == datesBefore, "Pasting an old item keeps its timestamp")
            check(st.items.first?.plainText == "Latest copied text", "Latest copied item stays on top")
            check(st.item(id: b.id)?.pasteCount == 1, "The paste is still counted")
            check(ClipStore(directory: dir).items.map(\.id) == orderBefore, "Order is the same after relaunch")
            // Selected / pasted clip vs. latest copy (run on a private pasteboard; the saved value is restored).
            let service = PasteService.shared
            let savedBoard = service.pasteboard
            let savedChoice = UserDefaults.standard.data(forKey: "lastClipboardChoice")
            service.pasteboard = pb2
            defer {
                service.pasteboard = savedBoard
                UserDefaults.standard.set(savedChoice, forKey: "lastClipboardChoice")
            }
            var userSelections = 0
            ps.onUserSelection = { userSelections += 1 }
            ps.reset()
            check(userSelections == 0, "Opening the panel doesn't count as a user selection")
            ps.clickRow(b.id, opensPreview: false); ps.moveSelection(1); ps.moveSelection(-1)
            check(userSelections == 3, "Clicks and ↑/↓ report a user selection")
            service.write(ps.selectedItems, images: st.images)
            check(service.currentChoiceIDs == [b.id], "The selected clip is what ⌘V pastes now")
            check(pb2.string(forType: .string) == "Old item B", "…and it's on the clipboard")
            ps.reset()
            check(ps.selectedID == b.id && ps.selectedIDs == [b.id], "Reopening restores the selected/pasted clip, not the latest")
            check(st.items.first?.plainText == "Latest copied text" && st.items.map(\.id) == orderBefore,
                  "Latest copied item and order unchanged by the selection")
            pb2.clearContents(); pb2.setString("copied elsewhere", forType: .string)
            check(service.currentChoiceIDs == nil, "A real copy elsewhere replaces Pastly's choice")
            ps.reset()
            check(ps.selectedID == st.items.first?.id, "With no restorable selection, the latest clip is selected")
            ps.onUserSelection = nil

            st.ingest(ClipItemParser.parseText("Old item B", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            check(st.items.first?.id == b.id && st.items.count == 4, "A genuine new copy of the same text moves it to the top")
        }

        print("One paste mode for every paste path")
        do {
            let st = ClipStore(directory: tmp.appendingPathComponent("pastemode"))
            let rich = NSMutableAttributedString(string: "Bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            rich.append(NSAttributedString(string: " link", attributes: [.link: URL(string: "https://example.com")!]))
            let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!
            let clip = st.ingest(ClipItemParser.parseText(rich.string, rtf: rtf, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            let prefs = Preferences.shared
            let saved = UserDefaults.standard.object(forKey: "pastePlainByDefault")
            defer {
                if let saved { UserDefaults.standard.set(saved, forKey: "pastePlainByDefault") } else { UserDefaults.standard.removeObject(forKey: "pastePlainByDefault") }
                prefs.pastePlainByDefault = UserDefaults.standard.bool(forKey: "pastePlainByDefault")
            }
            let pb = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.mode.\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            func types(_ items: [NSPasteboardItem]) -> Set<String> { Set(items.flatMap { $0.types.map(\.rawValue) }) }
            for plain in [true, false, true] {
                prefs.pastePlainByDefault = plain
                let drag = types(DragProvider.pasteboardItems(for: [clip], store: st))
                PasteService.shared.write([clip], plainText: prefs.pastePlainByDefault, images: st.images, to: pb)
                let board = Set((pb.types ?? []).map(\.rawValue))
                if plain {
                    check(!drag.contains("public.rtf") && drag.contains("public.utf8-plain-text"), "Plain mode: a drag carries plain text only")
                    check(!board.contains("public.rtf") && pb.string(forType: .string) == "Bold link", "Plain mode: paste writes the same text, no formatting")
                } else {
                    check(drag.contains("public.rtf"), "Formatted mode: a drag carries the RTF")
                    check(board.contains("public.rtf"), "Formatted mode: paste writes the RTF")
                }
            }
            check(st.item(id: clip.id)?.rtfData == rtf && st.item(id: clip.id)?.plainText == "Bold link",
                  "Switching modes never changes the stored clip")
        }

        print("Preview toggle")
        do {
            let st = ClipStore(directory: tmp.appendingPathComponent("preview"))
            for n in 1...3 {
                st.ingest(ClipItemParser.parseText("preview \(n)", rtf: nil, html: nil, trimWhitespace: false),
                          bundleID: nil, appName: nil, date: Date().addingTimeInterval(Double(n)))
            }
            let ps = PanelState(store: st)
            ps.selectFirst()
            let first = ps.selectedID!
            ps.togglePreview()
            check(ps.previewItem?.id == first, "Space opens the selected item's preview")
            ps.togglePreview()
            check(ps.previewItem == nil, "Space again closes it")
            ps.togglePreview(); ps.togglePreview(); ps.togglePreview()
            check(ps.previewItem?.id == first, "Space keeps toggling consistently")
            ps.closePreview()


            ps.closePreview()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            check(!ps.isPreviewVisible, "Preview only opens on purpose (click or Space)")
            ps.moveSelection(1); ps.moveSelection(1); ps.moveSelection(-1)
            check(!ps.isPreviewVisible, "Arrow keys change selection only, preview stays closed")
            ps.openPreview()
            ps.moveSelection(1)
            check(ps.previewItem?.id == ps.selectedID, "Open preview follows the selection")
            ps.closePreview()

            let second = st.items[1].id
            ps.clickRow(second)
            check(ps.selectedID == second && ps.previewItem?.id == second, "Click selects an item and opens its preview")
            ps.clickRow(second)
            check(ps.previewItem == nil && ps.selectedID == second, "Clicking the same item closes the preview, keeps selection")
            ps.clickRow(second)
            check(ps.previewItem?.id == second, "Clicking it again reopens")
            ps.closePreview()
            let firstClip = st.items[0].id
            ps.clickRow(firstClip, opensPreview: false)
            check(ps.selectedID == firstClip && !ps.isPreviewVisible, "Single-Click to Preview off: a click only selects")
            ps.clickRow(firstClip, opensPreview: false)
            check(ps.selectedID == firstClip && !ps.isPreviewVisible, "Single-Click to Preview off: a second click doesn't open it either")
            ps.togglePreview()
            check(ps.previewItem?.id == firstClip, "Single-Click to Preview off: Space still opens the preview")
            ps.clickRow(second, opensPreview: false)
            check(ps.previewItem?.id == second, "Single-Click to Preview off: an open preview follows the clicked item")
            ps.togglePreview()
            check(!ps.isPreviewVisible, "Single-Click to Preview off: Space closes the preview")
            check(UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)["singleClickPreview"] as? Bool == true, "Click Behavior defaults to Single Click to Preview")

            // Click Behavior setting drives the real click handler, live (no restart).
            let prefs = Preferences.shared
            let savedMode = UserDefaults.standard.object(forKey: "singleClickPreview")
            ps.closePreview()
            prefs.singleClickPreview = false
            ps.clickRow(firstClip)
            check(ps.selectedID == firstClip && !ps.isPreviewVisible, "Click Behavior = Select: a click selects, no preview")
            prefs.singleClickPreview = true
            ps.clickRow(second)
            check(ps.selectedID == second && ps.previewItem?.id == second, "Click Behavior = Preview: switching applies immediately")
            check(UserDefaults.standard.bool(forKey: "singleClickPreview"), "Click Behavior is saved to preferences")
            if let savedMode { UserDefaults.standard.set(savedMode, forKey: "singleClickPreview") }
            else { UserDefaults.standard.removeObject(forKey: "singleClickPreview") }
            prefs.singleClickPreview = UserDefaults.standard.bool(forKey: "singleClickPreview")
            ps.closePreview()
            ps.collection = .all
            ps.query = ""
            ps.select(second)
            ps.openPreview()
            let before = (ps.selectedIDs, ps.collection, ps.query)
            ps.closePreview()
            check(ps.selectedIDs == before.0 && ps.collection == before.1 && ps.query == before.2,
                  "Closing preview keeps list, selection and search unchanged")
            ps.selectAll()
            ps.togglePreview()
            check(ps.selectedIDs.count == 3 && ps.isPreviewVisible, "Space with multi-selection previews without losing the selection")
            ps.togglePreview()
        }

        print("Settings: privacy, lists, backup, shortcuts, about")
        do {
            check(SensitiveDetector.isCardNumber("4242 4242 4242 4242"), "Card number (valid Luhn) detected")
            check(!SensitiveDetector.isCardNumber("4242 4242 4242 4241"), "Invalid Luhn is not a card")
            check(!SensitiveDetector.isCardNumber("Order 1234567890123"), "Text with digits is not a card")
            check(SensitiveDetector.isOneTimeCode("482 913") && SensitiveDetector.isOneTimeCode("7731"), "One-time codes detected")
            check(!SensitiveDetector.isOneTimeCode("Room 4021"), "Text is not a one-time code")
            // Fake keys are assembled at run time so secret scanners don't flag this file.
            let fakeGitHubToken = ["gh", "p_"].joined() + String(repeating: "a", count: 36)
            let fakeAWSKey = ["AK", "IA"].joined() + "IOSFODNN7" + "EXAMPLE"          // AWS's documented example key
            check(SensitiveDetector.containsSecret("token: " + fakeGitHubToken), "GitHub token detected")
            check(SensitiveDetector.containsSecret(fakeAWSKey), "AWS key detected")
            check(!SensitiveDetector.containsSecret("just a normal sentence"), "Normal text has no secret")
            let opts = SensitiveDetector.Options(cards: true, codes: false, secrets: true)
            let onlyCards = CaptureFilter(excludedTypes: [], regexRules: [], keywordRules: [], sensitive: opts)
            check(onlyCards.reason(type: .text, text: "4242424242424242") != nil && onlyCards.reason(type: .text, text: "123456") == nil,
                  "Skips only the enabled kinds")

            let dir = tmp.appendingPathComponent("settings")
            let st = ClipStore(directory: dir)
            check(SecureStorage.isPrivate(dir), "History folder and files are private to this account (0700/0600)")
            let a = st.ingest(ClipItemParser.parseText("alpha", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            let b = st.ingest(ClipItemParser.parseText("beta", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            let work = st.createList(name: "Work"), home = st.createList(name: "Home")
            st.add(a.id, toList: work.id); st.add(b.id, toList: work.id)
            st.move([a.id], fromList: work.id, toList: home.id)
            check(st.lists.first { $0.id == work.id }?.itemIDs == [b.id] && st.lists.first { $0.id == home.id }?.itemIDs == [a.id],
                  "Move item between lists")
            st.moveLists(fromOffsets: IndexSet(integer: 1), toOffset: 0)
            check(st.lists.map(\.name) == ["Home", "Work"], "Reorder lists")
            check(ClipStore(directory: dir).lists.map(\.name) == ["Home", "Work"], "List order saved")
            st.add(a.id, toList: work.id)
            st.moveItem(a.id, inList: work.id, by: 1)
            check(st.lists.first { $0.id == work.id }?.itemIDs == [b.id, a.id], "Reorder items inside a list")
            st.setListColor(home.id, "green")
            check(ClipStore(directory: dir).lists.first { $0.id == home.id }?.color == "green", "List color saved")

            let backupDir = tmp.appendingPathComponent("backups")
            for _ in 0..<3 { try AutoBackup.backupNow(store: st, to: backupDir, keep: 2); Thread.sleep(forTimeInterval: 1.05) }
            let entries = AutoBackup.existingBackups(in: backupDir)
            check(entries.count == 2, "Automatic backup keeps only the latest N")
            let restoreInto = ClipStore(directory: tmp.appendingPathComponent("restore"))
            restoreInto.ingest(ClipItemParser.parseText("will be replaced", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            let merged = try AutoBackup.restore(from: entries[0].url, replace: false, into: restoreInto)
            check(merged.added == 2 && restoreInto.items.count == 3, "Restore (merge) adds backup items")
            _ = try AutoBackup.restore(from: entries[0].url, replace: true, into: restoreInto)
            check(restoreInto.items.count == 2 && !restoreInto.items.contains { $0.plainText == "will be replaced" },
                  "Restore (replace) swaps in the backup")
            let bogus = tmp.appendingPathComponent("bogus.pastly")
            try Data("not json".utf8).write(to: bogus)
            check((try? AutoBackup.restore(from: bogus, replace: true, into: restoreInto)) == nil && restoreInto.items.count == 2,
                  "Bad backup file is rejected without touching history")

            check(HotKeyManager.reservedReason(keyCode: 8, modifiers: 256) != nil, "⌘C can't be a global shortcut")
            check(HotKeyManager.reservedReason(keyCode: 49, modifiers: 256) != nil, "⌘Space can't be a global shortcut")
            check(HotKeyManager.reservedReason(keyCode: 9, modifiers: 768) == nil, "⇧⌘V is allowed")
            check(UpdateChecker.isNewer("v0.10.0", than: "0.9.2") && !UpdateChecker.isNewer("0.5.0", than: "0.5.0")
                  && !UpdateChecker.isNewer("0.4.9", than: "0.5"), "Version comparison")
            check(!AppInfo.changelog.isEmpty && AppInfo.license.contains("MIT"), "License and changelog available")
            check(Preferences.accentChoices.allSatisfy { Preferences.accentNSColor(named: $0).alphaComponent > 0 }, "Accent colors resolve")
        } catch {
            check(false, "Settings checks threw \(error)")
        }

        print("Drag & drop, Smart List rules, exclusions, colors, editing")
        do {
            // Exclusion rules
            let f = CaptureFilter(excludedTypes: ["image", SmartRule.codeKind], regexRules: [#"^SECRET-\d+$"#],
                                  keywordRules: [KeywordRule(keyword: "confidential"), KeywordRule(keyword: "draft", enabled: false),
                                                 KeywordRule(keyword: "ACME", matchCase: true)],
                                  sensitive: .init(cards: false, codes: false, secrets: false))
            check(f.reason(type: .image, text: nil) != nil, "Excluded kind (images) is skipped")
            check(f.reason(type: .text, text: "This is CONFIDENTIAL info") != nil, "Keyword rule skips (case-insensitive)")
            check(f.reason(type: .text, text: "draft email") == nil, "Disabled keyword rule is ignored")
            check(f.reason(type: .text, text: "acme corp") == nil && f.reason(type: .text, text: "ACME corp") != nil, "Match-case keyword")
            check(f.reason(type: .text, text: "SECRET-42") != nil && f.reason(type: .text, text: "secret-42 x") == nil, "Regex rule")
            check(f.reason(for: ClipItemParser.parseText("func a() {\n    return 1;\n}\nlet x = 2;", rtf: nil, html: nil, trimWhitespace: false)) != nil,
                  "Excluding code skips code clips")
            check(f.reason(type: .text, text: "Lunch at noon?") == nil, "Normal text is saved")

            // Smart Lists: domain, pattern, date
            let dir = tmp.appendingPathComponent("pn")
            let st = ClipStore(directory: dir)
            let link = st.ingest(ClipItemParser.parseText("https://developer.apple.com/documentation", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            let mention = st.ingest(ClipItemParser.parseText("see https://www.github.com/x/y for details", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            let ticket = st.ingest(ClipItemParser.parseText("ABC-1234", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil,
                                   date: Date().addingTimeInterval(-40 * 86_400))
            let apple = SmartRule(field: .domain, op: .is, value: "apple.com")
            check(apple.matches(link) && !apple.matches(mention), "Domain rule matches subdomains")
            check(SmartRule(field: .domain, op: .is, value: "github.com").matches(mention), "Domain rule finds links inside text")
            check(SmartRule(field: .pattern, op: .matches, value: #"^[A-Z]{3}-\d+$"#).matches(ticket), "Pattern rule")
            let cutoff = SmartRule.dayFormatter.string(from: Date().addingTimeInterval(-10 * 86_400))
            check(!SmartRule(field: .date, op: .onOrAfter, value: cutoff).matches(ticket)
                  && SmartRule(field: .date, op: .before, value: cutoff).matches(ticket), "Date rule")
            let combo = st.createSmartList(name: "Links or tickets", rules: [SmartRule(field: .type, op: .is, value: "url"),
                                           SmartRule(field: .pattern, op: .matches, value: #"^[A-Z]{3}-\d+$"#)], matchAll: false)
            check(st.filtered(collection: .smart(combo.id), query: "").count == 2, "OR rule combination")
            st.ingest(ClipItemParser.parseText("https://swift.org", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            check(st.filtered(collection: .smart(combo.id), query: "").count == 3, "Smart List updates when new clips arrive")

            // Color recognition
            check(ColorParser.findAll(in: "Brand: #5B5CF0, accent #fff and #14b8a680; not &#123; or id#ABC") == ["#5B5CF0", "#FFFFFF", "#14B8A680"],
                  "Finds #RGB/#RRGGBB/#RRGGBBAA inside text, skips non-colors")
            let palette = st.ingest(ClipItemParser.parseText("primary #FF0000 secondary #00FF00", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            check(st.embeddedColors(palette) == ["#FF0000", "#00FF00"], "Clip shows its colors")

            // Drag & drop reordering / moving
            let list = st.createList(name: "Board")
            st.moveItems([link.id, mention.id, ticket.id], inList: list.id, before: nil)
            check(st.lists.first { $0.id == list.id }?.itemIDs == [link.id, mention.id, ticket.id], "Dropping history clips into a list adds them")
            st.moveItems([ticket.id], inList: list.id, before: link.id)
            check(st.lists.first { $0.id == list.id }?.itemIDs == [ticket.id, link.id, mention.id], "Drag to reorder inside a list")
            st.moveItems([link.id, mention.id], inList: list.id, before: ticket.id)
            check(st.lists.first { $0.id == list.id }?.itemIDs == [link.id, mention.id, ticket.id], "Drag several clips at once")
            check(ClipStore(directory: dir).lists.first { $0.id == list.id }?.itemIDs == [link.id, mention.id, ticket.id], "Order saved")

            let dragItems = DragProvider.pasteboardItems(for: [link, ticket], store: st)
            let idsData = dragItems.first?.data(forType: NSPasteboard.PasteboardType(DragProvider.clipIDsType.identifier))
            check(idsData.flatMap { String(data: $0, encoding: .utf8) } == "\(link.id)\n\(ticket.id)", "Drag carries the selected clip IDs")
            check(dragItems.count == 2 && dragItems[0].types.contains(.URL), "Drag still gives other apps the link (one item per clip)")

            // Save as New keeps the original
            let ps = PanelState(store: st)
            ps.beginEdit(ticket)
            ps.editText = "ABC-1234 (fixed)"
            let copy = ps.saveEditAsNew()
            check(copy != nil && st.item(id: ticket.id)?.plainText == "ABC-1234" && copy?.plainText == "ABC-1234 (fixed)",
                  "Save as New keeps the original clip")
        }

        print("Images copied from Finder and other apps")
        do {
            let dir = tmp.appendingPathComponent("finder-images")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let cg = NSBitmapImageRep(data: DemoData.makeArtwork(width: 320, height: 180))!.cgImage!
            func write(_ name: String, _ type: UTType) -> URL {
                let url = dir.appendingPathComponent(name)
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, nil)
                    CGImageDestinationFinalize(dest)
                }
                return url
            }
            let files: [(URL, String)] = [(write("photo.png", .png), "png"), (write("photo.jpg", .jpeg), "jpg"),
                                          (write("photo.heic", .heic), "heic"), (write("anim.gif", .gif), "gif"),
                                          (write("scan.tiff", .tiff), "tiff")]
            let pdf = dir.appendingPathComponent("report.pdf")
            let pdfData = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 200, height: 200)
            if let consumer = CGDataConsumer(data: pdfData), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) {
                ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
            }
            pdfData.write(to: pdf, atomically: true)
            let doc = dir.appendingPathComponent("notes.txt")
            try? "hello".write(to: doc, atomically: true, encoding: .utf8)

            /// What Finder puts on the pasteboard for ⌘C on a file: file URL, its name as text, its icon as TIFF.
            func finderCopy(_ url: URL) -> RawClip {
                let pb = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.finder.\(UUID().uuidString)"))
                defer { pb.releaseGlobally() }
                pb.clearContents()
                let item = NSPasteboardItem()
                item.setString(url.absoluteString, forType: .fileURL)
                item.setString(url.lastPathComponent, forType: .string)
                if let icon = NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation { item.setData(icon, forType: .tiff) }
                pb.writeObjects([item])
                return RawClip.read(from: pb, types: Set((pb.types ?? []).map(\.rawValue)))
            }

            let st = ClipStore(directory: tmp.appendingPathComponent("finder-store"))
            for (url, ext) in files {
                let p = ClipItemParser.parse(finderCopy(url), trimWhitespace: false)
                let ok = p?.type == .file && p?.pngData != nil && p?.imageWidth == 320 && p?.imageHeight == 180
                    && p?.imageExtension == ext && p?.fileURLs == [url]
                check(ok, "Finder ⌘C on .\(ext): real image read from the file (320×180, original format), not the icon")
                if ext == "jpg", let p {
                    let item = st.ingest(p, bundleID: "com.apple.finder", appName: "Finder")
                    check(item.imagePath?.hasSuffix(".jpg") == true && st.images.thumbnail(for: item.imagePath!) != nil,
                          "Thumbnail generated for the copied image file")
                    check(st.images.data(for: item.imagePath!) == (try? Data(contentsOf: url)), "Original image bytes kept (no re-encoding)")
                    let out = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.out.\(UUID().uuidString)"))
                    PasteService.shared.write(item, images: st.images, to: out)
                    let t = Set((out.types ?? []).map(\.rawValue))
                    check(t.contains("public.file-url") && t.contains("public.jpeg") && t.contains("public.tiff"),
                          "Pasting it gives the file and the image")
                    out.releaseGlobally()
                }
            }
            let pdfClip = ClipItemParser.parse(finderCopy(pdf), trimWhitespace: false)
            check(pdfClip?.type == .file && pdfClip?.pngData == nil, "A copied PDF stays a file (not treated as an image)")
            let docClip = ClipItemParser.parse(finderCopy(doc), trimWhitespace: false)
            check(docClip?.type == .file && docClip?.pngData == nil, "A copied document stays a file")

            // Videos and music copied in Finder: stay file clips, get real details and a poster frame.
            let video = dir.appendingPathComponent("clip.mp4"), song = dir.appendingPathComponent("song.m4a")
            let madeVideo = DemoData.makeVideo(at: video), madeSong = DemoData.makeAudio(at: song)
            check(madeVideo && madeSong, "Test video and music files created")
            for media in [video, song] {
                let p = ClipItemParser.parse(finderCopy(media), trimWhitespace: false)
                check(p?.type == .file && p?.pngData == nil && p?.fileURLs == [media],
                      "Finder ⌘C on .\(media.pathExtension): saved as a file (not text, not an image)")
            }
            check(MediaSupport.kind(of: video) == .video && MediaSupport.kind(of: song) == .audio && MediaSupport.kind(of: pdf) == nil,
                  "Video and music recognized by content type")
            var vInfo: MediaSupport.Info?, aInfo: MediaSupport.Info?, poster: NSImage?
            MediaSupport.info(for: video) { vInfo = $0 }
            MediaSupport.info(for: song) { aInfo = $0 }
            MediaSupport.thumbnail(for: video, pixels: 120) { poster = $0 }
            let deadline = Date().addingTimeInterval(8)
            while (vInfo == nil || aInfo == nil || poster == nil) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            check(abs((vInfo?.duration ?? 0) - 1.5) < 0.2 && vInfo?.width == 320 && vInfo?.height == 180,
                  "Video details read (\(vInfo?.durationText ?? "?"), \(vInfo?.width ?? 0)×\(vInfo?.height ?? 0))")
            check(abs((aInfo?.duration ?? 0) - 2) < 0.2, "Music duration read (\(aInfo?.durationText ?? "?"))")
            check(poster != nil, "Video poster-frame thumbnail generated")
            let vClip = st.ingest(ClipItemParser.parse(finderCopy(video), trimWhitespace: false)!, bundleID: "com.apple.finder", appName: "Finder")
            let out = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.media.\(UUID().uuidString)"))
            PasteService.shared.write(vClip, images: st.images, to: out)
            check((out.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) == [video],
                  "Pasting a video clip gives the video file")
            out.releaseGlobally()
            check(DragProvider.pasteboardItems(for: [vClip], store: st).first?.string(forType: .fileURL).flatMap(URL.init(string:))?.path == video.path,
                  "Dragging a video clip offers the movie file")

            // Direct image data from apps.
            func appCopy(_ build: (NSPasteboardItem) -> Void) -> ParsedClip? {
                let pb = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.app.\(UUID().uuidString)"))
                defer { pb.releaseGlobally() }
                pb.clearContents()
                let item = NSPasteboardItem(); build(item); pb.writeObjects([item])
                return ClipItemParser.parse(RawClip.read(from: pb, types: Set((pb.types ?? []).map(\.rawValue))), trimWhitespace: false)
            }
            let tiff = NSBitmapImageRep(cgImage: cg).tiffRepresentation!
            let jpeg = try! Data(contentsOf: files[1].0)
            check(appCopy { $0.setData(tiff, forType: .tiff); $0.setString("https://example.com/photo.jpg", forType: .string) }?.type == .image,
                  "Safari-style copy (image + its URL) is saved as an image")
            check(appCopy { $0.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg")) }?.imageExtension == "jpeg",
                  "JPEG data from an app is kept as JPEG")
            check(appCopy { $0.setData(try! Data(contentsOf: files[0].0), forType: .png)
                            $0.setData(Data("<img src=\"x.png\">".utf8), forType: .html); $0.setString(" ", forType: .string) }?.type == .image,
                  "Chrome-style copy (image + <img> HTML) is saved as an image")
            let rtf = NSAttributedString(string: "Quarterly numbers").rtf(from: NSRange(location: 0, length: 17), documentAttributes: [:])!
            check(appCopy { $0.setData(rtf, forType: .rtf); $0.setString("Quarterly numbers", forType: .string)
                            $0.setData(tiff, forType: .tiff) }?.type == .text,
                  "Word/Excel-style copy (text + picture preview) stays text")
            let img = st.ingest(appCopy { $0.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg")) }!, bundleID: nil, appName: nil)
            check(DragProvider.pasteboardItems(for: [img], store: st).first?.types.contains(NSPasteboard.PasteboardType("public.jpeg")) == true,
                  "Dragging a JPEG clip offers the JPEG itself")
        }

        print("Screenshots (macOS name, ⌘V as a file)")
        do {
            let cg = NSBitmapImageRep(data: DemoData.makeArtwork(width: 200, height: 120))!.cgImage!
            func png(screenshot: Bool) -> Data {
                let out = NSMutableData()
                let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
                let props: [CFString: Any] = screenshot ? [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"]] : [:]
                CGImageDestinationAddImage(dest, cg, props as CFDictionary)
                CGImageDestinationFinalize(dest)
                return out as Data
            }
            var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 19; c.hour = 14; c.minute = 42; c.second = 59
            let date = Calendar(identifier: .gregorian).date(from: c)!
            let n12 = ClipItemParser.screenshotName(for: date, locale: Locale(identifier: "en_US"))
            check(n12.hasPrefix("Screenshot 2026-11-19 at 2.42.59") && n12.hasSuffix("PM"), "Screenshot name like Finder's, 12-hour clock (\(n12))")
            let n24 = ClipItemParser.screenshotName(for: date, locale: Locale(identifier: "en_GB"))
            check(n24 == "Screenshot 2026-11-19 at 14.42.59", "Screenshot name like Finder's, 24-hour clock (\(n24))")

            let shot = ClipItemParser.parseImage(png(screenshot: true), type: UTType.png.identifier)
            let plain = ClipItemParser.parseImage(png(screenshot: false), type: UTType.png.identifier)
            check(shot?.suggestedTitle?.hasPrefix("Screenshot ") == true, "A macOS screenshot (EXIF comment “Screenshot”) gets the macOS name")
            check(plain != nil && plain?.suggestedTitle == nil, "Other copied images keep showing their size")

            let dir = tmp.appendingPathComponent("screenshots")
            let st = ClipStore(directory: dir)
            let item = st.ingest(shot!, bundleID: nil, appName: nil)
            check(item.customTitle == shot!.suggestedTitle && ClipStore(directory: dir).item(id: item.id)?.customTitle == item.customTitle,
                  "The screenshot name is saved with the clip")
            let old = ClipStore(directory: tmp.appendingPathComponent("screenshots-old"))
            let untitled = old.ingest(plain!, bundleID: nil, appName: nil)
            let recopied = old.ingest(shot!, bundleID: nil, appName: nil)
            check(untitled.customTitle == nil && recopied.id == untitled.id && recopied.customTitle == shot!.suggestedTitle,
                  "An untitled copy of the same screenshot gets the name when copied again")
            old.setCustomTitle(recopied.id, "My title")
            check(old.ingest(shot!, bundleID: nil, appName: nil).customTitle == "My title", "A title you gave a clip is never replaced")

            let out = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.shot.\(UUID().uuidString)"))
            PasteService.shared.write(item, images: st.images, to: out)
            let types = Set((out.types ?? []).map(\.rawValue))
            check(types.contains("public.png") && types.contains("public.tiff") && types.contains("public.file-url"),
                  "⌘V of an image clip offers the image and a file (Finder pastes the file)")
            let file = out.string(forType: .fileURL).flatMap(URL.init(string:))
            check(file.map { FileManager.default.fileExists(atPath: $0.path) && $0.lastPathComponent == item.customTitle! + ".png"
                             && (try? Data(contentsOf: $0)) == st.images.data(for: item.imagePath!) } == true,
                  "The pasted file is named like the screenshot and holds the original image")
            let text = st.ingest(ClipItemParser.parseText("Just text", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            PasteService.shared.write(text, images: st.images, to: out)
            check(!(out.types ?? []).contains(.fileURL), "Text clips are still pasted as text only (no file)")
            out.releaseGlobally()
        }

        print("Native drag content")
        do {
            let st = ClipStore(directory: tmp.appendingPathComponent("dragnative"))
            func types(_ item: ClipItem) -> [String] { DragProvider.pasteboardItems(for: [item], store: st).first?.types.map(\.rawValue) ?? [] }
            let noPromise: ([String]) -> Bool = { t in !t.contains { $0.contains("promise") || $0.contains("Promise") } }
            let code = st.ingest(ClipItemParser.parseText("func a() {\n    return 1\n}", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            check(types(code).contains("public.utf8-plain-text") && !types(code).contains("public.file-url") && noPromise(types(code)),
                  "Text/code drags as text — no file, no file promise")
            check(DragProvider.pasteboardItems(for: [code], store: st).first?.string(forType: .string) == "func a() {\n    return 1\n}",
                  "Dragged text keeps its line breaks")
            let rtf = NSAttributedString(string: "Bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
                .rtf(from: NSRange(location: 0, length: 4), documentAttributes: [:])
            let rich = st.ingest(ClipItemParser.parseText("Bold", rtf: rtf, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            check(types(rich).contains("public.rtf") && types(rich).contains("public.utf8-plain-text") && noPromise(types(rich)),
                  "Rich text drags as RTF + text — no file promise")
            let link = st.ingest(ClipItemParser.parseText("https://swift.org/blog", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            check(types(link).contains("public.url") && types(link).contains("public.utf8-plain-text") && !types(link).contains("public.file-url"),
                  "Link drags as a URL and text, not a file")
            let img = st.ingest(ClipItemParser.parseImage(DemoData.makeArtwork(width: 64, height: 36), isPNG: true)!, bundleID: nil, appName: nil)
            let it = types(img)
            let file = DragProvider.pasteboardItems(for: [img], store: st).first?.string(forType: .fileURL).flatMap(URL.init(string:))
            check(it.contains("public.png") && it.contains("public.tiff") && noPromise(it), "Image drags as image data — no file promise")
            check(file.map { FileManager.default.fileExists(atPath: $0.path) && $0.pathExtension == "png" } == true,
                  "Image also offers a real image file for web upload areas")
        }

        print("Window dragging")
        do {
            let controller = PanelController(store: ClipStore(directory: tmp.appendingPathComponent("drag")))
            check(!controller.panel.isMovableByWindowBackground, "Clip rows don't move the window (background dragging off)")
            check(!WindowDragArea.DragView().mouseDownCanMoveWindow, "Header/footer drag area moves the window explicitly")
        }

        print("Sound")
        check(Feedback.availableSounds.first == Feedback.systemAlertSound, "Default choice is the macOS alert sound")
        check(Feedback.availableSounds.dropFirst().allSatisfy {
            FileManager.default.fileExists(atPath: "/System/Library/Sounds/\($0).aiff") }, "Every other choice is a built-in macOS sound")

        print("Keyboard")
        let v = KeyboardLayout.keyCode(for: "v")
        check(v != nil, "Found the key for 'v' on current layout (keycode \(v.map(String.init) ?? "nil"))")

        print("Transforms")
        check(TextTransform.jsonPretty.apply("{\"b\":1,\"a\":2}").contains("\n"), "JSON pretty-print")
        check(TextTransform.urlEncoded.apply("a b&c") == "a%20b%26c", "URL-encode")

        print("Clipboard checks (burst-aware)")
        do {
            let pb = NSPasteboard(name: NSPasteboard.Name("io.github.sp201004.pastly.selftest.burst.\(UUID().uuidString)"))
            let mon = ClipboardMonitor(pasteboard: pb)
            var seen = 0
            mon.onCapture = { _, _, _ in seen += 1 }
            mon.isPaused = { false }; mon.ignoredApps = { [] }
            mon.start()
            check(mon.currentInterval == ClipboardMonitor.idleInterval, "Idle: checks every \(ClipboardMonitor.idleInterval) s")
            pb.clearContents(); pb.setString("burst one", forType: .string); mon.tick()
            check(seen == 1 && mon.currentInterval == ClipboardMonitor.burstInterval, "After a copy: checks every \(ClipboardMonitor.burstInterval) s")
            pb.clearContents(); pb.setString("burst two", forType: .string); mon.tick()
            check(seen == 2, "Second copy in the burst is captured")
            mon.endBurstForTesting(); mon.tick()
            check(mon.currentInterval == ClipboardMonitor.idleInterval, "Burst over: back to \(ClipboardMonitor.idleInterval) s")
            mon.stop()
        }

        print("File lookups (fresh for capture, non-blocking for the UI)")
        do {
            let fm = FileManager.default
            let dir = tmp.appendingPathComponent("FileFacts-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let png = dir.appendingPathComponent("picture.png"), noExt = dir.appendingPathComponent("picture-without-extension")
            if let cg = makeTestImage(), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                try? data.write(to: png); try? data.write(to: noExt)
            }
            check(ImageFileLoader.isImageFile(png), "Capture: image file recognized (fresh lookup)")
            let firstUI = ImageFileLoader.displayIsImageFile(png)        // no disk access on this thread
            ImageFileLoader.factsQueue.sync {}                            // background lookup done
            check(firstUI && ImageFileLoader.displayIsImageFile(png), "UI: same answer immediately and after the background lookup")
            // macOS types local files by extension, so capture and UI agree on an extension-less file too (as before).
            let freshNoExt = ImageFileLoader.isImageFile(noExt)
            _ = ImageFileLoader.displayIsImageFile(noExt); ImageFileLoader.factsQueue.sync {}
            check(freshNoExt == ImageFileLoader.displayIsImageFile(noExt), "Capture and UI agree on a file without an extension")
            let ghost = dir.appendingPathComponent("gone.txt").path
            try? "x".write(toFile: ghost, atomically: true, encoding: .utf8)
            _ = FileIcons.icon(forExistingFile: ghost); ImageFileLoader.factsQueue.sync {}
            check(FileIcons.icon(forExistingFile: ghost) != nil, "UI: icon for an existing file")
            let missing = dir.appendingPathComponent("never-existed.txt").path
            _ = FileIcons.icon(forExistingFile: missing); ImageFileLoader.factsQueue.sync {}
            check(FileIcons.icon(forExistingFile: missing) == nil, "UI: no icon once a file is known to be missing")
        }

        print("Migration from earlier versions")
        do {
            let fm = FileManager.default
            let support = tmp.appendingPathComponent("AppSupport-\(UUID().uuidString)", isDirectory: true)
            let old = support.appendingPathComponent(LegacyMigration.legacyFolderName, isDirectory: true)
            let new = support.appendingPathComponent(LegacyMigration.folderName, isDirectory: true)
            check(LegacyMigration.migrateData(appSupport: support) == .notNeeded, "No old folder → nothing to migrate")
            check(!fm.fileExists(atPath: new.path), "No old folder → no Pastly folder created")

            // A real history store in the earlier versions' folder, with an image clip, a pin and a list.
            var imageID: String?
            do {
                let legacy = ClipStore(directory: old)
                legacy.ingest(ClipItemParser.parseText("Legacy text clip", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
                legacy.ingest(ClipItemParser.parseText("#3B82F6", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
                if let cg = makeTestImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]),
                   let parsed = ClipItemParser.parseImage(png, isPNG: true) {
                    imageID = legacy.ingest(parsed, bundleID: nil, appName: nil).id
                }
                if let top = legacy.items.first { legacy.togglePin(top.id) }
            }
            let oldFiles = (fm.enumerator(atPath: old.path)?.allObjects as? [String] ?? []).sorted()
            let oldDB = try? Data(contentsOf: old.appendingPathComponent("history.sqlite"))
            check(LegacyMigration.needsDataMigration(appSupport: support), "Old folder only → migration needed")
            check(LegacyMigration.migrateData(appSupport: support) == .copied, "History copied to the Pastly folder")
            let migrated = ClipStore(directory: new)
            check(migrated.items.count == 3, "Migrated store has all 3 clips (\(migrated.items.count))")
            check(migrated.items.contains { $0.isPinned }, "Pin kept")
            check(imageID.flatMap { migrated.item(id: $0)?.imagePath }.map { migrated.images.data(for: $0) != nil } == true, "Image file copied")
            check(migrated.item(withHash: ClipItemParser.parseText("#3B82F6", rtf: nil, html: nil, trimWhitespace: false).contentHash) != nil,
                  "Color hash unchanged after migration (no duplicate on re-copy)")
            let stillOld = (fm.enumerator(atPath: old.path)?.allObjects as? [String] ?? []).sorted()
            check(stillOld == oldFiles && (try? Data(contentsOf: old.appendingPathComponent("history.sqlite"))) == oldDB,
                  "Old folder left unchanged")
            check(fm.fileExists(atPath: new.appendingPathComponent(LegacyMigration.markerFileName).path), "Migration note written")
            let perms = (try? fm.attributesOfItem(atPath: new.path)[.posixPermissions] as? Int) ?? 0
            check(perms & 0o077 == 0, "Pastly folder private to the user (\(String(perms, radix: 8)))")
            migrated.ingest(ClipItemParser.parseText("New Pastly clip", rtf: nil, html: nil, trimWhitespace: false), bundleID: nil, appName: nil)
            check(LegacyMigration.migrateData(appSupport: support) == .alreadyDone, "Second run does nothing (idempotent)")
            check(ClipStore(directory: new).items.count == 4, "Second run doesn't overwrite newer Pastly data")
            let leftovers = ((try? fm.contentsOfDirectory(atPath: support.path)) ?? []).filter { $0.contains("migration") }
            check(leftovers.isEmpty, "No temporary migration folders left")

            // Preferences: copy missing keys once, keep Pastly's own values, rename window frames.
            let suite = "io.github.sp201004.pastly.selftest.prefs.\(UUID().uuidString)"
            if let d = UserDefaults(suiteName: suite) {
                defer { d.removePersistentDomain(forName: suite) }
                d.set(false, forKey: "autoPaste")
                let legacyPrefs: [String: Any] = ["autoPaste": true, "pastePlainByDefault": true, "singleClickPreview": false,
                                                  "NSWindow Frame " + LegacyMigration.legacyFolderName + "Popover": "1 2 3 4"]
                let n = LegacyMigration.migratePreferences(legacy: legacyPrefs, existing: d.persistentDomain(forName: suite), into: d)
                check(n == 3 && d.bool(forKey: "pastePlainByDefault") && d.object(forKey: "singleClickPreview") as? Bool == false,
                      "Missing preferences copied (\(n))")
                check(d.bool(forKey: "autoPaste") == false, "Existing Pastly preference not overwritten")
                check(d.string(forKey: "NSWindow Frame PastlyPopover") == "1 2 3 4", "Window frame key renamed")
                d.set(false, forKey: "pastePlainByDefault")
                check(LegacyMigration.migratePreferences(legacy: legacyPrefs, existing: d.persistentDomain(forName: suite), into: d) == 0 && !d.bool(forKey: "pastePlainByDefault"),
                      "Preferences migrate only once")
            } else {
                check(false, "Create test preferences domain")
            }

            // Backups from earlier versions stay restorable and are never pruned.
            let bdir = tmp.appendingPathComponent("Backups-\(UUID().uuidString)", isDirectory: true)
            try? fm.createDirectory(at: bdir, withIntermediateDirectories: true)
            let legacyBackup = bdir.appendingPathComponent("Old Backup.\(BackupService.legacyFileExtension)")
            try? BackupService.export(migrated, to: legacyBackup)
            for _ in 0..<2 { _ = try? AutoBackup.backupNow(store: migrated, to: bdir, keep: 1); Thread.sleep(forTimeInterval: 1.05) }
            let names = AutoBackup.existingBackups(in: bdir).map { $0.url.pathExtension }.sorted()
            check(names == [BackupService.legacyFileExtension, BackupService.fileExtension], "Legacy backup listed and kept, new ones pruned (\(names))")
            let restoreTarget = ClipStore(directory: tmp.appendingPathComponent("Restore-\(UUID().uuidString)"))
            check(((try? AutoBackup.restore(from: legacyBackup, replace: false, into: restoreTarget))?.added ?? 0) == 4, "Legacy backup restores")
        }

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
        return failures == 0
    }

    private static func makeTestImage() -> CGImage? {
        let w = 8, h = 8
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 8))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 4, y: 0, width: 4, height: 8))
        return ctx.makeImage()
    }
}

import AppKit
import Combine
import SwiftUI

/// Takes the first click even when the panel isn't key yet, so pressing on a clip always
/// starts a drag (instead of the first click only focusing the window).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ClipPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Side window for the click / Space preview. Never takes focus, so the list keeps the keyboard.
final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One pill in the tab bar.
struct TabInfo: Identifiable {
    let collection: Collection
    let title: String
    let symbol: String
    var tint: Color? = nil
    var count: Int
    var id: String { "\(collection)" }

    /// Lists and Pinned accept dropped clips; History, kinds and Smart Lists fill themselves.
    var acceptsClipDrop: Bool {
        switch collection {
        case .list, .pinned: return true
        default: return false
        }
    }
}

enum OpenSource { case hotkey, statusItem }

final class PanelState: ObservableObject {
    let store: ClipStore
    weak var controller: PanelController?

    @Published var query = "" { didSet { if query != oldValue { selectFirst() } } }
    @Published var collection: Collection = .all { didSet { if collection != oldValue { selectFirst() } } }
    /// The focused item ("cursor"): shown in preview, moved by arrows, start of ⇧ ranges.
    @Published var selectedID: String?
    /// Every selected item. Always contains `selectedID` when that is set.
    @Published var selectedIDs: Set<String> = []
    /// Fixed end of a ⇧-click / ⇧-arrow range.
    private var anchorID: String?
    @Published var showPreview = false
    @Published var editingItemID: String?
    @Published var editText = ""
    @Published var editTitle = ""
    @Published var focusToken = 0
    /// A clip is being dragged: the tab bar brings the list tabs into view so they can take the drop.
    @Published var dragInProgress = false
    /// Each rendered row's frame keyed by its clip ID, and the visible list area — both in the
    /// hosting view's own top-left coordinates (SwiftUI `.global`), the same space a mouse event is
    /// converted into. (They used to be measured in a space attached to the root view, which sits
    /// below the title-bar safe area, so a press in the lower part of a row hit the row below.)
    var rowFrames: [String: CGRect] = [:]
    var listViewport: CGRect = .null

    /// The visible clip under `point` (hosting-view coordinates, top-left origin), by stable ID.
    func rowID(at point: CGPoint) -> String? {
        guard listViewport.contains(point) else { return nil }            // not over the header/footer
        let visibleIDs = Set(visibleItems.map(\.id))                     // ignores rows animating out
        return rowFrames.first { visibleIDs.contains($0.key) && $0.value.contains(point) }?.key
    }

    var previousApp: NSRunningApplication?

    init(store: ClipStore) { self.store = store }

    var visibleItems: [ClipItem] { store.filtered(collection: collection, query: query) }
    var selectedItem: ClipItem? { selectedID.flatMap { store.item(id: $0) } }

    /// Selected items in on-screen order. This is what ↩, ⌘V, ⌘C, ⌫ and the context menu act on.
    var selectedItems: [ClipItem] {
        let ids = selectedIDs
        return visibleItems.filter { ids.contains($0.id) }
    }

    var hasMultipleSelection: Bool { selectedIDs.count > 1 }
    var editingItem: ClipItem? { editingItemID.flatMap { store.item(id: $0) } }

    /// Tabs in display order. Kind tabs with no clips are hidden to keep the bar short.
    var tabs: [TabInfo] {
        var t = [
            TabInfo(collection: .all, title: "History", symbol: "clock", count: store.items.count),
            TabInfo(collection: .pinned, title: "Pinned", symbol: "pin", count: store.counts.pinned),
        ]
        if Preferences.shared.showTypeTabs {
            let kinds: [(Collection, String, String, Int)] = [
                (.type(.text), "Text", "text.alignleft", store.count(of: .text)),
                (.type(.url), "Links", "link", store.count(of: .url)),
                (.type(.image), "Images", "photo", store.count(of: .image)),
                (.type(.color), "Colors", "paintpalette", store.count(of: .color)),
                (.type(.file), "Files", "doc", store.count(of: .file)),
                (.code, "Code", "chevron.left.forwardslash.chevron.right", store.codeCount),
            ]
            for (c, title, symbol, n) in kinds where n > 0 || collection == c {
                t.append(TabInfo(collection: c, title: title, symbol: symbol, count: n))
            }
        }
        t += store.smartLists.map { TabInfo(collection: .smart($0.id), title: $0.name, symbol: $0.symbol, count: store.count(in: $0)) }
        t += store.lists.map { TabInfo(collection: .list($0.id), title: $0.name, symbol: "folder.fill",
                                       tint: ListColor.color($0.color), count: $0.itemIDs.count) }
        return t
    }

    var allCollections: [Collection] { tabs.map(\.collection) }

    /// What the preview window shows. The preview opens only on purpose — a click on an item or
    /// Space — and then follows the selection. Hovering or moving the pointer never opens it.
    var previewItem: ClipItem? {
        if editingItemID != nil { return nil }
        return showPreview ? selectedItem : nil
    }

    /// True when the preview window is showing.
    var isPreviewVisible: Bool { previewItem != nil }

    /// Space: open the selected clip's preview, or close whatever preview is showing.
    func togglePreview() {
        if isPreviewVisible { closePreview() } else { openPreview() }
    }

    /// Opens the preview for the selection.
    func openPreview() {
        guard selectedID != nil else { NSSound.beep(); return }
        showPreview = true
    }

    /// Closes the preview. Selection, search and the current tab are left exactly as they were.
    func closePreview() {
        showPreview = false
    }

    /// Plain click on a row. With "Single-Click to Preview" on: select it and open its preview, and
    /// clicking the selected row again closes it. With it off: only select (Space still opens the preview,
    /// and an already-open preview keeps following the selection).
    func clickRow(_ id: String, opensPreview: Bool = Preferences.shared.singleClickPreview) {
        defer { onUserSelection?() }
        guard opensPreview else { select(id); return }
        let alreadySelectedAlone = selectedID == id && !hasMultipleSelection
        if alreadySelectedAlone && isPreviewVisible && previewItem?.id == id {
            closePreview()
        } else {
            select(id)
            openPreview()
        }
    }

    /// Called after the user changes the selection (click, ⌘/⇧-click, ↑/↓) — not for programmatic
    /// selection like opening the panel. The controller uses it to put the selection on the clipboard.
    var onUserSelection: (() -> Void)?

    /// Opening the panel: select what ⌘V currently pastes if Pastly put it there (the clip you
    /// last pasted or selected, as long as nothing newer was copied since); otherwise the latest copy.
    func restoreSelection() {
        let v = visibleItems
        if let ids = PasteService.shared.currentChoiceIDs.map(Set.init) {
            let chosen = v.filter { ids.contains($0.id) }
            if let first = chosen.first {
                selectedIDs = Set(chosen.map(\.id))
                selectedID = first.id
                anchorID = first.id
                return
            }
        }
        selectFirst()
    }


    func selectFirst() { select(visibleItems.first?.id) }

    /// Plain click / arrow: select just this item.
    func select(_ id: String?) {
        selectedID = id
        selectedIDs = id.map { [$0] } ?? []
        anchorID = id
    }

    /// ⌘-click: add or remove one item.
    func toggleSelection(_ id: String) {
        defer { onUserSelection?() }
        if selectedIDs.contains(id) {
            guard selectedIDs.count > 1 else { return }   // keep at least one selected
            selectedIDs.remove(id)
            if selectedID == id { selectedID = visibleItems.first { selectedIDs.contains($0.id) }?.id }
        } else {
            selectedIDs.insert(id)
            selectedID = id
        }
        anchorID = selectedID
    }

    /// ⇧-click / ⇧-arrow: select everything between the anchor and this item.
    func extendSelection(to id: String) {
        defer { onUserSelection?() }
        let v = visibleItems
        guard let to = v.firstIndex(where: { $0.id == id }) else { return }
        let from = anchorID.flatMap { a in v.firstIndex { $0.id == a } } ?? to
        selectedIDs = Set(v[min(from, to)...max(from, to)].map(\.id))
        selectedID = id
        if anchorID == nil { anchorID = id }
    }

    /// ⌘A
    func selectAll() {
        let v = visibleItems
        guard !v.isEmpty else { return }
        selectedIDs = Set(v.map(\.id))
        if selectedID == nil || !selectedIDs.contains(selectedID!) { selectedID = v.first?.id }
        anchorID = v.first?.id
    }

    /// Keeps the user's selection when the list changes (e.g. a new copy arrives while the panel
    /// is open). Only falls back to the first item if nothing selected is still visible.
    func validateSelection() {
        let visibleIDs = Set(visibleItems.map(\.id))
        let kept = selectedIDs.intersection(visibleIDs)
        if kept.isEmpty {
            selectFirst()
            return
        }
        if kept != selectedIDs { selectedIDs = kept }
        if let id = selectedID, kept.contains(id) { return }
        selectedID = visibleItems.first { kept.contains($0.id) }?.id
    }

    /// ↑/↓ (with `extend` for ⇧↑/⇧↓). ⌘↑/⌘↓ jump to the ends.
    func moveSelection(_ delta: Int, extend: Bool = false) {
        let v = visibleItems
        guard !v.isEmpty else { return }
        let idx = v.firstIndex { $0.id == selectedID } ?? -1
        let target = v[max(0, min(v.count - 1, idx + delta))].id
        if extend { extendSelection(to: target) } else { select(target); onUserSelection?() }
    }

    func cycleCollection(_ delta: Int) {
        let all = allCollections
        let idx = all.firstIndex(of: collection) ?? 0
        collection = all[(idx + delta + all.count) % all.count]
    }

    func reset() {
        query = ""
        collection = .all
        showPreview = false
        editingItemID = nil
        dragInProgress = false
        restoreSelection()
        focusToken += 1
    }

    func beginEdit(_ item: ClipItem) {
        editingItemID = item.id
        editText = item.pasteableText ?? ""
        editTitle = item.customTitle ?? ""
    }

    func cancelEdit() {
        editingItemID = nil
        focusToken += 1
    }

    /// Save the edit as a separate clip and leave the original untouched.
    @discardableResult
    func saveEditAsNew(copyAfter: Bool = false) -> ClipItem? {
        guard let item = editingItem, item.type.isTextual else { return nil }
        guard !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return nil }
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = store.addEditedCopy(of: item, text: editText, title: title.isEmpty ? nil : title)
        editingItemID = nil
        select(clip.id)
        store.flashRecent(clip.id)
        if copyAfter { copyToClipboard(clip) }
        focusToken += 1
        return clip
    }

    /// Save, then put the edited clip on the clipboard (ready to ⌘V anywhere).
    func commitEditAndCopy() {
        guard let id = editingItemID else { return }
        commitEdit()
        guard editingItemID == nil, let clip = store.item(id: selectedID ?? id) ?? store.item(id: id) else { return }
        copyToClipboard(clip)
    }

    private func copyToClipboard(_ clip: ClipItem) {
        PasteService.shared.write(clip)
        store.markUsed(clip.id)
        Feedback.shared.play(.copiedFromApp(clip.type))
        Toast.show("Copied — press ⌘V to paste")
    }

    func commitEdit() {
        guard let item = editingItem else { editingItemID = nil; return }
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.type.isTextual && editText != (item.pasteableText ?? "") {
            guard !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { NSSound.beep(); return }
            switch store.updateText(item.id, text: editText, title: title) {
            case .conflict(let otherID):
                let merge = controller?.runModal {
                    let alert = NSAlert()
                    alert.messageText = "This text is already in your history"
                    alert.informativeText = "Merge the edited item into the existing one?"
                    alert.addButton(withTitle: "Merge")
                    alert.addButton(withTitle: "Keep Editing")
                    return alert.runModal() == .alertFirstButtonReturn
                } ?? false
                if merge {
                    store.merge(item.id, into: otherID)
                    select(otherID)
                    editingItemID = nil
                    focusToken += 1
                }
                return
            case .saved, .notFound:
                break
            }
        } else {
            store.setCustomTitle(item.id, title)
        }
        editingItemID = nil
        focusToken += 1
    }
}

final class PanelController: NSObject, NSWindowDelegate, NSDraggingSource {
    let panel: ClipPanel
    let state: PanelState
    let store: ClipStore
    private var keyMonitor: Any?
    private var suppressAutoHide = false
    private var host: NSView?
    private var dragMonitor: Any?
    private var pressRowID: String?
    private var pressPoint: CGPoint = .zero
    private var dragStarted = false
    /// Sizes of the last drag's card images (diagnostics for tests).
    private(set) var lastDragImageSizes: [CGSize] = []
    private let effect = NSVisualEffectView()
    private let previewPanel: PreviewPanel
    private let previewEffect = NSVisualEffectView()
    private var subscriptions = Set<AnyCancellable>()
    static var previewWidth: CGFloat { CGFloat(max(300, min(640, Preferences.shared.previewWidth))) }

    /// Where the menu bar icon is (screen coordinates), so the panel can open right under it.
    var statusItemFrame: (() -> NSRect?)?
    var setStatusItemHighlighted: ((Bool) -> Void)?

    init(store: ClipStore = .shared) {
        self.store = store
        state = PanelState(store: store)
        panel = ClipPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 560),
                          styleMask: [.titled, .fullSizeContentView, .resizable],
                          backing: .buffered, defer: false)
        previewPanel = PreviewPanel(contentRect: NSRect(x: 0, y: 0, width: Self.previewWidth, height: 560),
                                    styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        super.init()
        state.controller = self
        state.onUserSelection = { [weak self] in self?.scheduleSelectionSync() }

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        // Off: otherwise a mouse-down on a clip row moves the whole window instead of starting the
        // clip's drag. The window is moved from its header and footer instead (see WindowDragArea).
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 380, height: 340)
        panel.delegate = self
        panel.setFrameAutosaveName("PastlyPopover")

        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = FirstMouseHostingView(rootView: PanelView(state: state, store: store, prefs: .shared))
        self.host = host
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        setUpPreviewPanel()
        applyAppearance()
        installKeyMonitor()
        installDragMonitor()

        // When the paste mode changes, the clip Pastly put on the clipboard (a selection or a paste)
        // is rewritten in the new mode, so a later ⌘V in any app pastes it the new way.
        Preferences.shared.$pastePlainByDefault.dropFirst().removeDuplicates()
            .sink { [weak self] plain in DispatchQueue.main.async { self?.rewriteClipboardChoice(plain: plain) } }
            .store(in: &subscriptions)
        Preferences.shared.$translucent.dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyAppearance() } }
            .store(in: &subscriptions)
        // @Published emits *before* the new value is stored, so hop to the next main-loop turn first,
        // then read the up-to-date preview item.
        Publishers.CombineLatest3(state.$showPreview, state.$selectedID, state.$editingItemID)
            .receive(on: DispatchQueue.main)
            .map { [weak self] _ in self?.state.previewItem?.id }
            // No removeDuplicates: hiding the panel (paste, esc, focus loss) orders the preview window out
            // directly, so a cached "already showing this item" would keep it hidden when the same clip
            // is previewed again. updatePreviewWindow is idempotent (shows only if hidden).
            .sink { [weak self] id in self?.updatePreviewWindow(visible: id != nil) }
            .store(in: &subscriptions)
    }

    private func setUpPreviewPanel() {
        previewPanel.titleVisibility = .hidden
        previewPanel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { previewPanel.standardWindowButton($0)?.isHidden = true }
        previewPanel.level = .floating
        previewPanel.hidesOnDeactivate = false
        previewPanel.isReleasedWhenClosed = false
        previewPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        previewPanel.animationBehavior = .none
        previewEffect.blendingMode = .behindWindow
        previewEffect.state = .active
        let host = NSHostingView(rootView: PreviewContainer(state: state, store: store, prefs: .shared))
        host.translatesAutoresizingMaskIntoConstraints = false
        previewEffect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: previewEffect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: previewEffect.trailingAnchor),
            host.topAnchor.constraint(equalTo: previewEffect.topAnchor),
            host.bottomAnchor.constraint(equalTo: previewEffect.bottomAnchor),
        ])
        previewPanel.contentView = previewEffect
    }

    func applyAppearance() {
        let translucent = Preferences.shared.translucent
        for view in [effect, previewEffect] {
            view.material = translucent ? .popover : .windowBackground
            view.blendingMode = translucent ? .behindWindow : .withinWindow
        }
    }

    // MARK: Preview window

    private func updatePreviewWindow(visible: Bool) {
        guard visible, panel.isVisible else {
            if previewPanel.isVisible {
                panel.removeChildWindow(previewPanel)
                previewPanel.orderOut(nil)
            }
            return
        }
        positionPreview()
        if !previewPanel.isVisible {
            previewPanel.alphaValue = 0
            previewPanel.orderFront(nil)
            panel.addChildWindow(previewPanel, ordered: .above)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
                previewPanel.animator().alphaValue = 1
            }
        }
    }

    /// Puts the preview beside the list: on the left if there is room, otherwise on the right.
    private func positionPreview() {
        let f = panel.frame
        let vf = (panel.screen ?? NSScreen.main)?.visibleFrame ?? f
        let gap: CGFloat = 8
        let w = Self.previewWidth
        let left = f.minX - gap - w, right = min(f.maxX + gap, vf.maxX - w)
        let x: CGFloat
        switch Preferences.shared.previewSide {
        case "left": x = max(vf.minX, left)
        case "right": x = right
        default: x = left >= vf.minX ? left : right
        }
        previewPanel.setFrame(NSRect(x: x, y: f.minY, width: w, height: f.height), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        if previewPanel.isVisible { positionPreview() }
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    func toggle(from source: OpenSource = .hotkey) { panel.isVisible ? hide() : show(from: source) }

    func show(from source: OpenSource = .hotkey) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { state.previousApp = front }
        state.reset()
        let mode = source == .statusItem ? "menuBar" : Preferences.shared.openPosition
        switch mode {
        case "menuBar": if !positionUnderStatusItem() { positionOnActiveScreen() }
        case "mouse": positionAtMouse()
        default: positionOnActiveScreen()
        }
        setStatusItemHighlighted?(true)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide(restoreFocus: Bool = true) {
        guard panel.isVisible else { return }
        orderOutPanel()
        let otherWindows = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeKey && !($0 is NSPanel) }
        if restoreFocus && NSApp.isActive && !otherWindows { NSApp.hide(nil) }
    }

    // MARK: Developer check: real-window snapshot of the list and its preview

    /// `--snapshot-panel <base> [--dark]`: opens the real panel, previews a few demo clips and saves
    /// each window as drawn on screen (base-<kind>-list.png / base-<kind>-preview.png).
    func snapshotWindows(to base: String) {
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if Preferences.isDemo && store.items.isEmpty {
            _ = DemoData.populate(store, filesDir: ClipStore.supportDirectory.appendingPathComponent("demo-files"))
        }
        func capture(_ w: NSWindow, _ path: String) {
            guard let frame = w.contentView?.superview else { return }
            frame.layoutSubtreeIfNeeded()
            if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        if Preferences.isDemo, !store.items.contains(where: { $0.rtfData != nil }) {   // a rich-text clip, as copied from TextEdit
            let s = NSMutableAttributedString(string: "Meeting notes: ", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
            s.append(NSAttributedString(string: "agenda in italics", attributes: [.font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .italicFontMask)]))
            s.append(NSAttributedString(string: " and a red word.", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 14)]))
            let rtf = s.rtf(from: NSRange(location: 0, length: s.length), documentAttributes: [:])
            store.ingest(ClipItemParser.parseText(s.string, rtf: rtf, html: nil, trimWhitespace: false), bundleID: "com.apple.TextEdit", appName: "TextEdit")
        }
        let picks: [(String, (ClipItem) -> Bool)] = [
            ("rich", { $0.rtfData != nil || $0.htmlData != nil }),
            ("plain", { $0.type == .text && $0.rtfData == nil && $0.htmlData == nil && !self.store.isCode($0) && self.store.embeddedColors($0).isEmpty }),
            ("url", { $0.type == .url }),
            ("colors", { $0.plainText?.hasPrefix("Poster colors") == true }),
            ("image", { $0.type == .image }),
            ("code", { self.store.isCode($0) }),
        ]
        show(from: .hotkey)
        var queue = picks
        func next() {
            guard !queue.isEmpty else { NSApp.terminate(nil); return }
            let (name, match) = queue.removeFirst()
            guard let item = state.visibleItems.first(where: match) else { next(); return }
            state.select(item.id); state.openPreview()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                capture(self.panel, "\(base)-\(name)-list.png")
                capture(self.previewPanel, "\(base)-\(name)-preview.png")
                print("\(name): preview visible \(self.previewPanel.isVisible) frame \(NSStringFromRect(self.previewPanel.frame))")
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() }
    }

    // MARK: Selection → clipboard

    private var selectionSync: DispatchWorkItem?

    private func scheduleSelectionSync() {
        selectionSync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncSelectionToClipboard() }
        selectionSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// A selected clip is what ⌘V pastes — in Pastly and in the app you switch to after the panel
    /// closes. Uses the same `PasteService.write` as double-click/↩ (a self-write: never captured, no
    /// duplicate, no reorder, no new timestamp). Nothing is written until the user selects something,
    /// so a plain ⌘V keeps pasting whatever was copied last.
    func syncSelectionToClipboard() {
        selectionSync?.cancel(); selectionSync = nil
        guard !PasteQueue.shared.isActive, state.editingItemID == nil else { return }
        let items = state.selectedItems
        guard !items.isEmpty, items.count <= 50 else { return }
        if PasteService.shared.currentChoiceIDs == items.map(\.id) { return }
        PasteService.shared.write(items, plainText: Preferences.shared.pastePlainByDefault)
    }

    /// Rewrites Pastly's own clipboard write in the current paste mode. Leaves real copies from other
    /// apps alone. A self-write: not captured, no reorder, no new timestamp.
    func rewriteClipboardChoice(plain: Bool) {
        guard !PasteQueue.shared.isActive, let ids = PasteService.shared.currentChoiceIDs else { return }
        let items = ids.compactMap { store.item(id: $0) }
        guard !items.isEmpty else { return }
        PasteService.shared.write(items, plainText: plain)
    }

    /// Hides the list and its preview without changing which app is active.
    private func orderOutPanel() {
        if let w = selectionSync, !w.isCancelled { syncSelectionToClipboard() }   // a click right before switching apps
        updatePreviewWindow(visible: false)
        panel.orderOut(nil)
        setStatusItemHighlighted?(false)
    }

    @discardableResult
    private func positionUnderStatusItem() -> Bool {
        guard let item = statusItemFrame?(), item.width > 0,
              let screen = NSScreen.screens.first(where: { NSMouseInRect(NSPoint(x: item.midX, y: item.midY), $0.frame, false) }) else {
            return false
        }
        let vf = screen.visibleFrame
        var frame = panel.frame
        frame.size.height = min(frame.height, vf.height - 12)
        frame.origin.y = item.minY - 6 - frame.height
        frame.origin.x = max(vf.minX + 6, min(item.midX - frame.width / 2, vf.maxX - frame.width - 6))
        panel.setFrame(frame, display: false)
        return true
    }

    private func positionAtMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.origin.x = max(vf.minX + 6, min(mouse.x - 40, vf.maxX - frame.width - 6))
        frame.origin.y = max(vf.minY + 6, min(mouse.y - frame.height + 20, vf.maxY - frame.height - 6))
        panel.setFrame(frame, display: false)
    }

    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        var frame = panel.frame
        frame.size.width = min(frame.width, vf.width - 40)
        frame.size.height = min(frame.height, vf.height - 40)
        frame.origin.x = vf.midX - frame.width / 2
        frame.origin.y = vf.midY - frame.height / 2 + vf.height * 0.08
        panel.setFrame(frame, display: false)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !suppressAutoHide, NSApp.modalWindow == nil else { return }
        if panel.attachedSheet == nil { orderOutPanel() }
    }

    /// Runs a modal alert above the floating panel without auto-hiding it.
    func runModal<T>(_ body: () -> T) -> T {
        suppressAutoHide = true
        panel.level = .normal
        defer {
            panel.level = .floating
            suppressAutoHide = false
            if panel.isVisible { panel.makeKeyAndOrderFront(nil) }
        }
        return body()
    }

    // MARK: Actions

    /// The items an action should apply to: the whole selection if `item` is part of it,
    /// otherwise just `item` (e.g. right-clicking an unselected row).
    func targets(for item: ClipItem) -> [ClipItem] {
        state.selectedIDs.contains(item.id) && state.hasMultipleSelection ? state.selectedItems : [item]
    }

    /// ↩ / ⌘V / double-click / ⌘1–9: uses the default format from Settings → General;
    /// `alternate` (⇧ or ⌥ held) pastes in the other format.
    func pasteDefault(_ items: [ClipItem], alternate: Bool = false) {
        paste(items, plain: alternate != Preferences.shared.pastePlainByDefault)
    }

    func paste(_ item: ClipItem, plain: Bool = false, transform: TextTransform? = nil) {
        paste([item], plain: plain, transform: transform)
    }

    func paste(_ items: [ClipItem], plain: Bool = false, transform: TextTransform? = nil) {
        selectionSync?.cancel()   // the paste writes these items itself
        guard let first = items.first else { NSSound.beep(); return }
        let target = state.previousApp
        orderOutPanel()
        Feedback.shared.play(.pasted(first.type))
        PasteService.shared.paste(items, plainText: plain, transform: transform, into: target)
    }

    /// Pastes the first clip now; each following ⌘V in any app pastes the next one (Esc stops).
    func pasteSequentially(_ items: [ClipItem], plain: Bool = false) {
        selectionSync?.cancel()
        guard items.count > 1 else { paste(items, plain: plain); return }
        let target = state.previousApp
        orderOutPanel()
        Feedback.shared.play(.pasted(items[0].type))
        PasteQueue.shared.start(items, plainText: plain, into: target)
    }

    /// "New Smart List from <App>": everything copied from the same app.
    func createSmartList(fromAppOf item: ClipItem) {
        guard let bundleID = item.sourceAppBundleID else { NSSound.beep(); return }
        let name = "From " + (item.sourceAppName ?? AppIconCache.name(for: bundleID))
        if let existing = store.smartLists.first(where: { $0.name == name }) {
            state.collection = .smart(existing.id)
            return
        }
        let list = store.createSmartList(name: name, symbol: "app.badge",
                                         rules: [SmartRule(field: .app, op: .is, value: bundleID)])
        state.collection = .smart(list.id)
    }

    func editSmartList(_ id: String) {
        hide(restoreFocus: false)
        SettingsWindowController.shared.show(tab: .general, smartListID: id)
    }

    func copy(_ items: [ClipItem]) {
        selectionSync?.cancel()
        guard let first = items.first else { NSSound.beep(); return }
        PasteService.shared.write(items)
        for item in items.reversed() { store.markUsed(item.id) }
        Feedback.shared.play(.copiedFromApp(first.type))
        if items.count > 1 { Toast.show("Copied \(items.count) items") }
        hide()
    }

    func copy(_ item: ClipItem) { copy([item]) }

    func copyPlain(_ items: [ClipItem]) {
        selectionSync?.cancel()
        guard let first = items.first else { return }
        PasteService.shared.write(items, plainText: true)
        for item in items.reversed() { store.markUsed(item.id) }
        Feedback.shared.play(.copiedFromApp(first.type))
        hide()
    }

    /// Copies a color value (from the preview) and keeps it in history as its own clip.
    func copyColor(_ value: String) {
        let parsed = ClipItemParser.parseText(value, rtf: nil, html: nil,
                                              trimWhitespace: Preferences.shared.trimWhitespaceForDedup)
        let clip = store.ingest(parsed, bundleID: Bundle.main.bundleIdentifier, appName: "Pastly")
        PasteService.shared.write(clip)
        store.flashRecent(clip.id)
        Feedback.shared.play(.copiedFromApp(clip.type))
    }

    func delete(_ item: ClipItem) { delete([item]) }

    /// Deletes the items, then selects the item that took the first one's place. Undo with ⌘Z.
    func delete(_ items: [ClipItem]) {
        guard !items.isEmpty else { NSSound.beep(); return }
        let v = state.visibleItems
        let ids = Set(items.map(\.id))
        let firstIdx = v.firstIndex { ids.contains($0.id) } ?? 0
        let count = store.deleteUndoable(Array(ids))
        let remaining = state.visibleItems
        state.select(remaining.isEmpty ? nil : remaining[min(firstIdx, remaining.count - 1)].id)
        Toast.show(count == 1 ? "Item deleted — ⌘Z to undo" : "\(count) items deleted — ⌘Z to undo")
    }

    func undoDelete() {
        let restored = store.undoDelete()
        guard !restored.isEmpty else { NSSound.beep(); return }
        state.validateSelection()
        let visibleIDs = Set(state.visibleItems.map(\.id))
        let ids = Set(restored.map(\.id)).intersection(visibleIDs)
        if !ids.isEmpty {
            state.selectedIDs = ids
            state.selectedID = state.visibleItems.first { ids.contains($0.id) }?.id
        }
        Toast.show(restored.count == 1 ? "Item restored" : "\(restored.count) items restored")
    }

    func togglePin(_ items: [ClipItem]) {
        let pinAll = !items.allSatisfy(\.isPinned)
        for item in items where item.isPinned != pinAll { store.togglePin(item.id) }
    }

    func openSettings() {
        hide(restoreFocus: false)
        SettingsWindowController.shared.show()
    }

    func promptNewList(adding items: [ClipItem] = []) {
        DispatchQueue.main.async {
            let name = self.runModal { TextPrompt.ask(title: "New List", message: "Name your list.", confirm: "Create") }
            guard let name else { return }
            let list = self.store.createList(name: name)
            if items.isEmpty { self.state.collection = .list(list.id) }
            for item in items.reversed() { self.store.add(item.id, toList: list.id) }
        }
    }

    func promptRenameList(_ list: ClipList) {
        DispatchQueue.main.async {
            let name = self.runModal { TextPrompt.ask(title: "Rename List", defaultValue: list.name, confirm: "Rename") }
            if let name { self.store.renameList(list.id, to: name) }
        }
    }

    func recognizeText(_ item: ClipItem) {
        guard let name = item.imagePath else { return }
        OCRService.recognizeText(in: store.images.url(for: name)) { [weak self] text in
            guard let self else { return }
            guard let text else {
                self.runModal {
                    let a = NSAlert()
                    a.messageText = "No text found in this image"
                    a.runModal()
                }
                return
            }
            let parsed = ClipItemParser.parseText(text, rtf: nil, html: nil,
                                                  trimWhitespace: Preferences.shared.trimWhitespaceForDedup)
            let newItem = self.store.ingest(parsed, bundleID: Bundle.main.bundleIdentifier, appName: "Pastly OCR")
            PasteService.shared.write(newItem)
            self.store.flashRecent(newItem.id)
            Feedback.shared.play(.copiedFromApp(.text))
            self.state.collection = .all
            self.state.query = ""
            self.state.select(newItem.id)
        }
    }

    // MARK: Native drag & drop (AppKit NSDraggingSession)

    /// Pressing on a clip and moving the mouse starts a real AppKit drag with the clip's native
    /// pasteboard data. Clicks, double-clicks and right-clicks are left to SwiftUI.
    private func installDragMonitor() {
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self, e.window === self.panel, let host = self.host else { return e }
            let p = host.convert(e.locationInWindow, from: nil)
            let point = host.isFlipped ? p : CGPoint(x: p.x, y: host.bounds.height - p.y)
            switch e.type {
            case .leftMouseDown:
                self.dragStarted = false
                self.pressPoint = point
                self.pressRowID = self.state.editingItemID == nil ? self.dragSourceID(atWindowPoint: e.locationInWindow) : nil   // stable clip ID
                if self.state.dragInProgress { self.state.dragInProgress = false }
                return e
            case .leftMouseDragged:
                if self.dragStarted { return nil }
                guard let id = self.pressRowID, hypot(point.x - self.pressPoint.x, point.y - self.pressPoint.y) > 4 else { return e }
                self.dragStarted = self.beginDrag(rowID: id, event: e, host: host)
                return self.dragStarted ? nil : e
            default:
                self.pressRowID = nil
                return e
            }
        }
    }

    /// The clip under a point in the panel's window coordinates (the row a mouse-down would drag),
    /// identified by the clip's stable ID.
    func dragSourceID(atWindowPoint location: CGPoint) -> String? {
        guard let host else { return nil }
        return state.rowID(at: hostPoint(location, in: host))
    }

    /// Window point → hosting-view point with a top-left origin (SwiftUI's `.global` space).
    private func hostPoint(_ location: CGPoint, in host: NSView) -> CGPoint {
        let p = host.convert(location, from: nil)
        return host.isFlipped ? p : CGPoint(x: p.x, y: host.bounds.height - p.y)
    }

    @discardableResult
    func beginDrag(rowID: String, event: NSEvent, host: NSView) -> Bool {
        guard let item = store.item(id: rowID) else { return false }
        let clips = state.selectedIDs.contains(rowID) && state.hasMultipleSelection ? state.selectedItems : [item]
        let rowRect = state.rowFrames[rowID] ?? CGRect(origin: pressPoint, size: CGSize(width: 200, height: 28))
        let frameInHost = host.isFlipped ? rowRect : CGRect(x: rowRect.minX, y: host.bounds.height - rowRect.maxY,
                                                            width: rowRect.width, height: rowRect.height)
        // A complete card rendered from the clip's data (not a screen snapshot), aligned with the row
        // so the cursor keeps its place on the card. Several clips fan out slightly, first on top.
        let scale = panel.backingScaleFactor
        let width = max(220, rowRect.width)
        let pbItems = DragProvider.pasteboardItems(for: clips, store: store)
        var items: [NSDraggingItem] = []
        for (i, pbItem) in pbItems.enumerated() {
            let clip = i < clips.count ? clips[i] : item
            // Drag events arrive on the main thread.
            let rendered = MainActor.assumeIsolated {
                DragCardView.render(clip, store: store, width: width, count: i == 0 ? clips.count : 1, scale: scale)
            }
            guard let card = rendered ?? Optional(snapshotImage(of: frameInHost, in: host)) else { continue }
            let size = card.size
            // Keep the card's top-left where the row's is (cursor stays over the same spot).
            let origin = host.isFlipped ? CGPoint(x: frameInHost.minX, y: frameInHost.minY)
                                        : CGPoint(x: frameInHost.minX, y: frameInHost.maxY - size.height)
            let offset = CGFloat(min(i, 4)) * 5
            let d = NSDraggingItem(pasteboardWriter: pbItem)
            d.setDraggingFrame(CGRect(origin: CGPoint(x: origin.x + offset, y: origin.y + (host.isFlipped ? offset : -offset)), size: size),
                               contents: card)
            items.append(d)
        }
        items.reverse()   // first clip drawn on top
        lastDragImageSizes = items.map { $0.draggingFrame.size }
        guard !items.isEmpty else { return false }
        DragProvider.lastDragTypes = items.compactMap { ($0.item as? NSPasteboardItem)?.types.map(\.rawValue) }.flatMap { $0 }
        host.beginDraggingSession(with: items, event: event, source: self)
        state.dragInProgress = true
        return true
    }

    private func snapshotImage(of rect: CGRect, in view: NSView) -> NSImage {
        guard rect.width > 1, rect.height > 1, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return NSImage() }
        view.cacheDisplay(in: rect, to: rep)
        let img = NSImage(size: rect.size)
        img.addRepresentation(rep)
        return img
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragStarted = false
        pressRowID = nil
    }

    // MARK: Keyboard

    private var mouseMonitor: Any?

    private func installKeyMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if event.window === self?.panel, self?.state.dragInProgress == true { self?.state.dragInProgress = false }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25] // 1…9

    private func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let opt = flags.contains(.option)
        let shift = flags.contains(.shift)

        if state.editingItemID != nil {
            if e.keyCode == 53 { state.cancelEdit(); return true }
            if e.keyCode == 36 && cmd { state.commitEdit(); return true }
            return false
        }

        // The search field keeps normal text editing (typing, ⌫, ←/→) unless the user is
        // clearly working with the item list: empty search, or several items selected via ⌘A/⇧/⌘-click.
        let listMode = state.query.isEmpty || state.hasMultipleSelection
        let selection = state.selectedItems
        // Match ⌘-letter shortcuts by the typed character so they work on any keyboard layout.
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""

        switch e.keyCode {
        case 125:                                                         // ↓  ⇧↓  ⌘↓
            cmd ? state.moveSelection(Int.max / 2, extend: shift) : state.moveSelection(1, extend: shift)
            return true
        case 126:                                                         // ↑  ⇧↑  ⌘↑
            cmd ? state.moveSelection(-(Int.max / 2), extend: shift) : state.moveSelection(-1, extend: shift)
            return true
        case 36 where cmd, 76 where cmd:                                  // ⌘↩ → paste one by one
            pasteSequentially(selection, plain: (opt || shift) != Preferences.shared.pastePlainByDefault)
            return true
        case 36, 76:                                                      // ↩ / ⇧↩ / ⌥↩ → paste selection
            pasteDefault(selection, alternate: opt || shift)
            return true
        case _ where cmd && key == "v" && !shift:                                                 // ⌘V / ⌥⌘V → paste selection
            pasteDefault(selection, alternate: opt)
            return true
        case _ where cmd && key == "a":                                                 // ⌘A → select all items
            state.selectAll()
            return true
        case 51 where cmd,                                                // ⌘⌫ → always delete selection
             51 where listMode && Preferences.shared.deleteKeyDeletes,    // ⌫  → delete selection
             117 where listMode && Preferences.shared.deleteKeyDeletes:   // ⌦  → delete selection
            delete(selection)
            return true
        case _ where cmd && !shift && key == "z":                                       // ⌘Z → undo delete
            if store.canUndoDelete { undoDelete(); return true }
            return false
        case 53:                                                          // esc
            if state.isPreviewVisible { state.closePreview() }
            else if state.hasMultipleSelection { state.select(state.selectedID) }
            else if !state.query.isEmpty { state.query = "" }
            else { hide() }
            return true
        case 48:                                                          // tab
            state.cycleCollection(shift ? -1 : 1); return true
        case 123 where state.query.isEmpty && !cmd,                       // ← / → switch tabs (search empty)
             124 where state.query.isEmpty && !cmd:
            state.cycleCollection(e.keyCode == 123 ? -1 : 1); return true
        case 115:                                                         // Home
            state.moveSelection(-(Int.max / 2), extend: shift); return true
        case 119:                                                         // End
            state.moveSelection(Int.max / 2, extend: shift); return true
        case 116:                                                         // Page Up
            state.moveSelection(-10, extend: shift); return true
        case 121:                                                         // Page Down
            state.moveSelection(10, extend: shift); return true
        case 49 where state.query.isEmpty && !cmd && Preferences.shared.spaceTogglesPreview: // space
            state.togglePreview(); return true
        case _ where cmd && key == "p":                                                // ⌘P → pin/unpin selection
            togglePin(selection)
            return true
        case _ where cmd && key == "e":                                                // ⌘E
            if let item = state.selectedItem { state.beginEdit(item) }
            return true
        case _ where cmd && listMode && key == "c":                                     // ⌘C → copy selection
            copy(selection)
            return true
        case _ where cmd && key == ",":                                                // ⌘,
            openSettings(); return true
        case _ where cmd && key == "f":                                                 // ⌘F
            state.focusToken += 1; return true
        case _ where cmd && key == "n":                                                // ⌘N
            promptNewList(); return true
        case _ where cmd && key == "w":                                                // ⌘W
            hide(); return true
        default:
            break
        }

        // Quick paste ⌘1–⌘9 (modifier and on/off in Settings → Shortcuts).
        let p = Preferences.shared
        let quickMod: Bool = {
            switch p.quickPasteModifier {
            case "option": return opt && !cmd && !flags.contains(.control)
            case "control": return flags.contains(.control) && !cmd && !opt
            default: return cmd && !flags.contains(.control)
            }
        }()
        if p.quickPasteEnabled, quickMod, let n = Self.digitKeyCodes.firstIndex(of: e.keyCode) {
            let v = state.visibleItems
            let alternate = p.quickPasteModifier == "option" ? shift : (opt || shift)
            if n < v.count { pasteDefault([v[n]], alternate: alternate) } else { NSSound.beep() }
            return true
        }
        return false
    }
}

enum TextPrompt {
    static func ask(title: String, message: String = "", defaultValue: String = "", confirm: String = "OK") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
}

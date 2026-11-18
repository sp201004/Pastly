import SwiftUI
import UniformTypeIdentifiers

/// Where each rendered clip row is, keyed by clip ID, in the hosting view's coordinates (`.global`).
struct RowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Main clipboard window: search + toolbar, list tabs, clip rows, shortcut hints.

struct PanelView: View {
    static let space = "PastlyPanel"

    @ObservedObject var state: PanelState
    @ObservedObject var store: ClipStore
    @ObservedObject var prefs: Preferences
    @ObservedObject private var queue = PasteQueue.shared
    @FocusState private var searchFocused: Bool
    @State private var dropTargetID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = state.visibleItems
        ZStack {
            VStack(spacing: 0) {
                header
                tabBar
                Divider()
                itemList(visible).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer(count: visible.count)
            }
            if state.editingItem != nil {
                EditOverlay(state: state)
            }
        }
        .frame(minWidth: 380, minHeight: 340)
        .coordinateSpace(name: PanelView.space)
        .tint(prefs.accent)
        .onAppear { searchFocused = true }
        .onChange(of: state.focusToken) { searchFocused = true }
        .onReceive(store.$items) { _ in DispatchQueue.main.async { state.validateSelection() } }
    }

    private var scale: CGFloat { prefs.fontScale }

    // MARK: Header (search + toolbar)

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15 * scale, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search clips", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16 * scale))
                .focused($searchFocused)
                // Focused whenever the window opens, with the normal blinking cursor in the accent
                // color, so a click or typing visibly goes straight into the search.
                .tint(prefs.accent)

            if queue.isActive {
                Button { queue.stop() } label: {
                    Label("\(queue.position)/\(queue.total)", systemImage: "list.number")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(prefs.accent.opacity(0.18)))
                }
                .buttonStyle(.plain).foregroundStyle(prefs.accent)
                .help("Paste queue running — click or press esc to stop")
            }
            if prefs.isPaused {
                Button { prefs.isPaused = false } label: {
                    Image(systemName: "pause.circle.fill")
                }
                .buttonStyle(.borderless).foregroundStyle(.orange)
                .help("Saving is paused — click to resume")
            }

            listsMenu
            toolbarButton("trash", help: "Delete selected (⌫)") {
                state.controller?.delete(state.selectedItems)
            }
            .disabled(state.selectedItems.isEmpty)
            toolbarButton(state.selectedItems.allSatisfy(\.isPinned) && !state.selectedItems.isEmpty ? "pin.slash" : "pin",
                          help: "Pin or unpin selected (⌘P)") {
                state.controller?.togglePin(state.selectedItems)
            }
            .disabled(state.selectedItems.isEmpty)
            toolbarButton("gearshape", help: "Settings (⌘,)") { state.controller?.openSettings() }
            toolbarButton("power", help: "Quit Pastly") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(WindowDragArea())      // empty header space moves the window
    }

    private func toolbarButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14 * scale))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    /// Jump to any list, or make a new one.
    private var listsMenu: some View {
        Menu {
            ForEach(state.tabs) { tab in
                Button { state.collection = tab.collection } label: {
                    Label("\(tab.title)  (\(tab.count))", systemImage: tab.symbol)
                }
            }
            Divider()
            Button("New Smart List…") { state.controller?.editSmartList("") }
            Button("New List…") { state.controller?.promptNewList() }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 14 * scale))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Lists and filters (⇥ to switch)")
    }

    // MARK: Tabs

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(state.tabs) { tab in
                        TabPill(tab: tab, selected: state.collection == tab.collection, scale: scale, accent: prefs.accent,
                                acceptsDrop: tab.acceptsClipDrop, onDropIDs: { ids in dropClips(ids, on: tab) }) {
                            state.collection = tab.collection
                        }
                        .id(tab.id)
                        .contextMenu { tabMenu(tab) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .onChange(of: state.collection) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("\(state.collection)", anchor: .center) }
            }
            .onAppear { proxy.scrollTo("\(state.collection)", anchor: .center) }
            .onChange(of: state.dragInProgress) {
                // While a clip is dragged, show the tabs that accept drops (your lists, else Pinned).
                guard state.dragInProgress, let target = state.tabs.first(where: {
                    if case .list = $0.collection { return true } else { return false }
                }) ?? state.tabs.first(where: { $0.collection == .pinned }) else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo(target.id, anchor: .leading) }
            }
        }
    }

    /// Drop clips on a tab: a list adds them (or moves them, when dragged from another list); Pinned pins them.
    private func dropClips(_ ids: [String], on tab: TabInfo) {
        state.dragInProgress = false
        let ids = ids.filter { store.item(id: $0) != nil }
        guard !ids.isEmpty else { return }
        let n = ids.count == 1 ? "1 clip" : "\(ids.count) clips"
        switch tab.collection {
        case .list(let target):
            if case .list(let source) = state.collection, source != target {
                store.move(ids, fromList: source, toList: target)
                Toast.show("Moved \(n) to \(tab.title)")
            } else {
                for id in ids.reversed() { store.add(id, toList: target) }
                Toast.show("Added \(n) to \(tab.title)")
            }
        case .pinned:
            for id in ids where store.item(id: id)?.isPinned == false { store.togglePin(id) }
            Toast.show("Pinned \(n)")
        default:
            break
        }
    }

    @ViewBuilder
    private func tabMenu(_ tab: TabInfo) -> some View {
        switch tab.collection {
        case .smart(let id):
            Button("Edit Smart List…") { state.controller?.editSmartList(id) }
            Button("Delete Smart List", role: .destructive) {
                if state.collection == tab.collection { state.collection = .all }
                store.deleteSmartList(id)
            }
        case .list(let id):
            if let list = store.lists.first(where: { $0.id == id }) {
                Button("Rename…") { state.controller?.promptRenameList(list) }
                Button("Delete List", role: .destructive) {
                    if state.collection == tab.collection { state.collection = .all }
                    store.deleteList(id)
                }
            }
        default:
            Button("New Smart List…") { state.controller?.editSmartList("") }
            Button("New List…") { state.controller?.promptNewList() }
        }
    }

    // MARK: Items

    @ViewBuilder
    private func itemList(_ visible: [ClipItem]) -> some View {
        if visible.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: state.query.isEmpty ? "list.clipboard" : "magnifyingglass")
                    .font(.system(size: 32)).foregroundStyle(.tertiary)
                Text(state.query.isEmpty ? "Nothing here yet" : "No matching clips")
                    .font(.headline).foregroundStyle(.secondary)
                Text(state.query.isEmpty ? "Copy something and it shows up here." : "Try another word, or press esc to clear.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: CGFloat(prefs.itemSpacing)) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                            ClipRow(item: item, index: index,
                                    isSelected: state.selectedIDs.contains(item.id),
                                    isCursor: item.id == state.selectedID && state.hasMultipleSelection,
                                    isRecent: item.id == store.recentlyCapturedID,
                                    isCode: store.isCode(item),
                                    store: store, prefs: prefs)
                                .id(item.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity),
                                    removal: .opacity))
                                .contentShape(Rectangle())
                                .onTapGesture { handleClick(on: item) }
                                .contextMenu { contextMenu(for: item) }
                                // Dragging is a native AppKit drag session started by PanelController
                                // (exact pasteboard data, no SwiftUI file promises). Rows report their frame
                                // by clip ID in the same space the mouse event is converted into.
                                .background(GeometryReader { geo in
                                    Color.clear.preference(key: RowFrameKey.self, value: [item.id: geo.frame(in: .global)])
                                })
                                .modifier(ListReorderTarget(item: item, collection: state.collection, store: store,
                                                            dropTargetID: $dropTargetID, accent: prefs.accent))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .onPreferenceChange(RowFrameKey.self) { state.rowFrames = $0 }
                    .animation(reduceMotion || !prefs.animateList ? nil : .spring(response: 0.35, dampingFraction: 0.82),
                               value: visible.map(\.id))
                }
                .background(GeometryReader { geo in        // the visible list area (rows outside it can't be grabbed)
                    Color.clear
                        .onAppear { state.listViewport = geo.frame(in: .global) }
                        .onChange(of: geo.frame(in: .global)) { state.listViewport = geo.frame(in: .global) }
                })
                .onChange(of: state.selectedID) {
                    if let id = state.selectedID { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// Click = select · ⌘-click = add/remove · ⇧-click = range · double-click = paste that item.
    /// Reads modifiers and click count from the real mouse event, so single clicks are never delayed.
    private func handleClick(on item: ClipItem) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
        if (event?.clickCount ?? 1) >= 2 && !flags.contains(.command) && !flags.contains(.shift) {
            state.select(item.id)
            state.controller?.pasteDefault([item])
        } else if flags.contains(.command) {
            state.toggleSelection(item.id)
        } else if flags.contains(.shift) {
            state.extendSelection(to: item.id)
        } else {
            state.clickRow(item.id)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        let targets = state.controller?.targets(for: item) ?? [item]
        let many = targets.count > 1
        let suffix = many ? " \(targets.count) Clips" : ""
        let allTextual = targets.allSatisfy { $0.type.isTextual }

        Button("Paste\(suffix)") { state.controller?.pasteDefault(targets) }
        if allTextual {
            if prefs.pastePlainByDefault {
                Button("Paste\(suffix) with Formatting") { state.controller?.paste(targets, plain: false) }
            } else {
                Button("Paste\(suffix) as Plain Text") { state.controller?.paste(targets, plain: true) }
            }
        }
        if many {
            Button("Paste One by One") { state.controller?.pasteSequentially(targets, plain: prefs.pastePlainByDefault) }
        }
        if allTextual {
            Menu("Paste Transformed") {
                ForEach(TextTransform.allCases) { t in
                    Button(t.title) { state.controller?.paste(targets, transform: t) }
                }
            }
        }
        Button("Copy\(suffix)") { state.controller?.copy(targets) }
        if allTextual && targets.contains(where: { $0.rtfData != nil || $0.htmlData != nil }) {
            Button("Copy\(suffix) as Plain Text") { state.controller?.copyPlain(targets) }
        }
        Divider()
        if !many {
            Button("Preview") { state.select(item.id); state.openPreview() }
            Button(item.type.isTextual ? "Edit…" : "Rename…") { state.select(item.id); state.beginEdit(item) }
            if item.type == .image {
                Button("Copy Text from Image (OCR)") { state.controller?.recognizeText(item) }
            }
            if item.type == .url, let u = URL(string: item.plainText ?? "") {
                Button("Open Link") { NSWorkspace.shared.open(u) }
            }
            if item.type == .file {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
            }
            Divider()
        }
        let allPinned = targets.allSatisfy(\.isPinned)
        Button((allPinned ? "Unpin" : "Pin") + suffix) { state.controller?.togglePin(targets) }
        Menu("Add\(suffix) to List") {
            ForEach(store.lists) { l in
                Button(l.name) { targets.forEach { store.add($0.id, toList: l.id) } }
                    .disabled(targets.allSatisfy { l.itemIDs.contains($0.id) })
            }
            if !store.lists.isEmpty { Divider() }
            Button("New List…") { state.controller?.promptNewList(adding: targets) }
        }
        if case .list(let listID) = state.collection {
            let others = store.lists.filter { $0.id != listID }
            if !others.isEmpty {
                Menu("Move\(suffix) to List") {
                    ForEach(others) { l in
                        Button(l.name) { store.move(targets.map(\.id), fromList: listID, toList: l.id) }
                    }
                }
            }
            Button("Remove\(suffix) from List") { targets.forEach { store.remove($0.id, fromList: listID) } }
        }
        if !many, let app = item.sourceAppName, item.sourceAppBundleID != nil {
            Button("New Smart List: From \(app)") { state.controller?.createSmartList(fromAppOf: item) }
        }
        Divider()
        Button("Delete\(suffix)", role: .destructive) { state.controller?.delete(targets) }
    }

    // MARK: Footer

    /// Minimal bottom bar: two hints on the left, the clip count on the right. (All shortcuts still work;
    /// esc reduces a multi-selection to one clip.)
    private func footer(count: Int) -> some View {
        HStack(spacing: 14) {
            hint("⌘P", "Pin")
            hint("Space", "Preview")
            Spacer(minLength: 8)
            Text("\(count) clip\(count == 1 ? "" : "s")")
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(WindowDragArea())      // footer moves the window too
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.07)))
            Text(label)
        }
    }
}

struct TabPill: View {
    let tab: TabInfo
    let selected: Bool
    let scale: CGFloat
    var accent: Color = .accentColor
    var acceptsDrop = false
    var onDropIDs: ([String]) -> Void = { _ in }
    let action: () -> Void
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .foregroundStyle(tab.tint ?? (selected ? accent : Color.secondary))
                Text(tab.title).lineLimit(1)
            }
            .font(.system(size: 12.5 * scale, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? accent : Color.primary.opacity(0.8))
            .background(Capsule().fill(selected ? accent.opacity(0.16)
                                               : Color.primary.opacity(hovering ? 0.09 : 0.055)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .overlay(Capsule().strokeBorder(accent, lineWidth: dropTargeted ? 2 : 0))
        .scaleEffect(dropTargeted ? 1.08 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dropTargeted)
        .onHover { hovering = $0 }
        .onDrop(of: acceptsDrop ? [DragProvider.clipIDsType] : [], isTargeted: $dropTargeted) { providers in
            DragProvider.lastDropNote = "tab \(tab.title): \(providers.count) providers, types \(providers.map(\.registeredTypeIdentifiers))"
            DragProvider.loadIDs(from: providers) { ids in
                DragProvider.lastDropNote += " → ids \(ids)"
                onDropIDs(ids)
            }
            return true
        }
        .help(acceptsDrop ? "\(tab.title) — drop clips here" : "\(tab.title) — \(tab.count) clip\(tab.count == 1 ? "" : "s")")
    }
}

/// Makes a row a reorder drop target when a list tab is showing, with an insertion line above it.
struct ListReorderTarget: ViewModifier {
    let item: ClipItem
    let collection: Collection
    let store: ClipStore
    @Binding var dropTargetID: String?
    let accent: Color

    func body(content: Content) -> some View {
        if case .list(let listID) = collection {
            content
                .overlay(alignment: .top) {
                    Capsule().fill(accent).frame(height: 3).offset(y: -2)
                        .opacity(dropTargetID == item.id ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .onDrop(of: [DragProvider.clipIDsType],
                        delegate: ListRowDropDelegate(targetID: item.id, listID: listID, store: store, dropTargetID: $dropTargetID))
        } else {
            content
        }
    }
}

/// A view that moves its window when dragged. Used only behind the header and footer, so dragging
/// a clip row drags the clip, never the window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { return }
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

enum ListColor {
    static func color(_ name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "pink": return .pink
        case "orange": return .orange
        case "green": return .green
        case "teal": return .teal
        case "red": return .red
        case "yellow": return .yellow
        default: return .blue
        }
    }
}

enum DragProvider {
    /// Private type that carries clip IDs for drags inside Pastly (lists, reordering).
    static let clipIDsType = UTType(exportedAs: "io.github.sp201004.pastly.clip-ids")
    /// Types offered by the most recent drag (diagnostics for the end-to-end check).
    static var lastDragTypes: [String]?
    static var lastDropNote = "no drop received"

    /// What a drag puts on the pasteboard: per clip, exactly the representations ⌘V paste uses
    /// (text + RTF/HTML, URL + text, image in its own format + TIFF, file URLs) — plus a real image
    /// file for images (web upload areas take files) and the clip IDs for drops inside Pastly.
    /// No file promises, no files for ordinary text.
    static func pasteboardItems(for clips: [ClipItem], store: ClipStore) -> [NSPasteboardItem] {
        let ids = Data(clips.map(\.id).joined(separator: "\n").utf8)
        var out: [NSPasteboardItem] = []
        for clip in clips {
            // Same paste mode as every other paste (Settings → Default paste format): Plain drags plain text.
            let items = PasteService.shared.pasteboardItems(for: clip, plainText: Preferences.shared.pastePlainByDefault,
                                                            transform: nil, images: store.images)
            guard let first = items.first else { continue }
            if clip.type == .image, let name = clip.imagePath, let data = store.images.data(for: name),
               let file = DragFiles.file(for: clip, data: data, ext: (name as NSString).pathExtension) {
                first.setString(file.absoluteString, forType: .fileURL)
            }
            if clip.type == .url { first.setString(clip.plainText ?? "", forType: NSPasteboard.PasteboardType("public.url-name")) }
            out += items
        }
        out.first?.setData(ids, forType: NSPasteboard.PasteboardType(clipIDsType.identifier))
        return out
    }

    /// Reads clip IDs from a drop.
    static func loadIDs(from providers: [NSItemProvider], completion: @escaping ([String]) -> Void) {
        guard let p = providers.first(where: { $0.hasItemConformingToTypeIdentifier(clipIDsType.identifier) }) else {
            completion([]); return
        }
        p.loadDataRepresentation(forTypeIdentifier: clipIDsType.identifier) { data, _ in
            let ids = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\n").map(String.init) ?? []
            DispatchQueue.main.async { completion(ids) }
        }
    }
}

/// Real image files handed to drags (web pages upload files). Kept in Pastly's cache folder,
/// named after the image, and cleared at launch.
enum DragFiles {
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "io.github.sp201004.Pastly") + "/Drag", isDirectory: true)
    }

    static func clear() { try? FileManager.default.removeItem(at: folder) }

    static func file(for item: ClipItem, data: Data, ext: String) -> URL? {
        let dir = folder.appendingPathComponent(String(item.contentHash.prefix(12)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var base = (item.customTitle?.isEmpty == false ? item.customTitle! : "Image \(item.imageWidth)x\(item.imageHeight)")
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(base.prefix(80)).\(ext.isEmpty ? "png" : ext)")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        }
        return url
    }
}

/// Drop on a clip while viewing a list: move the dragged clips to that spot (insertion line shows where).
struct ListRowDropDelegate: DropDelegate {
    let targetID: String
    let listID: String
    let store: ClipStore
    @Binding var dropTargetID: String?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [DragProvider.clipIDsType]) }
    func dropEntered(info: DropInfo) { withAnimation(.easeOut(duration: 0.12)) { dropTargetID = targetID } }
    func dropExited(info: DropInfo) { if dropTargetID == targetID { withAnimation(.easeOut(duration: 0.12)) { dropTargetID = nil } } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dropTargetID = nil
        DragProvider.loadIDs(from: info.itemProviders(for: [DragProvider.clipIDsType])) { ids in
            guard !ids.isEmpty else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                store.moveItems(ids, inList: listID, before: targetID)
            }
        }
        return true
    }
}

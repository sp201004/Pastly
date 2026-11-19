import AppKit
import Combine

final class ClipStore: ObservableObject {
    static let shared = ClipStore()

    /// Sorted by lastUsedAt, newest first.
    @Published private(set) var items: [ClipItem] = [] { didSet { revision &+= 1 } }
    @Published private(set) var lists: [ClipList] = [] { didSet { revision &+= 1 } }
    @Published private(set) var smartLists: [SmartList] = [] { didSet { revision &+= 1 } }
    /// Bumped on every change to items, lists or Smart Lists; derived results are cached per revision.
    private var revision = 0
    /// Item that was just captured; the panel briefly highlights it.
    @Published private(set) var recentlyCapturedID: String?
    /// Called on the main thread after a real copy (not a Pastly self-write) is saved.
    var onCaptured: ((ClipItem) -> Void)?

    let images: ImageStore
    private let db: Database?
    private var hashIndex: [String: String] = [:]   // contentHash -> id
    private var blobCache: [String: String] = [:]   // id -> search blob
    private let workQueue = DispatchQueue(label: "Pastly.capture", qos: .userInitiated)

    static var supportDirectory: URL {
        // Developer screenshots: PASTLY_DATA_DIR points at a throwaway demo store.
        if Preferences.isDemo, let dir = ProcessInfo.processInfo.environment["PASTLY_DATA_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pastly", isDirectory: true)
    }

    init(directory: URL = ClipStore.supportDirectory) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        images = ImageStore(directory: directory.appendingPathComponent("Images", isDirectory: true))
        do {
            db = try Database(path: directory.appendingPathComponent("history.sqlite").path)
        } catch {
            NSLog("Pastly: could not open database: \(error)")
            db = nil
        }
        reload()
        SecureStorage.apply(to: directory)
    }

    func reload() {
        items = db?.loadItems() ?? []
        lists = db?.loadLists() ?? []
        smartLists = db?.loadSmartLists() ?? []
        hashIndex = Dictionary(items.map { ($0.contentHash, $0.id) }, uniquingKeysWith: { a, _ in a })
        blobCache = [:]
        prewarmCaches()
    }

    func item(id: String) -> ClipItem? { items.first { $0.id == id } }
    func item(withHash hash: String) -> ClipItem? { hashIndex[hash].flatMap { item(id: $0) } }
    func count(of type: ClipType) -> Int { counts.byType[type] ?? 0 }

    var listedIDs: Set<String> { Set(lists.flatMap(\.itemIDs)) }

    // MARK: Capture

    func capture(_ raw: RawClip, bundleID: String?, appName: String?) {
        let trim = Preferences.shared.trimWhitespaceForDedup
        let filter = CaptureFilter.current
        workQueue.async { [weak self] in
            guard let parsed = ClipItemParser.parse(raw, trimWhitespace: trim) else { return }
            if filter.reason(for: parsed) != nil { return }   // excluded by a Privacy rule
            // Write a new image file here, off the main thread (up to 50 MB); ingest then finds it in place.
            if let bytes = parsed.pngData, let images = self?.images {
                images.save(bytes, name: parsed.contentHash + "." + parsed.imageExtension)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let item = self.ingest(parsed, bundleID: bundleID, appName: appName)
                self.flashRecent(item.id)
                self.onCaptured?(item)
            }
        }
    }

    /// Dedup upsert: an existing hash updates lastUsedAt/source/useCount instead of inserting.
    @discardableResult
    func ingest(_ p: ParsedClip, bundleID: String?, appName: String?, date: Date = Date()) -> ClipItem {
        if let existingID = hashIndex[p.contentHash], let idx = items.firstIndex(where: { $0.id == existingID }) {
            var it = items[idx]
            it.lastUsedAt = date
            it.sourceAppBundleID = bundleID
            it.sourceAppName = appName
            it.useCount += 1
            if it.type == .text {
                it.rtfData = p.rtf
                it.htmlData = p.html
                it.primaryUTI = p.primaryUTI
            }
            // A file clip copied again now that its image can be read (e.g. saved before this support existed).
            if it.imagePath == nil, let bytes = p.pngData {
                let name = p.contentHash + "." + p.imageExtension
                images.save(bytes, name: name)
                it.imagePath = name
                it.imageWidth = p.imageWidth
                it.imageHeight = p.imageHeight
            }
            if (it.customTitle ?? "").isEmpty, let title = p.suggestedTitle { it.customTitle = title }   // e.g. a screenshot's name
            items.remove(at: idx)
            items.insert(it, at: 0)
            db?.save(it)
            blobCache[it.id] = nil
            return it
        }

        var imageName: String?
        if let bytes = p.pngData {
            let name = p.contentHash + "." + p.imageExtension
            images.save(bytes, name: name)
            imageName = name
        }
        var it = ClipItem(type: p.type, primaryUTI: p.primaryUTI, plainText: p.plainText,
                          rtfData: p.rtf, htmlData: p.html, imagePath: imageName,
                          imageWidth: p.imageWidth, imageHeight: p.imageHeight,
                          fileURLs: p.fileURLs, colorHex: p.colorHex,
                          sourceAppBundleID: bundleID, sourceAppName: appName,
                          createdAt: date, lastUsedAt: date, contentHash: p.contentHash)
        it.customTitle = p.suggestedTitle   // e.g. "Screenshot 2026-11-19 at 2.42.59 PM"; nil for other clips
        items.insert(it, at: 0)
        hashIndex[it.contentHash] = it.id
        db?.save(it)
        enforceLimits()
        return it
    }

    func flashRecent(_ id: String) {
        recentlyCapturedID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.recentlyCapturedID == id { self?.recentlyCapturedID = nil }
        }
    }

    /// Pasting or copying a clip from Pastly counts as a "use" but not as a capture:
    /// the clip keeps its place in the history and its timestamp. Only a genuinely new copy
    /// (see `ingest`) moves a clip to the top.
    func markUsed(_ id: String, pasted: Bool = false) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].useCount += 1
        if pasted { items[idx].pasteCount += 1 }
        db?.save(items[idx])
    }

    // MARK: Editing

    func togglePin(_ id: String) {
        update(id) { $0.isPinned.toggle() }
    }

    func setCustomTitle(_ id: String, _ title: String?) {
        update(id) { $0.customTitle = (title?.isEmpty ?? true) ? nil : title }
    }

    enum EditResult { case saved, conflict(existingID: String), notFound }

    func updateText(_ id: String, text: String, title: String?) -> EditResult {
        guard let current = item(id: id) else { return .notFound }
        let parsed = ClipItemParser.parseText(text, rtf: nil, html: nil,
                                              trimWhitespace: Preferences.shared.trimWhitespaceForDedup)
        if let other = hashIndex[parsed.contentHash], other != id { return .conflict(existingID: other) }
        hashIndex[current.contentHash] = nil
        update(id) {
            $0.type = parsed.type
            $0.primaryUTI = parsed.primaryUTI
            $0.plainText = parsed.plainText
            $0.colorHex = parsed.colorHex
            $0.rtfData = nil
            $0.htmlData = nil
            $0.contentHash = parsed.contentHash
            $0.customTitle = (title?.isEmpty ?? true) ? nil : title
        }
        hashIndex[parsed.contentHash] = id
        return .saved
    }

    /// "Save as New": stores edited text as its own clip; the original stays as it was.
    @discardableResult
    func addEditedCopy(of original: ClipItem, text: String, title: String?) -> ClipItem {
        let parsed = ClipItemParser.parseText(text, rtf: nil, html: nil,
                                              trimWhitespace: Preferences.shared.trimWhitespaceForDedup)
        var clip = ingest(parsed, bundleID: original.sourceAppBundleID, appName: original.sourceAppName)
        if let title, clip.customTitle == nil {
            setCustomTitle(clip.id, title)
            clip.customTitle = title
        }
        return clip
    }

    /// Merge an edited item into an existing duplicate (keeps list memberships).
    func merge(_ id: String, into existingID: String) {
        for l in lists where l.itemIDs.contains(id) && !l.itemIDs.contains(existingID) {
            add(existingID, toList: l.id)
        }
        delete([id])
        markUsed(existingID)
    }

    private func update(_ id: String, _ change: (inout ClipItem) -> Void) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[idx])
        db?.save(items[idx])
        blobCache[id] = nil
    }

    // MARK: Deleting

    /// Everything needed to undo the last delete (⌘Z).
    struct DeletedBatch {
        var items: [ClipItem]
        var memberships: [String: [(itemID: String, index: Int)]]  // listID -> positions
        var date = Date()
    }
    private(set) var lastDeleted: DeletedBatch?
    private var trashDirectory: URL { images.directory.deletingLastPathComponent().appendingPathComponent("Trash", isDirectory: true) }

    /// Permanent delete (limits, clear history, merge).
    func delete(_ ids: [String]) {
        _ = remove(ids, keepForUndo: false)
    }

    /// User delete: removes the items but keeps them (and their images) so ⌘Z can restore them.
    @discardableResult
    func deleteUndoable(_ ids: [String]) -> Int {
        purgeTrash()
        let batch = remove(ids, keepForUndo: true)
        lastDeleted = batch
        return batch?.items.count ?? 0
    }

    var canUndoDelete: Bool {
        guard let b = lastDeleted else { return false }
        return Date().timeIntervalSince(b.date) < 300
    }

    /// Restores the last deleted batch. Returns the restored items (in their original order).
    @discardableResult
    func undoDelete() -> [ClipItem] {
        guard canUndoDelete, let batch = lastDeleted else { return [] }
        lastDeleted = nil
        var restored: [ClipItem] = []
        for it in batch.items where hashIndex[it.contentHash] == nil && item(id: it.id) == nil {
            if let img = it.imagePath {
                let from = trashDirectory.appendingPathComponent(img)
                try? FileManager.default.moveItem(at: from, to: images.url(for: img))
            }
            items.append(it)
            hashIndex[it.contentHash] = it.id
            db?.save(it)
            restored.append(it)
        }
        items.sort { $0.lastUsedAt > $1.lastUsedAt }
        let restoredIDs = Set(restored.map(\.id))
        for (listID, entries) in batch.memberships {
            updateList(listID) { l in
                for e in entries.sorted(by: { $0.index < $1.index }) where restoredIDs.contains(e.itemID) {
                    l.itemIDs.insert(e.itemID, at: min(e.index, l.itemIDs.count))
                }
            }
        }
        purgeTrash()
        return restored
    }

    private func purgeTrash() {
        try? FileManager.default.removeItem(at: trashDirectory)
    }

    private func remove(_ ids: [String], keepForUndo: Bool) -> DeletedBatch? {
        let set = Set(ids)
        guard !set.isEmpty else { return nil }
        if keepForUndo { try? FileManager.default.createDirectory(at: trashDirectory, withIntermediateDirectories: true) }

        var removed: [ClipItem] = []
        for it in items where set.contains(it.id) {
            if let img = it.imagePath {
                if keepForUndo {
                    try? FileManager.default.moveItem(at: images.url(for: img), to: trashDirectory.appendingPathComponent(img))
                    images.delete(img)   // clears caches; file already moved
                } else {
                    images.delete(img)
                }
            }
            hashIndex[it.contentHash] = nil
            blobCache[it.id] = nil
            removed.append(it)
        }
        items.removeAll { set.contains($0.id) }
        db?.deleteItems(Array(set))

        var memberships: [String: [(itemID: String, index: Int)]] = [:]
        var changed = false
        var newLists = lists
        for i in newLists.indices {
            for (idx, itemID) in newLists[i].itemIDs.enumerated() where set.contains(itemID) {
                memberships[newLists[i].id, default: []].append((itemID, idx))
            }
            let before = newLists[i].itemIDs.count
            newLists[i].itemIDs.removeAll { set.contains($0) }
            if newLists[i].itemIDs.count != before { changed = true }
        }
        if changed { lists = newLists }
        return DeletedBatch(items: removed, memberships: memberships)
    }

    /// Removes history. Pinned items and items saved in lists are kept unless `everything` is true.
    func clearHistory(everything: Bool = false) {
        let listed = listedIDs
        let ids = items.filter { everything || (!$0.isPinned && !listed.contains($0.id)) }.map(\.id)
        delete(ids)
    }

    /// History size limit + auto-delete by age. Pinned and listed items are protected.
    func enforceLimits() {
        let prefs = Preferences.shared
        let listed = listedIDs
        let unprotected = items.filter { !$0.isPinned && !listed.contains($0.id) }
        var toDelete = Set<String>()
        if prefs.autoDeleteDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(prefs.autoDeleteDays) * 86_400)
            unprotected.filter { $0.lastUsedAt < cutoff }.forEach { toDelete.insert($0.id) }
        }
        if prefs.historyLimit > 0, unprotected.count > prefs.historyLimit {
            unprotected[prefs.historyLimit...].forEach { toDelete.insert($0.id) }
        }
        if !toDelete.isEmpty { delete(Array(toDelete)) }
    }

    // MARK: Lists

    @discardableResult
    func createList(name: String) -> ClipList {
        let l = ClipList(name: name, color: ClipList.palette[lists.count % ClipList.palette.count],
                         sortOrder: (lists.map(\.sortOrder).max() ?? 0) + 1)
        lists.append(l)
        db?.saveList(l)
        return l
    }

    func renameList(_ id: String, to name: String) {
        updateList(id) { $0.name = name }
    }

    func deleteList(_ id: String) {
        lists.removeAll { $0.id == id }
        db?.deleteList(id)
    }

    func add(_ itemID: String, toList listID: String) {
        updateList(listID) { l in
            if !l.itemIDs.contains(itemID) { l.itemIDs.insert(itemID, at: 0) }
        }
    }

    /// Moves clips from one list to another (Settings → Lists, and "Move to List" in the clipboard window).
    func move(_ itemIDs: [String], fromList source: String, toList target: String) {
        guard source != target else { return }
        for id in itemIDs.reversed() { add(id, toList: target) }
        updateList(source) { l in l.itemIDs.removeAll { itemIDs.contains($0) } }
    }

    /// Drag-and-drop reorder: puts `ids` (in their current order) just before `targetID` in the list.
    /// Clips that aren't in the list yet are added there. `nil` target = end of the list.
    func moveItems(_ ids: [String], inList listID: String, before targetID: String?) {
        let known = Set(items.map(\.id))
        updateList(listID) { l in
            let inList = l.itemIDs.filter { ids.contains($0) }
            let newOnes = ids.filter { known.contains($0) && !l.itemIDs.contains($0) }
            let moving = inList + newOnes
            guard !moving.isEmpty, !(targetID.map { moving.contains($0) } ?? false) else { return }
            var rest = l.itemIDs.filter { !moving.contains($0) }
            let at = targetID.flatMap { rest.firstIndex(of: $0) } ?? rest.count
            rest.insert(contentsOf: moving, at: at)
            l.itemIDs = rest
        }
    }

    /// Moves one item up (-1) or down (+1) inside a list.
    func moveItem(_ itemID: String, inList listID: String, by delta: Int) {
        updateList(listID) { l in
            guard let i = l.itemIDs.firstIndex(of: itemID) else { return }
            let j = max(0, min(l.itemIDs.count - 1, i + delta))
            guard i != j else { return }
            l.itemIDs.swapAt(i, j)
        }
    }

    func setListColor(_ id: String, _ color: String) {
        updateList(id) { $0.color = color }
    }

    /// Custom order for lists (drag to reorder in Settings → Lists).
    func moveLists(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = lists
        let moving = source.sorted().map { reordered[$0] }
        for i in source.sorted(by: >) { reordered.remove(at: i) }
        let insertAt = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: max(0, min(insertAt, reordered.count)))
        for i in reordered.indices { reordered[i].sortOrder = i }
        lists = reordered
        reordered.forEach { db?.saveList($0) }
    }

    func moveSmartLists(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = smartLists
        let moving = source.sorted().map { reordered[$0] }
        for i in source.sorted(by: >) { reordered.remove(at: i) }
        let insertAt = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: max(0, min(insertAt, reordered.count)))
        for i in reordered.indices { reordered[i].sortOrder = i }
        smartLists = reordered
        reordered.forEach { db?.saveSmartList($0) }
    }

    func remove(_ itemID: String, fromList listID: String) {
        updateList(listID) { $0.itemIDs.removeAll { $0 == itemID } }
    }

    private func updateList(_ id: String, _ change: (inout ClipList) -> Void) {
        guard let idx = lists.firstIndex(where: { $0.id == id }) else { return }
        change(&lists[idx])
        db?.saveList(lists[idx])
    }

    // MARK: Smart Lists

    @discardableResult
    func createSmartList(name: String, symbol: String = "sparkles", rules: [SmartRule], matchAll: Bool = true) -> SmartList {
        let l = SmartList(name: name, symbol: symbol, matchAll: matchAll, rules: rules,
                          sortOrder: (smartLists.map(\.sortOrder).max() ?? 0) + 1)
        smartLists.append(l)
        db?.saveSmartList(l)
        return l
    }

    func updateSmartList(_ list: SmartList) {
        guard let idx = smartLists.firstIndex(where: { $0.id == list.id }) else { return }
        smartLists[idx] = list
        db?.saveSmartList(list)
    }

    func deleteSmartList(_ id: String) {
        smartLists.removeAll { $0.id == id }
        db?.deleteSmartList(id)
    }

    func count(in smart: SmartList) -> Int {
        validateDerivedCaches()
        if let n = smartCountCache[smart] { return n }
        let now = Date()
        let n = items.reduce(0) { $0 + (smart.matches($1, now: now, ctx: self) ? 1 : 0) }
        smartCountCache[smart] = n
        return n
    }

    // MARK: Import (used by BackupService)

    func insertImported(_ item: ClipItem, png: Data?) {
        var it = item
        if self.item(id: it.id) != nil { it.id = UUID().uuidString }
        if let png, let name = it.imagePath { images.save(png, name: name) }
        items.append(it)
        hashIndex[it.contentHash] = it.id
        db?.save(it)
    }

    func finishImport() {
        items.sort { $0.lastUsedAt > $1.lastUsedAt }
        blobCache = [:]
    }

    // MARK: Filtering / search

    // MARK: Derived-data cache
    //
    // The window asks for the visible list and the tab counts many times per redraw (and every
    // redraw used to re-run every Smart List rule over the whole history). Results are now kept
    // until the history changes, and for at most 30 s so time-based rules ("Last used within") stay current.

    struct Counts { var byType: [ClipType: Int] = [:]; var pinned = 0; var code = 0 }
    private struct FilterKey: Hashable { let collection: Collection; let query: String }
    private var cacheRevision = -1
    private var cacheBucket = -1
    private var filterCache: [FilterKey: [ClipItem]] = [:]
    private var smartCountCache: [SmartList: Int] = [:]
    private var countsCache: Counts?

    private func validateDerivedCaches() {
        let bucket = Int(Date().timeIntervalSince1970 / 30)
        guard cacheRevision != revision || cacheBucket != bucket else { return }
        cacheRevision = revision; cacheBucket = bucket
        filterCache.removeAll(keepingCapacity: true)
        smartCountCache.removeAll(keepingCapacity: true)
        countsCache = nil
    }

    /// Clip counts per kind, pinned and code — one pass, cached until the history changes.
    var counts: Counts {
        validateDerivedCaches()
        if let c = countsCache { return c }
        var c = Counts()
        for it in items {
            c.byType[it.type, default: 0] += 1
            if it.isPinned { c.pinned += 1 }
            if isCode(it) { c.code += 1 }
        }
        countsCache = c
        return c
    }

    func filtered(collection: Collection, query: String) -> [ClipItem] {
        validateDerivedCaches()
        let key = FilterKey(collection: collection, query: query)
        if let cached = filterCache[key] { return cached }
        let result = computeFiltered(collection: collection, query: query)
        if filterCache.count > 64 { filterCache.removeAll(keepingCapacity: true) }
        filterCache[key] = result
        return result
    }

    private func computeFiltered(collection: Collection, query: String) -> [ClipItem] {
        var base: [ClipItem]
        switch collection {
        case .all: base = items
        case .pinned: base = items.filter(\.isPinned)
        case .type(let t): base = items.filter { $0.type == t }
        case .code: base = items.filter { isCode($0) }
        case .smart(let id):
            guard let smart = smartLists.first(where: { $0.id == id }) else { return [] }
            let now = Date()
            base = items.filter { smart.matches($0, now: now, ctx: self) }
        case .list(let id):
            guard let list = lists.first(where: { $0.id == id }) else { return [] }
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            base = list.itemIDs.compactMap { byID[$0] }
        }
        let tokens = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return base }
        return base.filter { item in
            let blob = searchBlob(for: item)
            return tokens.allSatisfy { blob.contains($0) }
        }
    }

    private var codeCache: [String: Bool] = [:]   // contentHash -> isCode

    func isCode(_ item: ClipItem) -> Bool {
        guard item.type == .text else { return false }
        if let c = codeCache[item.contentHash] { return c }
        let c = item.isCode
        codeCache[item.contentHash] = c
        return c
    }

    private var colorCache: [String: [String]] = [:]   // contentHash -> embedded colors

    /// HEX colors found inside a text clip (a clip that *is* a color is handled as a color clip).
    func embeddedColors(_ item: ClipItem) -> [String] {
        guard item.type == .text else { return [] }
        if let c = colorCache[item.contentHash] { return c }
        let c = ColorParser.findAll(in: item.plainText ?? "")
        colorCache[item.contentHash] = c
        return c
    }

    var codeCount: Int { counts.code }

    private func searchBlob(for item: ClipItem) -> String {
        if let b = blobCache[item.id] { return b }
        let b = item.searchBlob
        blobCache[item.id] = b
        return b
    }

    // MARK: Per-clip facts for Smart List rules (cached; content-derived ones keyed by content hash)

    private var hostsCache: [String: [String]] = [:]       // contentHash -> link hosts
    private var patternCache: [String: Bool] = [:]         // pattern + NUL + contentHash -> matches

    /// Fills the search, code and link-host caches off the main thread after loading, so the first
    /// window open doesn't pay for a full pass over a large history.
    private func prewarmCaches() {
        let snapshot = items
        guard !snapshot.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var blobs: [String: (sig: String, blob: String)] = [:], code: [String: Bool] = [:], hosts: [String: [String]] = [:]
            for it in snapshot {
                blobs[it.id] = (Self.blobSignature(it), it.searchBlob)
                if it.type == .text { code[it.contentHash] = it.isCode }
                if it.type == .text || it.type == .url { hosts[it.contentHash] = SmartRule.hosts(in: it) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for it in self.items {   // only fill gaps, and only if the clip didn't change meanwhile
                    if self.blobCache[it.id] == nil, let b = blobs[it.id], b.sig == Self.blobSignature(it) { self.blobCache[it.id] = b.blob }
                    if self.codeCache[it.contentHash] == nil, let c = code[it.contentHash] { self.codeCache[it.contentHash] = c }
                    if self.hostsCache[it.contentHash] == nil, let h = hosts[it.contentHash] { self.hostsCache[it.contentHash] = h }
                }
            }
        }
    }

    /// The fields the search text is built from (content, title, source app).
    private static func blobSignature(_ it: ClipItem) -> String {
        "\(it.contentHash)\u{0}\(it.customTitle ?? "")\u{0}\(it.sourceAppName ?? "")"
    }
}

extension ClipStore: SmartRuleContext {
    func searchBlob(_ item: ClipItem) -> String { searchBlob(for: item) }

    func hosts(_ item: ClipItem) -> [String] {
        if let h = hostsCache[item.contentHash] { return h }
        let h = SmartRule.hosts(in: item)
        if hostsCache.count > 50_000 { hostsCache.removeAll() }
        hostsCache[item.contentHash] = h
        return h
    }

    func patternMatches(_ re: NSRegularExpression, pattern: String, _ item: ClipItem) -> Bool {
        let key = pattern + "\u{0}" + item.contentHash
        if let hit = patternCache[key] { return hit }
        let hit = SmartRule.firstMatch(re, in: item)
        if patternCache.count > 100_000 { patternCache.removeAll() }
        patternCache[key] = hit
        return hit
    }
}

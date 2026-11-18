import Foundation

/// Manual JSON backups (no cloud). Images are embedded as base64 PNG so the backup is a single file.
struct BackupFile: Codable {
    var format = "Pastly"
    var version = 1
    var exportedAt: Date
    var items: [BackupItem]
    var lists: [BackupList]
    var smartLists: [SmartList]?
}

struct BackupItem: Codable {
    var id: String
    var type: ClipType
    var primaryUTI: String
    var plainText: String?
    var rtfData: Data?
    var htmlData: Data?
    var imagePNG: Data?
    var imageWidth: Int
    var imageHeight: Int
    var filePaths: [String]
    var colorHex: String?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var createdAt: Date
    var lastUsedAt: Date
    var useCount: Int
    var isPinned: Bool
    var customTitle: String?
    var contentHash: String
    var pasteCount: Int?
    /// File extension of `imagePNG` (png, jpeg, heic…). Older backups: always PNG.
    var imageExtension: String?
}

struct BackupList: Codable {
    var name: String
    var color: String
    var itemIDs: [String]
}

enum BackupService {
    static let fileExtension = "pastly"
    /// Backup files written by earlier versions of the app. Same JSON format.
    static let legacyFileExtension = ["paste", "stash"].joined()
    static let readableExtensions: Set<String> = [fileExtension, legacyFileExtension]

    struct ImportResult { var added = 0; var skipped = 0; var lists = 0 }

    static func export(_ store: ClipStore, to url: URL) throws {
        let items = store.items.map { i in
            BackupItem(id: i.id, type: i.type, primaryUTI: i.primaryUTI, plainText: i.plainText,
                       rtfData: i.rtfData, htmlData: i.htmlData,
                       imagePNG: i.imagePath.flatMap { store.images.data(for: $0) },
                       imageWidth: i.imageWidth, imageHeight: i.imageHeight,
                       filePaths: i.fileURLs.map(\.path), colorHex: i.colorHex,
                       sourceAppBundleID: i.sourceAppBundleID, sourceAppName: i.sourceAppName,
                       createdAt: i.createdAt, lastUsedAt: i.lastUsedAt, useCount: i.useCount,
                       isPinned: i.isPinned, customTitle: i.customTitle, contentHash: i.contentHash,
                       pasteCount: i.pasteCount,
                       imageExtension: i.imagePath.map { ($0 as NSString).pathExtension })
        }
        let lists = store.lists.map { BackupList(name: $0.name, color: $0.color, itemIDs: $0.itemIDs) }
        let file = BackupFile(exportedAt: Date(), items: items, lists: lists, smartLists: store.smartLists)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(file).write(to: url, options: .atomic)
    }

    static func importBackup(from url: URL, into store: ClipStore) throws -> ImportResult {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let file = try dec.decode(BackupFile.self, from: Data(contentsOf: url))
        var result = ImportResult()
        var idMap: [String: String] = [:]   // backup id -> id in store

        for b in file.items {
            if let existing = store.item(withHash: b.contentHash) {
                idMap[b.id] = existing.id
                result.skipped += 1
                continue
            }
            let item = ClipItem(id: b.id, type: b.type, primaryUTI: b.primaryUTI, plainText: b.plainText,
                                rtfData: b.rtfData, htmlData: b.htmlData,
                                imagePath: b.imagePNG == nil ? nil : b.contentHash + "." + (b.imageExtension ?? "png"),
                                imageWidth: b.imageWidth, imageHeight: b.imageHeight,
                                fileURLs: b.filePaths.map { URL(fileURLWithPath: $0) }, colorHex: b.colorHex,
                                sourceAppBundleID: b.sourceAppBundleID, sourceAppName: b.sourceAppName,
                                createdAt: b.createdAt, lastUsedAt: b.lastUsedAt, useCount: b.useCount,
                                isPinned: b.isPinned, customTitle: b.customTitle, contentHash: b.contentHash,
                                pasteCount: b.pasteCount ?? 0)
            store.insertImported(item, png: b.imagePNG)
            idMap[b.id] = store.item(withHash: b.contentHash)?.id ?? b.id
            result.added += 1
        }
        store.finishImport()

        for bl in file.lists {
            let list = store.lists.first { $0.name == bl.name } ?? {
                result.lists += 1
                return store.createList(name: bl.name)
            }()
            for oldID in bl.itemIDs.reversed() {
                if let newID = idMap[oldID] { store.add(newID, toList: list.id) }
            }
        }
        for smart in file.smartLists ?? [] where !store.smartLists.contains(where: { $0.name == smart.name }) {
            store.createSmartList(name: smart.name, symbol: smart.symbol, rules: smart.rules, matchAll: smart.matchAll)
        }
        return result
    }
}

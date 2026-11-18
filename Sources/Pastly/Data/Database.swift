import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue {
    case text(String?)
    case blob(Data?)
    case real(Double)
    case int(Int)
}

struct SQLRow {
    let stmt: OpaquePointer

    func string(_ i: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: c)
    }

    func data(_ i: Int32) -> Data? {
        guard sqlite3_column_type(stmt, i) != SQLITE_NULL, let b = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: b, count: Int(sqlite3_column_bytes(stmt, i)))
    }

    func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
}

enum DatabaseError: Error {
    case open(String)
}

/// Minimal SQLite wrapper (no third-party dependencies).
final class Database {
    private var db: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw DatabaseError.open(String(cString: sqlite3_errmsg(db)))
        }
        exec("PRAGMA journal_mode=WAL;")
        migrate()
    }

    deinit { sqlite3_close(db) }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            NSLog("Pastly SQL error: %@", err.map { String(cString: $0) } ?? lastError)
            sqlite3_free(err)
        }
        return rc == SQLITE_OK
    }

    @discardableResult
    func run(_ sql: String, _ values: [SQLValue] = []) -> Bool {
        guard let stmt = prepare(sql, values) else { return false }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            NSLog("Pastly SQL error: %@", lastError)
            return false
        }
        return true
    }

    func query(_ sql: String, _ values: [SQLValue] = [], _ each: (SQLRow) -> Void) {
        guard let stmt = prepare(sql, values) else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(SQLRow(stmt: stmt)) }
    }

    func transaction(_ body: () -> Void) {
        exec("BEGIN;")
        body()
        exec("COMMIT;")
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            NSLog("Pastly SQL prepare error: %@", lastError)
            return nil
        }
        for (i, value) in values.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .text(let str?):
                sqlite3_bind_text(s, idx, str, -1, SQLITE_TRANSIENT)
            case .blob(let data?):
                if data.isEmpty {
                    sqlite3_bind_zeroblob(s, idx, 0)
                } else {
                    data.withUnsafeBytes { p in
                        _ = sqlite3_bind_blob(s, idx, p.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                    }
                }
            case .real(let d):
                sqlite3_bind_double(s, idx, d)
            case .int(let n):
                sqlite3_bind_int64(s, idx, sqlite3_int64(n))
            case .text(nil), .blob(nil):
                sqlite3_bind_null(s, idx)
            }
        }
        return s
    }

    private func migrate() {
        var version = 0
        query("PRAGMA user_version;") { version = $0.int(0) }
        if version < 1 {
            exec("""
            CREATE TABLE IF NOT EXISTS items (
              id TEXT PRIMARY KEY,
              type TEXT NOT NULL,
              primary_uti TEXT NOT NULL,
              plain_text TEXT,
              rtf BLOB,
              html BLOB,
              image_path TEXT,
              image_w INTEGER NOT NULL DEFAULT 0,
              image_h INTEGER NOT NULL DEFAULT 0,
              file_urls TEXT,
              color_hex TEXT,
              source_bundle TEXT,
              source_name TEXT,
              created_at REAL NOT NULL,
              last_used_at REAL NOT NULL,
              use_count INTEGER NOT NULL DEFAULT 1,
              is_pinned INTEGER NOT NULL DEFAULT 0,
              custom_title TEXT,
              content_hash TEXT NOT NULL UNIQUE
            );
            CREATE INDEX IF NOT EXISTS idx_items_last_used ON items(last_used_at DESC);
            CREATE TABLE IF NOT EXISTS lists (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              color TEXT,
              sort_order INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS list_items (
              list_id TEXT NOT NULL,
              item_id TEXT NOT NULL,
              sort_order INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (list_id, item_id)
            );
            PRAGMA user_version = 1;
            """)
            version = 1
        }
        if version < 2 {
            exec("""
            ALTER TABLE items ADD COLUMN paste_count INTEGER NOT NULL DEFAULT 0;
            CREATE TABLE IF NOT EXISTS smart_lists (
              id TEXT PRIMARY KEY,
              json TEXT NOT NULL,
              sort_order INTEGER NOT NULL DEFAULT 0
            );
            PRAGMA user_version = 2;
            """)
            for list in SmartList.defaults { saveSmartList(list) }
        }
    }
}

// MARK: - Items & lists

extension Database {
    private static let itemColumns = "id, type, primary_uti, plain_text, rtf, html, image_path, image_w, image_h, file_urls, color_hex, source_bundle, source_name, created_at, last_used_at, use_count, is_pinned, custom_title, content_hash, paste_count"

    func loadItems() -> [ClipItem] {
        var out: [ClipItem] = []
        query("SELECT \(Self.itemColumns) FROM items ORDER BY last_used_at DESC;") { r in
            guard let id = r.string(0),
                  let type = ClipType(rawValue: r.string(1) ?? ""),
                  let hash = r.string(18) else { return }
            let files = (r.string(9) ?? "")
                .split(separator: "\n")
                .map { URL(fileURLWithPath: String($0)) }
            out.append(ClipItem(
                id: id, type: type, primaryUTI: r.string(2) ?? type.canonicalUTI,
                plainText: r.string(3), rtfData: r.data(4), htmlData: r.data(5),
                imagePath: r.string(6), imageWidth: r.int(7), imageHeight: r.int(8),
                fileURLs: files, colorHex: r.string(10),
                sourceAppBundleID: r.string(11), sourceAppName: r.string(12),
                createdAt: Date(timeIntervalSince1970: r.double(13)),
                lastUsedAt: Date(timeIntervalSince1970: r.double(14)),
                useCount: r.int(15), isPinned: r.int(16) != 0,
                customTitle: r.string(17), contentHash: hash, pasteCount: r.int(19)))
        }
        return out
    }

    @discardableResult
    func save(_ i: ClipItem) -> Bool {
        run("""
        INSERT INTO items (\(Self.itemColumns)) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          type=excluded.type, primary_uti=excluded.primary_uti, plain_text=excluded.plain_text,
          rtf=excluded.rtf, html=excluded.html, image_path=excluded.image_path,
          image_w=excluded.image_w, image_h=excluded.image_h, file_urls=excluded.file_urls,
          color_hex=excluded.color_hex, source_bundle=excluded.source_bundle, source_name=excluded.source_name,
          last_used_at=excluded.last_used_at, use_count=excluded.use_count, is_pinned=excluded.is_pinned,
          custom_title=excluded.custom_title, content_hash=excluded.content_hash, paste_count=excluded.paste_count;
        """, [
            .text(i.id), .text(i.type.rawValue), .text(i.primaryUTI), .text(i.plainText),
            .blob(i.rtfData), .blob(i.htmlData), .text(i.imagePath),
            .int(i.imageWidth), .int(i.imageHeight),
            .text(i.fileURLs.isEmpty ? nil : i.fileURLs.map(\.path).joined(separator: "\n")),
            .text(i.colorHex), .text(i.sourceAppBundleID), .text(i.sourceAppName),
            .real(i.createdAt.timeIntervalSince1970), .real(i.lastUsedAt.timeIntervalSince1970),
            .int(i.useCount), .int(i.isPinned ? 1 : 0), .text(i.customTitle), .text(i.contentHash),
            .int(i.pasteCount),
        ])
    }

    func deleteItems(_ ids: [String]) {
        transaction {
            for id in ids {
                run("DELETE FROM items WHERE id = ?;", [.text(id)])
                run("DELETE FROM list_items WHERE item_id = ?;", [.text(id)])
            }
        }
    }

    func loadLists() -> [ClipList] {
        var lists: [ClipList] = []
        query("SELECT id, name, color, sort_order FROM lists ORDER BY sort_order, name;") { r in
            guard let id = r.string(0), let name = r.string(1) else { return }
            lists.append(ClipList(id: id, name: name, color: r.string(2) ?? "blue", sortOrder: r.int(3)))
        }
        for idx in lists.indices {
            var ids: [String] = []
            query("SELECT item_id FROM list_items WHERE list_id = ? ORDER BY sort_order;", [.text(lists[idx].id)]) { r in
                if let s = r.string(0) { ids.append(s) }
            }
            lists[idx].itemIDs = ids
        }
        return lists
    }

    func saveList(_ l: ClipList) {
        transaction {
            run("""
            INSERT INTO lists (id, name, color, sort_order) VALUES (?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, color=excluded.color, sort_order=excluded.sort_order;
            """, [.text(l.id), .text(l.name), .text(l.color), .int(l.sortOrder)])
            run("DELETE FROM list_items WHERE list_id = ?;", [.text(l.id)])
            for (n, itemID) in l.itemIDs.enumerated() {
                run("INSERT OR IGNORE INTO list_items (list_id, item_id, sort_order) VALUES (?,?,?);",
                    [.text(l.id), .text(itemID), .int(n)])
            }
        }
    }

    func loadSmartLists() -> [SmartList] {
        var out: [SmartList] = []
        query("SELECT json FROM smart_lists ORDER BY sort_order;") { r in
            if let s = r.string(0), let d = s.data(using: .utf8), let l = try? JSONDecoder().decode(SmartList.self, from: d) {
                out.append(l)
            }
        }
        return out
    }

    func saveSmartList(_ l: SmartList) {
        guard let d = try? JSONEncoder().encode(l), let json = String(data: d, encoding: .utf8) else { return }
        run("""
        INSERT INTO smart_lists (id, json, sort_order) VALUES (?,?,?)
        ON CONFLICT(id) DO UPDATE SET json=excluded.json, sort_order=excluded.sort_order;
        """, [.text(l.id), .text(json), .int(l.sortOrder)])
    }

    func deleteSmartList(_ id: String) {
        run("DELETE FROM smart_lists WHERE id = ?;", [.text(id)])
    }

    func deleteList(_ id: String) {
        transaction {
            run("DELETE FROM lists WHERE id = ?;", [.text(id)])
            run("DELETE FROM list_items WHERE list_id = ?;", [.text(id)])
        }
    }
}

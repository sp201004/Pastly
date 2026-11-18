import AppKit

/// One-time, non-destructive import of data from earlier versions of the app.
///
/// - History: the earlier data folder (`legacyFolderName` in Application Support) is **copied** to `…/Pastly` — only when
///   `…/Pastly` doesn't exist yet. The copy is made in a temporary folder next to it and renamed into
///   place in one step, so a half-finished copy never looks like real data. The old folder is never
///   modified or deleted, and an existing Pastly folder is never overwritten.
/// - Preferences: keys from the old preferences domain are copied into Pastly's only where Pastly
///   has no value yet, once (a flag records it). The old domain is left untouched.
///
/// Both steps are idempotent: running them again does nothing.
enum LegacyMigration {
    static let legacyBundleID = ["com", "pastestash", "PasteStash"].joined(separator: ".")
    static let legacyFolderName = ["Paste", "Stash"].joined()
    static let folderName = "Pastly"
    static let preferencesFlag = "migratedLegacyPreferences"
    static let markerFileName = "Imported from an earlier version.txt"

    enum DataResult: Equatable { case notNeeded, alreadyDone, copied, failed(String) }

    /// Window-frame autosave names that changed since earlier versions.
    static let renamedKeys = [
        "NSWindow Frame " + legacyFolderName + "Panel": "NSWindow Frame PastlyPanel",
        "NSWindow Frame " + legacyFolderName + "Popover": "NSWindow Frame PastlyPopover",
    ]

    static func needsDataMigration(appSupport: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: appSupport.appendingPathComponent(legacyFolderName).path)
            && !fm.fileExists(atPath: appSupport.appendingPathComponent(folderName).path)
    }

    /// Copies the old data folder to the new one (see type comment). Never deletes or overwrites user data.
    static func migrateData(appSupport: URL) -> DataResult {
        let fm = FileManager.default
        let old = appSupport.appendingPathComponent(legacyFolderName, isDirectory: true)
        let new = appSupport.appendingPathComponent(folderName, isDirectory: true)
        guard fm.fileExists(atPath: old.path) else { return .notNeeded }
        guard !fm.fileExists(atPath: new.path) else { return .alreadyDone }
        let staging = appSupport.appendingPathComponent(".\(folderName)-migration-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.copyItem(at: old, to: staging)   // keeps permissions (0700 / 0600)
            let note = """
            Pastly copied this history from \(old.path) on \(ISO8601DateFormatter().string(from: Date())).
            The original folder was left unchanged. After checking that Pastly shows your history,
            you can delete the old folder yourself if you no longer need it.

            """
            try? Data(note.utf8).write(to: staging.appendingPathComponent(markerFileName))
            try fm.moveItem(at: staging, to: new)   // same volume: an atomic rename; fails if `new` appeared meanwhile
            return .copied
        } catch {
            try? fm.removeItem(at: staging)         // only our own temporary copy
            return fm.fileExists(atPath: new.path) ? .alreadyDone : .failed(error.localizedDescription)
        }
    }

    /// Copies legacy preference values that Pastly hasn't saved yet. `existing` is Pastly's persisted domain
    /// (registered defaults don't count as saved). Returns the number of keys copied.
    @discardableResult
    static func migratePreferences(legacy: [String: Any]?, existing: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard existing?[preferencesFlag] as? Bool != true else { return 0 }
        var copied = 0
        for (key, value) in legacy ?? [:] {
            let target = renamedKeys[key] ?? key
            if existing?[target] == nil { defaults.set(value, forKey: target); copied += 1 }
        }
        defaults.set(true, forKey: preferencesFlag)
        return copied
    }

    // MARK: At launch (real app only)

    /// Runs before the history store opens. Returns false if Pastly should quit (the user chose not to
    /// quit the old app, which would keep writing to the data being copied).
    static func runAtLaunch() -> Bool {
        guard !Preferences.isDemo else { return true }
        let own = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        migratePreferences(legacy: UserDefaults.standard.persistentDomain(forName: legacyBundleID), existing: own, into: .standard)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard needsDataMigration(appSupport: appSupport) else { return true }

        let running = NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID)
        if !running.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "An older version of Pastly is still running"
            alert.informativeText = """
            To bring over your clipboard history and settings, the older version needs to quit first. \
            Your existing data is copied, never moved or deleted.
            """
            alert.addButton(withTitle: "Quit Older Version and Continue")
            alert.addButton(withTitle: "Quit Pastly")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            running.forEach { $0.terminate() }
            let deadline = Date().addingTimeInterval(10)
            while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            guard running.allSatisfy(\.isTerminated) else {
                showFailure("The older version didn't quit. Quit it from its menu bar icon, then open Pastly again.")
                return false
            }
        }

        switch migrateData(appSupport: appSupport) {
        case .copied:
            NSLog("Pastly: copied history from an earlier version's folder (original left unchanged)")
            return true
        case .notNeeded, .alreadyDone:
            return true
        case .failed(let reason):
            NSLog("Pastly: history migration failed: %@", reason)
            showFailure("Pastly couldn't copy your earlier history (\(reason)). Nothing was changed. "
                        + "Quit Pastly and try again, or restore a backup in Settings → Backup.")
            return false
        }
    }

    private static func showFailure(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Your history wasn't moved to Pastly"
        alert.informativeText = text
        alert.runModal()
    }
}

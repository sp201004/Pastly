import AppKit

// MARK: - Sensitive content (Settings → Privacy)

/// Optional detectors for text that usually shouldn't be kept in history.
enum SensitiveDetector {
    private static let secretPatterns: [NSRegularExpression] = [
        #"\bAKIA[0-9A-Z]{16}\b"#,                                   // AWS access key
        #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#,                          // GitHub token
        #"\bgithub_pat_[A-Za-z0-9_]{40,}\b"#,
        #"\bsk-[A-Za-z0-9_\-]{20,}\b"#,                              // OpenAI / Anthropic style keys
        #"\bsk_(live|test)_[A-Za-z0-9]{16,}\b"#,                     // Stripe
        #"\bxox[abprs]-[A-Za-z0-9\-]{10,}\b"#,                       // Slack
        #"\bAIza[0-9A-Za-z_\-]{35}\b"#,                              // Google API key
        #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, // JWT
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,                      // private keys
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func isCardNumber(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 23, t.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else { return false }
        let digits = t.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        // Luhn checksum
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    /// A copied text that is only a 4–8 digit code (optionally split as 123-456 / 123 456).
    static func isOneTimeCode(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 9 else { return false }
        let digits = t.filter(\.isNumber)
        guard (4...8).contains(digits.count) else { return false }
        return t.allSatisfy { $0.isNumber || $0 == "-" || $0 == " " }
    }

    static func containsSecret(_ text: String) -> Bool {
        let sample = String(text.prefix(20_000))
        let range = NSRange(sample.startIndex..., in: sample)
        return secretPatterns.contains { $0.firstMatch(in: sample, range: range) != nil }
    }

    struct Options { var cards: Bool; var codes: Bool; var secrets: Bool }

    static var currentOptions: Options {
        let p = Preferences.shared
        return Options(cards: p.skipCardNumbers, codes: p.skipOneTimeCodes, secrets: p.skipSecrets)
    }
}

// MARK: - Secure storage

/// History is readable only by your macOS account: folders 0700, files 0600.
enum SecureStorage {
    static func apply(to directory: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in e {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try? fm.setAttributes([.posixPermissions: isDir ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
    }

    /// True when the folder and every file inside are private to the current user.
    static func isPrivate(_ directory: URL) -> Bool {
        let fm = FileManager.default
        func perms(_ path: String) -> Int { ((try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber)?.intValue ?? 0o777 }
        guard perms(directory.path) & 0o077 == 0 else { return false }
        guard let e = fm.enumerator(atPath: directory.path) else { return true }
        for case let rel as String in e where perms(directory.appendingPathComponent(rel).path) & 0o077 != 0 {
            return false
        }
        return true
    }
}

// MARK: - Automatic backups (Settings → Backup)

enum AutoBackup {
    struct Entry: Identifiable { let url: URL; let date: Date; let size: Int64; var id: URL { url } }

    static var folder: URL { URL(fileURLWithPath: Preferences.shared.autoBackupFolder, isDirectory: true) }

    static var interval: TimeInterval { Preferences.shared.autoBackupFrequency == "weekly" ? 7 * 86_400 : 86_400 }

    static func isDue(now: Date = Date()) -> Bool {
        let p = Preferences.shared
        return p.autoBackupEnabled && now.timeIntervalSince1970 - p.lastAutoBackup >= interval
    }

    /// Called at launch and every hour.
    static func runIfDue() {
        guard isDue() else { return }
        do { _ = try backupNow() } catch { NSLog("Pastly: automatic backup failed: \(error)") }
    }

    /// Writes a dated backup into the backup folder and removes the oldest beyond the keep limit.
    @discardableResult
    static func backupNow(store: ClipStore = .shared, to dir: URL? = nil, keep: Int? = nil) throws -> URL {
        let dir = dir ?? folder
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HHmmss"
        let url = dir.appendingPathComponent("Pastly Backup \(df.string(from: Date())).\(BackupService.fileExtension)")
        try BackupService.export(store, to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if dir == folder { Preferences.shared.lastAutoBackup = Date().timeIntervalSince1970 }
        prune(in: dir, keep: keep ?? Preferences.shared.autoBackupKeep)
        return url
    }

    static func existingBackups(in dir: URL? = nil) -> [Entry] {
        let dir = dir ?? folder
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return urls.filter { BackupService.readableExtensions.contains($0.pathExtension) }.compactMap { url in
            let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return Entry(url: url, date: v?.contentModificationDate ?? .distantPast, size: Int64(v?.fileSize ?? 0))
        }
        .sorted { $0.date > $1.date }
    }

    static func prune(in dir: URL, keep: Int) {
        guard keep > 0 else { return }
        // Only Pastly's own automatic backups are pruned; older Pastly backups are never deleted.
        let own = existingBackups(in: dir).filter { $0.url.pathExtension == BackupService.fileExtension }
        for old in own.dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
    }

    /// Restores a backup. `replace` first removes the current history (lists themselves are kept).
    static func restore(from url: URL, replace: Bool, into store: ClipStore = .shared) throws -> BackupService.ImportResult {
        // Validate before touching anything.
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        _ = try dec.decode(BackupFile.self, from: Data(contentsOf: url))
        if replace { store.clearHistory(everything: true) }
        return try BackupService.importBackup(from: url, into: store)
    }
}

// MARK: - App info, updates (Settings → About)

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev" }

    /// "owner/repo" from Info.plist key PastlyGitHubRepository.
    static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "PastlyGitHubRepository") as? String ?? "your-github-username/Pastly"
    }
    static var isRepositoryConfigured: Bool { !repository.hasPrefix("your-github-username") }
    static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
    static var releasesURL: URL { URL(string: "https://github.com/\(repository)/releases")! }

    static func bundledText(_ name: String, ext: String) -> String? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext), let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        // Running from `swift build`: read from the project folder next to the binary.
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = dir.appendingPathComponent("\(name).\(ext)")
            if let s = try? String(contentsOf: candidate, encoding: .utf8) { return s }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static var license: String { bundledText("LICENSE", ext: "txt") ?? bundledText("LICENSE", ext: "") ?? "MIT License — see LICENSE in the Pastly repository." }
    static var changelog: String { bundledText("CHANGELOG", ext: "md") ?? "See CHANGELOG.md in the Pastly repository." }
}

enum UpdateChecker {
    enum Result: Equatable {
        case upToDate(String)
        case available(version: String, url: URL, notes: String)
        case notConfigured
        case failed(String)
    }

    /// Compares dotted versions: "0.10.0" > "0.9.2".
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Asks GitHub for the latest release. Only runs when you click "Check for Updates"
    /// or turn on automatic checks; nothing else is sent.
    static func check(completion: @escaping (Result) -> Void) {
        guard AppInfo.isRepositoryConfigured,
              let url = URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest") else {
            completion(.notConfigured)
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Pastly/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, response, error in
            let result: Result
            if let error {
                result = .failed(error.localizedDescription)
            } else if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                result = .failed("No releases have been published yet.")
            } else if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String {
                let page = (json["html_url"] as? String).flatMap(URL.init(string:)) ?? AppInfo.releasesURL
                let notes = json["body"] as? String ?? ""
                result = isNewer(tag, than: AppInfo.version) ? .available(version: tag, url: page, notes: notes)
                                                             : .upToDate(AppInfo.version)
            } else {
                result = .failed("Unexpected response from GitHub.")
            }
            DispatchQueue.main.async {
                Preferences.shared.lastUpdateCheck = Date().timeIntervalSince1970
                completion(result)
            }
        }.resume()
    }

    /// Weekly background check when enabled in Settings → About.
    static func checkAutomaticallyIfDue() {
        let p = Preferences.shared
        guard p.checkUpdatesAutomatically, Date().timeIntervalSince1970 - p.lastUpdateCheck > 7 * 86_400 else { return }
        check { result in
            if case .available(let v, _, _) = result { Toast.show("Pastly \(v) is available — see Settings → About", duration: 4) }
        }
    }
}

// MARK: - Shortcut conflicts

extension HotKeyManager {
    /// Common system and app shortcuts that a global Pastly shortcut must not take over.
    static func reservedReason(keyCode: Int, modifiers: Int) -> String? {
        let cmd = 256, shift = 512, opt = 2048, ctrl = 4096
        let reserved: [(Int, Int, String)] = [
            (8, cmd, "⌘C is Copy in every app"), (9, cmd, "⌘V is Paste in every app"),
            (7, cmd, "⌘X is Cut in every app"), (6, cmd, "⌘Z is Undo in every app"),
            (0, cmd, "⌘A is Select All in every app"), (12, cmd, "⌘Q quits apps"),
            (13, cmd, "⌘W closes windows"), (48, cmd, "⌘⇥ switches apps"),
            (49, cmd, "⌘Space opens Spotlight"), (49, ctrl, "⌃Space switches input sources"),
            (20, cmd | shift, "⇧⌘3 takes a screenshot"), (21, cmd | shift, "⇧⌘4 takes a screenshot"),
            (23, cmd | shift, "⇧⌘5 opens Screenshot"), (49, cmd | opt, "⌥⌘Space opens a Finder search"),
            (53, cmd | opt, "⌥⌘esc is Force Quit"),
        ]
        return reserved.first { $0.0 == keyCode && $0.1 == modifiers }?.2
    }
}

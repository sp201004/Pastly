import AppKit

enum ClipType: String, Codable, CaseIterable, Identifiable {
    case text, url, color, image, file

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .url: return "Links"
        case .color: return "Colors"
        case .image: return "Images"
        case .file: return "Files"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    /// Hashing identifier for colors, kept from earlier versions. Changing it would
    /// change the content hash of every saved color and break duplicate detection for existing history.
    static let legacyColorUTI = ["com", "pastly", "color"].joined(separator: ".")

    /// Canonical UTI used for content hashing.
    var canonicalUTI: String {
        switch self {
        case .text: return "public.plain-text"
        case .url: return "public.url"
        case .color: return Self.legacyColorUTI   // frozen: stored content hashes depend on it
        case .image: return "public.image"
        case .file: return "public.file-url"
        }
    }

    var isTextual: Bool { self == .text || self == .url || self == .color }
}

struct ClipItem: Identifiable {
    var id: String = UUID().uuidString
    var type: ClipType
    var primaryUTI: String
    var plainText: String?
    var rtfData: Data?
    var htmlData: Data?
    var imagePath: String?
    var imageWidth: Int = 0
    var imageHeight: Int = 0
    var fileURLs: [URL] = []
    var colorHex: String?
    var sourceAppBundleID: String?
    var sourceAppName: String?
    var createdAt: Date = Date()
    var lastUsedAt: Date = Date()
    var useCount: Int = 1
    var isPinned: Bool = false
    var customTitle: String?
    var contentHash: String
    var pasteCount: Int = 0

    /// Text that looks like source code (gets the Code tab and syntax highlighting).
    var isCode: Bool { type == .text && CodeDetector.isCode(plainText ?? "") }

    var displayText: String {
        if let t = customTitle, !t.isEmpty { return t }
        switch type {
        case .text, .url:
            let t = (plainText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return String(t.prefix(500))
        case .color: return colorHex ?? ""
        case .image: return "Image \(imageWidth) × \(imageHeight)"
        case .file:
            let names = fileURLs.map(\.lastPathComponent)
            return names.count > 3 ? names.prefix(3).joined(separator: ", ") + " +\(names.count - 3) more" : names.joined(separator: ", ")
        }
    }

    /// Text representation used for pasting text, OCR, transforms, and drag.
    var pasteableText: String? {
        switch type {
        case .text, .url: return plainText
        case .color: return colorHex
        case .file: return fileURLs.map(\.path).joined(separator: "\n")
        case .image: return nil
        }
    }

    var searchBlob: String {
        [customTitle, plainText.map { String($0.prefix(20_000)) }, colorHex,
         fileURLs.map(\.path).joined(separator: " "), sourceAppName, type.displayName]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

struct ClipList: Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var color: String
    var sortOrder: Int
    var itemIDs: [String] = []

    static let palette = ["blue", "purple", "pink", "orange", "green", "teal", "red", "yellow"]
}

enum Collection: Hashable {
    case all
    case pinned
    case type(ClipType)
    case code
    case smart(String)
    case list(String)
}

// MARK: - Smart Lists (rule-based, fill themselves)

struct SmartRule: Codable, Hashable, Identifiable {
    enum Field: String, Codable, CaseIterable, Identifiable {
        case type, app, text, age, pinned, domain, pattern, date
        var id: String { rawValue }
        var title: String {
            switch self {
            case .type: return "Kind"
            case .app: return "Copied from app"
            case .text: return "Text"
            case .age: return "Last used"
            case .pinned: return "Pinned"
            case .domain: return "Link domain"
            case .pattern: return "Text pattern"
            case .date: return "First copied"
            }
        }
        var operators: [Op] {
            switch self {
            case .type, .app, .pinned: return [.is, .isNot]
            case .text: return [.contains, .notContains]
            case .age: return [.withinDays, .olderThanDays]
            case .domain: return [.is, .contains, .isNot]
            case .pattern: return [.matches, .notMatches]
            case .date: return [.onOrAfter, .before]
            }
        }
    }

    enum Op: String, Codable, CaseIterable, Identifiable {
        case `is`, isNot, contains, notContains, withinDays, olderThanDays, matches, notMatches, onOrAfter, before
        var id: String { rawValue }
        var title: String {
            switch self {
            case .matches: return "matches"
            case .notMatches: return "does not match"
            case .onOrAfter: return "on or after"
            case .before: return "before"
            case .is: return "is"
            case .isNot: return "is not"
            case .contains: return "contains"
            case .notContains: return "does not contain"
            case .withinDays: return "within the last"
            case .olderThanDays: return "more than"
            }
        }
    }

    /// Value for `.type` rules: a ClipType raw value or "code".
    static let codeKind = "code"

    var id: String = UUID().uuidString
    var field: Field
    var op: Op
    var value: String

    /// `ctx` (the history store) supplies cached search text, link hosts, code detection and pattern
    /// results; without it everything is computed directly (same answers, just slower).
    func matches(_ item: ClipItem, now: Date = Date(), ctx: SmartRuleContext? = nil) -> Bool {
        switch field {
        case .type:
            let isKind = value == Self.codeKind ? (ctx?.isCode(item) ?? item.isCode) : item.type.rawValue == value
            return op == .isNot ? !isKind : isKind
        case .app:
            let same = item.sourceAppBundleID == value
                || (item.sourceAppName?.localizedCaseInsensitiveCompare(value) == .orderedSame)
            return op == .isNot ? !same : same
        case .text:
            guard !value.isEmpty else { return true }
            let has = (ctx?.searchBlob(item) ?? item.searchBlob).contains(value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
            return op == .notContains ? !has : has
        case .age:
            let days = Double(Int(value) ?? 7)
            let within = now.timeIntervalSince(item.lastUsedAt) <= days * 86_400
            return op == .olderThanDays ? !within : within
        case .pinned:
            let wantPinned = value != "false"
            return (item.isPinned == wantPinned) != (op == .isNot)
        case .domain:
            let wanted = value.lowercased().trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            guard !wanted.isEmpty else { return true }
            let hosts = ctx?.hosts(item) ?? Self.hosts(in: item)
            let hit: Bool
            switch op {
            case .contains: hit = hosts.contains { $0.contains(wanted) }
            default: hit = hosts.contains { $0 == wanted || $0.hasSuffix("." + wanted) }   // "apple.com" matches developer.apple.com
            }
            return op == .isNot ? !hit : hit
        case .pattern:
            guard let re = Self.regex(value) else { return op == .notMatches }
            let hit = ctx?.patternMatches(re, pattern: value, item) ?? Self.firstMatch(re, in: item)
            return op == .notMatches ? !hit : hit
        case .date:
            guard let day = Self.dayFormatter.date(from: value) else { return true }
            let start = Calendar.current.startOfDay(for: day)
            return op == .before ? item.createdAt < start : item.createdAt >= start
        }
    }

    /// Dates are stored as "yyyy-MM-dd" (local day).
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Compiled pattern-rule expressions, shared (compiling one per clip per redraw was the main cost).
    private static var regexCache: [String: NSRegularExpression?] = [:]
    private static let regexLock = NSLock()
    static func regex(_ pattern: String) -> NSRegularExpression? {
        regexLock.lock(); defer { regexLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        if regexCache.count > 200 { regexCache.removeAll() }
        regexCache[pattern] = re
        return re
    }

    static func firstMatch(_ re: NSRegularExpression, in item: ClipItem) -> Bool {
        let text = item.pasteableText ?? ""
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s<>"']+"#, options: [.caseInsensitive])

    /// Lower-cased hosts of a link clip, or of links found inside a text clip (www. removed).
    static func hosts(in item: ClipItem) -> [String] {
        let text = item.plainText ?? ""
        var urls: [String] = []
        if item.type == .url { urls = [text] }
        else if item.type == .text {
            let sample = String(text.prefix(20_000))
            urls = urlRegex.matches(in: sample, range: NSRange(sample.startIndex..., in: sample))
                .compactMap { Range($0.range, in: sample).map { String(sample[$0]) } }
        }
        return urls.compactMap { URL(string: $0)?.host?.lowercased() }
            .map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }
}

/// Cached per-clip facts used by Smart List rules (provided by the history store).
protocol SmartRuleContext: AnyObject {
    func searchBlob(_ item: ClipItem) -> String
    func hosts(_ item: ClipItem) -> [String]
    func isCode(_ item: ClipItem) -> Bool
    func patternMatches(_ re: NSRegularExpression, pattern: String, _ item: ClipItem) -> Bool
}

struct SmartList: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var symbol: String = "sparkles"
    var matchAll: Bool = true
    var rules: [SmartRule]
    var sortOrder: Int = 0

    func matches(_ item: ClipItem, now: Date = Date(), ctx: SmartRuleContext? = nil) -> Bool {
        guard !rules.isEmpty else { return true }
        return matchAll ? rules.allSatisfy { $0.matches(item, now: now, ctx: ctx) }
                        : rules.contains { $0.matches(item, now: now, ctx: ctx) }
    }

    static let symbols = ["sparkles", "clock", "calendar", "hammer", "globe", "envelope", "paintbrush",
                          "photo", "doc.text", "terminal", "star", "bolt", "tag", "folder", "bookmark"]

    static var defaults: [SmartList] {
        [
            SmartList(name: "Today", symbol: "sun.max", rules: [SmartRule(field: .age, op: .withinDays, value: "1")], sortOrder: 0),
            SmartList(name: "This Week", symbol: "calendar", rules: [SmartRule(field: .age, op: .withinDays, value: "7")], sortOrder: 1),
        ]
    }
}

// MARK: - Code detection

enum CodeDetector {
    private static let keywords = [
        "func ", "def ", "class ", "struct ", "enum ", "import ", "return ", "const ", "let ", "var ",
        "function ", "=> ", "->", "#include", "public ", "private ", "static ", "SELECT ", " FROM ", "WHERE ",
        "if (", "for (", "while (", "elif ", "fn ", "impl ", "package ", "</", "/>", "console.log",
        "print(", "#!/", "async ", "await ", "interface ", "namespace ", "try {", "catch", "self.", "this.",
    ]

    static func isCode(_ s: String) -> Bool {
        let sample = String(s.prefix(4000))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
           let d = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: d)) != nil {
            return true
        }
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        var score = keywords.reduce(0) { $0 + (sample.contains($1) ? 2 : 0) }
        score += lines.reduce(0) { acc, line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return acc + ((t.hasSuffix(";") || t.hasSuffix("{") || t.hasSuffix("}") || t.hasSuffix(");")) ? 2 : 0)
        }
        if lines.count > 1 {
            score += min(lines.filter { $0.hasPrefix("    ") || $0.hasPrefix("\t") }.count, 4)
        }
        score -= max(0, sample.components(separatedBy: ". ").count - 1) * 2   // prose has sentences
        return score >= 6
    }
}

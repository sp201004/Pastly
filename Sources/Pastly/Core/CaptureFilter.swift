import Foundation

/// A keyword exclusion: copies containing this word or phrase are not saved.
struct KeywordRule: Codable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var keyword: String
    var matchCase: Bool = false
    var enabled: Bool = true

    func matches(_ text: String) -> Bool {
        guard enabled, !keyword.isEmpty else { return false }
        return matchCase ? text.contains(keyword)
                         : text.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// Every content-based exclusion rule in one place, used by background capture and by the
/// "Test your rules" box in Settings → Privacy, so both always agree.
struct CaptureFilter {
    var excludedTypes: Set<String>
    var regexRules: [String]
    var keywordRules: [KeywordRule]
    var sensitive: SensitiveDetector.Options

    /// Snapshot of the current settings (taken on the main thread before background parsing).
    static var current: CaptureFilter {
        let p = Preferences.shared
        return CaptureFilter(excludedTypes: Set(p.excludedTypes), regexRules: p.activeRegexRules,
                             keywordRules: p.keywordRules.filter(\.enabled), sensitive: SensitiveDetector.currentOptions)
    }

    /// Why this clip would be skipped, or nil if it will be saved.
    func reason(type: ClipType, text: String?, isCode: Bool = false) -> String? {
        if excludedTypes.contains(type.rawValue) { return "\(type.displayName) aren't saved (Privacy → Content kinds)" }
        if isCode && excludedTypes.contains(SmartRule.codeKind) { return "Code isn't saved (Privacy → Content kinds)" }
        guard let text, !text.isEmpty else { return nil }
        if let k = keywordRules.first(where: { $0.matches(text) }) { return "Contains the keyword “\(k.keyword)”" }
        let range = NSRange(text.startIndex..., in: text)
        for rule in regexRules {
            if let re = try? NSRegularExpression(pattern: rule), re.firstMatch(in: text, range: range) != nil {
                return "Matches the pattern \(rule)"
            }
        }
        if sensitive.cards && SensitiveDetector.isCardNumber(text) { return "Looks like a card number" }
        if sensitive.codes && SensitiveDetector.isOneTimeCode(text) { return "Looks like a one-time code" }
        if sensitive.secrets && SensitiveDetector.containsSecret(text) { return "Looks like an API key, token or private key" }
        return nil
    }

    func reason(for parsed: ParsedClip) -> String? {
        let text = parsed.plainText ?? parsed.colorHex
        let code = parsed.type == .text && excludedTypes.contains(SmartRule.codeKind) && CodeDetector.isCode(parsed.plainText ?? "")
        return reason(type: parsed.type, text: text, isCode: code)
    }

    /// Full check for the tester: app rules + content rules.
    static func explain(text: String, appBundleID: String?) -> String? {
        let p = Preferences.shared
        if let app = appBundleID, p.activeIgnoredApps.contains(app) { return "Copies from \(AppIconCache.name(for: app)) are never saved" }
        let parsed = ClipItemParser.parseText(text, rtf: nil, html: nil, trimWhitespace: p.trimWhitespaceForDedup)
        return current.reason(for: parsed)
    }
}

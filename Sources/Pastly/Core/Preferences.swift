import AppKit
import SwiftUI

final class Preferences: ObservableObject {
    static let shared = Preferences()
    /// PASTLY_DEMO=1 (developer screenshots) uses a separate, throwaway preferences domain.
    static let isDemo = ProcessInfo.processInfo.environment["PASTLY_DEMO"] == "1"
    private let d: UserDefaults = Preferences.isDemo ? (UserDefaults(suiteName: "io.github.sp201004.pastly.demo") ?? .standard) : .standard

    static let defaultIgnoredApps = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "org.keepassxc.keepassxc",
        "com.dashlane.dashlanephonefinal",
    ]

    /// Default shortcut: ⇧⌘V  (kVK_ANSI_V = 9, cmdKey|shiftKey = 256|512)
    static let defaultHotKeyCode = 9
    static let defaultHotKeyModifiers = 768
    static let defaultHotKeyDisplay = "⇧⌘V"

    @Published var historyLimit: Int { didSet { d.set(historyLimit, forKey: "historyLimit") } }
    @Published var autoDeleteDays: Int { didSet { d.set(autoDeleteDays, forKey: "autoDeleteDays") } }
    @Published var isPaused: Bool { didSet { d.set(isPaused, forKey: "isPaused") } }
    @Published var autoPaste: Bool { didSet { d.set(autoPaste, forKey: "autoPaste") } }
    @Published var trimWhitespaceForDedup: Bool { didSet { d.set(trimWhitespaceForDedup, forKey: "trimWhitespaceForDedup") } }
    @Published var ignoredBundleIDs: [String] { didSet { d.set(ignoredBundleIDs, forKey: "ignoredBundleIDs") } }
    @Published var regexRules: [String] { didSet { d.set(regexRules, forKey: "regexRules") } }
    @Published var hotKeyCode: Int { didSet { d.set(hotKeyCode, forKey: "hotKeyCode") } }
    @Published var hotKeyModifiers: Int { didSet { d.set(hotKeyModifiers, forKey: "hotKeyModifiers") } }
    @Published var hotKeyDisplay: String { didSet { d.set(hotKeyDisplay, forKey: "hotKeyDisplay") } }
    @Published var hasOnboarded: Bool { didSet { d.set(hasOnboarded, forKey: "hasOnboarded") } }
    @Published var animateMenuBarIcon: Bool { didSet { d.set(animateMenuBarIcon, forKey: "animateMenuBarIcon") } }
    @Published var playSoundOnCopy: Bool { didSet { d.set(playSoundOnCopy, forKey: "playSoundOnCopy") } }
    @Published var playSoundOnPaste: Bool { didSet { d.set(playSoundOnPaste, forKey: "playSoundOnPaste") } }
    @Published var soundName: String { didSet { d.set(soundName, forKey: "soundName") } }
    @Published var soundVolume: Double { didSet { d.set(soundVolume, forKey: "soundVolume") } }

    // Appearance
    @Published var theme: String { didSet { d.set(theme, forKey: "theme"); Self.applyTheme(theme) } }      // system | light | dark
    @Published var rowDensity: String { didSet { d.set(rowDensity, forKey: "rowDensity") } }                // compact | comfortable
    @Published var textSize: String { didSet { d.set(textSize, forKey: "textSize") } }                      // small | medium | large
    @Published var showAppIcons: Bool { didSet { d.set(showAppIcons, forKey: "showAppIcons") } }
    @Published var showShortcutNumbers: Bool { didSet { d.set(showShortcutNumbers, forKey: "showShortcutNumbers") } }
    @Published var showTypeTabs: Bool { didSet { d.set(showTypeTabs, forKey: "showTypeTabs") } }
    @Published var openPosition: String { didSet { d.set(openPosition, forKey: "openPosition") } }          // menuBar | center | mouse
    @Published var translucent: Bool { didSet { d.set(translucent, forKey: "translucent") } }

    /// Extra global shortcuts (open-history uses hotKeyCode/Modifiers/Display above).
    @Published var extraHotKeys: [String: HotKeySpec] {
        didSet { d.set(try? JSONEncoder().encode(extraHotKeys), forKey: "extraHotKeys") }
    }

    // Appearance (added in the 7-section settings)
    @Published var accentColor: String { didSet { d.set(accentColor, forKey: "accentColor") } }       // system | blue | purple | …
    @Published var cornerRadius: Double { didSet { d.set(cornerRadius, forKey: "cornerRadius") } }     // item corner radius
    @Published var itemSpacing: Double { didSet { d.set(itemSpacing, forKey: "itemSpacing") } }       // gap between items
    @Published var animateList: Bool { didSet { d.set(animateList, forKey: "animateList") } }         // slide-in + glow for new items
    @Published var previewSide: String { didSet { d.set(previewSide, forKey: "previewSide") } }       // auto | left | right
    @Published var previewWidth: Double { didSet { d.set(previewWidth, forKey: "previewWidth") } }
    @Published var highlightCode: Bool { didSet { d.set(highlightCode, forKey: "highlightCode") } }

    // Paste & shortcuts
    @Published var pastePlainByDefault: Bool { didSet { d.set(pastePlainByDefault, forKey: "pastePlainByDefault") } }
    @Published var quickPasteEnabled: Bool { didSet { d.set(quickPasteEnabled, forKey: "quickPasteEnabled") } }
    @Published var quickPasteModifier: String { didSet { d.set(quickPasteModifier, forKey: "quickPasteModifier") } } // command | option | control
    @Published var spaceTogglesPreview: Bool { didSet { d.set(spaceTogglesPreview, forKey: "spaceTogglesPreview") } }
    /// Click Behavior (Settings → General → Clipboard History): true = Single Click to Preview (default),
    /// false = Single Click to Select. Read by `PanelState.clickRow` on every click.
    @Published var singleClickPreview: Bool { didSet { d.set(singleClickPreview, forKey: "singleClickPreview") } }
    @Published var deleteKeyDeletes: Bool { didSet { d.set(deleteKeyDeletes, forKey: "deleteKeyDeletes") } }

    // Privacy
    @Published var skipCardNumbers: Bool { didSet { d.set(skipCardNumbers, forKey: "skipCardNumbers") } }
    @Published var skipOneTimeCodes: Bool { didSet { d.set(skipOneTimeCodes, forKey: "skipOneTimeCodes") } }
    @Published var skipSecrets: Bool { didSet { d.set(skipSecrets, forKey: "skipSecrets") } }
    @Published var clearOnQuit: Bool { didSet { d.set(clearOnQuit, forKey: "clearOnQuit") } }

    // Exclusion rules (Settings → Privacy). Existing app/regex lists are kept as they were;
    // these add per-rule on/off switches, keyword rules and excluded content kinds.
    @Published var disabledIgnoredApps: [String] { didSet { d.set(disabledIgnoredApps, forKey: "disabledIgnoredApps") } }
    @Published var disabledRegexRules: [String] { didSet { d.set(disabledRegexRules, forKey: "disabledRegexRules") } }
    @Published var keywordRules: [KeywordRule] {
        didSet { d.set(try? JSONEncoder().encode(keywordRules), forKey: "keywordRules") }
    }
    @Published var excludedTypes: [String] { didSet { d.set(excludedTypes, forKey: "excludedTypes") } }

    /// Apps that are excluded right now (listed and switched on).
    var activeIgnoredApps: [String] { ignoredBundleIDs.filter { !disabledIgnoredApps.contains($0) } }
    var activeRegexRules: [String] { regexRules.filter { !disabledRegexRules.contains($0) } }

    // Backup
    @Published var autoBackupEnabled: Bool { didSet { d.set(autoBackupEnabled, forKey: "autoBackupEnabled") } }
    @Published var autoBackupFrequency: String { didSet { d.set(autoBackupFrequency, forKey: "autoBackupFrequency") } } // daily | weekly
    @Published var autoBackupFolder: String { didSet { d.set(autoBackupFolder, forKey: "autoBackupFolder") } }
    @Published var autoBackupKeep: Int { didSet { d.set(autoBackupKeep, forKey: "autoBackupKeep") } }
    @Published var lastAutoBackup: Double { didSet { d.set(lastAutoBackup, forKey: "lastAutoBackup") } }

    // About
    @Published var checkUpdatesAutomatically: Bool { didSet { d.set(checkUpdatesAutomatically, forKey: "checkUpdatesAutomatically") } }
    @Published var lastUpdateCheck: Double { didSet { d.set(lastUpdateCheck, forKey: "lastUpdateCheck") } }

    static let accentChoices = ["system", "blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "graphite"]
    static var defaultBackupFolder: String {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pastly Backups")).path
    }

    /// The accent used for selection, tabs and highlights in Pastly's windows.
    var accent: Color { Color(nsColor: accentNSColor) }

    var accentNSColor: NSColor { Self.accentNSColor(named: accentColor) }

    static func accentNSColor(named name: String) -> NSColor {
        switch name {
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "teal": return .systemTeal
        case "graphite": return .systemGray
        default: return .controlAccentColor
        }
    }

    /// Symbol shown in rows for quick paste (⌘1, ⌥1, ⌃1).
    var quickPasteSymbol: String {
        switch quickPasteModifier {
        case "option": return "⌥"
        case "control": return "⌃"
        default: return "⌘"
        }
    }

    /// Runtime only: ignore the next clipboard change ("Ignore Next Copy").
    @Published var skipNextCopy = false

    var fontScale: CGFloat {
        switch textSize {
        case "small": return 0.92
        case "large": return 1.15
        default: return 1
        }
    }

    static func applyTheme(_ theme: String) {
        guard let app = NSApp else { return }
        switch theme {
        case "light": app.appearance = NSAppearance(named: .aqua)
        case "dark": app.appearance = NSAppearance(named: .darkAqua)
        default: app.appearance = nil
        }
    }

    private init() {
        d.register(defaults: [
            "historyLimit": 500,
            "autoDeleteDays": 0,
            "isPaused": false,
            "autoPaste": true,
            "trimWhitespaceForDedup": false,
            "ignoredBundleIDs": Self.defaultIgnoredApps,
            "regexRules": [String](),
            "hotKeyCode": Self.defaultHotKeyCode,
            "hotKeyModifiers": Self.defaultHotKeyModifiers,
            "hotKeyDisplay": Self.defaultHotKeyDisplay,
            "hasOnboarded": false,
            "animateMenuBarIcon": true,
            "playSoundOnCopy": true,
            "playSoundOnPaste": false,
            "soundName": "macOS Alert Sound",
            "soundVolume": 0.5,
            "theme": "system",
            "rowDensity": "compact",
            "textSize": "medium",
            "showAppIcons": true,
            "showShortcutNumbers": true,
            "showTypeTabs": true,
            "openPosition": "menuBar",
            "translucent": true,
            "accentColor": "system",
            "cornerRadius": 7.0,
            "itemSpacing": 2.0,
            "animateList": true,
            "previewSide": "auto",
            "previewWidth": 400.0,
            "highlightCode": true,
            "pastePlainByDefault": false,
            "quickPasteEnabled": true,
            "quickPasteModifier": "command",
            "spaceTogglesPreview": true,
            "singleClickPreview": true,
            "deleteKeyDeletes": true,
            "skipCardNumbers": false,
            "skipOneTimeCodes": false,
            "skipSecrets": false,
            "clearOnQuit": false,
            "disabledIgnoredApps": [String](),
            "disabledRegexRules": [String](),
            "excludedTypes": [String](),
            "autoBackupEnabled": false,
            "autoBackupFrequency": "daily",
            "autoBackupFolder": Self.defaultBackupFolder,
            "autoBackupKeep": 7,
            "lastAutoBackup": 0.0,
            "checkUpdatesAutomatically": false,
            "lastUpdateCheck": 0.0,
        ])
        historyLimit = d.integer(forKey: "historyLimit")
        autoDeleteDays = d.integer(forKey: "autoDeleteDays")
        isPaused = d.bool(forKey: "isPaused")
        autoPaste = d.bool(forKey: "autoPaste")
        trimWhitespaceForDedup = d.bool(forKey: "trimWhitespaceForDedup")
        ignoredBundleIDs = d.stringArray(forKey: "ignoredBundleIDs") ?? Self.defaultIgnoredApps
        regexRules = d.stringArray(forKey: "regexRules") ?? []
        hotKeyCode = d.integer(forKey: "hotKeyCode")
        hotKeyModifiers = d.integer(forKey: "hotKeyModifiers")
        hotKeyDisplay = d.string(forKey: "hotKeyDisplay") ?? Self.defaultHotKeyDisplay
        hasOnboarded = d.bool(forKey: "hasOnboarded")
        animateMenuBarIcon = d.bool(forKey: "animateMenuBarIcon")
        playSoundOnCopy = d.bool(forKey: "playSoundOnCopy")
        playSoundOnPaste = d.bool(forKey: "playSoundOnPaste")
        // One-time switch to the native macOS alert sound for anyone on the old "Pop" default.
        if !d.bool(forKey: "soundMigratedToSystemAlert") {
            d.removeObject(forKey: "soundName")
            d.set(true, forKey: "soundMigratedToSystemAlert")
        }
        soundName = d.string(forKey: "soundName") ?? "macOS Alert Sound"
        soundVolume = d.double(forKey: "soundVolume")
        theme = d.string(forKey: "theme") ?? "system"
        rowDensity = d.string(forKey: "rowDensity") ?? "compact"
        textSize = d.string(forKey: "textSize") ?? "medium"
        showAppIcons = d.bool(forKey: "showAppIcons")
        showShortcutNumbers = d.bool(forKey: "showShortcutNumbers")
        showTypeTabs = d.bool(forKey: "showTypeTabs")
        openPosition = d.string(forKey: "openPosition") ?? "menuBar"
        translucent = d.bool(forKey: "translucent")
        accentColor = d.string(forKey: "accentColor") ?? "system"
        cornerRadius = d.double(forKey: "cornerRadius")
        itemSpacing = d.double(forKey: "itemSpacing")
        animateList = d.bool(forKey: "animateList")
        previewSide = d.string(forKey: "previewSide") ?? "auto"
        previewWidth = d.double(forKey: "previewWidth")
        highlightCode = d.bool(forKey: "highlightCode")
        pastePlainByDefault = d.bool(forKey: "pastePlainByDefault")
        quickPasteEnabled = d.bool(forKey: "quickPasteEnabled")
        quickPasteModifier = d.string(forKey: "quickPasteModifier") ?? "command"
        spaceTogglesPreview = d.bool(forKey: "spaceTogglesPreview")
        singleClickPreview = d.bool(forKey: "singleClickPreview")
        deleteKeyDeletes = d.bool(forKey: "deleteKeyDeletes")
        skipCardNumbers = d.bool(forKey: "skipCardNumbers")
        skipOneTimeCodes = d.bool(forKey: "skipOneTimeCodes")
        skipSecrets = d.bool(forKey: "skipSecrets")
        clearOnQuit = d.bool(forKey: "clearOnQuit")
        disabledIgnoredApps = d.stringArray(forKey: "disabledIgnoredApps") ?? []
        disabledRegexRules = d.stringArray(forKey: "disabledRegexRules") ?? []
        keywordRules = d.data(forKey: "keywordRules").flatMap { try? JSONDecoder().decode([KeywordRule].self, from: $0) } ?? []
        excludedTypes = d.stringArray(forKey: "excludedTypes") ?? []
        autoBackupEnabled = d.bool(forKey: "autoBackupEnabled")
        autoBackupFrequency = d.string(forKey: "autoBackupFrequency") ?? "daily"
        autoBackupFolder = d.string(forKey: "autoBackupFolder") ?? Self.defaultBackupFolder
        autoBackupKeep = d.integer(forKey: "autoBackupKeep")
        lastAutoBackup = d.double(forKey: "lastAutoBackup")
        checkUpdatesAutomatically = d.bool(forKey: "checkUpdatesAutomatically")
        lastUpdateCheck = d.double(forKey: "lastUpdateCheck")
        extraHotKeys = (d.data(forKey: "extraHotKeys")).flatMap { try? JSONDecoder().decode([String: HotKeySpec].self, from: $0) } ?? [:]
    }
}

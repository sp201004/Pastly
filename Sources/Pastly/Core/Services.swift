import AppKit
import Carbon.HIToolbox
import ServiceManagement
import Vision

// MARK: - Global hotkeys (Carbon, no dependencies)

struct HotKeySpec: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int      // Carbon modifier mask
    var display: String
}

enum HotKeyAction: UInt32, CaseIterable, Identifiable {
    case openHistory = 1
    case pasteLatestPlain = 2
    case togglePause = 3
    case skipNextCopy = 4
    case stopPasteQueue = 5

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .openHistory: return "Open clipboard history"
        case .pasteLatestPlain: return "Paste latest clip as plain text"
        case .togglePause: return "Pause / resume saving"
        case .skipNextCopy: return "Ignore the next copy"
        case .stopPasteQueue: return "Stop the paste queue"
        }
    }

    var key: String { "\(rawValue)" }
}

private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hkID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    guard status == noErr else { return status }
    let id = hkID.id
    DispatchQueue.main.async { HotKeyManager.shared.fire(id) }
    return noErr
}

final class HotKeyManager {
    static let shared = HotKeyManager()
    /// Called for the open-history shortcut (kept for compatibility).
    var onPress: (() -> Void)?
    var onAction: ((HotKeyAction) -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature = OSType(0x5053_5448) // "PSTH"

    fileprivate func fire(_ id: UInt32) {
        guard let action = HotKeyAction(rawValue: id) else { return }
        if action == .openHistory { onPress?() }
        onAction?(action)
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, &handlerRef)
    }

    @discardableResult
    func register(_ action: HotKeyAction, spec: HotKeySpec?) -> Bool {
        unregister(action)
        guard let spec else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(spec.keyCode), UInt32(spec.modifiers),
                                         EventHotKeyID(signature: Self.signature, id: action.rawValue),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[action.rawValue] = ref; return true }
        return false
    }

    /// Back-compat: registers the open-history shortcut.
    @discardableResult
    func register(keyCode: Int, carbonModifiers: Int) -> Bool {
        register(.openHistory, spec: HotKeySpec(keyCode: keyCode, modifiers: carbonModifiers, display: ""))
    }

    static func spec(for action: HotKeyAction) -> HotKeySpec? {
        let p = Preferences.shared
        if action == .openHistory {
            return HotKeySpec(keyCode: p.hotKeyCode, modifiers: p.hotKeyModifiers, display: p.hotKeyDisplay)
        }
        return p.extraHotKeys[action.key]
    }

    static func setSpec(_ spec: HotKeySpec?, for action: HotKeyAction) {
        let p = Preferences.shared
        if action == .openHistory {
            let s = spec ?? HotKeySpec(keyCode: Preferences.defaultHotKeyCode, modifiers: Preferences.defaultHotKeyModifiers,
                                       display: Preferences.defaultHotKeyDisplay)
            p.hotKeyCode = s.keyCode; p.hotKeyModifiers = s.modifiers; p.hotKeyDisplay = s.display
        } else {
            p.extraHotKeys[action.key] = spec
        }
    }

    @discardableResult
    func register(_ action: HotKeyAction) -> Bool { register(action, spec: Self.spec(for: action)) }

    /// Registers every configured shortcut. Returns the actions that failed (taken by another app).
    @discardableResult
    func registerAll() -> [HotKeyAction] {
        HotKeyAction.allCases.filter { !register($0) }
    }


    func unregister(_ action: HotKeyAction) {
        if let ref = refs.removeValue(forKey: action.rawValue) { UnregisterEventHotKey(ref) }
    }

    func unregister() { unregister(.openHistory) }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.shift) { m |= shiftKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        return m
    }

    static func displayString(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        s += special[keyCode] ?? (characters ?? "?").uppercased()
        return s
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// MARK: - OCR (on-device, Vision)

enum OCRService {
    static func recognizeText(in url: URL, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
        }
    }
}

// MARK: - App icon cache

enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let b = bundleID else { return nil }
        if let i = icons[b] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[b] = icon
        return icon
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Onboarding / permissions

enum Onboarding {
    private static var warnedThisLaunch = false

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func showWelcomeIfNeeded() {
        let prefs = Preferences.shared
        guard !prefs.hasOnboarded else { return }
        prefs.hasOnboarded = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to Pastly"
        alert.informativeText = """
        Pastly runs in your menu bar and keeps everything you copy. All data stays on this Mac.

        • Press \(prefs.hotKeyDisplay) to open your clipboard history.
        • ↩ pastes, ⇧↩ or ⌥↩ pastes in the other format (Formatted ↔ Plain), ⌘1–⌘9 quick-paste.

        To paste directly into other apps, Pastly needs Accessibility permission.
        """
        alert.addButton(withTitle: "Grant Accessibility…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibility()
        }
    }

    /// Paste couldn't be sent because Pastly lacks Accessibility permission. Always tells the user
    /// (never pretends it pasted): a full explanation once per launch, a short notice after that.
    static func accessibilityMissingAfterCopy() {
        NSLog("Pastly: paste not sent — Accessibility permission missing (AXIsProcessTrusted = false)")
        guard !warnedThisLaunch else {
            NSApp.hide(nil)
            Toast.show("Not pasted — Pastly needs Accessibility permission. The item is on the clipboard (⌘V).", duration: 3)
            return
        }
        warnedThisLaunch = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pastly can't paste into other apps yet"
        alert.informativeText = """
        To paste with a double-click, ↩ or ⌘V, macOS requires you to allow Pastly in System Settings → Privacy & Security → Accessibility.

        The item is on the clipboard now, so you can press ⌘V yourself.

        If Pastly is already in that list, it's an outdated entry: select it, click –, then add Pastly again.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            requestAccessibility()
            openAccessibilitySettings()
        }
    }
}

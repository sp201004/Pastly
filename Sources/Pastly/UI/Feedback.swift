import AppKit
import AudioToolbox
import Combine
import Symbols

/// What happened, so feedback can match the action.
enum FeedbackEvent {
    case captured(ClipType)       // user copied something anywhere on the Mac
    case copiedFromApp(ClipType)  // user copied an item from Pastly (⌘C / Copy / OCR)
    case pasted(ClipType)         // user pasted an item from Pastly
}

/// Plays copy/paste sound + menu bar animation. Every feedback path in the app goes through here.
final class Feedback {
    static let shared = Feedback()

    private var playing: [NSSound] = []
    private var lastSoundAt = Date.distantPast
    private let minSoundGap: TimeInterval = 0.12   // avoid a burst of sounds when many copies happen at once

    /// The Mac's own alert sound, exactly as chosen in System Settings → Sound → Alert sound.
    static let systemAlertSound = "macOS Alert Sound"
    private static let systemSoundsDir = "/System/Library/Sounds"

    /// Only sounds that ship with macOS: the system alert sound, then the built-in sounds in
    /// /System/Library/Sounds. No bundled, downloaded, or user-added sound files.
    static let availableSounds: [String] = {
        let builtIn = ((try? FileManager.default.contentsOfDirectory(atPath: systemSoundsDir)) ?? [])
            .filter { $0.lowercased().hasSuffix(".aiff") }
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            .sorted()
        return [systemAlertSound] + builtIn
    }()

    func play(_ event: FeedbackEvent) {
        let p = Preferences.shared
        let wantsSound: Bool
        switch event {
        case .captured, .copiedFromApp: wantsSound = p.playSoundOnCopy
        case .pasted: wantsSound = p.playSoundOnPaste
        }
        if p.animateMenuBarIcon { MenuBarIcon.shared.animate(symbol: symbol(for: event)) }
        if wantsSound { playSound(p.soundName, volume: Float(p.soundVolume)) }
    }

    /// Settings "Test" button: always plays both, ignoring the on/off switches.
    func preview() {
        MenuBarIcon.shared.animate(symbol: symbol(for: .captured(.text)))
        playSound(Preferences.shared.soundName, volume: Float(Preferences.shared.soundVolume), force: true)
    }

    func playSound(_ name: String, volume: Float, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastSoundAt) >= minSoundGap else { return }
        lastSoundAt = now
        // The Mac's alert sound via System Sound Services: same sound, same alert volume, and it
        // follows the "Play sound effects through" output device setting — exactly like the system.
        if name == Self.systemAlertSound || !Self.availableSounds.contains(name) {
            AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert)
            return
        }
        // A built-in macOS sound, loaded straight from /System/Library/Sounds.
        guard let sound = NSSound(contentsOfFile: "\(Self.systemSoundsDir)/\(name).aiff", byReference: true) else {
            AudioServicesPlaySystemSound(kSystemSoundID_UserPreferredAlert)
            return
        }
        sound.volume = max(0, min(1, volume))
        playing.append(sound)   // keep a strong reference until it finishes
        sound.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(sound.duration, 0.3) + 0.2) { [weak self] in
            self?.playing.removeAll { $0 === sound }
        }
    }

    private func symbol(for event: FeedbackEvent) -> String {
        switch event {
        case .pasted: return "arrow.down.doc.fill"
        case .captured(let t), .copiedFromApp(let t):
            switch t {
            case .text: return "doc.on.doc.fill"
            case .url: return "link.circle.fill"
            case .color: return "paintpalette.fill"
            case .image: return "photo.fill"
            case .file: return "doc.fill"
            }
        }
    }
}

/// Image view that never takes clicks, so the status bar button underneath still works.
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Animated menu bar icon. On each copy it bounces, morphs into an icon for the copied type,
/// then morphs back. Respects System Settings → Accessibility → Reduce motion.
final class MenuBarIcon {
    static let shared = MenuBarIcon()
    static let baseSymbol = "list.clipboard"

    private let imageView = PassthroughImageView()
    private let badge = PassthroughLabel(labelWithString: "")
    private var restoreWork: DispatchWorkItem?
    private var pausedSub: AnyCancellable?

    func attach(to button: NSStatusBarButton) {
        button.image = nil
        button.title = ""
        button.setAccessibilityLabel("Pastly")

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        imageView.image = Self.image(Self.baseSymbol)
        imageView.unregisterDraggedTypes()
        button.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Small count badge (paste queue).
        badge.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = Preferences.shared.accentNSColor.cgColor
        badge.layer?.cornerRadius = 6
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 1),
            badge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -1),
            badge.heightAnchor.constraint(equalToConstant: 12),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
        ])

        // Dim the icon while capture is paused.
        pausedSub = Preferences.shared.$isPaused.sink { [weak self] paused in
            self?.imageView.animator().alphaValue = paused ? 0.4 : 1
        }
    }

    func animate(symbol name: String) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        restoreWork?.cancel()

        if let img = Self.image(name) {
            if reduceMotion {
                imageView.image = img
            } else {
                imageView.setSymbolImage(img, contentTransition: .replace.downUp)
                imageView.addSymbolEffect(.bounce.up, options: .nonRepeating)
            }
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, let base = Self.image(Self.baseSymbol) else { return }
            if reduceMotion {
                self.imageView.image = base
            } else {
                self.imageView.setSymbolImage(base, contentTransition: .replace.upUp)
            }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func setBadge(_ text: String?) {
        badge.stringValue = text ?? ""
        badge.isHidden = text == nil
    }

    private static func image(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Pastly")
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Pastly")
        img?.isTemplate = true
        return img
    }
}

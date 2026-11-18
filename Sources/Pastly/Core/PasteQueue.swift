import AppKit
import Carbon.HIToolbox

/// Sequential paste ("paste one by one"). Pastly pastes the first clip, then every time
/// you press ⌘V in any app, it loads the next clip onto the clipboard. Esc stops the queue.
///
/// Uses a pass-through keyboard event tap (needs the same Accessibility permission as auto-paste).
/// Events are never modified or blocked; Pastly's own synthetic ⌘V is recognized by a tag and ignored.
final class PasteQueue: ObservableObject {
    static let shared = PasteQueue()

    /// Clips still to come, in order. Empty when no queue is running.
    @Published private(set) var remaining: [ClipItem] = []
    @Published private(set) var total = 0
    private var plainText = false
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingAdvance: DispatchWorkItem?
    /// How long to wait after a ⌘V before replacing the clipboard, so the target app reads it first.
    private let advanceDelay: TimeInterval = 0.3

    var isActive: Bool { tap != nil }
    var position: Int { total - remaining.count }

    func start(_ items: [ClipItem], plainText: Bool, into app: NSRunningApplication?) {
        stop(silently: true)
        guard let first = items.first else { return }
        guard AXIsProcessTrusted() else {
            PasteService.shared.write([first], plainText: plainText)   // copy-only fallback, like other paste paths
            Onboarding.accessibilityMissingAfterCopy()
            return
        }
        self.plainText = plainText
        total = items.count
        remaining = Array(items.dropFirst())

        guard !remaining.isEmpty else {
            PasteService.shared.paste([first], plainText: plainText, transform: nil, into: app)
            return
        }
        guard installTap() else {
            NSLog("Pastly: could not start key watcher for paste queue")
            Toast.show("Couldn't start the paste queue — check Accessibility permission")
            remaining = []
            return
        }
        PasteService.shared.paste([first], plainText: plainText, transform: nil, into: app) { [weak self] pasted in
            guard let self else { return }
            if pasted {
                self.scheduleAdvance()
            } else {
                // Auto-paste didn't happen; the first clip is on the clipboard and the user pastes it.
                Toast.show("Paste queue: press ⌘V to paste 1 of \(self.total)")
            }
        }
        MenuBarIcon.shared.setBadge("\(total)")
    }

    /// Stops the queue. The clipboard keeps whatever clip is on it.
    func stop(silently: Bool = false) {
        pendingAdvance?.cancel()
        pendingAdvance = nil
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil
        runLoopSource = nil
        let wasActive = !remaining.isEmpty
        remaining = []
        total = 0
        MenuBarIcon.shared.setBadge(nil)
        if wasActive && !silently { Toast.show("Paste queue stopped") }
    }

    // MARK: Advancing

    private func scheduleAdvance() {
        pendingAdvance?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.advance() }
        pendingAdvance = work
        DispatchQueue.main.asyncAfter(deadline: .now() + advanceDelay, execute: work)
    }

    /// Puts the next clip on the clipboard.
    private func advance() {
        pendingAdvance = nil
        guard !remaining.isEmpty else { finish(); return }
        let next = remaining.removeFirst()
        PasteService.shared.write(next, plainText: plainText)
        ClipStore.shared.markUsed(next.id, pasted: true)
        let left = remaining.count
        MenuBarIcon.shared.setBadge(left > 0 ? "\(left + 1)" : "1")
        Toast.show("Next: \(position) of \(total) — press ⌘V", duration: 1.4)
    }

    private func finish() {
        let n = total
        stop(silently: true)
        Toast.show("Pasted all \(n) clips")
    }

    /// Called for every real (non-synthetic) ⌘V the user presses while the queue runs.
    fileprivate func userPressedPaste() {
        Feedback.shared.play(.pasted(.text))
        if let pending = pendingAdvance {
            // A fast second ⌘V: load the next clip right now so this paste gets it.
            pending.cancel()
            advance()
        }
        if remaining.isEmpty {
            // This ⌘V pastes the last clip; finish once the app has read it.
            pendingAdvance?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.finish() }
            pendingAdvance = work
            DispatchQueue.main.asyncAfter(deadline: .now() + advanceDelay, execute: work)
        } else {
            scheduleAdvance()
        }
    }

    // MARK: Event tap

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: pasteQueueTapCallback, userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = src
        return true
    }

    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    fileprivate static func isPasteKey(_ event: CGEvent) -> Bool {
        let flags = event.flags
        guard flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskShift) else { return false }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        return code == (KeyboardLayout.keyCode(for: "v") ?? 0x09)
    }
}

private func pasteQueueTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                                   _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        DispatchQueue.main.async { PasteQueue.shared.reenableTap() }
    case .keyDown:
        if event.getIntegerValueField(.eventSourceUserData) == PasteService.syntheticEventTag { break }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { break }
        if PasteQueue.isPasteKey(event) {
            DispatchQueue.main.async { PasteQueue.shared.userPressedPaste() }
        } else if event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Escape) {
            DispatchQueue.main.async { PasteQueue.shared.stop() }
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

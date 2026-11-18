import AppKit
import QuartzCore

/// Developer check: scrolls the real clip list programmatically (no mouse or keyboard input) and
/// times every frame with the display's own refresh clock, so dropped frames show up as long gaps.
/// Usage: PASTLY_DEMO=1 PASTLY_DATA_DIR=<history> Pastly --scroll-probe <report.txt>
final class ScrollProbe: NSObject {
    private let controller: PanelController
    private let reportPath: String
    private var scrollView: NSScrollView?
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var frameDuration: CFTimeInterval = 0
    private var lastStamp: CFTimeInterval = 0
    private var direction: CGFloat = 1
    private var passes = 0
    private let speed: CGFloat = 2400   // points per second (a brisk trackpad fling)
    private var lines: [String] = []
    private var longFrames: [String] = []
    // Main-thread watchdog: a background thread pings the main thread every 20 ms and records how long
    // each ping waits. A long frame with a short ping wait means the app wasn't blocked (the frame clock paused).
    private let watchdogLock = NSLock()
    private var maxMainWait: Double = 0
    private var mainWaits: [(at: CFTimeInterval, ms: Double)] = []
    private var watchdogRunning = false

    init(controller: PanelController, reportPath: String) {
        self.controller = controller
        self.reportPath = reportPath
    }

    func start() {
        controller.show(from: .hotkey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            guard let content = controller.panel.contentView,
                  let sv = Self.scrollViews(in: content).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else {
                finish("FAIL: no scroll view found"); return
            }
            scrollView = sv
            let screen = controller.panel.screen ?? NSScreen.main
            lines.append("display: \(screen?.localizedName ?? "?"), maximum refresh \(screen?.maximumFramesPerSecond ?? 0) Hz")
            lines.append("list: document height \(Int(sv.documentView?.frame.height ?? 0)) pt, visible \(Int(sv.contentView.bounds.height)) pt")
            startWatchdog()
            let l = content.displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        frameDuration = l.targetTimestamp - l.timestamp
        let dt = lastStamp == 0 ? frameDuration : l.timestamp - lastStamp
        lastStamp = l.timestamp
        stamps.append(l.timestamp)
        if dt > 0.1, let sv0 = scrollView, let d0 = sv0.documentView {   // where long frames happen
            let visible = controller.panel.occlusionState.contains(.visible)
            longFrames.append(String(format: "  long frame %.0f ms at y=%.0f of %.0f, pass %d, direction %@, window visible: %@", dt * 1000,
                                     sv0.contentView.bounds.origin.y, d0.frame.height, passes + 1, direction > 0 ? "down" : "up", visible ? "yes" : "NO"))
        }

        // Scroll by distance = speed × elapsed time, so a late frame jumps further (like real scrolling).
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        var y = sv.contentView.bounds.origin.y + direction * speed * CGFloat(dt) * (doc.isFlipped ? 1 : -1)
        y = min(max(0, y), maxY)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y))
        sv.reflectScrolledClipView(sv.contentView)

        let atEnd = doc.isFlipped ? (direction > 0 ? y >= maxY : y <= 0) : (direction > 0 ? y <= 0 : y >= maxY)
        if atEnd || stamps.count > 4000 {
            passes += 1
            if passes >= 2 { l.invalidate(); report(); return }
            direction = -direction
        }
    }

    private func report() {
        let intervals = zip(stamps.dropFirst(), stamps).map { ($0 - $1) * 1000 }
        guard !intervals.isEmpty else { finish("FAIL: no frames"); return }
        let sorted = intervals.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let expected = frameDuration * 1000
        let dropped = intervals.filter { $0 > expected * 1.5 }.count
        let missedFrames = intervals.reduce(0) { $0 + max(0, Int(($1 / expected).rounded()) - 1) }
        lines.append(String(format: "frame budget %.2f ms (%.0f Hz)", expected, 1000 / expected))
        lines.append("frames: \(intervals.count + 1) over \(String(format: "%.2f", (stamps.last! - stamps.first!))) s (down + up)")
        lines.append(String(format: "frame time avg %.2f ms, median %.2f, p95 %.2f, p99 %.2f, worst %.1f ms", intervals.reduce(0, +) / Double(intervals.count), pct(0.5), pct(0.95), pct(0.99), sorted.last!))
        lines.append("late frames (>1.5× budget): \(dropped) of \(intervals.count) (\(String(format: "%.1f", Double(dropped) * 100 / Double(intervals.count)))%), missed refreshes: \(missedFrames)")
        lines += longFrames
        watchdogLock.lock(); watchdogRunning = false
        let worst = maxMainWait, blocked = mainWaits.filter { $0.ms > 100 }.count; watchdogLock.unlock()
        lines.append(String(format: "main thread (watchdog, 20 ms pings): worst wait %.0f ms, waits over 100 ms: %d", worst, blocked))
        finish(nil)
    }

    private func startWatchdog() {
        watchdogRunning = true
        Thread.detachNewThread { [weak self] in
            while let self {
                self.watchdogLock.lock(); let running = self.watchdogRunning; self.watchdogLock.unlock()
                guard running else { return }
                let sent = CACurrentMediaTime()
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let waited = (CACurrentMediaTime() - sent) * 1000
                self.watchdogLock.lock()
                self.maxMainWait = max(self.maxMainWait, waited)
                if waited > 100 { self.mainWaits.append((sent, waited)) }
                self.watchdogLock.unlock()
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }

    private func finish(_ error: String?) {
        if let error { lines.append(error) }
        try? lines.joined(separator: "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let sv = view as? NSScrollView, sv.hasVerticalScroller || (sv.documentView?.frame.height ?? 0) > sv.contentView.bounds.height { out.append(sv) }
        for sub in view.subviews { out += scrollViews(in: sub) }
        return out
    }
}

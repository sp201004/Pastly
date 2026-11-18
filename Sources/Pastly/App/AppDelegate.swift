import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var panel: PanelController!
    private var monitor: ClipboardMonitor!
    private var maintenanceTimer: Timer?
    private var scrollProbe: ScrollProbe?   // developer check only
    /// False if launch stopped before the history store opened (see LegacyMigration).
    private var didOpenStore = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Earlier versions: copy history and settings once, before anything reads them.
        guard LegacyMigration.runAtLaunch() else { NSApp.terminate(nil); return }
        didOpenStore = true
        DragFiles.clear()   // temporary image files from earlier drags
        Preferences.applyTheme(Preferences.shared.theme)
        NSLog("Pastly: launched, accessibilityTrusted=%@", AXIsProcessTrusted() ? "yes" : "no")
        setupMainMenu()

        let store = ClipStore.shared
        store.enforceLimits()
        panel = PanelController(store: store)

        setupStatusItem()
        panel.statusItemFrame = { [weak self] in
            guard let button = self?.statusItem.button, let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        panel.setStatusItemHighlighted = { [weak self] on in self?.statusItem.button?.highlight(on) }

        HotKeyManager.shared.onAction = { [weak self] action in self?.handleHotKey(action) }
        let failed = HotKeyManager.shared.registerAll()
        if !failed.isEmpty {
            NSLog("Pastly: shortcuts not registered: %@", failed.map(\.title).joined(separator: ", "))
        }

        monitor = ClipboardMonitor()
        monitor.onCapture = { raw, bundleID, appName in
            ClipStore.shared.capture(raw, bundleID: bundleID, appName: appName)
        }
        monitor.start()
        store.onCaptured = { item in Feedback.shared.play(.captured(item.type)) }

        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            ClipStore.shared.enforceLimits()
            AutoBackup.runIfDue()
            UpdateChecker.checkAutomaticallyIfDue()
        }
        AutoBackup.runIfDue()
        UpdateChecker.checkAutomaticallyIfDue()

        if let i = CommandLine.arguments.firstIndex(of: "--e2e-browsers"), CommandLine.arguments.count > i + 1 {   // developer check
            E2ETest.runBrowsers(panel: panel, reportPath: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--e2e-dragsource"), CommandLine.arguments.count > i + 1 {   // developer check
            E2ETest.runDragSource(panel: panel, reportPath: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--e2e-dragtypes"), CommandLine.arguments.count > i + 1 {   // developer check
            E2ETest.runDragTypes(panel: panel, reportPath: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--e2e-finder"), CommandLine.arguments.count > i + 1 {   // developer check
            E2ETest.runFinder(panel: panel, reportPath: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--e2e"), CommandLine.arguments.count > i + 1 {   // developer check
            E2ETest.run(panel: panel, reportPath: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--ax-status"), CommandLine.arguments.count > i + 1 {   // developer check
            let info = "trusted=\(AXIsProcessTrusted()) signature=\(Bundle.main.bundlePath)\n"
            try? info.write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--scroll-probe"), CommandLine.arguments.count > i + 1 {   // developer check
            scrollProbe = ScrollProbe(controller: panel, reportPath: CommandLine.arguments[i + 1])
            scrollProbe?.start()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-panel"), CommandLine.arguments.count > i + 1 {   // developer check
            panel.snapshotWindows(to: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-settings"), CommandLine.arguments.count > i + 1 {
            SettingsWindowController.shared.snapshot(to: CommandLine.arguments[i + 1])   // developer check
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Onboarding.showWelcomeIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard didOpenStore else { return }   // don't create an empty data folder on an aborted launch
        PasteQueue.shared.stop(silently: true)
        // Settings → Privacy → "Clear history when Pastly quits" (pinned and listed items are kept).
        if Preferences.shared.clearOnQuit { ClipStore.shared.clearHistory() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show()
        return true
    }

    private func handleHotKey(_ action: HotKeyAction) {
        switch action {
        case .openHistory:
            panel.toggle(from: .hotkey)
        case .pasteLatestPlain:
            guard let latest = ClipStore.shared.items.first else { NSSound.beep(); return }
            PasteService.shared.paste([latest], plainText: true, transform: nil,
                                      into: NSWorkspace.shared.frontmostApplication)
        case .togglePause:
            Preferences.shared.isPaused.toggle()
            Toast.show(Preferences.shared.isPaused ? "Saving paused" : "Saving resumed")
        case .skipNextCopy:
            Preferences.shared.skipNextCopy = true
            Toast.show("The next copy won't be saved")
        case .stopPasteQueue:
            PasteQueue.shared.stop()
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            MenuBarIcon.shared.attach(to: button)
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusMenu = NSMenu()
        statusMenu.delegate = self
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if event?.modifierFlags.contains(.option) == true {
            Preferences.shared.isPaused.toggle()
            Toast.show(Preferences.shared.isPaused ? "Saving paused" : "Saving resumed")
        } else {
            panel.toggle(from: .statusItem)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Preferences.shared
        menu.addItem(item("Open Pastly  (\(prefs.hotKeyDisplay))", #selector(openPanel)))

        // Recent clips: pick one to paste into the app you're using.
        let recent = NSMenuItem(title: "Recent Clips", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        for clip in ClipStore.shared.items.prefix(10) {
            var title = clip.displayText.replacingOccurrences(of: "\n", with: " ⏎ ")
            if title.count > 50 { title = String(title.prefix(50)) + "…" }
            let mi = item(title, #selector(pasteRecent(_:)))
            mi.representedObject = clip.id
            mi.image = NSImage(systemSymbolName: clip.type.symbol, accessibilityDescription: nil)
            recentMenu.addItem(mi)
        }
        if recentMenu.items.isEmpty { recentMenu.addItem(NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")) }
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())

        if PasteQueue.shared.isActive {
            menu.addItem(item("Stop Paste Queue (\(PasteQueue.shared.position) of \(PasteQueue.shared.total))", #selector(stopQueue)))
            menu.addItem(.separator())
        }
        let pause = item("Pause Saving", #selector(togglePause))
        pause.state = prefs.isPaused ? .on : .off
        menu.addItem(pause)
        let skip = item("Ignore Next Copy", #selector(toggleSkipNext))
        skip.state = prefs.skipNextCopy ? .on : .off
        menu.addItem(skip)
        menu.addItem(item("Clear History…", #selector(clearHistory)))
        menu.addItem(.separator())
        menu.addItem(item("Export Backup…", #selector(exportBackup)))
        menu.addItem(item("Import Backup…", #selector(importBackup)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Pastly", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openPanel() { panel.show(from: .statusItem) }
    @objc private func stopQueue() { PasteQueue.shared.stop() }
    @objc private func toggleSkipNext() { Preferences.shared.skipNextCopy.toggle() }
    @objc private func pasteRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let clip = ClipStore.shared.item(id: id) else { return }
        Feedback.shared.play(.pasted(clip.type))
        PasteService.shared.paste([clip], plainText: Preferences.shared.pastePlainByDefault, transform: nil,
                                  into: NSWorkspace.shared.frontmostApplication)
    }
    @objc private func togglePause() { Preferences.shared.isPaused.toggle() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func exportBackup() { report(BackupActions.export()) }
    @objc private func importBackup() { report(BackupActions.importBackup()) }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned items and items saved in lists are kept. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { ClipStore.shared.clearHistory() }
    }

    private func report(_ message: String?) {
        guard let message else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    // MARK: Main menu (enables ⌘C/⌘V/⌘A/⌘Z in text fields of an accessory app)

    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Quit Pastly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The seven Settings sections, in toolbar order.
enum SettingsTab: Int, CaseIterable, Hashable {
    case general, appearance, shortcuts, lists, privacy, backup, about

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .lists: return "Lists"
        case .privacy: return "Privacy"
        case .backup: return "Backup"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .shortcuts: return "keyboard"
        case .lists: return "list.bullet.rectangle"
        case .privacy: return "hand.raised"
        case .backup: return "externaldrive"
        case .about: return "info.circle"
        }
    }
}

/// Lets other parts of the app open Settings on a specific section (e.g. "Edit Smart List…").
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var tab: SettingsTab = .general
    /// Smart list to edit on the Lists tab; "" means "create a new one".
    @Published var smartListRequest: String?
}

/// Native macOS settings window: a toolbar of icon tabs with the active one highlighted,
/// cross-fading between sections. Each section is a SwiftUI grouped form.
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    /// Settings panel size. The window's outer frame stays at the first build's 600 × 572
    /// (32 pt title bar + 540 pt of content, which now includes the tab bar). Do not change.
    static let contentSize = NSSize(width: 600, height: 540)
    private var window: NSWindow?

    func show(tab: SettingsTab? = nil, smartListID: String? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "Pastly Settings"
            w.contentView = NSHostingView(rootView: SettingsView(router: .shared))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if let tab { SettingsRouter.shared.tab = tab }
        if let smartListID {
            SettingsRouter.shared.tab = .lists
            SettingsRouter.shared.smartListRequest = smartListID
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Developer check: captures the real Settings window (title bar included) for every tab.
    func snapshot(to base: String) {
        if CommandLine.arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if Preferences.isDemo && ClipStore.shared.items.isEmpty {
            _ = DemoData.populate(ClipStore.shared, filesDir: ClipStore.supportDirectory.appendingPathComponent("demo-files"))
            ClipStore.shared.createSmartList(name: "Links", symbol: "link", rules: [SmartRule(field: .type, op: .is, value: "url")])
        }
        show(tab: .general)
        var tabs = SettingsTab.allCases
        func next() {
            guard !tabs.isEmpty, let w = window, let frameView = w.contentView?.superview else {
                NSLog("Pastly: snapshot done, window frame %@", NSStringFromRect(window?.frame ?? .zero))
                NSApp.terminate(nil)
                return
            }
            let tab = tabs.removeFirst()
            SettingsRouter.shared.tab = tab
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                frameView.layoutSubtreeIfNeeded()
                if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                    frameView.cacheDisplay(in: frameView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(tab.title.lowercased()).png"))
                }
                print("window \(NSStringFromRect(w.frame)) content \(NSStringFromRect(w.contentLayoutRect)) tab \(tab.title)")
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() }
    }

    @ViewBuilder
    static func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .shortcuts: ShortcutsSettings()
        case .lists: ListsSettings(router: .shared)
        case .privacy: PrivacySettings()
        case .backup: BackupSettings()
        case .about: AboutSettings()
        }
    }
}

/// The Settings panel: the original tab bar layout, with all seven sections.
struct SettingsView: View {
    @ObservedObject var router: SettingsRouter

    /// Margin on each side of the tab bar.
    static let tabBarMargin: CGFloat = 20

    /// Native segmented tab bar placed inside the window (not in the title bar, where macOS 26
    /// hides tabs that don't fit behind a » menu). Seven equal tabs, centered, inside the panel.
    var body: some View {
        let barWidth = SettingsWindowController.contentSize.width - Self.tabBarMargin * 2
        VStack(spacing: 0) {
            SettingsTabBar(selection: $router.tab, totalWidth: barWidth)
                .frame(width: barWidth)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 10)
            Divider()
            SettingsWindowController.content(for: router.tab)
                .id(router.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsWindowController.contentSize.width, height: SettingsWindowController.contentSize.height)
    }
}

/// Standard NSSegmentedControl with equal-width segments that exactly fill `totalWidth`.
struct SettingsTabBar: NSViewRepresentable {
    @Binding var selection: SettingsTab
    let totalWidth: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: SettingsTab.allCases.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentStyle = .automatic
        control.segmentDistribution = .fillEqually
        control.translatesAutoresizingMaskIntoConstraints = false
        for (i, tab) in SettingsTab.allCases.enumerated() { control.setToolTip(tab.title, forSegment: i) }
        control.selectedSegment = selection.rawValue
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.selectedSegment != selection.rawValue { control.selectedSegment = selection.rawValue }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: totalWidth, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: SettingsTabBar
        init(_ parent: SettingsTabBar) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            if let tab = SettingsTab(rawValue: sender.selectedSegment) { parent.selection = tab }
        }
    }
}

// MARK: - Shared controls

struct HotKeyRecorder: View {
    let action: HotKeyAction
    @ObservedObject private var prefs = Preferences.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var error: String?

    init(action: HotKeyAction = .openHistory) { self.action = action }

    private var current: HotKeySpec? {
        _ = prefs.hotKeyDisplay; _ = prefs.extraHotKeys   // re-render on change
        return HotKeyManager.spec(for: action)
    }

    var body: some View {
        HStack {
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            Button(recording ? "Type shortcut…" : (current?.display ?? "Record Shortcut")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            if !recording && current != nil && (action != .openHistory || prefs.hotKeyDisplay != Preferences.defaultHotKeyDisplay) {
                Button {
                    HotKeyManager.setSpec(nil, for: action)
                    apply()
                } label: { Image(systemName: action == .openHistory ? "arrow.uturn.backward" : "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help(action == .openHistory ? "Reset to ⇧⌘V" : "Remove shortcut")
            }
        }
    }

    private func start() {
        recording = true
        error = nil
        HotKeyManager.shared.unregister(action)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty, mods != .shift else { NSSound.beep(); return nil }
            let spec = HotKeySpec(keyCode: Int(e.keyCode), modifiers: HotKeyManager.carbonModifiers(mods),
                                  display: HotKeyManager.displayString(keyCode: e.keyCode, flags: mods,
                                                                       characters: e.charactersIgnoringModifiers))
            if let reason = HotKeyManager.reservedReason(keyCode: spec.keyCode, modifiers: spec.modifiers) {
                error = "Not available: \(reason)"
                NSSound.beep()
                return nil
            }
            if let clash = HotKeyAction.allCases.first(where: { $0 != action && HotKeyManager.spec(for: $0)?.keyCode == spec.keyCode
                && HotKeyManager.spec(for: $0)?.modifiers == spec.modifiers }) {
                error = "Already used for “\(clash.title)”"
                NSSound.beep()
                return nil
            }
            HotKeyManager.setSpec(spec, for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
        apply()
    }

    private func apply() {
        if HotKeyManager.shared.register(action) {
            if error?.hasPrefix("Already") != true && error?.hasPrefix("Not available") != true { error = nil }
        } else {
            error = "In use by another app"
        }
    }
}

struct SmartListEditor: View {
    @State var list: SmartList
    let store: ClipStore

    private var knownApps: [(id: String, name: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for item in store.items {
            guard let id = item.sourceAppBundleID, !seen.contains(id) else { continue }
            seen.insert(id)
            out.append((id, item.sourceAppName ?? AppIconCache.name(for: id)))
        }
        return out.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $list.name)
                Picker("Icon", selection: $list.symbol) {
                    ForEach(Array(Set(SmartList.symbols + [list.symbol])).sorted(), id: \.self) { sym in
                        Label(sym, systemImage: sym).labelStyle(.iconOnly).tag(sym)
                    }
                }
                Picker("Show clips that match", selection: $list.matchAll) {
                    Text("all rules").tag(true)
                    Text("any rule").tag(false)
                }
                .pickerStyle(.segmented)
            }
            Section("Rules") {
                ForEach($list.rules) { $rule in
                    // Two lines so a rule always fits the panel width: field + operator, then the value.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Picker("", selection: $rule.field) {
                                ForEach(SmartRule.Field.allCases) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(minWidth: 90, maxWidth: 150)
                            .onChange(of: rule.field) { resetValue(&rule) }
                            Picker("", selection: $rule.op) {
                                ForEach(rule.field.operators) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(minWidth: 90, maxWidth: 140)
                            Spacer(minLength: 0)
                            Button { list.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                        valueEditor($rule).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button { list.rules.append(SmartRule(field: .text, op: .contains, value: "")) } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }
            Section {
                LabeledContent("Matching clips") { Text("\(store.count(in: list))").monospacedDigit() }
            }
        }
        .formStyle(.grouped)
        .onChange(of: list) { store.updateSmartList(list) }
    }

    private func resetValue(_ rule: inout SmartRule) {
        rule.op = rule.field.operators[0]
        switch rule.field {
        case .type: rule.value = ClipType.url.rawValue
        case .app: rule.value = knownApps.first?.id ?? ""
        case .text: rule.value = ""
        case .age: rule.value = "7"
        case .pinned: rule.value = "true"
        case .domain: rule.value = ""
        case .pattern: rule.value = ""
        case .date: rule.value = SmartRule.dayFormatter.string(from: Date())
        }
    }

    @ViewBuilder
    private func valueEditor(_ rule: Binding<SmartRule>) -> some View {
        switch rule.wrappedValue.field {
        case .type:
            Picker("", selection: rule.value) {
                ForEach(ClipType.allCases) { Text($0.displayName).tag($0.rawValue) }
                Text("Code").tag(SmartRule.codeKind)
            }
            .labelsHidden()
        case .app:
            Picker("", selection: rule.value) {
                ForEach(knownApps, id: \.id) { Text($0.name).tag($0.id) }
                if !knownApps.contains(where: { $0.id == rule.wrappedValue.value }) && !rule.wrappedValue.value.isEmpty {
                    Text(AppIconCache.name(for: rule.wrappedValue.value)).tag(rule.wrappedValue.value)
                }
            }
            .labelsHidden()
        case .text:
            TextField("word or phrase", text: rule.value)
        case .age:
            HStack(spacing: 4) {
                TextField("", text: rule.value).frame(width: 44).multilineTextAlignment(.trailing)
                Text("days")
            }
        case .pinned:
            Picker("", selection: rule.value) {
                Text("yes").tag("true")
                Text("no").tag("false")
            }
            .labelsHidden()
        case .domain:
            TextField("e.g. github.com", text: rule.value)
        case .pattern:
            VStack(alignment: .leading, spacing: 2) {
                TextField("regular expression, e.g. ^[A-Z]{3}-\\d+$", text: rule.value)
                    .font(.system(size: 12, design: .monospaced))
                if !rule.wrappedValue.value.isEmpty && (try? NSRegularExpression(pattern: rule.wrappedValue.value)) == nil {
                    Text("Not a valid pattern").font(.caption).foregroundStyle(.red)
                }
            }
        case .date:
            DatePicker("", selection: Binding(
                get: { SmartRule.dayFormatter.date(from: rule.wrappedValue.value) ?? Date() },
                set: { rule.wrappedValue.value = SmartRule.dayFormatter.string(from: $0) }),
                displayedComponents: .date)
            .labelsHidden()
        }
    }
}

enum BackupActions {
    static let fileType = UTType(filenameExtension: BackupService.fileExtension) ?? .json
    /// Backup files from earlier versions — still listed and restorable.
    static let legacyFileType = UTType(filenameExtension: BackupService.legacyFileExtension) ?? .json

    static func export() -> String? {
        let panel = NSSavePanel()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Pastly Backup \(df.string(from: Date())).\(BackupService.fileExtension)"
        panel.allowedContentTypes = [fileType, legacyFileType, .json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try BackupService.export(.shared, to: url)
            return "Exported \(ClipStore.shared.items.count) items to \(url.lastPathComponent)."
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
    }

    static func importBackup() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [fileType, legacyFileType, .json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let r = try BackupService.importBackup(from: url, into: .shared)
            return "Imported \(r.added) items (\(r.skipped) duplicates skipped, \(r.lists) new lists)."
        } catch {
            return "Import failed: \(error.localizedDescription)"
        }
    }
}


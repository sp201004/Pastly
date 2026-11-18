import AppKit
import SwiftUI

// The seven Settings sections. Every control is bound to a persisted Preferences value
// or calls a real store/service action.

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

/// Inverse binding for "Monitor the clipboard" (stored as `isPaused`, shared with the menu bar).
private var monitorBinding: Binding<Bool> {
    Binding(get: { !Preferences.shared.isPaused }, set: { Preferences.shared.isPaused = !$0 })
}

// MARK: - 1. General

struct GeneralSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var axTrusted = Onboarding.isAccessibilityTrusted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Pastly at login", isOn: $launchAtLogin)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Clipboard") {
                Toggle("Monitor the clipboard", isOn: monitorBinding)
                Hint("When off, nothing new is saved. Same as Pause in the menu bar (or ⌥-click the menu bar icon).")
                Toggle("Ignore the next copy", isOn: $prefs.skipNextCopy)
                Toggle("Treat leading/trailing whitespace as the same item", isOn: $prefs.trimWhitespaceForDedup)
            }
            Section("Choosing an item") {
                Picker("When you press ↩ or double-click", selection: $prefs.autoPaste) {
                    Text("Paste into the active app").tag(true)
                    Text("Copy to the clipboard only").tag(false)
                }
                Picker("Default paste format", selection: $prefs.pastePlainByDefault) {
                    Text("Keep original formatting").tag(false)
                    Text("Plain text").tag(true)
                }
                Hint("Hold ⇧ or ⌥ while pasting to use the other format.")
                Picker("Open clipboard history", selection: $prefs.openPosition) {
                    Text("Below the menu bar icon").tag("menuBar")
                    Text("In the center of the screen").tag("center")
                    Text("At the mouse pointer").tag("mouse")
                }
            }
            Section("Clipboard History") {
                Picker("Click Behavior", selection: $prefs.singleClickPreview) {
                    Text("Single Click to Preview").tag(true)
                    Text("Single Click to Select").tag(false)
                }
                .pickerStyle(.radioGroup)
                Hint(prefs.singleClickPreview
                     ? "A click opens the item's preview to inspect its original content, with a Paste button. Click it again, press Space or esc to close."
                     : "A click selects the item. Press ⌘V or ↩ to paste it. Space still opens the preview.")
                Picker("Keep up to", selection: $prefs.historyLimit) {
                    Text("100 items").tag(100)
                    Text("250 items").tag(250)
                    Text("500 items").tag(500)
                    Text("1,000 items").tag(1000)
                    Text("5,000 items").tag(5000)
                    Text("Unlimited").tag(0)
                }
                Picker("Delete items not used for", selection: $prefs.autoDeleteDays) {
                    Text("Never").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Hint("Pinned items and items saved in lists are never deleted automatically.")
            }
            Section("Permissions") {
                LabeledContent("Accessibility") {
                    HStack {
                        Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(axTrusted ? .green : .orange)
                        Text(axTrusted ? "Granted" : "Not granted")
                        if !axTrusted {
                            Button("Grant…") { Onboarding.requestAccessibility(); Onboarding.openAccessibilitySettings() }
                        }
                    }
                }
                Hint(axTrusted
                     ? "Lets Pastly paste into the app you were using and follow your ⌘V in the paste queue."
                     : "Needed to paste into other apps. Without it, Pastly copies the item and you press ⌘V. After an update you may need to remove Pastly from the list and add it again.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.historyLimit) { ClipStore.shared.enforceLimits() }
        .onChange(of: prefs.autoDeleteDays) { ClipStore.shared.enforceLimits() }
        .onChange(of: launchAtLogin) {
            do {
                try LoginItem.set(launchAtLogin)
                loginError = nil
            } catch {
                loginError = "Couldn't change login item: \(error.localizedDescription)"
                launchAtLogin = LoginItem.isEnabled
            }
        }
        .onReceive(timer) { _ in axTrusted = Onboarding.isAccessibilityTrusted }
    }
}

// MARK: - 2. Appearance

struct AppearanceSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    private let sampleSelected = ClipItem(type: .text, primaryUTI: "public.utf8-plain-text",
                                          plainText: "Meeting moved to 3:30 — same room", sourceAppBundleID: "com.apple.Notes",
                                          sourceAppName: "Notes", lastUsedAt: Date().addingTimeInterval(-120), contentHash: "sample-1")
    private let sampleOther = ClipItem(type: .url, primaryUTI: "public.url", plainText: "https://www.apple.com/macos",
                                       sourceAppBundleID: "com.apple.Safari", sourceAppName: "Safari",
                                       lastUsedAt: Date().addingTimeInterval(-3600), contentHash: "sample-2")

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $prefs.theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                LabeledContent("Accent color") { AccentPicker(selection: $prefs.accentColor) }
                Toggle("Translucent background", isOn: $prefs.translucent)
            }
            Section("Clipboard items") {
                VStack(spacing: CGFloat(prefs.itemSpacing)) {
                    ClipRow(item: sampleSelected, index: 0, isSelected: true, store: .shared, prefs: prefs)
                    ClipRow(item: sampleOther, index: 1, isSelected: false, store: .shared, prefs: prefs)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .allowsHitTesting(false)
                Picker("Text size", selection: $prefs.textSize) {
                    Text("Small").tag("small")
                    Text("Medium").tag("medium")
                    Text("Large").tag("large")
                }
                .pickerStyle(.segmented)
                Picker("Layout", selection: $prefs.rowDensity) {
                    Text("Compact").tag("compact")
                    Text("Comfortable (shows source app)").tag("comfortable")
                }
                LabeledContent("Rounded corners") {
                    HStack {
                        Slider(value: $prefs.cornerRadius, in: 0...12, step: 1)
                        Text("\(Int(prefs.cornerRadius)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                LabeledContent("Spacing between items") {
                    HStack {
                        Slider(value: $prefs.itemSpacing, in: 0...8, step: 1)
                        Text("\(Int(prefs.itemSpacing)) pt").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Show source app icons", isOn: $prefs.showAppIcons)
                Toggle("Show quick-paste numbers (⌘1–⌘9)", isOn: $prefs.showShortcutNumbers)
                Toggle("Show tabs for kinds (Text, Links, Images, Code…)", isOn: $prefs.showTypeTabs)
            }
            Section("Animations & sound") {
                Toggle("Animate the menu bar icon when copying or pasting", isOn: $prefs.animateMenuBarIcon)
                Toggle("Animate new items in the list", isOn: $prefs.animateList)
                Toggle("Play sound when copying", isOn: $prefs.playSoundOnCopy)
                Toggle("Play sound when pasting from Pastly", isOn: $prefs.playSoundOnPaste)
                Picker("Sound", selection: $prefs.soundName) {
                    ForEach(Feedback.availableSounds, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!prefs.playSoundOnCopy && !prefs.playSoundOnPaste)
                if prefs.soundName == Feedback.systemAlertSound {
                    Hint("Plays your Mac's alert sound and uses the alert volume from System Settings → Sound.")
                }
                LabeledContent("Volume") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $prefs.soundVolume, in: 0...1) { editing in
                            if !editing { Feedback.shared.preview() }
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled((!prefs.playSoundOnCopy && !prefs.playSoundOnPaste) || prefs.soundName == Feedback.systemAlertSound)
                HStack {
                    Spacer()
                    Button("Test Feedback") { Feedback.shared.preview() }
                }
            }
            Section("Preview") {
                Hint(prefs.singleClickPreview
                     ? "Click an item or press Space to open its preview. Space, esc or clicking the item again closes it. Click Behavior is in General → Clipboard History."
                     : "A click only selects an item. Press Space to open its preview; Space or esc closes it. Click Behavior is in General → Clipboard History.")
                Picker("Show the preview", selection: $prefs.previewSide) {
                    Text("Where there's room").tag("auto")
                    Text("On the left").tag("left")
                    Text("On the right").tag("right")
                }
                LabeledContent("Preview width") {
                    HStack {
                        Slider(value: $prefs.previewWidth, in: 300...640, step: 10)
                        Text("\(Int(prefs.previewWidth)) pt").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("Highlight code syntax", isOn: $prefs.highlightCode)
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.soundName) { Feedback.shared.preview() }
    }
}

struct AccentPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Preferences.accentChoices, id: \.self) { name in
                Button { selection = name } label: {
                    ZStack {
                        Circle().fill(fill(name)).frame(width: 18, height: 18)
                        if selection == name {
                            Circle().strokeBorder(Color.primary.opacity(0.55), lineWidth: 2).frame(width: 24, height: 24)
                            Circle().fill(.white).frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(name == "system" ? "Use the accent from System Settings" : name.capitalized)
            }
        }
    }

    private func fill(_ name: String) -> AnyShapeStyle {
        if name == "system" {
            return AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .red],
                                                 center: .center))
        }
        return AnyShapeStyle(Color(nsColor: Preferences.accentNSColor(named: name)))
    }
}

// MARK: - 3. Shortcuts

struct ShortcutsSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    private func fixed(_ what: String, _ keys: String) -> some View {
        LabeledContent(what) {
            Text(keys).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action == .openHistory ? "Open clipboard history" : action.title) {
                        HotKeyRecorder(action: action)
                    }
                }
                Hint("These work in any app. Pastly won't accept a shortcut that macOS or another Pastly action already uses (such as ⌘C, ⌘Space or the screenshot keys), and tells you if another app has taken it.")
            }
            Section("Quick paste") {
                Toggle("Paste items 1–9 with a number key", isOn: $prefs.quickPasteEnabled)
                Picker("Hold", selection: $prefs.quickPasteModifier) {
                    Text("⌘ Command").tag("command")
                    Text("⌥ Option").tag("option")
                    Text("⌃ Control").tag("control")
                }
                .disabled(!prefs.quickPasteEnabled)
                Hint(prefs.quickPasteModifier == "control"
                     ? "Some Macs use ⌃1–⌃9 to switch Spaces; those keys then won't reach Pastly."
                     : "Add ⇧ (or ⌥ with ⌘) to paste in the other format.")
            }
            Section("In the clipboard window") {
                fixed("Select all items", "⌘A")
                fixed("Paste the selected items", "↩   ⌘V")
                fixed("Paste in the other format", "⇧↩   ⌥↩   ⌥⌘V")
                fixed("Paste the selected items one by one", "⌘↩")
                Toggle("Delete selected items with ⌫ / ⌦", isOn: $prefs.deleteKeyDeletes)
                Hint("⌘⌫ always deletes, and ⌘Z brings deleted items back.")
                Toggle("Space opens and closes the preview", isOn: $prefs.spaceTogglesPreview)
                fixed("Close the preview", "esc")
                fixed("Copy the selected items", "⌘C")
                fixed("Pin / unpin", "⌘P")
                fixed("Edit text or title", "⌘E")
                fixed("Next / previous list", "⇥   ⇧⇥   ←   →")
                fixed("Move to top / bottom, one page", "Home   End   Page Up/Down")
                fixed("Add clips to a list, or reorder a list", "Drag onto a tab / within a list")
                fixed("Search", "⌘F")
                fixed("New list", "⌘N")
                fixed("Close the window", "esc   ⌘W")
            }
            Section("Menu bar icon") {
                fixed("Open clipboard history", "Click")
                fixed("Menu: recent items, pause, backup, settings", "Right-click")
                fixed("Pause / resume monitoring", "⌥-click")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 4. Lists

struct ListsSettings: View {
    @ObservedObject var router: SettingsRouter
    @ObservedObject private var store = ClipStore.shared
    @State private var selection: String? = "pinned"

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    Section("Library") {
                        Label("Pinned", systemImage: "pin")
                            .badge(store.items.filter(\.isPinned).count)
                            .tag("pinned")
                    }
                    Section("Smart Lists") {
                        ForEach(store.smartLists) { l in
                            Label(l.name, systemImage: l.symbol).badge(store.count(in: l)).tag("smart:" + l.id)
                        }
                        .onMove { store.moveSmartLists(fromOffsets: $0, toOffset: $1) }
                    }
                    Section("Lists") {
                        ForEach(store.lists) { l in
                            Label { Text(l.name) } icon: { Image(systemName: "folder.fill").foregroundStyle(ListColor.color(l.color)) }
                                .badge(l.itemIDs.count)
                                .tag("list:" + l.id)
                        }
                        .onMove { store.moveLists(fromOffsets: $0, toOffset: $1) }
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 6) {
                    Menu {
                        Button("New Smart List") { newSmartList() }
                        Button("New List") { newList() }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("New list")
                    Button { deleteSelected() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selection == nil || selection == "pinned")
                        .help("Delete the selected list (its items stay in History)")
                    Spacer()
                    Text("Drag to reorder").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(8)
            }
            .frame(width: 220)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: handleRequest)
        .onChange(of: router.smartListRequest) { handleRequest() }
    }

    @ViewBuilder
    private var detail: some View {
        if selection == "pinned" {
            PinnedListEditor(store: store)
        } else if let sel = selection, sel.hasPrefix("smart:"), let smart = store.smartLists.first(where: { "smart:" + $0.id == sel }) {
            SmartListEditor(list: smart, store: store).id(smart.id)
        } else if let sel = selection, sel.hasPrefix("list:"), let list = store.lists.first(where: { "list:" + $0.id == sel }) {
            ListEditor(listID: list.id, store: store).id(list.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 34)).foregroundStyle(.tertiary)
                Text("Organize your clipboard").font(.headline)
                Text("Lists hold the items you put in them. Smart Lists fill themselves from rules.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
            }
        }
    }

    private func handleRequest() {
        guard let req = router.smartListRequest else { return }
        router.smartListRequest = nil
        if req.isEmpty { newSmartList() } else { selection = "smart:" + req }
    }

    private func newSmartList() {
        let l = store.createSmartList(name: "New Smart List", rules: [SmartRule(field: .type, op: .is, value: ClipType.url.rawValue)])
        selection = "smart:" + l.id
    }

    private func newList() {
        let l = store.createList(name: "New List")
        selection = "list:" + l.id
    }

    private func deleteSelected() {
        guard let sel = selection else { return }
        if sel.hasPrefix("list:") { store.deleteList(String(sel.dropFirst(5))) }
        if sel.hasPrefix("smart:") { store.deleteSmartList(String(sel.dropFirst(6))) }
        selection = "pinned"
    }
}

/// One clip in a Settings list: icon, text, and actions.
private struct SettingsClipRow<Actions: View>: View {
    let item: ClipItem
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.type.symbol).foregroundStyle(.secondary).frame(width: 16)
            Text(item.displayText.replacingOccurrences(of: "\n", with: " ⏎ ")).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            actions()
        }
    }
}

struct PinnedListEditor: View {
    @ObservedObject var store: ClipStore

    var body: some View {
        let pinned = store.items.filter(\.isPinned)
        Form {
            Section("Pinned items") {
                if pinned.isEmpty {
                    Hint("Nothing pinned yet. Select an item in the clipboard window and press ⌘P.")
                }
                ForEach(pinned) { item in
                    SettingsClipRow(item: item) {
                        Menu("Add to List") {
                            ForEach(store.lists) { l in
                                Button(l.name) { store.add(item.id, toList: l.id) }.disabled(l.itemIDs.contains(item.id))
                            }
                        }
                        .fixedSize()
                        .disabled(store.lists.isEmpty)
                        Button("Unpin") { store.togglePin(item.id) }
                    }
                }
            }
            Hint("Pinned items stay at hand in the Pinned tab and are never deleted automatically.")
        }
        .formStyle(.grouped)
    }
}

struct ListEditor: View {
    let listID: String
    @ObservedObject var store: ClipStore
    @State private var name = ""

    private var list: ClipList? { store.lists.first { $0.id == listID } }

    var body: some View {
        if let list {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .onSubmit(commitName)
                    LabeledContent("Color") {
                        HStack(spacing: 8) {
                            ForEach(ClipList.palette, id: \.self) { c in
                                Button { store.setListColor(listID, c) } label: {
                                    Circle().fill(ListColor.color(c)).frame(width: 16, height: 16)
                                        .overlay(Circle().strokeBorder(Color.primary.opacity(list.color == c ? 0.6 : 0), lineWidth: 2).frame(width: 22, height: 22))
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .help(c.capitalized)
                            }
                        }
                    }
                }
                Section("Items (\(list.itemIDs.count))") {
                    if list.itemIDs.isEmpty {
                        Hint("Right-click an item in the clipboard window → Add to List.")
                    }
                    ForEach(Array(list.itemIDs.enumerated()), id: \.element) { index, itemID in
                        if let item = store.item(id: itemID) {
                            SettingsClipRow(item: item) {
                                Button { store.moveItem(itemID, inList: listID, by: -1) } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.borderless).disabled(index == 0).help("Move up")
                                Button { store.moveItem(itemID, inList: listID, by: 1) } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.borderless).disabled(index == list.itemIDs.count - 1).help("Move down")
                                Menu("Move to") {
                                    ForEach(store.lists.filter { $0.id != listID }) { other in
                                        Button(other.name) { store.move([itemID], fromList: listID, toList: other.id) }
                                    }
                                }
                                .fixedSize()
                                .disabled(store.lists.count < 2)
                                Button { store.remove(itemID, fromList: listID) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remove from this list")
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear { name = list.name }
            .onDisappear(perform: commitName)
            .onChange(of: name) { commitName() }
        }
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty, n != list?.name { store.renameList(listID, to: n) }
    }
}

// MARK: - 5. Privacy

struct PrivacySettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var newRule = ""
    @State private var ruleError: String?
    @State private var storagePrivate = SecureStorage.isPrivate(ClipStore.supportDirectory)
    @State private var newKeyword = ""
    @State private var testText = ""
    @State private var testApp = ""

    /// On/off switch for a rule kept in a "disabled" list.
    private func enabledBinding(_ value: String, in key: ReferenceWritableKeyPath<Preferences, [String]>) -> Binding<Bool> {
        Binding(get: { !prefs[keyPath: key].contains(value) },
                set: { on in
                    if on { prefs[keyPath: key].removeAll { $0 == value } }
                    else if !prefs[keyPath: key].contains(value) { prefs[keyPath: key].append(value) }
                })
    }

    private func kindBinding(_ kind: String) -> Binding<Bool> {
        Binding(get: { !prefs.excludedTypes.contains(kind) },
                set: { on in
                    if on { prefs.excludedTypes.removeAll { $0 == kind } }
                    else if !prefs.excludedTypes.contains(kind) { prefs.excludedTypes.append(kind) }
                })
    }

    private func addKeyword() {
        let k = newKeyword.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, !prefs.keywordRules.contains(where: { $0.keyword == k }) else { return }
        prefs.keywordRules.append(KeywordRule(keyword: k))
        newKeyword = ""
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && !prefs.ignoredBundleIDs.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        Form {
            Section("Clipboard monitoring") {
                Toggle("Monitor the clipboard", isOn: monitorBinding)
                Hint("Turn off to stop saving anything new. Your existing history stays.")
            }

            Section {
                ForEach(prefs.ignoredBundleIDs, id: \.self) { id in
                    HStack {
                        if let icon = AppIconCache.icon(for: id) {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 18)
                        }
                        Text(AppIconCache.name(for: id)).lineLimit(1)
                        Text(id).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Toggle("", isOn: enabledBinding(id, in: \.disabledIgnoredApps))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .help("Turn this rule on or off without removing it")
                        Button { prefs.ignoredBundleIDs.removeAll { $0 == id }; prefs.disabledIgnoredApps.removeAll { $0 == id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Menu("Add Running App") {
                        ForEach(runningApps, id: \.processIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier!) {
                                prefs.ignoredBundleIDs.append(app.bundleIdentifier!)
                            }
                        }
                    }
                    .fixedSize()
                    Button("Choose App…") { chooseApp() }
                }
            } header: {
                Text("Never save copies from these apps")
            }

            Section("Sensitive content") {
                Label("Passwords and anything apps mark as concealed or temporary are never saved.", systemImage: "lock.shield")
                    .font(.callout)
                Toggle("Skip card numbers", isOn: $prefs.skipCardNumbers)
                Toggle("Skip one-time codes (a copied 4–8 digit code)", isOn: $prefs.skipOneTimeCodes)
                Toggle("Skip API keys, tokens and private keys", isOn: $prefs.skipSecrets)
                Hint("Card numbers are checked with the standard Luhn checksum. Keys include AWS, GitHub, Stripe, Slack, Google, OpenAI/Anthropic-style keys, JWTs and PEM private keys.")
            }

            Section {
                ForEach($prefs.keywordRules) { $rule in
                    HStack {
                        Text(rule.keyword).lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Toggle("Match case", isOn: $rule.matchCase).toggleStyle(.checkbox).controlSize(.small)
                        Toggle("", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        Button { prefs.keywordRules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Word or phrase", text: $newKeyword).onSubmit(addKeyword)
                    Button("Add") { addKeyword() }.disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Never save text containing")
            }

            Section("Content kinds") {
                ForEach(ClipType.allCases) { type in
                    Toggle("Save \(type.displayName.lowercased())", isOn: kindBinding(type.rawValue))
                }
                Toggle("Save code", isOn: kindBinding(SmartRule.codeKind))
                Hint("Turn a kind off to stop saving it. Clips you already have are kept.")
            }

            Section {
                ForEach(prefs.regexRules, id: \.self) { rule in
                    HStack {
                        Text(rule).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Toggle("", isOn: enabledBinding(rule, in: \.disabledRegexRules))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                        Button { prefs.regexRules.removeAll { $0 == rule }; prefs.disabledRegexRules.removeAll { $0 == rule } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Regular expression", text: $newRule)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Add") { addRule() }.disabled(newRule.isEmpty)
                }
                if let ruleError { Text(ruleError).font(.caption).foregroundStyle(.red) }
                Button("Add Credit-Card Number Rule") {
                    newRule = #"\b(?:\d[ -]?){13,19}\b"#
                    addRule()
                }
            } header: {
                Text("Never save text that matches")
            }

            Section("Test your rules") {
                TextField("Paste or type something you might copy", text: $testText)
                Picker("Copied from", selection: $testApp) {
                    Text("Any app").tag("")
                    ForEach(prefs.ignoredBundleIDs, id: \.self) { Text(AppIconCache.name(for: $0)).tag($0) }
                }
                if !testText.isEmpty || !testApp.isEmpty {
                    let reason = CaptureFilter.explain(text: testText, appBundleID: testApp.isEmpty ? nil : testApp)
                    Label(reason.map { "Won't be saved — \($0)" } ?? "Will be saved",
                          systemImage: reason == nil ? "checkmark.circle.fill" : "nosign")
                        .foregroundStyle(reason == nil ? .green : .orange)
                }
            }

            Section("Data retention") {
                Picker("Keep up to", selection: $prefs.historyLimit) {
                    Text("100 items").tag(100)
                    Text("250 items").tag(250)
                    Text("500 items").tag(500)
                    Text("1,000 items").tag(1000)
                    Text("5,000 items").tag(5000)
                    Text("Unlimited").tag(0)
                }
                Picker("Automatically delete items not used for", selection: $prefs.autoDeleteDays) {
                    Text("Never").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Toggle("Clear history when Pastly quits", isOn: $prefs.clearOnQuit)
                Hint("Pinned items and items in lists are kept.")
            }

            Section("Storage") {
                LabeledContent("Location") {
                    Text(ClipStore.supportDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent("Access") {
                    HStack {
                        Image(systemName: storagePrivate ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(storagePrivate ? .green : .orange)
                        Text(storagePrivate ? "Only your account can read it" : "Other accounts may read it")
                        if !storagePrivate {
                            Button("Fix") {
                                SecureStorage.apply(to: ClipStore.supportDirectory)
                                storagePrivate = SecureStorage.isPrivate(ClipStore.supportDirectory)
                            }
                        }
                    }
                }
                Hint("History never leaves this Mac — no cloud, no accounts, no tracking.")
                Button("Show in Finder") { NSWorkspace.shared.open(ClipStore.supportDirectory) }
            }

            Section("Clear") {
                HStack {
                    Button("Clear History…") { confirmClear(everything: false) }
                    Button("Delete Everything…", role: .destructive) { confirmClear(everything: true) }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: prefs.historyLimit) { ClipStore.shared.enforceLimits() }
        .onChange(of: prefs.autoDeleteDays) { ClipStore.shared.enforceLimits() }
        .onAppear { storagePrivate = SecureStorage.isPrivate(ClipStore.supportDirectory) }
    }

    private func addRule() {
        let r = newRule.trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return }
        guard (try? NSRegularExpression(pattern: r)) != nil else { ruleError = "Invalid regular expression."; return }
        if !prefs.regexRules.contains(r) { prefs.regexRules.append(r) }
        newRule = ""
        ruleError = nil
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !prefs.ignoredBundleIDs.contains(id) {
                prefs.ignoredBundleIDs.append(id)
            }
        }
    }

    private func confirmClear(everything: Bool) {
        let alert = NSAlert()
        alert.messageText = everything ? "Delete all items, including pinned and listed ones?" : "Clear clipboard history?"
        alert.informativeText = everything
            ? "This permanently deletes every saved item. Lists are kept but emptied. This can't be undone."
            : "Pinned items and items saved in lists are kept. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: everything ? "Delete Everything" : "Clear History")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            ClipStore.shared.clearHistory(everything: everything)
        }
    }
}

// MARK: - 6. Backup

struct BackupSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var status: String?
    @State private var backups: [AutoBackup.Entry] = []

    var body: some View {
        Form {
            Section("Export & import") {
                Text("Save your history to a file you choose, or bring one back — for example on another Mac.")
                    .font(.callout)
                HStack {
                    Button("Export…") { status = BackupActions.export() }
                    Button("Import…") { status = BackupActions.importBackup(); refresh() }
                }
            }
            Section("Manual backup") {
                HStack {
                    Button("Back Up Now") { backUpNow() }
                    Spacer()
                    Button("Show Backups in Finder") { revealFolder() }
                }
                Hint("Saves a dated copy into your backup folder.")
            }
            Section("Automatic backups") {
                Toggle("Back up automatically", isOn: $prefs.autoBackupEnabled)
                Picker("How often", selection: $prefs.autoBackupFrequency) {
                    Text("Every day").tag("daily")
                    Text("Every week").tag("weekly")
                }
                .disabled(!prefs.autoBackupEnabled)
                Stepper("Keep the latest \(prefs.autoBackupKeep) backup\(prefs.autoBackupKeep == 1 ? "" : "s")",
                        value: $prefs.autoBackupKeep, in: 1...60)
                LabeledContent("Folder") {
                    HStack {
                        Text(prefs.autoBackupFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                LabeledContent("Last automatic backup") {
                    Text(prefs.lastAutoBackup > 0
                         ? Date(timeIntervalSince1970: prefs.lastAutoBackup).formatted(date: .abbreviated, time: .shortened)
                         : "Never")
                    .foregroundStyle(.secondary)
                }
            }
            Section("Restore") {
                if backups.isEmpty {
                    Hint("No backups in the backup folder yet.")
                }
                ForEach(backups.prefix(10)) { b in
                    HStack {
                        Image(systemName: "doc.zipper").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.date.formatted(date: .abbreviated, time: .shortened))
                            Text(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore…") { restore(b.url) }
                    }
                }
                Button("Restore from File…") { restoreFromFile() }
            }
            Section("What's included") {
                Hint("Text and rich text (RTF/HTML), links, colors, images (stored inside the backup), file references, titles, pins, use counts, lists and Smart Lists. Files themselves aren't copied — only where they are.")
            }
            if let status {
                Section { Text(status).font(.callout) }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onChange(of: prefs.autoBackupFolder) { refresh() }
        .onChange(of: prefs.autoBackupKeep) { AutoBackup.prune(in: AutoBackup.folder, keep: prefs.autoBackupKeep); refresh() }
        .onChange(of: prefs.autoBackupEnabled) { AutoBackup.runIfDue(); refresh() }
    }

    private func refresh() { backups = AutoBackup.existingBackups() }

    private func backUpNow() {
        do {
            let url = try AutoBackup.backupNow()
            status = "Backed up \(ClipStore.shared.items.count) items to \(url.lastPathComponent)."
        } catch {
            status = "Backup failed: \(error.localizedDescription)"
        }
        refresh()
    }

    private func revealFolder() {
        try? FileManager.default.createDirectory(at: AutoBackup.folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AutoBackup.folder)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = AutoBackup.folder
        if panel.runModal() == .OK, let url = panel.url { prefs.autoBackupFolder = url.path }
    }

    private func restoreFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [BackupActions.fileType, BackupActions.legacyFileType, .json]
        if panel.runModal() == .OK, let url = panel.url { restore(url) }
    }

    private func restore(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Restore this backup?"
        alert.informativeText = "Merge adds the backup's items to your current history (duplicates are skipped). Replace removes your current items first, then restores the backup."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace History")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        do {
            let r = try AutoBackup.restore(from: url, replace: choice == .alertSecondButtonReturn)
            status = "Restored \(r.added) items (\(r.skipped) already there, \(r.lists) new lists)."
        } catch {
            status = "Restore failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - 7. About

struct AboutSettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @State private var checking = false
    @State private var result: UpdateChecker.Result?
    @State private var showLicense = false
    @State private var showChangelog = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pastly").font(.title2.bold())
                        Text("Version \(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary)
                        Text("A beautiful, native clipboard manager for macOS.\nFree and open source · 100% local · No tracking.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Updates") {
                HStack {
                    Button("Check for Updates") { check() }.disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    resultView
                }
                Toggle("Check automatically every week", isOn: $prefs.checkUpdatesAutomatically)
                    .disabled(!AppInfo.isRepositoryConfigured)
                Hint(AppInfo.isRepositoryConfigured
                     ? "Only GitHub is contacted, and only to read the latest release number."
                     : "Update checks start working once the GitHub repository is set (PastlyGitHubRepository in Info.plist).")
            }
            Section("Links") {
                Link("GitHub repository", destination: AppInfo.repositoryURL)
                Link("Release notes", destination: AppInfo.releasesURL)
            }
            Section("License & changes") {
                LabeledContent("License") {
                    HStack {
                        Text("MIT — free and open source").foregroundStyle(.secondary)
                        Button("View…") { showLicense = true }
                    }
                }
                LabeledContent("Changelog") {
                    Button("View…") { showChangelog = true }
                }
            }
            Section("Credits") {
                Text("Built with Swift and SwiftUI on Apple's frameworks: AppKit, SQLite, CryptoKit, Vision (on-device OCR), Carbon hot keys and ServiceManagement. No third-party code.")
                    .font(.callout)
                Text("Sounds are the ones that ship with macOS. Thanks to everyone who reports bugs and suggests ideas.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLicense) { TextSheet(title: "License", text: AppInfo.license) }
        .sheet(isPresented: $showChangelog) { TextSheet(title: "Changelog", text: AppInfo.changelog) }
    }

    @ViewBuilder
    private var resultView: some View {
        switch result {
        case .upToDate(let v)?: Label("You're up to date (\(v))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .available(let v, let url, _)?:
            HStack {
                Text("Pastly \(v) is available")
                Link("Download", destination: url)
            }
        case .notConfigured?: Text("Repository not set yet").foregroundStyle(.secondary)
        case .failed(let msg)?: Text(msg).foregroundStyle(.orange).lineLimit(2)
        case nil:
            if prefs.lastUpdateCheck > 0 {
                Text("Last checked \(Date(timeIntervalSince1970: prefs.lastUpdateCheck).formatted(.relative(presentation: .named)))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func check() {
        checking = true
        UpdateChecker.check { r in
            checking = false
            result = r
        }
    }
}

struct TextSheet: View {
    let title: String
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).padding(12)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            Divider()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(12)
        }
        .frame(width: 560, height: 460)
    }
}

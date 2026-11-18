import AVKit
import SwiftUI

enum RelativeTime {
    /// Short form for rows: "now", "5m ago", "3h ago", "2d ago", then a date.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d ago" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func string(_ date: Date) -> String { short(date) }
}

// MARK: - Row

struct ClipRow: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    var isCursor: Bool = false
    var isRecent: Bool = false
    var isCode: Bool = false
    let store: ClipStore
    @ObservedObject var prefs: Preferences

    private var scale: CGFloat { prefs.fontScale }
    private var comfortable: Bool { prefs.rowDensity == "comfortable" }
    private var fg: Color { .primary }
    private var secondary: Color { .secondary }
    /// Selected rows: light blue background (#EAF2FF; a blue tint in Dark Mode) with a blue border
    /// (#3B82F6); the keyboard cursor in a multi-selection uses the deeper accent (#2563EB).
    static let selectionBorder = Color(nsColor: NSColor(srgbRed: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 1))
    static let selectionAccent = Color(nsColor: NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1))
    static let selectionBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 0.24)
            : NSColor(srgbRed: 0xEA / 255, green: 0xF2 / 255, blue: 0xFF / 255, alpha: 1)
    })

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5 * scale, design: item.type == .color || isCode ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(item.type == .image && !hasCustomTitle ? secondary : fg)
                if comfortable {
                    HStack(spacing: 4) {
                        if let icon = AppIconCache.icon(for: item.sourceAppBundleID) {
                            Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                        }
                        Text(item.sourceAppName ?? "Unknown app").lineLimit(1)
                    }
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(secondary)
                }
            }
            Spacer(minLength: 6)
            let colors = store.embeddedColors(item)
            if !colors.isEmpty {
                HStack(spacing: -3) {
                    ForEach(colors.prefix(3), id: \.self) { hex in
                        Circle().fill(Color(nsColor: NSColor(hex: hex) ?? .clear))
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                    }
                }
                .help(colors.joined(separator: "  "))
            }
            if item.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(.orange)
            }
            if prefs.showAppIcons && !comfortable, let icon = AppIconCache.icon(for: item.sourceAppBundleID) {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14).opacity(isSelected ? 1 : 0.85)
            }
            Text(RelativeTime.short(item.lastUsedAt))
                .font(.system(size: 11.5 * scale))
                .foregroundStyle(secondary)
                .monospacedDigit()
            if prefs.showShortcutNumbers && prefs.quickPasteEnabled {
                Text(index < 9 ? "\(prefs.quickPasteSymbol)\(index + 1)" : "")
                    .font(.system(size: 11.5 * scale))
                    .foregroundStyle(Color.secondary.opacity(0.75))
                    .frame(width: 24, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, comfortable ? 7 : (item.type == .image ? 4 : 5))
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(isSelected ? Self.selectionBackground : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(isCursor ? Self.selectionAccent : Self.selectionBorder.opacity(isSelected ? 1 : 0),
                              lineWidth: isCursor ? 1.8 : 1.2)
        )
        // "Just copied" glow
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(prefs.accent.opacity(isRecent && !isSelected && prefs.animateList ? 0.22 : 0))
                .allowsHitTesting(false)
                .animation(.easeOut(duration: isRecent ? 0.15 : 0.9), value: isRecent)
        )
    }

    private var radius: CGFloat { CGFloat(prefs.cornerRadius) }

    private var hasCustomTitle: Bool { !(item.customTitle ?? "").isEmpty }

    private var title: String {
        if item.type == .image && !hasCustomTitle { return "\(item.imageWidth)×\(item.imageHeight)" }
        if item.type == .file && !hasCustomTitle && item.fileURLs.count > 1 {
            return "\(item.fileURLs.count) files: " + item.fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        }
        return item.displayText
            .replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    @ViewBuilder
    private var leading: some View {
        switch item.type {
        case .image:
            if let name = item.imagePath {
                AsyncThumbnail(images: store.images, name: name, file: nil, maxPixel: 160) { symbolBox("photo") }
                    .frame(width: comfortable ? 64 : 58, height: comfortable ? 42 : 38)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            } else {
                symbolBox("photo")
            }
        case .color:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: NSColor(hex: item.colorHex ?? "") ?? .clear))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                .frame(width: iconSize, height: iconSize)
        case .file:
            if item.imagePath != nil || imageFileURL != nil {
                AsyncThumbnail(images: store.images, name: item.imagePath, file: imageFileURL, maxPixel: 160) { symbolBox("photo") }
                    .frame(width: comfortable ? 64 : 58, height: comfortable ? 42 : 38)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            } else if let media = item.fileURLs.first(where: { MediaSupport.kind(of: $0) != nil }) {
                MediaThumbnailView(url: media, size: CGSize(width: comfortable ? 64 : 58, height: comfortable ? 42 : 38))
            } else if item.fileURLs.count == 1, let u = item.fileURLs.first, let icon = FileIcons.icon(forExistingFile: u.path) {
                Image(nsImage: icon).resizable().scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            } else {
                symbolBox("doc")
            }
        case .url:
            symbolBox("link")
        case .text:
            symbolBox(isCode ? "chevron.left.forwardslash.chevron.right" : "text.alignleft")
        }
    }

    /// An image file in a file clip (thumbnail source for older clips without a stored copy).
    private var imageFileURL: URL? { item.fileURLs.first(where: ImageFileLoader.displayIsImageFile) }

    private var iconSize: CGFloat { (comfortable ? 26 : 22) * scale }

    private func symbolBox(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .overlay(Image(systemName: symbol).font(.system(size: 10.5 * scale, weight: .medium)).foregroundStyle(secondary))
            .frame(width: iconSize, height: iconSize)
    }
}

// MARK: - Preview window content

/// Hosted in the side preview window; shows whatever `state.previewItem` is.
struct PreviewContainer: View {
    @ObservedObject var state: PanelState
    @ObservedObject var store: ClipStore
    @ObservedObject var prefs: Preferences

    var body: some View {
        Group {
            if let item = state.previewItem {
                PreviewPane(item: item, store: store, isCode: store.isCode(item), pinnedOpen: state.showPreview,
                            controller: state.controller)
                    .id(item.id)
            } else {
                Color.clear
            }
        }
        .tint(prefs.accent)
    }
}

struct PreviewPane: View {
    let item: ClipItem
    let store: ClipStore
    var isCode: Bool = false
    var pinnedOpen: Bool = false
    weak var controller: PanelController?

    private static let maxPreviewChars = 30_000
    /// Formatted / Plain, chosen next to the Paste button. It decides what Paste pastes and how the
    /// preview shows rich text. Starts from Settings → General → "Default paste format".
    /// The one paste mode (Settings → General → Default paste format). The Formatted/Plain menu next to
    /// Paste edits this same setting — there is no separate copy here that could go stale.
    @ObservedObject private var prefs = Preferences.shared
    private var plainMode: Bool { prefs.pastePlainByDefault }
    private var showFormatted: Bool { !plainMode }
    /// Rich text has formatting to keep or drop; other text kinds paste the same either way.
    private var hasFormatting: Bool { item.type == .text && (item.rtfData != nil || item.htmlData != nil) }

    /// The clip's original formatting (RTF or HTML), when it has some.
    private var richText: AttributedString? {
        guard item.type == .text else { return nil }
        let ns: NSAttributedString?
        if let rtf = item.rtfData, rtf.count < 400_000 {
            ns = NSAttributedString(rtf: rtf, documentAttributes: nil)
        } else if let html = item.htmlData, html.count < 400_000 {
            ns = NSAttributedString(html: html, documentAttributes: nil)
        } else {
            ns = nil
        }
        guard let ns, ns.length > 0 else { return nil }
        return try? AttributedString(ns, including: \.appKit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            Divider()
            metadata.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            Text(pinnedOpen ? "Space closes the preview · ⌘E to edit" : "Space keeps the preview open · ⌘E to edit")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    // MARK: Header

    private var kindTitle: String {
        switch item.type {
        case .text: return isCode ? "Code" : "Text"
        case .url: return "Link"
        case .color: return "Color"
        case .image: return "Image"
        case .file: return item.fileURLs.count == 1 ? "File" : "\(item.fileURLs.count) Files"
        }
    }

    private var kindSymbol: String {
        switch item.type {
        case .text: return isCode ? "chevron.left.forwardslash.chevron.right" : "text.alignleft"
        case .url: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kindSymbol).foregroundStyle(.secondary)
            Text(item.customTitle?.isEmpty == false ? item.customTitle! : kindTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            pasteControl
                .fixedSize()            // never squeezed (a squeezed Paste button became a tall blue bar)
                .layoutPriority(2)
            headerButton(item.isPinned ? "pin.fill" : "pin", help: item.isPinned ? "Unpin (⌘P)" : "Pin (⌘P)") {
                controller?.togglePin([item])
            }
            headerButton("doc.on.doc", help: "Copy (⌘C)") { controller?.copy(item) }
            headerButton("pencil", help: item.type.isTextual ? "Edit (⌘E)" : "Rename (⌘E)") {
                controller?.state.select(item.id)
                controller?.state.beginEdit(item)
                controller?.panel.makeKeyAndOrderFront(nil)
            }
            headerButton("trash", help: "Delete (⌫)") { controller?.delete(item) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    /// [ Paste ][ Formatted ▾ ] — Paste uses the mode chosen in the menu. Images and files have one way to paste.
    private var pasteControl: some View {
        HStack(spacing: 1) {
            Button("Paste") { controller?.paste([item], plain: plainMode) }
                .buttonStyle(BluePasteButtonStyle(trailingFlat: item.type.isTextual))
                .help(item.type.isTextual ? (plainMode ? "Paste as plain text" : "Paste with its formatting")
                                          : "Paste this item into the app you were using (↩)")
            if item.type.isTextual {
                Menu {
                    Picker("Paste as", selection: $prefs.pastePlainByDefault) {
                        Text("Formatted Paste").tag(false)
                        Text("Plain Paste").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(spacing: 4) {
                        Text(plainMode ? "Plain" : "Formatted")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .menuStyle(.button)
                .buttonStyle(BluePasteMenuStyle())
                .menuIndicator(.hidden)
                .help(hasFormatting ? "Choose Formatted (keeps bold, fonts, colors, links) or Plain text"
                                    : "This clip has no formatting — both modes paste the same text")
                .accessibilityLabel(plainMode ? "Paste mode: Plain" : "Paste mode: Formatted")
            }
        }
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch item.type {
        case .text:
            let text = String((item.plainText ?? "").prefix(Self.maxPreviewChars))
            VStack(alignment: .leading, spacing: 8) {
                if let rich = richText, showFormatted {
                    Text(rich).textSelection(.enabled)
                } else if isCode && Preferences.shared.highlightCode {
                    Text(CodeHighlighter.highlight(text))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text(text)
                        .font(isCode ? .system(size: 12, design: .monospaced) : .system(size: 13))
                        .textSelection(.enabled)
                }
                let colors = store.embeddedColors(item)
                if !colors.isEmpty {
                    Divider().padding(.vertical, 4)
                    Text("Colors in this clip").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(colors, id: \.self) { hex in
                            ColorChip(hex: hex) { controller?.copyColor(hex) }
                        }
                    }
                }
                if (item.plainText?.count ?? 0) > Self.maxPreviewChars {
                    Text("Preview shortened — \(item.plainText!.count) characters in total.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .url:
            VStack(alignment: .leading, spacing: 12) {
                if let u = URL(string: item.plainText ?? ""), let host = u.host {
                    Label(host, systemImage: "globe").font(.system(size: 15, weight: .semibold))
                }
                Text(item.plainText ?? "").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                if let u = URL(string: item.plainText ?? "") {
                    Button("Open in Browser") { NSWorkspace.shared.open(u) }
                }
            }
        case .color:
            let ns = NSColor(hex: item.colorHex ?? "") ?? .clear
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: ns)).frame(height: 170)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                Text(item.colorHex ?? "").font(.system(size: 20, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                ForEach(ColorFormats.all(ns), id: \.self) { line in
                    HStack {
                        Text(line).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        Spacer()
                        Button { controller?.copyColor(line) } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Copy \(line)")
                    }
                }
            }
        case .image:
            VStack(alignment: .leading, spacing: 12) {
                if let name = item.imagePath {
                    AsyncThumbnail(images: store.images, name: name, file: nil, maxPixel: Self.previewPixels,
                                   contentMode: .fit, aspect: aspect) { EmptyView() }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(maxWidth: .infinity)
                }
                Button("Copy Text from Image (OCR)") { controller?.recognizeText(item) }
            }
        case .file:
            VStack(alignment: .leading, spacing: 10) {
                if let file = previewImageFile {
                    // The file on disk first (as before), the stored copy if the file is gone.
                    AsyncThumbnail(images: store.images, name: nil, file: file, maxPixel: Self.previewPixels,
                                   contentMode: .fit, aspect: aspect) {
                        AsyncThumbnail(images: store.images, name: item.imagePath, file: nil, maxPixel: Self.previewPixels,
                                       contentMode: .fit, aspect: aspect) { EmptyView() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity)
                } else if let name = item.imagePath {
                    AsyncThumbnail(images: store.images, name: name, file: nil, maxPixel: Self.previewPixels,
                                   contentMode: .fit, aspect: aspect) { EmptyView() }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .frame(maxWidth: .infinity)
                } else if let media = item.fileURLs.first(where: { MediaSupport.kind(of: $0) != nil }) {
                    MediaPreview(url: media).id(media)
                }
                ForEach(item.fileURLs, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: FileIcons.icon(forFile: url.path)).resizable().frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.lastPathComponent).font(.system(size: 13, weight: .medium))
                            Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
            }
        }
    }

    /// Full image for an image-file clip: the original file when it's still there, else the stored copy.
    /// Preview images are decoded off the main thread at up to this size (sharp at the widest preview).
    static let previewPixels = 1600
    private var previewImageFile: URL? { item.fileURLs.first(where: ImageFileLoader.displayIsImageFile) }
    private var aspect: CGFloat? { item.imageWidth > 0 && item.imageHeight > 0 ? CGFloat(item.imageWidth) / CGFloat(item.imageHeight) : nil }

    // MARK: Metadata

    private var metadata: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                label("App")
                HStack(spacing: 5) {
                    if let icon = AppIconCache.icon(for: item.sourceAppBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text(item.sourceAppName ?? "Unknown")
                }
            }
            if let length = lengthDescription { GridRow { label("Length"); Text(length) } }
            if (item.type == .image || item.type == .file) && item.imageWidth > 0 {
                GridRow { label("Dimensions"); Text("\(item.imageWidth) × \(item.imageHeight) px") }
            }
            if item.type == .file, let media = item.fileURLs.first(where: { MediaSupport.kind(of: $0) != nil }),
               let d = MediaSupport.cachedInfo(for: media)?.durationText {
                GridRow { label("Duration"); Text(d) }
            }
            if let name = item.imagePath, item.type == .image || item.type == .file {
                GridRow { label("Format"); Text(store.images.uti(for: name).localizedDescription ?? "Image") }
            }
            GridRow { label("First copied"); Text(item.createdAt.formatted(date: .abbreviated, time: .shortened)) }
            GridRow { label("Last copied"); Text(item.lastUsedAt.formatted(date: .abbreviated, time: .shortened)) }
            GridRow { label("Copies / pastes"); Text("\(max(1, item.useCount - item.pasteCount)) / \(item.pasteCount)") }
            if let size = sizeDescription { GridRow { label("Size"); Text(size) } }
        }
        .font(.system(size: 11.5))
        .textSelection(.enabled)
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    private var lengthDescription: String? {
        guard item.type.isTextual, let t = item.pasteableText else { return nil }
        let lines = t.split(separator: "\n", omittingEmptySubsequences: false).count
        let words = t.split { $0.isWhitespace || $0.isNewline }.count
        return "\(t.count) characters · \(lines) line\(lines == 1 ? "" : "s") · \(words) word\(words == 1 ? "" : "s")"
    }

    private var sizeDescription: String? {
        let bytes: Int
        switch item.type {
        case .image:
            guard let name = item.imagePath,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: store.images.url(for: name).path),
                  let n = attrs[.size] as? Int else { return nil }
            bytes = n
        case .file:
            return nil
        default:
            bytes = (item.pasteableText ?? "").utf8.count + (item.rtfData?.count ?? 0) + (item.htmlData?.count ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The preview's Paste button: always blue (#2563EB), even though the preview window is never the key window.
/// With `trailingFlat` it joins the Formatted/Plain menu on its right as one compact control.
struct BluePasteButtonStyle: ButtonStyle {
    var trailingFlat = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 3.5)
            .background(UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 11,
                                               bottomTrailingRadius: trailingFlat ? 3 : 11, topTrailingRadius: trailingFlat ? 3 : 11)
                .fill(ClipRow.selectionAccent.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
            .fixedSize()
    }
}

/// The Formatted / Plain menu half of the Paste control.
struct BluePasteMenuStyle: ButtonStyle {
    /// #2563EB on light backgrounds, a lighter blue in Dark Mode so the label stays readable.
    static let text = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x93 / 255, green: 0xB8 / 255, blue: 0xFF / 255, alpha: 1)
            : NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1)
    })
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(Self.text)
            .padding(.leading, 9).padding(.trailing, 8).padding(.vertical, 3.5)
            .background(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 11, topTrailingRadius: 11)
                .fill(ClipRow.selectionAccent.opacity(configuration.isPressed ? 0.22 : 0.13)))
            .contentShape(Rectangle())
            .fixedSize()
    }
}

/// A recognized color: swatch + value; click to copy it.
struct ColorChip: View {
    let hex: String
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            copy()
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: NSColor(hex: hex) ?? .clear))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                    .frame(width: 18, height: 18)
                Text(copied ? "Copied" : hex).font(.system(size: 11.5, design: .monospaced))
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help("Copy \(hex)")
    }
}

// MARK: - Drag card (the image that follows the cursor while dragging)

/// A complete, self-contained card for a clip, rendered with ImageRenderer from the clip's own data —
/// never a screen snapshot — so it is always fully drawn: real thumbnail when one is available
/// (cached or read synchronously from disk), otherwise a complete icon; never a loading placeholder.
struct DragCardView: View {
    let item: ClipItem
    let store: ClipStore
    let width: CGFloat
    var count: Int = 1
    let accent: Color
    let radius: CGFloat

    static func thumbnail(for item: ClipItem, store: ClipStore) -> NSImage? {
        if let name = item.imagePath, let t = store.images.thumbnail(for: name) { return t }
        if item.type == .file, let url = item.fileURLs.first {
            if let t = store.images.thumbnail(forFile: url) { return t }
            if MediaSupport.kind(of: url) != nil, let t = MediaSupport.cachedThumbnail(for: url, pixels: 120) { return t }
        }
        return nil
    }

    private var title: String {
        if item.type == .image && (item.customTitle ?? "").isEmpty { return "Image \(item.imageWidth) × \(item.imageHeight)" }
        return item.displayText.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\t", with: " ")
    }

    private var subtitle: String {
        var parts: [String] = []
        switch item.type {
        case .text: parts.append(CodeDetector.isCode(item.plainText ?? "") ? "Code" : "Text")
        case .url: parts.append(URL(string: item.plainText ?? "")?.host ?? "Link")
        case .color: parts.append("Color")
        case .image: parts.append("Image")
        case .file:
            if let u = item.fileURLs.first, let kind = MediaSupport.kind(of: u) { parts.append(kind == .video ? "Video" : "Music") }
            else { parts.append(item.fileURLs.count == 1 ? (ImageFileLoader.displayContentType(of: item.fileURLs[0])?.localizedDescription ?? "File") : "\(item.fileURLs.count) files") }
        }
        if let app = item.sourceAppName { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let thumb = Self.thumbnail(for: item, store: store)
        HStack(spacing: 10) {
            leading(thumb)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, design: item.type == .color || CodeDetector.isCode(item.plainText ?? "") ? .monospaced : .default))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(accent))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(accent.opacity(0.75), lineWidth: 1.5))
    }

    @ViewBuilder
    private func leading(_ thumb: NSImage?) -> some View {
        let isMedia = item.type == .file && item.fileURLs.first.flatMap(MediaSupport.kind(of:)) != nil
        if let thumb {
            ZStack {
                Image(nsImage: thumb).resizable().scaledToFill()
                if isMedia {
                    Image(systemName: MediaSupport.kind(of: item.fileURLs[0]) == .video ? "play.circle.fill" : "music.note")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).shadow(radius: 2)
                }
            }
            .frame(width: 58, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else if item.type == .color {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: NSColor(hex: item.colorHex ?? "") ?? .clear))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                .frame(width: 30, height: 30)
        } else if item.type == .file, let u = item.fileURLs.first {
            Image(nsImage: FileIcons.icon(forFile: u.path)).resizable().scaledToFit().frame(width: 30, height: 30)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.08))
                .overlay(Image(systemName: item.type == .url ? "link"
                               : (CodeDetector.isCode(item.plainText ?? "") ? "chevron.left.forwardslash.chevron.right" : "text.alignleft"))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary))
                .frame(width: 30, height: 30)
        }
    }

    /// Renders the card at the display's scale (Retina-sharp).
    @MainActor
    static func render(_ item: ClipItem, store: ClipStore, width: CGFloat, count: Int = 1, scale: CGFloat) -> NSImage? {
        let prefs = Preferences.shared
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let card = DragCardView(item: item, store: store, width: width, count: count, accent: prefs.accent,
                                radius: max(6, CGFloat(prefs.cornerRadius)))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.nsImage
    }
}

/// Poster frame (video) or cover art (music) for a file clip, loaded in the background and cached.
struct MediaThumbnailView: View {
    let url: URL
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        let kind = MediaSupport.kind(of: url)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(nsImage: FileIcons.icon(forFile: url.path)).resizable().scaledToFit().padding(3)
            }
            if image != nil {
                Image(systemName: kind == .video ? "play.circle.fill" : "music.note")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .onAppear {
            image = MediaSupport.cachedThumbnail(for: url, pixels: 120)
            if image == nil { MediaSupport.thumbnail(for: url, pixels: 120) { image = $0 } }
        }
    }
}

/// AppKit's AVPlayerView (standard macOS video controls). Used instead of SwiftUI's VideoPlayer,
/// which crashes when its AVKit/SwiftUI layer fails to load in this build setup.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = true
        v.videoGravity = .resizeAspect
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause()
        v.player = nil
    }
}

/// Video player or music card in the preview, with duration, size and tags.
struct MediaPreview: View {
    let url: URL
    @State private var info: MediaSupport.Info?
    @State private var cover: NSImage?
    @State private var player: AVPlayer?
    @State private var playing = false

    var body: some View {
        let kind = MediaSupport.kind(of: url)
        VStack(alignment: .leading, spacing: 10) {
            if kind == .video {
                if let player, FileManager.default.fileExists(atPath: url.path) {
                    NativeVideoPlayer(player: player)
                        .aspectRatio(aspect, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else if let cover {
                    Image(nsImage: cover).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Group {
                        if let art = info?.artwork ?? cover {
                            Image(nsImage: art).resizable().scaledToFill()
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07))
                                Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(info?.title ?? url.deletingPathExtension().lastPathComponent)
                            .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        if let artist = info?.artist { Text(artist).font(.callout).foregroundStyle(.secondary) }
                        if let album = info?.album { Text(album).font(.caption).foregroundStyle(.secondary) }
                        Button {
                            togglePlay()
                        } label: {
                            Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
                        }
                        .padding(.top, 4)
                        .disabled(!FileManager.default.fileExists(atPath: url.path))
                    }
                }
            }
            let details = [info?.durationText,
                           (info?.width ?? 0) > 0 ? "\(info!.width) × \(info!.height)" : nil].compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            MediaSupport.info(for: url) { info = $0 }
            MediaSupport.thumbnail(for: url, pixels: 400) { cover = $0 }
            if kind == .video { player = AVPlayer(url: url) }
        }
        .onDisappear {
            player?.pause()
            player = nil
            playing = false
        }
    }

    private var aspect: CGFloat {
        guard let i = info, i.width > 0, i.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(i.width) / CGFloat(i.height)
    }

    private func togglePlay() {
        if player == nil { player = AVPlayer(url: url) }
        if playing { player?.pause() } else { player?.play() }
        playing.toggle()
    }
}

enum ColorFormats {
    static func all(_ c: NSColor) -> [String] {
        guard let s = c.usingColorSpace(.sRGB) else { return [] }
        let r = Int((s.redComponent * 255).rounded()), g = Int((s.greenComponent * 255).rounded()), b = Int((s.blueComponent * 255).rounded())
        let a = s.alphaComponent
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0
        s.getHue(&hue, saturation: &sat, brightness: &bri, alpha: nil)
        // HSL from HSB
        let l = bri * (1 - sat / 2)
        let sl = (l == 0 || l == 1) ? 0 : (bri - l) / min(l, 1 - l)
        let rgb = a < 1 ? "rgba(\(r), \(g), \(b), \(String(format: "%.2f", a)))" : "rgb(\(r), \(g), \(b))"
        let hsl = "hsl(\(Int((hue * 360).rounded())), \(Int((sl * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        let swift = String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", s.redComponent, s.greenComponent, s.blueComponent)
        return [rgb, hsl, swift]
    }
}

// MARK: - Syntax highlighting (lightweight, language-agnostic)

enum CodeHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "class", "struct", "enum", "protocol",
        "extension", "guard", "switch", "case", "default", "break", "continue", "in", "true", "false", "nil", "null",
        "self", "this", "def", "elif", "lambda", "from", "as", "try", "catch", "throw", "throws", "async", "await",
        "const", "function", "new", "public", "private", "static", "final", "override", "void", "int", "string",
        "bool", "package", "interface", "type", "fn", "impl", "pub", "mut", "match", "where", "do", "yield",
        "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "JOIN", "ON", "AND", "OR", "NOT", "None", "True", "False",
    ]

    private static let stringRegex = try! NSRegularExpression(pattern: #""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`[^`]*`"#)
    private static let commentRegex = try! NSRegularExpression(pattern: #"//[^\n]*|/\*[\s\S]*?\*/|(?m)^\s*#(?!include|!)[^\n]*"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#)
    private static let wordRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)

    static func highlight(_ code: String) -> AttributedString {
        let ns = NSMutableAttributedString(string: code, attributes: [.foregroundColor: NSColor.labelColor])
        let full = NSRange(location: 0, length: (code as NSString).length)
        var protected = IndexSet()

        func paint(_ regex: NSRegularExpression, _ color: NSColor, protect: Bool) {
            for m in regex.matches(in: code, range: full) {
                let r = m.range
                if protected.intersects(integersIn: r.location..<(r.location + r.length)) { continue }
                ns.addAttribute(.foregroundColor, value: color, range: r)
                if protect { protected.insert(integersIn: r.location..<(r.location + r.length)) }
            }
        }

        paint(commentRegex, .secondaryLabelColor, protect: true)
        paint(stringRegex, .systemRed, protect: true)
        for m in wordRegex.matches(in: code, range: full) {
            let r = m.range
            if protected.intersects(integersIn: r.location..<(r.location + r.length)) { continue }
            let word = (code as NSString).substring(with: r)
            if keywords.contains(word) {
                ns.addAttribute(.foregroundColor, value: NSColor.systemPink, range: r)
            } else if let first = word.first, first.isUppercase {
                ns.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: r)
            }
        }
        paint(numberRegex, .systemPurple, protect: false)
        return (try? AttributedString(ns, including: \.appKit)) ?? AttributedString(code)
    }
}

// MARK: - Edit overlay

struct EditOverlay: View {
    @ObservedObject var state: PanelState

    var body: some View {
        let item = state.editingItem
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
                .onTapGesture { state.cancelEdit() }
            VStack(alignment: .leading, spacing: 12) {
                Text(item?.type.isTextual == true ? "Edit Clip" : "Rename Clip").font(.headline)
                TextField("Title (optional, searchable)", text: $state.editTitle)
                    .textFieldStyle(.roundedBorder)
                if item?.type.isTextual == true {
                    TextEditor(text: $state.editText)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                        .frame(minHeight: 180, maxHeight: .infinity)
                }
                HStack {
                    Text("⌘↩ save · esc cancel").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { state.cancelEdit() }
                    if item?.type.isTextual == true {
                        Button("Save as New") { state.saveEditAsNew() }
                            .help("Keep the original and add the edited text as a new clip")
                        Button("Save & Copy") { state.commitEditAndCopy() }
                            .help("Save, then put the edited text on the clipboard")
                    }
                    Button("Save") { state.commitEdit() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(maxWidth: 520)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
            .shadow(radius: 20)
            .padding(14)
        }
    }
}

/// An image loaded off the main thread (rows and the preview). Shows the cached image right away
/// when there is one; otherwise a neutral placeholder of the same size until it has loaded, and
/// `fallback` if the image can't be read.
struct AsyncThumbnail<Fallback: View>: View {
    let images: ImageStore
    let name: String?
    let file: URL?
    let maxPixel: Int
    var contentMode: ContentMode = .fill
    /// Width ÷ height of the image, so the placeholder reserves the right space (no layout jump).
    var aspect: CGFloat? = nil
    @ViewBuilder var fallback: () -> Fallback
    @State private var loaded: NSImage?
    @State private var failed = false

    var body: some View {
        let image = loaded ?? images.cachedThumbnail(name: name, file: file, maxPixel: maxPixel)
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else if failed {
                fallback()
            } else if let aspect {
                Rectangle().fill(Color.primary.opacity(0.06)).aspectRatio(aspect, contentMode: .fit)
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
            }
        }
        .task(id: "\(name ?? "")|\(file?.path ?? "")|\(maxPixel)") {
            guard images.cachedThumbnail(name: name, file: file, maxPixel: maxPixel) == nil else { return }
            let img = await images.loadThumbnail(name: name, file: file, maxPixel: maxPixel)
            if let img { loaded = img } else { failed = true }
        }
    }
}

/// File icons for the UI, without touching the disk on the calling thread. The existence check and the
/// real icon are looked up on a serial background queue and remembered (refreshed after 30 s); until
/// then the generic icon for the file's type (from its extension) is shown.
enum FileIcons {
    private struct Facts { let exists: Bool; let icon: NSImage?; let at: Date }
    private static var cache: [String: Facts] = [:]
    private static var pending: Set<String> = []
    private static let lock = NSLock()

    /// The file's icon, or nil once it's known that the file no longer exists.
    static func icon(forExistingFile path: String) -> NSImage? {
        guard let facts = lookup(path) else { return genericIcon(path) }
        return facts.exists ? (facts.icon ?? genericIcon(path)) : nil
    }

    /// The file's icon (generic icon for its type while unknown or if the file is gone).
    static func icon(forFile path: String) -> NSImage {
        lookup(path)?.icon ?? genericIcon(path)
    }

    private static func lookup(_ path: String) -> Facts? {
        let now = Date()
        lock.lock()
        let hit = cache[path]
        let stale = hit.map { now.timeIntervalSince($0.at) >= 30 } ?? true
        let start = stale && !pending.contains(path)
        if start { pending.insert(path) }
        lock.unlock()
        if start {
            ImageFileLoader.factsQueue.async {
                let exists = FileManager.default.fileExists(atPath: path)
                let icon = exists ? NSWorkspace.shared.icon(forFile: path) : nil
                lock.lock()
                if cache.count > 1000 { cache.removeAll() }
                cache[path] = Facts(exists: exists, icon: icon, at: Date()); pending.remove(path)
                lock.unlock()
            }
        }
        return hit
    }

    private static func genericIcon(_ path: String) -> NSImage {
        NSWorkspace.shared.icon(for: UTType(filenameExtension: (path as NSString).pathExtension) ?? .data)
    }
}

import AppKit
import ImageIO
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Marker added to every pasteboard write made by Pastly (secondary self-capture guard).
    static let pastlyInternal = NSPasteboard.PasteboardType("io.github.sp201004.pastly.internal")
}

/// Raw pasteboard contents, read on the main thread.
/// Raw pasteboard contents, read on the main thread. Every available representation is looked at:
/// file URLs (Finder), text/rich text, and image data in its original format.
struct RawClip {
    var types: Set<String>
    var string: String?
    var rtf: Data?
    var html: Data?
    var imageData: Data?
    var imageType: String?          // UTI of `imageData`, e.g. public.jpeg
    var fileURLs: [URL] = []

    static let maxRichBytes = 2_000_000
    static let maxImageBytes = 50_000_000

    /// Image representations in order of preference: original formats before TIFF (often a conversion).
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier), NSPasteboard.PasteboardType(UTType.webP.identifier), .tiff,
    ]

    static func read(from pb: NSPasteboard, types: Set<String>) -> RawClip {
        var fileURLs = (pb.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if fileURLs.isEmpty,   // legacy NSFilenamesPboardType list
           let paths = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            fileURLs = paths.map { URL(fileURLWithPath: $0) }
        }
        let string = pb.string(forType: .string)
        var clip = RawClip(types: types, string: string, fileURLs: fileURLs)
        guard fileURLs.isEmpty else { return clip }   // Finder: the file is the content (its icon TIFF is not)

        if let s = string, !s.isEmpty {
            if let rtf = pb.data(forType: .rtf), rtf.count <= maxRichBytes { clip.rtf = rtf }
            if let html = pb.data(forType: .html), html.count <= maxRichBytes { clip.html = html }
        }
        for t in imageTypes where types.contains(t.rawValue) {
            if let d = pb.data(forType: t), !d.isEmpty, d.count <= maxImageBytes {
                clip.imageData = d
                clip.imageType = t == .tiff ? UTType.tiff.identifier : (t == .png ? UTType.png.identifier : t.rawValue)
                break
            }
        }
        return clip
    }
}

struct ParsedClip {
    var type: ClipType
    var primaryUTI: String
    var plainText: String?
    var rtf: Data?
    var html: Data?
    /// Image bytes to store (original format where possible; see `imageExtension`).
    var pngData: Data?
    var imageExtension = "png"
    var imageWidth = 0
    var imageHeight = 0
    var fileURLs: [URL] = []
    var colorHex: String?
    var contentHash: String
    /// Name to show for a new clip, e.g. the macOS name of a screenshot ("Screenshot 2026-11-19 at 2.42.59 PM").
    var suggestedTitle: String? = nil
}

/// Loads image files (e.g. copied in Finder) safely: checks the real content type, keeps the
/// original bytes and quality, and makes a reduced copy only for very large files.
enum ImageFileLoader {
    struct Loaded { let data: Data; let ext: String; let width: Int; let height: Int }

    /// File type, read from the file system now. Used by capture and background work, which must see
    /// the file as it is (never a remembered answer).
    static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
    }

    // MARK: Display lookups (UI only — never touch the disk on the calling thread)
    //
    // Rows ask on every redraw. On a network share, an unplugged drive or an iCloud placeholder a single
    // file-system lookup can block for seconds, so the UI gets the remembered type (refreshed in the
    // background after 60 s) or — the very first time — the type implied by the file extension while the
    // real type is looked up on a serial background queue.

    static let factsQueue = DispatchQueue(label: "Pastly.fileFacts", qos: .utility)
    private static var typeCache: [String: (type: UTType?, at: Date)] = [:]
    private static var typePending: Set<String> = []
    private static let typeLock = NSLock()

    static func displayContentType(of url: URL) -> UTType? {
        let key = url.path, now = Date()
        typeLock.lock()
        let hit = typeCache[key]
        let stale = hit.map { now.timeIntervalSince($0.at) >= 60 } ?? true
        let start = stale && !typePending.contains(key)
        if start { typePending.insert(key) }
        typeLock.unlock()
        if start {
            factsQueue.async {
                let t = contentType(of: url)
                typeLock.lock()
                if typeCache.count > 2000 { typeCache.removeAll() }
                typeCache[key] = (t, Date()); typePending.remove(key)
                typeLock.unlock()
            }
        }
        if let hit { return hit.type }                 // remembered (possibly being refreshed)
        return UTType(filenameExtension: url.pathExtension)   // first time: from the extension, no disk access
    }

    static func displayIsImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, let t = displayContentType(of: url) else { return false }
        return t.conforms(to: .image) && !t.conforms(to: .pdf)
    }

    /// True for real images (PNG, JPEG, HEIC, TIFF, GIF, WebP…). PDFs and documents are not images.
    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, let t = contentType(of: url) else { return false }
        return t.conforms(to: .image) && !t.conforms(to: .pdf)
    }

    static func load(_ url: URL, maxBytes: Int = RawClip.maxImageBytes) -> Loaded? {
        guard isImageFile(url), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let (w, h) = pixelSize(src)
        guard w > 0, h > 0 else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 0, size <= maxBytes, let data = try? Data(contentsOf: url) {
            let ext = url.pathExtension.isEmpty ? (contentType(of: url)?.preferredFilenameExtension ?? "img") : url.pathExtension.lowercased()
            return Loaded(data: data, ext: ext, width: w, height: h)
        }
        // Very large: keep a high-quality 2048 px PNG instead of the whole file.
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 2048,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        return Loaded(data: png, ext: "png", width: w, height: h)
    }

    /// Pixel size as displayed (EXIF rotation applied).
    static func pixelSize(_ src: CGImageSource) -> (Int, Int) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (h, w) : (w, h)
    }
}

enum ClipItemParser {
    static func parse(_ raw: RawClip, trimWhitespace: Bool) -> ParsedClip? {
        if !raw.fileURLs.isEmpty {
            var p = ParsedClip(type: .file, primaryUTI: "public.file-url",
                               fileURLs: raw.fileURLs, contentHash: ContentHasher.fileHash(raw.fileURLs))
            // A copied image file (Finder): keep the real image for the thumbnail, preview and pasting.
            if let url = raw.fileURLs.first(where: ImageFileLoader.isImageFile), let img = ImageFileLoader.load(url) {
                p.pngData = img.data
                p.imageExtension = img.ext
                p.imageWidth = img.width
                p.imageHeight = img.height
            }
            return p
        }
        if let s = raw.string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let data = raw.imageData, prefersImage(over: s, rtf: raw.rtf, html: raw.html),
               let image = parseImage(data, type: raw.imageType) {
                return image
            }
            return parseText(s, rtf: raw.rtf, html: raw.html, trimWhitespace: trimWhitespace)
        }
        if let data = raw.imageData {
            return parseImage(data, type: raw.imageType)
        }
        return nil
    }

    static func parseText(_ s: String, rtf: Data?, html: Data?, trimWhitespace: Bool) -> ParsedClip {
        if let hex = ColorParser.parse(s) {
            return ParsedClip(type: .color, primaryUTI: ClipType.color.canonicalUTI,
                              plainText: s.trimmingCharacters(in: .whitespacesAndNewlines),
                              colorHex: hex, contentHash: ContentHasher.colorHash(hex))
        }
        if isURL(s) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedClip(type: .url, primaryUTI: "public.url", plainText: t,
                              contentHash: ContentHasher.urlHash(t))
        }
        let uti = rtf != nil ? "public.rtf" : (html != nil ? "public.html" : "public.utf8-plain-text")
        return ParsedClip(type: .text, primaryUTI: uti, plainText: s, rtf: rtf, html: html,
                          contentHash: ContentHasher.textHash(s, trimWhitespace: trimWhitespace))
    }

    static func isURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 4000, !t.contains(where: { $0.isWhitespace }),
              let u = URL(string: t), let scheme = u.scheme?.lowercased() else { return false }
        if scheme == "mailto" { return t.count > 7 }
        return ["http", "https", "ftp"].contains(scheme) && (u.host?.isEmpty == false)
    }

    /// Text that is only the image's address (Safari/Chrome "Copy Image") or HTML that only wraps
    /// an <img> shouldn't hide the image. Real documents with formatted text stay text.
    static func prefersImage(over text: String, rtf: Data?, html: Data?) -> Bool {
        guard rtf == nil else { return false }
        if isURL(text) { return true }
        if let html, let h = String(data: html, encoding: .utf8), h.range(of: "<img", options: .caseInsensitive) != nil {
            let visible = h.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return visible.isEmpty
        }
        return false
    }

    static func parseImage(_ data: Data, isPNG: Bool) -> ParsedClip? {
        parseImage(data, type: isPNG ? UTType.png.identifier : UTType.tiff.identifier)
    }

    /// Direct image data. PNG, JPEG, HEIC, GIF and WebP are kept as they are (original quality and
    /// metadata); TIFF, usually a conversion, is stored as PNG.
    static func parseImage(_ data: Data, type: String?) -> ParsedClip? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let hash = ContentHasher.imageHash(cg)
        let (w, h) = ImageFileLoader.pixelSize(src)
        let uti = UTType(type ?? "") ?? .tiff
        let keepOriginal: [UTType] = [.png, .jpeg, .heic, .gif, .webP]
        let bytes: Data
        let ext: String
        if keepOriginal.contains(uti) {
            bytes = data
            ext = uti.preferredFilenameExtension ?? "png"
        } else {
            guard let encoded = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
            bytes = encoded
            ext = "png"
        }
        var clip = ParsedClip(type: .image, primaryUTI: uti.identifier, pngData: bytes, imageExtension: ext,
                              imageWidth: w > 0 ? w : cg.width, imageHeight: h > 0 ? h : cg.height, contentHash: hash)
        if isMacScreenshot(src) { clip.suggestedTitle = screenshotName(for: Date()) }
        return clip
    }

    /// macOS marks its screenshots (⇧⌘3, ⇧⌘4, ⇧⌘5 — also when they go to the clipboard) with the EXIF
    /// comment "Screenshot". Other copied images don't carry it.
    static func isMacScreenshot(_ src: CGImageSource) -> Bool {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let exif = props?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        return (exif?[kCGImagePropertyExifUserComment] as? String) == "Screenshot"
    }

    /// The name macOS gives a screenshot taken at `date`, e.g. "Screenshot 2026-11-19 at 2.42.59 PM"
    /// (the time in the Mac's own 12- or 24-hour format, with dots instead of colons, like Finder shows it).
    static func screenshotName(for date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian); day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = locale
        time.dateFormat = DateFormatter.dateFormat(fromTemplate: "jms", options: 0, locale: locale) ?? "HH:mm:ss"
        return "Screenshot \(day.string(from: date)) at \(time.string(from: date).replacingOccurrences(of: ":", with: "."))"
    }
}

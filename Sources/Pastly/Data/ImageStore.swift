import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Stores captured images on disk (original format); the database only keeps the filename.
/// Safe to use from the thumbnail queue: its state is an immutable folder URL and thread-safe NSCaches.
final class ImageStore: @unchecked Sendable {
    let directory: URL
    // Caches are bounded by decoded size, not just by count: one 1600-px preview is ~8 MB and a
    // full 4000×3000 image ~48 MB, so a count limit alone could hold gigabytes.
    private let thumbCache = NSCache<NSString, NSImage>()     // row thumbnails (≤ 160 px)
    private let previewCache = NSCache<NSString, NSImage>()   // preview images (≤ 1600 px)
    private let fullCache = NSCache<NSString, NSImage>()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fullCache.countLimit = 4
        fullCache.totalCostLimit = 150 * 1024 * 1024
        thumbCache.countLimit = 1000
        thumbCache.totalCostLimit = 64 * 1024 * 1024
        previewCache.countLimit = 12
        previewCache.totalCostLimit = 96 * 1024 * 1024
    }

    private func cache(for maxPixel: Int) -> NSCache<NSString, NSImage> { maxPixel > 400 ? previewCache : thumbCache }

    /// Decoded size of an image, used as its cache cost.
    private static func cost(_ img: NSImage) -> Int {
        if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg.bytesPerRow * cg.height }
        return Int(img.size.width * img.size.height * 4)
    }

    func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    @discardableResult
    func save(_ data: Data, name: String) -> Bool {
        // Names are content hashes: an existing file already holds these exact bytes
        // (capture writes it ahead of time on its background queue).
        if FileManager.default.fileExists(atPath: url(for: name).path) { return true }
        return (try? data.write(to: url(for: name), options: .atomic)) != nil
    }

    func data(for name: String) -> Data? { try? Data(contentsOf: url(for: name)) }

    func image(for name: String) -> NSImage? {
        if let cached = fullCache.object(forKey: name as NSString) { return cached }
        guard let img = NSImage(contentsOf: url(for: name)) else { return nil }
        fullCache.setObject(img, forKey: name as NSString, cost: Self.cost(img))
        return img
    }

    func thumbnail(for name: String, maxPixel: Int = 160) -> NSImage? {
        let key = "\(name)-\(maxPixel)" as NSString
        if let cached = cache(for: maxPixel).object(forKey: key) { return cached }
        guard let src = CGImageSourceCreateWithURL(url(for: name) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache(for: maxPixel).setObject(img, forKey: key, cost: Self.cost(img))
        return img
    }

    /// Pasteboard/drag type of a stored image, from its file extension (png, jpeg, heic, gif, webp…).
    func uti(for name: String) -> UTType {
        UTType(filenameExtension: (name as NSString).pathExtension) ?? .png
    }

    /// Thumbnail straight from an image file on disk (e.g. an older Finder clip), cached by path and date.
    func thumbnail(forFile url: URL, maxPixel: Int = 160) -> NSImage? {
        guard ImageFileLoader.isImageFile(url) else { return nil }
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "file:\(url.path)#\(mod)-\(maxPixel)" as NSString
        if let cached = cache(for: maxPixel).object(forKey: key) { return cached }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache(for: maxPixel).setObject(img, forKey: key, cost: Self.cost(img))
        return img
    }

    // MARK: Off-main-thread loading (rows and the preview)
    //
    // Making a thumbnail decodes the whole image (≈60 ms for a 4000×3000 PNG). Doing that while a row
    // scrolls into view stalls the UI, so views ask for a cached image first and load the rest here.

    private static let loadQueue = DispatchQueue(label: "Pastly.thumbnails", qos: .userInitiated, attributes: .concurrent)

    /// Cache-only lookup (no disk access) for a stored image or an image file.
    func cachedThumbnail(name: String?, file: URL?, maxPixel: Int) -> NSImage? {
        if let name, let img = cache(for: maxPixel).object(forKey: "\(name)-\(maxPixel)" as NSString) { return img }
        if let file, let img = cache(for: maxPixel).object(forKey: "fileq:\(file.path)-\(maxPixel)" as NSString) { return img }
        return nil
    }

    /// Loads (and caches) a thumbnail on a background queue; the stored copy is preferred over the file.
    func loadThumbnail(name: String?, file: URL?, maxPixel: Int) async -> NSImage? {
        if let hit = cachedThumbnail(name: name, file: file, maxPixel: maxPixel) { return hit }
        return await withCheckedContinuation { cont in
            Self.loadQueue.async {
                var img = name.flatMap { self.thumbnail(for: $0, maxPixel: maxPixel) }
                if img == nil, let file {
                    img = self.thumbnail(forFile: file, maxPixel: maxPixel)
                    if let img { self.cache(for: maxPixel).setObject(img, forKey: "fileq:\(file.path)-\(maxPixel)" as NSString, cost: Self.cost(img)) }
                }
                cont.resume(returning: img)
            }
        }
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
        fullCache.removeObject(forKey: name as NSString)
        for px in [160, 1600] { cache(for: px).removeObject(forKey: "\(name)-\(px)" as NSString) }
    }
}

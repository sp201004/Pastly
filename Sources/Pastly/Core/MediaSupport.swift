import AppKit
import AVFoundation
import QuickLookThumbnailing

/// Videos and music copied as files (e.g. ⌘C in Finder). They stay file clips — pasting gives the
/// file — but get a real thumbnail (poster frame / cover art) and details for the row and preview.
enum MediaSupport {
    enum Kind { case video, audio }

    struct Info {
        var kind: Kind
        var duration: Double?           // seconds
        var width = 0, height = 0       // video
        var title: String?
        var artist: String?
        var album: String?
        var artwork: NSImage?

        var durationText: String? {
            guard let d = duration, d.isFinite, d > 0 else { return nil }
            let s = Int(d.rounded())
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                             : String(format: "%d:%02d", s / 60, s % 60)
        }
    }

    static func kind(of url: URL) -> Kind? {
        // UI-safe lookup (no disk access on the calling thread); used for rows, the preview and media info.
        guard url.isFileURL, let t = ImageFileLoader.displayContentType(of: url) else { return nil }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        return nil
    }

    // MARK: Thumbnails (Quick Look: video poster frame, music cover art), cached

    private static let thumbs = NSCache<NSString, NSImage>()

    private static func key(_ url: URL, _ px: Int) -> NSString {
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.path)#\(mod)#\(px)" as NSString
    }

    static func cachedThumbnail(for url: URL, pixels: Int) -> NSImage? { thumbs.object(forKey: key(url, pixels)) }

    /// Calls back on the main thread; nil when there's nothing to show (e.g. music without cover art).
    static func thumbnail(for url: URL, pixels: Int, completion: @escaping (NSImage?) -> Void) {
        let k = key(url, pixels)
        if let hit = thumbs.object(forKey: k) { completion(hit); return }
        guard FileManager.default.fileExists(atPath: url.path) else { completion(nil); return }
        let size = CGSize(width: pixels, height: pixels)
        let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            if let img = rep?.nsImage {
                thumbs.setObject(img, forKey: k)
                DispatchQueue.main.async { completion(img) }
                return
            }
            // Fallback: video frame or embedded artwork via AVFoundation.
            Task {
                let info = await loadInfo(url)
                var img = info?.artwork
                if img == nil, info?.kind == .video { img = await posterFrame(url, maxPixels: pixels * 2) }
                let result = img
                if let result { thumbs.setObject(result, forKey: k) }
                await MainActor.run { completion(result) }
            }
        }
    }

    private static func posterFrame(_ url: URL, maxPixels: Int) async -> NSImage? {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        guard let (cg, _) = try? await gen.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Details (duration, resolution, title / artist / album, artwork)

    private static let infos = NSCache<NSString, InfoBox>()
    private final class InfoBox { let info: Info; init(_ i: Info) { info = i } }

    static func cachedInfo(for url: URL) -> Info? { infos.object(forKey: key(url, 0))?.info }

    static func info(for url: URL, completion: @escaping (Info?) -> Void) {
        if let hit = cachedInfo(for: url) { completion(hit); return }
        Task {
            let i = await loadInfo(url)
            if let i { infos.setObject(InfoBox(i), forKey: key(url, 0)) }
            await MainActor.run { completion(i) }
        }
    }

    static func loadInfo(_ url: URL) async -> Info? {
        guard let kind = kind(of: url), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        var info = Info(kind: kind)
        if let d = try? await asset.load(.duration) { info.duration = d.seconds }
        if kind == .video, let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(transform)
            info.width = Int(abs(r.width).rounded()); info.height = Int(abs(r.height).rounded())
        }
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle: info.title = try? await item.load(.stringValue)
                case .commonKeyArtist: info.artist = try? await item.load(.stringValue)
                case .commonKeyAlbumName: info.album = try? await item.load(.stringValue)
                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) { info.artwork = NSImage(data: data) }
                default: break
                }
            }
        }
        return info
    }
}

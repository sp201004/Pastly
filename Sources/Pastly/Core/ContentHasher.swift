import AppKit
import CryptoKit

/// contentHash = SHA256(canonicalUTI + "\0" + normalizedContentBytes)
enum ContentHasher {
    static func hash(uti: String, bytes: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(uti.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: bytes)
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Text

    static func normalizeText(_ s: String, trimWhitespace: Bool) -> String {
        var t = s.precomposedStringWithCanonicalMapping
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if trimWhitespace { t = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        return t
    }

    static func textHash(_ s: String, trimWhitespace: Bool) -> String {
        hash(uti: ClipType.text.canonicalUTI, bytes: Data(normalizeText(s, trimWhitespace: trimWhitespace).utf8))
    }

    // MARK: URL

    static func normalizeURL(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed) else { return trimmed }
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if c.path == "/" && c.query == nil && c.fragment == nil { c.path = "" }
        return c.string ?? trimmed
    }

    static func urlHash(_ s: String) -> String {
        hash(uti: ClipType.url.canonicalUTI, bytes: Data(normalizeURL(s).utf8))
    }

    // MARK: Color

    static func colorHash(_ canonicalHex: String) -> String {
        hash(uti: ClipType.color.canonicalUTI, bytes: Data(canonicalHex.uppercased().utf8))
    }

    // MARK: Files

    static func fileHash(_ urls: [URL]) -> String {
        let joined = urls.map { $0.standardizedFileURL.path }.sorted().joined(separator: "\n")
        return hash(uti: ClipType.file.canonicalUTI, bytes: Data(joined.utf8))
    }

    // MARK: Image (pixel data, format-independent)

    static func imageHash(_ image: CGImage) -> String {
        let w = image.width, h = image.height
        let uti = ClipType.image.canonicalUTI
        guard w > 0, h > 0, w * h <= 60_000_000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            // Fallback for huge/odd images: hash the raw provider bytes.
            let raw = (image.dataProvider?.data as Data?) ?? Data()
            return hash(uti: uti, bytes: raw)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let ptr = ctx.data else { return hash(uti: uti, bytes: Data()) }

        var hasher = SHA256()
        hasher.update(data: Data(uti.utf8))
        hasher.update(data: Data([0]))
        let dims = [UInt32(w).littleEndian, UInt32(h).littleEndian]
        dims.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: ptr, count: w * h * 4))
        return hex(hasher.finalize())
    }
}

/// Detects HEX / rgb() colors and converts them to canonical uppercase "#RRGGBB" or "#RRGGBBAA".
enum ColorParser {
    private static let rgbRegex = try! NSRegularExpression(
        pattern: #"^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*(?:,\s*([0-9]*\.?[0-9]+%?)\s*)?\)$"#,
        options: [.caseInsensitive])

    static func parse(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 40 else { return nil }

        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            switch hex.count {
            case 3, 4: return dropOpaqueAlpha("#" + hex.map { "\($0)\($0)" }.joined().uppercased())
            case 6, 8: return dropOpaqueAlpha("#" + hex.uppercased())
            default: return nil
            }
        }

        let range = NSRange(s.startIndex..., in: s)
        guard let m = rgbRegex.firstMatch(in: s, range: range) else { return nil }
        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return String(s[r])
        }
        guard let r = group(1).flatMap(Int.init), let g = group(2).flatMap(Int.init), let b = group(3).flatMap(Int.init),
              (0...255).contains(r), (0...255).contains(g), (0...255).contains(b) else { return nil }
        var out = String(format: "#%02X%02X%02X", r, g, b)
        if let aStr = group(4) {
            let a: Double
            if aStr.hasSuffix("%") { a = (Double(aStr.dropLast()) ?? 100) / 100 } else { a = Double(aStr) ?? 1 }
            guard (0...1).contains(a) else { return nil }
            out += String(format: "%02X", Int((a * 255).rounded()))
        }
        return dropOpaqueAlpha(out)
    }

    private static let embeddedHex = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z&#])#(?:[0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3,4})(?![0-9A-Za-z])"#)

    /// Every HEX color written inside a piece of text (#FFF, #FFFF, #FFFFFF, #FFFFFFFF),
    /// canonical and de-duplicated in the order they appear. Capped at 24.
    static func findAll(in text: String) -> [String] {
        let sample = String(text.prefix(50_000))
        var seen = Set<String>(), out: [String] = []
        for m in embeddedHex.matches(in: sample, range: NSRange(sample.startIndex..., in: sample)) {
            guard let r = Range(m.range, in: sample), let hex = parse(String(sample[r])), seen.insert(hex).inserted else { continue }
            out.append(hex)
            if out.count == 24 { break }
        }
        return out
    }

    private static func dropOpaqueAlpha(_ hex: String) -> String {
        hex.count == 9 && hex.hasSuffix("FF") ? String(hex.prefix(7)) : hex
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 6 {
            r = CGFloat((v >> 16) & 0xFF) / 255; g = CGFloat((v >> 8) & 0xFF) / 255; b = CGFloat(v & 0xFF) / 255; a = 1
        } else {
            r = CGFloat((v >> 24) & 0xFF) / 255; g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255; a = CGFloat(v & 0xFF) / 255
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

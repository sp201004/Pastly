// Generates the macOS app icon from the Pastly logo (Resources/AppIcon.svg), unchanged.
// Usage: swift Scripts/make_icon.swift <output.iconset> [svg]
//        iconutil -c icns <output.iconset> -o Resources/AppIcon.icns
// Also: swift Scripts/make_icon.swift --png <size> <out.png> [svg]   (single PNG, e.g. website favicons)
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
var singlePNG: (Int, URL)?
if args.first == "--png", args.count >= 3, let px = Int(args[1]) {
    singlePNG = (px, URL(fileURLWithPath: args[2])); args.removeFirst(3)
}
let svgPath = singlePNG == nil ? (args.count > 1 ? args[1] : "Resources/AppIcon.svg") : (args.first ?? "Resources/AppIcon.svg")
guard let logo = NSImage(contentsOf: URL(fileURLWithPath: svgPath)) else {
    FileHandle.standardError.write("Can't read the logo at \(svgPath)\n".data(using: .utf8)!); exit(1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    // The SVG is drawn as vector artwork at the exact pixel size — no resampling, no changes.
    logo.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if let (px, url) = singlePNG {
    try! render(px).write(to: url); exit(0)
}
let out = URL(fileURLWithPath: args[0])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try! render(px).write(to: out.appendingPathComponent("\(name).png"))
}

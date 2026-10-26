// Prepares the user's own Synco artwork for the app, without redrawing it:
//   - the app icon: the white outside the rounded square becomes transparent;
//   - the white mark and wordmark from the negative version: black becomes transparent.
//   swift extract.swift   (reads originales/, writes next to this file)
import AppKit

struct Pixels {
    var w: Int, h: Int, data: [UInt8]   // RGBA, row-major, y down
    init(_ path: String) {
        let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))!
        w = rep.pixelsWide; h = rep.pixelsHigh
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
        data = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }
    init(w: Int, h: Int) { self.w = w; self.h = h; data = [UInt8](repeating: 0, count: w * h * 4) }
    func px(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        let i = (y * w + x) * 4; return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
    mutating func set(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int, _ a: Int) {
        // stored premultiplied
        let i = (y * w + x) * 4
        data[i] = UInt8(r * a / 255); data[i + 1] = UInt8(g * a / 255); data[i + 2] = UInt8(b * a / 255); data[i + 3] = UInt8(a)
    }
    func save(_ path: String, size: Int? = nil) {
        var copy = data
        let ctx = CGContext(data: &copy, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var image = ctx.makeImage()!
        if let size {
            let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            out.interpolationQuality = .high
            out.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            image = out.makeImage()!
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }
}

// 1. App icon: flood the near-white outside from the corners; the rounded square stops it.
var icon = Pixels("originales/icono-app.png")
func whiteness(_ p: (Int, Int, Int, Int)) -> Int { min(p.0, p.1, p.2) }
var outside = [Bool](repeating: false, count: icon.w * icon.h)
var stack = [(0, 0), (icon.w - 1, 0), (0, icon.h - 1), (icon.w - 1, icon.h - 1)]
while let (x, y) = stack.popLast() {
    guard x >= 0, y >= 0, x < icon.w, y < icon.h, !outside[y * icon.w + x] else { continue }
    let p = icon.px(x, y)
    // The tile is off-white (warm); the backdrop is pure white and neutral.
    guard whiteness(p) >= 248, abs(p.0 - p.2) <= 4 else { continue }
    outside[y * icon.w + x] = true
    stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
}
for y in 0..<icon.h { for x in 0..<icon.w where outside[y * icon.w + x] {
    let p = icon.px(x, y); icon.set(x, y, p.0, p.1, p.2, 0)
} }
// Soften the cut: pixels next to the outside fade by how white they are.
for y in 1..<(icon.h - 1) { for x in 1..<(icon.w - 1) where !outside[y * icon.w + x] {
    let n = outside[y * icon.w + x - 1] || outside[y * icon.w + x + 1] || outside[(y - 1) * icon.w + x] || outside[(y + 1) * icon.w + x]
    if n { let p = icon.px(x, y); icon.set(x, y, p.0, p.1, p.2, max(0, min(255, (255 - whiteness(p)) * 8))) }
} }
icon.save("icon-1024.png")
let set = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    icon.save("\(set)/icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png", size: base * scale)
}

// 2. White on black (right half of the positive/negative sheet): brightness becomes opacity.
let sheet = Pixels("originales/positivo-negativo.png")
func cutWhite(x0: Int, y0: Int, x1: Int, y1: Int, name: String) {
    var minX = x1, minY = y1, maxX = x0, maxY = y0
    for y in y0..<y1 { for x in x0..<x1 where sheet.px(x, y).0 > 128 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    let pad = 4
    var out = Pixels(w: maxX - minX + 1 + 2 * pad, h: maxY - minY + 1 + 2 * pad)
    for y in minY...maxY { for x in minX...maxX {
        let p = sheet.px(x, y); let lum = (p.0 * 3 + p.1 * 6 + p.2) / 10
        out.set(x - minX + pad, y - minY + pad, 255, 255, 255, lum)
    } }
    out.save("\(name).png")
    print(name, out.w, "x", out.h)
}
// 3. Black on white (left half): darkness becomes opacity, in the brand charcoal, for light pages.
func cutBlack(x0: Int, y0: Int, x1: Int, y1: Int, name: String) {
    var minX = x1, minY = y1, maxX = x0, maxY = y0
    for y in y0..<y1 { for x in x0..<x1 where sheet.px(x, y).0 < 128 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    let pad = 4
    var out = Pixels(w: maxX - minX + 1 + 2 * pad, h: maxY - minY + 1 + 2 * pad)
    for y in minY...maxY { for x in minX...maxX {
        let p = sheet.px(x, y); let lum = (p.0 * 3 + p.1 * 6 + p.2) / 10
        out.set(x - minX + pad, y - minY + pad, 0x3A, 0x3A, 0x3A, 255 - lum)
    } }
    out.save("\(name).png")
    print(name, out.w, "x", out.h)
}
cutBlack(x0: 70, y0: 520, x1: 660, y1: 680, name: "wordmark-dark")
cutWhite(x0: 760, y0: 120, x1: 1340, y1: 520, name: "mark-white")
cutWhite(x0: 760, y0: 520, x1: 1340, y1: 680, name: "wordmark-white")
print("listo")

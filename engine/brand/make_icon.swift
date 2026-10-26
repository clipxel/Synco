import AppKit
// The app icon from the user's artwork (originales/icono-app.png): their S + SYNCO, exactly as
// drawn, on a cream tile with Apple's icon shape filling the standard 824-in-1024 grid.
// macOS 26 and later shrink any icon that is not that shape into a grey plate.
//   swift make_icon.swift   (writes icon-1024.png and AppIcon.iconset here)
let src = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: "originales/icono-app.png")))!
func px(_ x: Int, _ y: Int) -> (Int, Int, Int) { let c = src.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!; return (Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255)) }
let cream = px(300, 300)
let creamColor = NSColor(srgbRed: CGFloat(cream.0)/255, green: CGFloat(cream.1)/255, blue: CGFloat(cream.2)/255, alpha: 1)
// The artwork: everything inside the tile that is clearly not cream.
var minX = 1024, minY = 1024, maxX = 0, maxY = 0
for y in 260..<745 { for x in 270..<760 {
    let p = px(x, y); if abs(p.0-cream.0) + abs(p.1-cream.1) + abs(p.2-cream.2) > 90 { minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y) }
} }
print("cream", cream, "artwork", minX, minY, maxX, maxY)
let crop = src.cgImage!.cropping(to: CGRect(x: minX - 6, y: minY - 6, width: maxX - minX + 13, height: maxY - minY + 13))!
// Make the artwork's cream background transparent so it sits on any tile colour cleanly.
let cw = crop.width, ch = crop.height
var buf = [UInt8](repeating: 0, count: cw * ch * 4)
let cctx = CGContext(data: &buf, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
cctx.draw(crop, in: CGRect(x: 0, y: 0, width: cw, height: ch))
for i in stride(from: 0, to: buf.count, by: 4) {
    let d = abs(Int(buf[i])-cream.0) + abs(Int(buf[i+1])-cream.1) + abs(Int(buf[i+2])-cream.2)
    let a = min(255, max(0, (d - 12) * 6))
    if a < 255 { for k in 0..<3 { buf[i+k] = UInt8(Int(buf[i+k]) * a / 255) }; buf[i+3] = UInt8(a) }
}
let art = cctx.makeImage()!

func superellipse(_ r: CGRect, n: CGFloat = 5) -> NSBezierPath {
    let p = NSBezierPath(); let a = r.width/2, b = r.height/2, cx = r.midX, cy = r.midY
    for i in 0...720 { let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2/n), y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2/n)
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) } }
    p.close(); return p
}
func render(_ name: String, shape: (CGRect) -> NSBezierPath?, tile: CGRect, artScale: CGFloat) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    creamColor.setFill()
    if let s = shape(tile) { s.fill() } else { NSRect(x: 0, y: 0, width: 1024, height: 1024).fill() }
    let side = tile.width * artScale, k = side / CGFloat(max(cw, ch))
    let w = CGFloat(cw) * k, h = CGFloat(ch) * k
    NSGraphicsContext.current!.cgContext.interpolationQuality = .high
    NSGraphicsContext.current!.cgContext.draw(art, in: CGRect(x: tile.midX - w/2, y: tile.midY - h/2, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(name).png"))
}
let grid = CGRect(x: 100, y: 100, width: 824, height: 824)
render("icon-1024", shape: { superellipse($0) }, tile: grid, artScale: 0.70)
let full = NSImage(contentsOfFile: "icon-1024.png")!
try? FileManager.default.createDirectory(atPath: "AppIcon.iconset", withIntermediateDirectories: true)
for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let n = base * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    full.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "AppIcon.iconset/icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
}
print("listo")

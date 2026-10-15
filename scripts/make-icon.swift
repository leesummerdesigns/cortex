// Draws the Cortex app icon (dark squircle, flat network in the app's "Koralle" style)
// and builds Resources/AppIcon.icns.  Usage: swift scripts/make-icon.swift
import AppKit

// MARK: Design (1024 × 1024 canvas, origin top-left)

struct Node { let x, y, r: CGFloat; let color: NSColor }

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}

let cream = hex(0xF3E9DF), coral = hex(0xE5484D), taupe = hex(0xB8A397), fire = hex(0xFFC21A)
let redLine = hex(0xEB5458, 0.9), greyLine = hex(0xA0B6B4, 0.55), fireLine = hex(0xFFC21A, 0.95)

let core = Node(x: 500, y: 532, r: 96, color: cream)
let nodes: [String: Node] = [
    "core": core,
    "a": Node(x: 292, y: 352, r: 56, color: coral),
    "b": Node(x: 724, y: 330, r: 62, color: coral),
    "d": Node(x: 770, y: 690, r: 46, color: coral),
    "e": Node(x: 318, y: 728, r: 60, color: coral),
    "f": Node(x: 572, y: 806, r: 36, color: coral),
    "y": Node(x: 548, y: 232, r: 34, color: fire),     // the recalled memory
    "t1": Node(x: 196, y: 548, r: 20, color: taupe),
    "t2": Node(x: 836, y: 470, r: 18, color: taupe),
    "t3": Node(x: 420, y: 878, r: 15, color: taupe),
    "t4": Node(x: 850, y: 792, r: 14, color: taupe),
    "t5": Node(x: 214, y: 236, r: 14, color: taupe),
]
let redLinks = [("core", "a"), ("core", "b"), ("core", "d"), ("core", "e"), ("core", "f"), ("a", "e"), ("b", "d")]
let greyLinks = [("a", "t5"), ("a", "t1"), ("e", "t1"), ("e", "t3"), ("f", "t3"), ("d", "t4"), ("b", "t2"), ("d", "t2"),
                 ("f", "d"), ("a", "y"), ("e", "f"), ("t5", "y")]
let fireLinks = [("y", "core"), ("y", "b")]

// MARK: Drawing

func draw(in ctx: CGContext, size px: CGFloat) {
    let s = px / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1) // top-left origin
    let small = px < 64

    // Body with drop shadow (macOS icon grid: 824pt body, 100pt margin)
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: hex(0x000000, 0.45).cgColor)
    ctx.addPath(body); ctx.setFillColor(hex(0x1A1919).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [hex(0x4A4745).cgColor, hex(0x262524).cgColor, hex(0x101010).cgColor] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawRadialGradient(bg, startCenter: CGPoint(x: 400, y: 330), startRadius: 0, endCenter: CGPoint(x: 400, y: 330), endRadius: 820, options: .drawsAfterEndLocation)

    func line(_ a: String, _ b: String, _ color: NSColor, _ width: CGFloat) {
        let p = nodes[a]!, q = nodes[b]!
        ctx.move(to: CGPoint(x: p.x, y: p.y)); ctx.addLine(to: CGPoint(x: q.x, y: q.y))
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.strokePath()
    }
    if !small { for (a, b) in greyLinks { line(a, b, greyLine, 4) } }
    for (a, b) in redLinks { line(a, b, redLine, small ? 16 : 7) }
    for (a, b) in fireLinks { line(a, b, fireLine, small ? 16 : 9) }

    for key in ["t1", "t2", "t3", "t4", "t5", "f", "d", "a", "e", "b", "y", "core"] where !(small && key.hasPrefix("t")) {
        sphere(ctx, nodes[key]!)
    }

    if !small { labelTag(ctx) }
    ctx.restoreGState()

    // Hairline rim light along the top edge
    ctx.addPath(CGPath(roundedRect: CGRect(x: 101.5, y: 101.5, width: 821, height: 821), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(hex(0xFFFFFF, 0.08).cgColor); ctx.setLineWidth(3); ctx.strokePath()
}

/// Flat disc with a soft contact shadow (no shading, no highlight).
func sphere(_ ctx: CGContext, _ n: Node) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: n.r * 0.1, height: n.r * 0.2), blur: n.r * 0.6, color: hex(0x000000, 0.5).cgColor)
    ctx.addEllipse(in: CGRect(x: n.x - n.r, y: n.y - n.r, width: 2 * n.r, height: 2 * n.r))
    ctx.setFillColor(n.color.cgColor); ctx.fillPath()
    ctx.restoreGState()
}

func labelTag(_ ctx: CGContext) {
    let rect = CGRect(x: 618, y: 474, width: 196, height: 50)
    ctx.setFillColor(hex(0x080808, 0.94).cgColor); ctx.fill(rect)
    let font = NSFont.monospacedSystemFont(ofSize: 30, weight: .medium)
    let text = NSAttributedString(string: "CORTEX", attributes: [.font: font, .foregroundColor: hex(0xE8E2DC), .kern: 3])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    text.draw(at: CGPoint(x: rect.minX + 22, y: rect.minY + 8))
    NSGraphicsContext.restoreGraphicsState()
    // connector from core to tag
    ctx.move(to: CGPoint(x: core.x + core.r * 0.93, y: rect.midY)); ctx.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
    ctx.setStrokeColor(hex(0xE8E2DC, 0.6).cgColor); ctx.setLineWidth(3); ctx.strokePath()
}

// MARK: Output

func png(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(in: ctx, size: CGFloat(px))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try png(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(1024).write(to: resources.appendingPathComponent("AppIcon-1024.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
try FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")

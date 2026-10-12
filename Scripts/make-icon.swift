// Generates Resources/App/AppIcon.icns: rounded-square gradient with routed waveform bars.
// Usage: swift Scripts/make-icon.swift   (writes Resources/App/AppIcon.icns via iconutil)
import AppKit

func render(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }
    let s = size / 1024

    // macOS icon grid: 824x824 body centered in 1024 canvas, corner radius ~185.
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: body, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.95, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.05, green: 0.62, blue: 0.92, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.maxX, y: body.minY), options: [])

    // Three input waveforms (left) converging through cables into one output bar stack (right).
    let white = NSColor.white
    let heights: [[CGFloat]] = [[40, 90, 60, 120, 70], [70, 140, 100, 50, 110], [30, 80, 130, 90, 50]]
    let rowsY: [CGFloat] = [700, 512, 324]
    let barW: CGFloat = 22, gap: CGFloat = 14
    for (row, y) in rowsY.enumerated() {
        for (i, h) in heights[row].enumerated() {
            let x = 205 + CGFloat(i) * (barW + gap)
            let r = CGRect(x: x * s, y: (y - h / 2) * s, width: barW * s, height: h * s)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 11 * s, cornerHeight: 11 * s, transform: nil))
        }
        ctx.setFillColor(white.withAlphaComponent(0.95).cgColor)
        ctx.fillPath()

        // Cable from the waveform to the output node.
        ctx.move(to: CGPoint(x: 395 * s, y: y * s))
        ctx.addCurve(to: CGPoint(x: 700 * s, y: 512 * s),
                     control1: CGPoint(x: 560 * s, y: y * s), control2: CGPoint(x: 560 * s, y: 512 * s))
        ctx.setStrokeColor(white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(18 * s)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
    // Output node.
    let node = CGRect(x: 690 * s, y: 432 * s, width: 160 * s, height: 160 * s)
    ctx.setFillColor(white.cgColor)
    ctx.fillEllipse(in: node)
    ctx.setFillColor(NSColor(calibratedRed: 0.20, green: 0.40, blue: 0.94, alpha: 1).cgColor)
    ctx.fillEllipse(in: node.insetBy(dx: 42 * s, dy: 42 * s))
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func writePNG(_ img: NSImage, pixels: Int, to url: URL) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = render(size: 1024)
for base in [16, 32, 128, 256, 512] {
    try writePNG(master, pixels: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(master, pixels: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/App/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
try writePNG(master, pixels: 512, to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-preview.png"))

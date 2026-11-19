import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    let inset = s * 0.09
    let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2), xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(starting: NSColor(red: 0.16, green: 0.2, blue: 0.26, alpha: 1), ending: NSColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1))!.draw(in: tile, angle: -90)

    let phone = NSRect(x: s * 0.36, y: s * 0.22, width: s * 0.28, height: s * 0.56)
    let body = NSBezierPath(roundedRect: phone, xRadius: s * 0.06, yRadius: s * 0.06)
    NSColor(red: 0.98, green: 0.77, blue: 0.2, alpha: 1).setStroke()
    body.lineWidth = s * 0.03
    body.stroke()
    NSColor(red: 0.98, green: 0.77, blue: 0.2, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.455, y: s * 0.70, width: s * 0.09, height: s * 0.025), xRadius: s * 0.0125, yRadius: s * 0.0125).fill()

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: s * 0.5, y: s * 0.60))
    arrow.line(to: NSPoint(x: s * 0.5, y: s * 0.38))
    arrow.move(to: NSPoint(x: s * 0.43, y: s * 0.45))
    arrow.line(to: NSPoint(x: s * 0.5, y: s * 0.38))
    arrow.line(to: NSPoint(x: s * 0.57, y: s * 0.45))
    arrow.lineWidth = s * 0.03
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor.white.setStroke()
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                       ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try render(pixels).write(to: output.appendingPathComponent("\(name).png"))
}

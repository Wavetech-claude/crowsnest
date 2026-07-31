import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle plate, matching the macOS icon silhouette.
    let inset = size * 0.085
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let plate = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    ctx.saveGState()
    plate.addClip()
    let grad = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.23, alpha: 1),
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)])!
    grad.draw(in: rect, angle: -90)
    ctx.restoreGState()

    // Speech bubble, the same idea the menu bar glyph uses.
    let w = rect.width * 0.52, h = w * 0.78
    let bx = rect.midX - w / 2, by = rect.midY - h / 2 + rect.height * 0.055
    let bubble = NSBezierPath(roundedRect: CGRect(x: bx, y: by, width: w, height: h),
                              xRadius: h * 0.30, yRadius: h * 0.30)
    let tail = NSBezierPath()
    tail.move(to: CGPoint(x: bx + w * 0.24, y: by + h * 0.06))
    tail.line(to: CGPoint(x: bx + w * 0.20, y: by - h * 0.26))
    tail.line(to: CGPoint(x: bx + w * 0.50, y: by + h * 0.06))
    tail.close()
    NSColor.white.setFill()
    bubble.fill(); tail.fill()

    // One amber dot: the state this app exists to surface.
    let d = w * 0.155
    NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: rect.midX - d / 2, y: by + h / 2 - d / 2, width: d, height: d)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments[1]
for (name, px) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),
                   ("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),
                   ("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let rep = render(CGFloat(px))
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("rendered 10 sizes")

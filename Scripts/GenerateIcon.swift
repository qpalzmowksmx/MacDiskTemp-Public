import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let base = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 212, yRadius: 212)
    NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.23, blue: 0.27, alpha: 1),
               ending: NSColor(srgbRed: 0.035, green: 0.085, blue: 0.13, alpha: 1))!.draw(in: base, angle: -90)
    let drive = NSBezierPath(roundedRect: NSRect(x: 211, y: 205, width: 602, height: 618), xRadius: 78, yRadius: 78)
    NSColor(srgbRed: 0.84, green: 0.91, blue: 0.93, alpha: 1).setFill(); drive.fill()
    let face = NSBezierPath(roundedRect: NSRect(x: 245, y: 283, width: 534, height: 506), xRadius: 53, yRadius: 53)
    NSColor(srgbRed: 0.17, green: 0.27, blue: 0.31, alpha: 1).setFill(); face.fill()
    let outline = NSBezierPath(roundedRect: NSRect(x: 450, y: 420, width: 124, height: 280), xRadius: 62, yRadius: 62)
    NSColor(srgbRed: 0.35, green: 0.94, blue: 0.82, alpha: 1).setFill(); outline.fill()
    NSBezierPath(ovalIn: NSRect(x: 413, y: 355, width: 198, height: 198)).fill()
    let tube = NSBezierPath(roundedRect: NSRect(x: 492, y: 451, width: 40, height: 205), xRadius: 20, yRadius: 20)
    NSColor(srgbRed: 0.08, green: 0.30, blue: 0.31, alpha: 1).setFill(); tube.fill()
    NSBezierPath(ovalIn: NSRect(x: 461, y: 403, width: 102, height: 102)).fill()
    NSColor(srgbRed: 0.06, green: 0.30, blue: 0.30, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 718, y: 235, width: 21, height: 21)).fill()
    NSBezierPath(roundedRect: NSRect(x: 285, y: 237, width: 160, height: 17), xRadius: 8, yRadius: 8).fill()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        try drawIcon(size: base * multiplier).write(to: destination.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}

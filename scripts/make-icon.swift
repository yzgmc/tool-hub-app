import AppKit

// Vector-authored icon; render only during the build, no private image inputs.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGradient(starting: NSColor(red: 0.04, green: 0.13, blue: 0.33, alpha: 1),
           ending: NSColor(red: 0.08, green: 0.38, blue: 0.78, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024), angle: 60)
for (x, y, alpha) in [(240.0, 532.0, 0.94), (532.0, 532.0, 0.70), (240.0, 240.0, 0.70), (532.0, 240.0, 0.94)] {
    let rect = NSRect(x: x, y: y, width: 252, height: 252)
    let path = NSBezierPath(roundedRect: rect, xRadius: 72, yRadius: 72)
    NSColor.white.withAlphaComponent(alpha).setFill(); path.fill()
    NSColor.white.withAlphaComponent(0.55).setStroke(); path.lineWidth = 3; path.stroke()
}
NSGraphicsContext.restoreGraphicsState()
let destination = CommandLine.arguments[1]
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))

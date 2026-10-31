import AppKit

// Store a 2x image with a logical size matching the Finder window.
let size = NSSize(width: 560, height: 320)
guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 1120, pixelsHigh: 640,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
      ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { fatalError("Usage: swift generate-dmg-background.swift output.tiff") }

bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: 2, y: 2)
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 1.00, green: 0.87, blue: 0.78, alpha: 1),
    NSColor(srgbRed: 0.97, green: 0.90, blue: 0.92, alpha: 1),
    NSColor(srgbRed: 0.85, green: 0.87, blue: 0.98, alpha: 1),
])!
gradient.draw(in: NSRect(origin: .zero, size: size), angle: 20)

// Finder places both icons 130 points down from the top of its content area.
NSColor(srgbRed: 0.42, green: 0.36, blue: 0.47, alpha: 0.35).setStroke()
let arrow = NSBezierPath()
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 262, y: 190))
arrow.line(to: NSPoint(x: 298, y: 190))
arrow.move(to: NSPoint(x: 289, y: 199))
arrow.line(to: NSPoint(x: 298, y: 190))
arrow.line(to: NSPoint(x: 289, y: 181))
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.tiffRepresentation else {
    fatalError("Could not encode the DMG background")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

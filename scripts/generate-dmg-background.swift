import AppKit

// Regenerate scripts/dmg-background.tiff:
//   swift scripts/generate-dmg-background.swift scripts/dmg-background.tiff
//
// Finder draws dark label text over background pictures regardless of
// appearance, so the background must stay light.

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift generate-dmg-background.swift output.tiff")
}

// Logical size matches the Finder window content area (bounds in create-dmg.sh).
let size = NSSize(width: 560, height: 320)
// Finder centers both icons 130pt below the top of the content area.
let iconCenterY: CGFloat = 130

func color(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
        green: CGFloat(hex >> 8 & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func render(scale: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    // Background: light gray with a soft warm glow behind the icons.
    color(0xDCDBD9).setFill()
    NSRect(origin: .zero, size: size).fill()
    let centerY = size.height - iconCenterY
    NSGradient(colors: [color(0xEFE3DA), color(0xDCDBD9)])!
        .draw(fromCenter: NSPoint(x: size.width / 2, y: centerY), radius: 0,
              toCenter: NSPoint(x: size.width / 2, y: centerY), radius: 300,
              options: [])

    // A dashed circular arc from the app over to Applications. Its ends are
    // tangent to lines through the icon centers (x 140 and 420), so extending
    // the arrow's tail or head runs into the icons.
    // Draw opaque into a translucent layer so overlapping strokes don't darken.
    let ink = color(0x2B2B2D)
    let cg = NSGraphicsContext.current!.cgContext
    cg.setAlpha(0.5)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    let cx = size.width / 2
    let halfChord: CGFloat = 63
    let endY = centerY + 4
    let appCenter = NSPoint(x: 140, y: centerY)
    // Angle between the chord and the line from the app icon to the tail.
    let tilt = atan2(endY - appCenter.y, cx - halfChord - appCenter.x)
    let radius = halfChord / sin(tilt)
    let arcCenter = NSPoint(x: cx, y: endY - radius * cos(tilt))
    let degrees = tilt * 180 / .pi
    let swoop = NSBezierPath()
    swoop.appendArc(withCenter: arcCenter, radius: radius,
                    startAngle: 90 + degrees, endAngle: 90 - degrees, clockwise: true)
    let end = NSPoint(x: cx + halfChord, y: endY)
    swoop.lineWidth = 2.5
    swoop.lineCapStyle = .round
    swoop.lineJoinStyle = .round
    swoop.setLineDash([7, 7], count: 2, phase: 0)
    ink.setStroke()
    swoop.stroke()

    // Solid arrowhead with uneven arms, pointing back along the arc's end tangent.
    let angle = .pi - tilt
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x + 20 * cos(angle + 0.62), y: end.y + 20 * sin(angle + 0.62)))
    head.line(to: end)
    head.line(to: NSPoint(x: end.x + 16 * cos(angle - 0.5), y: end.y + 16 * sin(angle - 0.5)))
    head.lineWidth = 2.5
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    ink.setStroke()
    head.stroke()
    cg.endTransparencyLayer()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: size)
image.addRepresentation(render(scale: 1))
image.addRepresentation(render(scale: 2))
guard let data = image.tiffRepresentation(using: .lzw, factor: 0) else {
    fatalError("Could not encode TIFF")
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

import AppKit

// Regenerate scripts/dmg-background.tiff:
//   swift scripts/generate-dmg-background.swift scripts/dmg-background.tiff
//
// Finder draws dark label text over background pictures regardless of
// appearance, so the dark background gets a light plate behind each label.

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift generate-dmg-background.swift output.tiff")
}

// Logical size matches the Finder window content area (bounds in create-dmg.sh).
let size = NSSize(width: 560, height: 320)
// Finder centers both icons 130pt below the top of the content area.
let iconCenterY: CGFloat = 130
// Measured in Finder: the 14pt labels center 196pt below the top.
let labelCenterY: CGFloat = 196
let labelPlateSize = NSSize(width: 112, height: 24)
let iconCenterXs: [CGFloat] = [140, 420]

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
    )!.retagging(with: .sRGB)!
    rep.size = size
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    // Solid dark background. Finder shows background pictures noticeably
    // lighter than drawn, so judge this color in a built DMG.
    color(0x262626).setFill()
    NSRect(origin: .zero, size: size).fill()
    let centerY = size.height - iconCenterY

    // Light plates so Finder's dark label text stays readable.
    for x in iconCenterXs {
        let plate = NSRect(
            x: x - labelPlateSize.width / 2,
            y: size.height - labelCenterY - labelPlateSize.height / 2,
            width: labelPlateSize.width, height: labelPlateSize.height)
        let path = NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2)
        color(0xE8E8E8).setFill()
        path.fill()
    }

    // A dashed circular arc from the app over to Applications. Its ends are
    // tangent to lines through the icon centers (x 140 and 420), so extending
    // the arrow's tail or head runs into the icons.
    // Draw opaque into a translucent layer so overlapping strokes don't darken.
    let ink = color(0xFFFFFF)
    let cg = NSGraphicsContext.current!.cgContext
    cg.setAlpha(0.2)
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

// Generates Resources/AppIcon.icns — monochrome: charcoal squircle,
// white arrow pulling down into a tray. Run:  swift scripts/make_icon.swift
import AppKit

let canvas: CGFloat = 1024

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = size / canvas
    let inset: CGFloat = 100 * s
    let side = size - inset * 2
    let corner = side * 0.2237
    let square = NSRect(x: inset, y: inset, width: side, height: side)
    let squircle = NSBezierPath(roundedRect: square, xRadius: corner, yRadius: corner)

    // soft shadow
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 22 * s
    shadow.set()
    NSColor.black.withAlphaComponent(0.001).setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // charcoal gradient tile
    let top = NSColor(calibratedWhite: 0.16, alpha: 1)
    let bottom = NSColor(calibratedWhite: 0.05, alpha: 1)
    NSGradient(starting: top, ending: bottom)!.draw(in: squircle, angle: -90)

    // subtle top sheen
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.10),
               ending: NSColor.white.withAlphaComponent(0.0))!
        .draw(in: NSRect(x: inset, y: inset + side * 0.6, width: side, height: side * 0.4), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    NSColor.white.setFill()
    NSColor.white.setStroke()
    let cx = size / 2

    // arrow shaft
    let shaftW = 74 * s
    let shaftTop = inset + side * 0.72
    let shaftBottom = inset + side * 0.40
    let shaft = NSBezierPath(roundedRect: NSRect(x: cx - shaftW/2, y: shaftBottom,
                                                 width: shaftW, height: shaftTop - shaftBottom),
                             xRadius: shaftW/2, yRadius: shaftW/2)
    shaft.fill()

    // arrow head (triangle, rounded feel via line join)
    let headW = 210 * s
    let headH = 130 * s
    let head = NSBezierPath()
    head.move(to: NSPoint(x: cx - headW/2, y: shaftBottom + 8 * s))
    head.line(to: NSPoint(x: cx + headW/2, y: shaftBottom + 8 * s))
    head.line(to: NSPoint(x: cx, y: shaftBottom - headH))
    head.close()
    head.lineJoinStyle = .round
    head.lineWidth = 26 * s
    head.stroke()
    head.fill()

    // tray
    let trayW = side * 0.46
    let trayH = 30 * s
    let trayY = inset + side * 0.17
    let tray = NSBezierPath(roundedRect: NSRect(x: cx - trayW/2, y: trayY, width: trayW, height: trayH),
                            xRadius: trayH/2, yRadius: trayH/2)
    tray.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    let png = drawIcon(size: px).representation(using: .png, properties: [:])!
    try! png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")

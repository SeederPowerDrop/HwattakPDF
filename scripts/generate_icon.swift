import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: generate_icon output.png")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fatalError("Could not allocate icon bitmap")
}

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create icon graphics context")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

let background = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900), xRadius: 214, yRadius: 214)
background.addClip()
let backgroundGradient = NSGradient(
    colorsAndLocations:
        (NSColor(calibratedRed: 0.32, green: 0.41, blue: 1.00, alpha: 1), 0),
        (NSColor(calibratedRed: 0.19, green: 0.36, blue: 1.00, alpha: 1), 0.55),
        (NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.78, alpha: 1), 1)
)
backgroundGradient?.draw(in: NSRect(x: 62, y: 62, width: 900, height: 900), angle: -48)

let wave = NSBezierPath()
wave.move(to: NSPoint(x: 142, y: 322))
wave.curve(to: NSPoint(x: 565, y: 350), controlPoint1: NSPoint(x: 305, y: 441), controlPoint2: NSPoint(x: 400, y: 217))
wave.curve(to: NSPoint(x: 902, y: 624), controlPoint1: NSPoint(x: 688, y: 450), controlPoint2: NSPoint(x: 760, y: 564))
wave.line(to: NSPoint(x: 902, y: 276))
wave.curve(to: NSPoint(x: 748, y: 122), controlPoint1: NSPoint(x: 902, y: 190), controlPoint2: NSPoint(x: 834, y: 122))
wave.line(to: NSPoint(x: 276, y: 122))
wave.curve(to: NSPoint(x: 142, y: 256), controlPoint1: NSPoint(x: 202, y: 122), controlPoint2: NSPoint(x: 142, y: 182))
wave.close()
NSColor(calibratedRed: 0.04, green: 0.14, blue: 0.50, alpha: 0.18).setFill()
wave.fill()

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -28)
shadow.shadowBlurRadius = 30
shadow.shadowColor = NSColor(calibratedRed: 0.03, green: 0.10, blue: 0.44, alpha: 0.38)
shadow.set()

let paper = NSBezierPath(roundedRect: NSRect(x: 226, y: 183, width: 534, height: 647), xRadius: 60, yRadius: 60)
NSColor(calibratedRed: 0.96, green: 0.98, blue: 1.00, alpha: 1).setFill()
paper.fill()

NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let fold = NSBezierPath()
fold.move(to: NSPoint(x: 620, y: 830))
fold.line(to: NSPoint(x: 620, y: 724))
fold.curve(to: NSPoint(x: 654, y: 690), controlPoint1: NSPoint(x: 620, y: 705), controlPoint2: NSPoint(x: 635, y: 690))
fold.line(to: NSPoint(x: 760, y: 690))
fold.close()
NSColor(calibratedRed: 0.81, green: 0.85, blue: 1.00, alpha: 1).setFill()
fold.fill()

func roundedBar(_ rect: NSRect, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
}

let blue = NSColor(calibratedRed: 0.19, green: 0.36, blue: 1.00, alpha: 1)
roundedBar(NSRect(x: 300, y: 598, width: 385, height: 32), color: blue)
roundedBar(NSRect(x: 300, y: 540, width: 306, height: 24), color: NSColor(calibratedRed: 0.62, green: 0.67, blue: 0.85, alpha: 1))
roundedBar(NSRect(x: 300, y: 488, width: 348, height: 24), color: NSColor(calibratedRed: 0.62, green: 0.67, blue: 0.85, alpha: 1))

let tileRects = [
    NSRect(x: 450, y: 328, width: 108, height: 86),
    NSRect(x: 576, y: 328, width: 108, height: 86),
    NSRect(x: 450, y: 224, width: 108, height: 86),
    NSRect(x: 576, y: 224, width: 108, height: 86),
]
let alphas: [CGFloat] = [1, 0.88, 0.76, 0.64]
for (rect, alpha) in zip(tileRects, alphas) {
    blue.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
}

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon PNG")
}
try png.write(to: outputURL, options: [.atomic])

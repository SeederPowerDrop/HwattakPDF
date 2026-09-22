// SPDX-License-Identifier: MPL-2.0
// Original vector artwork for HwattakPDF's associated PDF documents.
// Usage: swift scripts/generate_document_icon.swift <output-directory>
// Then: iconutil -c icns <output-directory>/HwattakPDFDocument.iconset

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: generate_document_icon.swift <output-directory>")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("HwattakPDFDocument.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
let navy = color(0.078, 0.149, 0.231)
let ivory = color(1, 0.976, 0.933)
let steel = color(0.435, 0.557, 0.682)
let coral = color(0.910, 0.310, 0.278)

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func render(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create icon bitmap")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    let cg = graphics.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    graphics.imageInterpolation = .high

    let page = NSBezierPath()
    page.move(to: NSPoint(x: 232, y: 956))
    page.line(to: NSPoint(x: 638, y: 956))
    page.line(to: NSPoint(x: 836, y: 758))
    page.line(to: NSPoint(x: 836, y: 112))
    page.curve(to: NSPoint(x: 792, y: 68), controlPoint1: NSPoint(x: 836, y: 84), controlPoint2: NSPoint(x: 820, y: 68))
    page.line(to: NSPoint(x: 232, y: 68))
    page.curve(to: NSPoint(x: 188, y: 112), controlPoint1: NSPoint(x: 204, y: 68), controlPoint2: NSPoint(x: 188, y: 84))
    page.line(to: NSPoint(x: 188, y: 912))
    page.curve(to: NSPoint(x: 232, y: 956), controlPoint1: NSPoint(x: 188, y: 940), controlPoint2: NSPoint(x: 204, y: 956))
    page.close()

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: navy.withAlphaComponent(0.25).cgColor)
    ivory.setFill()
    page.fill()
    cg.restoreGState()
    NSGradient(starting: color(0.935, 0.914, 0.859), ending: ivory)?.draw(in: page, angle: 90)
    navy.withAlphaComponent(0.24).setStroke()
    page.lineWidth = pixels <= 32 ? 12 : 4
    page.stroke()

    let fold = NSBezierPath()
    fold.move(to: NSPoint(x: 638, y: 956))
    fold.line(to: NSPoint(x: 638, y: 800))
    fold.curve(to: NSPoint(x: 680, y: 758), controlPoint1: NSPoint(x: 638, y: 774), controlPoint2: NSPoint(x: 654, y: 758))
    fold.line(to: NSPoint(x: 836, y: 758))
    fold.close()
    color(0.749, 0.788, 0.808).setFill()
    fold.fill()

    // The two-page workspace motif echoes the app icon without reproducing
    // its tiny UI details, which disappear at Finder's 16/32-pixel sizes.
    for x: CGFloat in [274, 516] {
        rounded(NSRect(x: x, y: 400, width: 234, height: 316), radius: 30, fill: navy)
        rounded(NSRect(x: x + 22, y: 422, width: 190, height: 272), radius: 14, fill: ivory)
        if pixels >= 64 {
            rounded(NSRect(x: x + 48, y: 630, width: 138, height: 16), radius: 4, fill: navy)
            rounded(NSRect(x: x + 48, y: 584, width: 138, height: 12), radius: 3, fill: steel)
            rounded(NSRect(x: x + 48, y: 545, width: 105, height: 12), radius: 3, fill: steel)
        }
    }
    rounded(NSRect(x: 316, y: 470, width: 152, height: pixels <= 32 ? 34 : 28), radius: 5, fill: steel)
    rounded(NSRect(x: 676, y: 434, width: 34, height: 114), radius: 5, fill: coral)

    rounded(NSRect(x: 274, y: 160, width: 476, height: 174), radius: 26, fill: navy)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 128, weight: .bold),
        .foregroundColor: ivory,
        .kern: 7
    ]
    let label = "PDF" as NSString
    let labelSize = label.size(withAttributes: attributes)
    label.draw(at: NSPoint(x: 512 - labelSize.width / 2, y: 247 - labelSize.height / 2), withAttributes: attributes)

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode icon bitmap")
    }
    return png
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(pixels: points * scale).write(
            to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"), options: .atomic
        )
    }
}
try render(pixels: 1024).write(to: output.appendingPathComponent("HwattakPDFDocument.png"), options: .atomic)
print("Generated vector document icon at 16–1024 pixels in \(output.path)")

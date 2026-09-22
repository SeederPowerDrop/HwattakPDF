// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Vector appearance preserves variable stylus width in ordinary PDF readers.
/// It is a Stamp appearance, not a native constant-width Ink path.
final class PressureInkAnnotation: PDFAnnotation {
    static let stampName = "HwattakPDFPressureInk"
    static let maximumPoints = 8_192
    private let points: [CGPoint]
    private let widths: [CGFloat]
    private let inkColor: NSColor

    init?(points: [CGPoint], pressures: [CGFloat], width: CGFloat, color: NSColor) {
        guard !points.isEmpty, points.count <= Self.maximumPoints,
              points.count == pressures.count, width.isFinite, (0.2...32).contains(width),
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              pressures.allSatisfy(\.isFinite) else { return nil }
        self.points = points
        widths = pressures.map { width * (0.2 + 0.8 * min(1, max(0, $0))) }
        inkColor = color.usingColorSpace(.deviceRGB)?.withAlphaComponent(1) ?? .black
        let x = points.map(\.x), y = points.map(\.y)
        let padding = width + 1
        let bounds = CGRect(x: x.min()! - padding, y: y.min()! - padding,
            width: x.max()! - x.min()! + 2 * padding, height: y.max()! - y.min()! + 2 * padding)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        PDFAnnotationPrivacy.clearImplicitAuthor(on: self)
        self.color = inkColor
        shouldDisplay = true
        shouldPrint = true
        setValue(Self.stampName, forAnnotationKey: .iconName)
    }

    required init?(coder: NSCoder) { nil }

    /// PDFPage.copy() copies its annotations through NSCopying. PDFAnnotation's
    /// implementation only copies its own Objective-C state; it does not
    /// initialize this subclass's Swift arrays. The resulting object can appear
    /// valid until PDFKit draws it to build the saved appearance stream.
    override func copy(with zone: NSZone? = nil) -> Any {
        PressureInkAnnotation(copying: self)
    }

    private init(copying source: PressureInkAnnotation) {
        // Arrays have value semantics and NSColor is immutable. Retaining these
        // values keeps the detached stroke alive independently of its source.
        points = source.points
        widths = source.widths
        inkColor = source.inkColor
        var properties = source.annotationKeyValues
        // annotationKeyValues provides a deep copy of PDF values. Page/parent
        // references belong to the source graph, never to a detached annotation.
        properties.removeValue(forKey: PDFAnnotationKey.page.rawValue)
        properties.removeValue(forKey: PDFAnnotationKey.parent.rawValue)
        super.init(bounds: source.bounds, forType: .stamp, withProperties: properties)
        // PDFKit may insert the macOS account name when the source dictionary
        // has no author. Preserve absence as well as an explicitly set author.
        userName = source.userName
        page = nil
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(inkColor.cgColor)
        context.setFillColor(inkColor.cgColor)
        context.setLineCap(.round)
        if points.count == 1 {
            context.fillEllipse(in: CGRect(x: points[0].x - widths[0] / 2,
                y: points[0].y - widths[0] / 2, width: widths[0], height: widths[0]))
        } else {
            for index in 1..<points.count {
                context.setLineWidth((widths[index - 1] + widths[index]) / 2)
                context.move(to: points[index - 1])
                context.addLine(to: points[index])
                context.strokePath()
            }
        }
    }
}

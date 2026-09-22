// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Identifies the app's appearance-backed Study marks after a PDF round trip.
///
/// PDFKit rebuilds a custom Stamp while serializing it and drops `/NM` (the
/// annotation's unique-name field). The standard Stamp-specific `/Name` entry,
/// exposed publicly as `.iconName`, does survive that rebuild. We use a small,
/// honest custom stamp name for *kind classification only*; it is not presented
/// as a semantic PDF Highlight/Underline annotation or as a globally unique ID.
enum StudyMarkupAnnotationIdentity {
    private static let prefix = "HwattakPDFStudyMarkup-"

    static func assign(_ kind: StudyMarkupKind, to annotation: PDFAnnotation) {
        annotation.setValue(
            "\(prefix)\(kind.rawValue)",
            forAnnotationKey: .iconName
        )
    }

    static func kind(of annotation: PDFAnnotation) -> StudyMarkupKind? {
        let type = annotation.type?.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        guard type == "Stamp" else { return nil }
        guard let rawName = annotation.value(forAnnotationKey: .iconName) as? String else {
            return nil
        }
        let name = rawName.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard name.hasPrefix(prefix) else { return nil }
        let rawKind = String(name.dropFirst(prefix.count))
        return StudyMarkupKind(rawValue: rawKind)
    }
}

/// A text-markup annotation whose saved appearance preserves user opacity.
///
/// PDFKit exposes highlight and underline colors, but it drops the alpha
/// component of `NSColor` when it writes a PDF. The PDF specification has an
/// annotation-opacity entry (`/CA`), yet PDFKit's public mutation API rejects
/// that key for these two subtypes on current macOS releases. Relying on the
/// rejected dictionary value would make a 25% highlight become 100% opaque
/// after the file is reopened.
///
/// The supported alternative is an appearance stream. PDFKit asks custom
/// `PDFAnnotation` subclasses to draw and serializes that drawing into `/AP`.
/// Other conforming PDF readers can then display the same translucent mark.
/// PDFKit only emits that appearance for a supported appearance-backed subtype,
/// so the saved annotation is a standard Stamp. PDFKit also rebuilds the
/// custom object while serializing and does not retain app-only class metadata.
/// Consequently the saved file preserves the visual result, not a semantic
/// Highlight/Underline subtype or an app-specific editable study-mark model.
final class StudyMarkupAnnotation: PDFAnnotation {
    let markupKind: StudyMarkupKind
    let markupColor: NSColor
    let markupThickness: CGFloat
    let markupOpacity: CGFloat

    init(bounds: CGRect, style requestedStyle: StudyMarkupStyle) {
        let style = requestedStyle.normalized
        markupKind = style.kind
        markupColor = style.color.usingColorSpace(.deviceRGB) ?? style.color
        markupThickness = style.thickness
        markupOpacity = style.opacity
        super.init(
            bounds: bounds,
            // PDFKit does not generate an appearance stream for a custom
            // subclass that claims the native Highlight/Underline subtype.
            // Stamp is the public, appearance-backed subtype used by the app's
            // existing image annotations as well.
            forType: .stamp,
            withProperties: nil
        )
        PDFAnnotationPrivacy.clearImplicitAuthor(on: self)

        // `/C` remains useful semantic metadata for readers that inspect the
        // annotation. Keep it opaque because transparency belongs to `/AP` and
        // must not be applied twice by a renderer.
        color = markupColor.withAlphaComponent(1)
        shouldDisplay = true
        shouldPrint = true
        modificationDate = Date()
        StudyMarkupAnnotationIdentity.assign(style.kind, to: self)

        if style.kind == .underline {
            let border = PDFBorder()
            border.lineWidth = style.thickness
            self.border = border
        }
    }

    required init?(coder: NSCoder) {
        // The subclass is an in-memory authoring object. Once serialized, its
        // standard subtype and appearance stream are sufficient to reconstruct
        // the visible PDF; it is never restored from NSKeyedArchiver data.
        return nil
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !bounds.isEmpty else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(markupOpacity)

        guard let cgColor = markupColor.cgColor.copy(alpha: 1) else { return }
        switch markupKind {
        case .highlight:
            context.setFillColor(cgColor)
            context.fill(bounds)

        case .underline:
            // Keep a baseline stroke even for small text or a style inherited
            // from a thick highlighter. Its appearance must leave the body of
            // the text clear, including after PDFKit serializes the stamp.
            let visibleWidth = min(markupThickness, bounds.height * 0.2)
            context.setStrokeColor(cgColor)
            context.setLineWidth(visibleWidth)
            context.setLineCap(.round)
            let y = bounds.minY + visibleWidth / 2
            context.move(to: CGPoint(x: bounds.minX, y: y))
            context.addLine(to: CGPoint(x: bounds.maxX, y: y))
            context.strokePath()
        }
    }
}

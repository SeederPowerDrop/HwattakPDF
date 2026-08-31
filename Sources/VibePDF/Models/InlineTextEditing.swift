// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit

/// Why the inline editor is being opened.
///
/// A beginner may reasonably expect "replace selected PDF text" to rewrite
/// the page's content stream. PDFKit does not expose a safe content-stream text
/// editor, so HwattakPDF deliberately models that operation as a visible
/// FreeText overlay. The original glyphs remain underneath and therefore also
/// remain available to search, copy, accessibility extraction, and recovery.
enum InlineTextEditPurpose: String, Equatable {
    /// A normal, app-owned FreeText annotation.
    case freeText
    /// An opaque FreeText annotation placed over existing page text.
    case visualReplacement
}

/// Why a synchronous request did not create the on-page editor.
///
/// The view uses this narrow result to avoid silently routing an unsafe object
/// into another unbounded editor after the model has deliberately refused it.
enum InlineTextEditRejectionReason: Equatable {
    case existingTextExceedsSafetyLimit
}

/// Pure keyboard policy for the AppKit editor. Keeping key-code interpretation
/// out of the view makes IME and shortcut behavior regression-testable.
enum InlineTextEditorKeyIntent: Equatable {
    case passThrough
    case commit
    case cancel
    case lineBreak

    static func resolve(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> InlineTextEditorKeyIntent {
        if hasMarkedText { return .passThrough }
        if keyCode == 53 { return .cancel }
        if keyCode == 36 || keyCode == 76 {
            return modifiers.contains(.shift) ? .lineBreak : .commit
        }
        return .passThrough
    }
}

struct LimitedInlineText: Equatable {
    let text: String
    let wasTruncated: Bool
}

/// Hard safety envelope for FreeText draft content.
///
/// PDF selections can span a whole dense textbook, and pasteboards can contain
/// megabytes. A bounded editor prevents one click/paste from synchronously
/// laying out an effectively unbounded NSTextView while still allowing a very
/// generous annotation (32,768 user-perceived characters).
enum InlineTextDraftLimiter {
    static let maximumCharacterCount = 32_768
    /// A Character can contain an enormous number of combining marks or ZWJ
    /// scalars. This secondary encoded-size ceiling prevents one pathological
    /// grapheme from bypassing the user-perceived-character limit.
    static let maximumUTF16CodeUnitCount = 1_048_576

    static func limit(_ text: String) -> LimitedInlineText {
        limit(
            text,
            characterLimit: maximumCharacterCount,
            utf16Limit: maximumUTF16CodeUnitCount
        )
    }

    /// Limits an insertion before NSTextView lays it out. The UTF-16 pass runs
    /// first because it can stop at an encoded offset without asking Swift to
    /// segment a potentially multi-megabyte extended grapheme cluster.
    static func limit(
        _ text: String,
        characterLimit requestedCharacterLimit: Int,
        utf16Limit requestedUTF16Limit: Int
    ) -> LimitedInlineText {
        let characterLimit = max(0, requestedCharacterLimit)
        let utf16Limit = max(0, requestedUTF16Limit)
        guard characterLimit > 0, utf16Limit > 0 else {
            return LimitedInlineText(text: "", wasTruncated: !text.isEmpty)
        }

        let encodedCandidate: String
        let wasUTF16Truncated: Bool
        if
            let encodedCutoff = text.utf16.index(
                text.utf16.startIndex,
                offsetBy: utf16Limit,
                limitedBy: text.utf16.endIndex
            ),
            encodedCutoff != text.utf16.endIndex
        {
            // Decode only the bounded prefix. Move back one unit when the cap
            // lands after a high surrogate so truncation never manufactures a
            // replacement character in place of half an emoji.
            var codeUnits = Array(text.utf16.prefix(utf16Limit))
            if
                let last = codeUnits.last,
                (0xD800...0xDBFF).contains(last)
            {
                codeUnits.removeLast()
            }
            encodedCandidate = String(decoding: codeUnits, as: UTF16.self)
            wasUTF16Truncated = true
        } else {
            encodedCandidate = text
            wasUTF16Truncated = false
        }

        guard
            let characterCutoff = encodedCandidate.index(
                encodedCandidate.startIndex,
                offsetBy: characterLimit,
                limitedBy: encodedCandidate.endIndex
            ),
            characterCutoff != encodedCandidate.endIndex
        else {
            return LimitedInlineText(
                text: encodedCandidate,
                wasTruncated: wasUTF16Truncated
            )
        }
        return LimitedInlineText(
            text: String(encodedCandidate[..<characterCutoff]),
            wasTruncated: true
        )
    }

    /// Builds a bounded excerpt without first joining every selected line.
    /// The sequence is consumed only until the cap is reached.
    static func limit<S: Sequence>(
        fragments: S,
        separator: String = "\n"
    ) -> LimitedInlineText where S.Element == String {
        var result = ""
        var characterCount = 0
        var utf16Count = 0
        var first = true

        // Append at most the remaining grapheme budget. Separator and fragment
        // are handled independently, so a single enormous PDF line is never
        // copied in full merely to discover that only a prefix is needed.
        func appendBounded(_ piece: String) -> Bool {
            let remainingCharacters = maximumCharacterCount - characterCount
            let remainingUTF16 = maximumUTF16CodeUnitCount - utf16Count
            guard remainingCharacters > 0, remainingUTF16 > 0 else { return true }
            let limited = limit(
                piece,
                characterLimit: remainingCharacters,
                utf16Limit: remainingUTF16
            )
            result += limited.text
            // Each traversal is bounded by the remaining safety envelope; the
            // whole operation is therefore O(the cap), not O(the document).
            characterCount += limited.text.count
            utf16Count += limited.text.utf16.count
            return limited.wasTruncated
        }

        for fragment in fragments {
            if !first, appendBounded(separator) {
                return LimitedInlineText(text: result, wasTruncated: true)
            }
            if appendBounded(fragment) {
                return LimitedInlineText(text: result, wasTruncated: true)
            }
            first = false
        }
        return LimitedInlineText(text: result, wasTruncated: false)
    }
}

/// Portable RGBA storage used while an inline editor is open.
///
/// Holding `NSColor` directly would also work in memory, but components make
/// equality deterministic and keep this value ready for future session
/// migration without archiving AppKit implementation classes.
struct PDFTextColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    static let black = PDFTextColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let clear = PDFTextColor(red: 1, green: 1, blue: 1, alpha: 0)
    static let white = PDFTextColor(red: 1, green: 1, blue: 1, alpha: 1)

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = min(1, max(0, red.isFinite ? red : 0))
        self.green = min(1, max(0, green.isFinite ? green : 0))
        self.blue = min(1, max(0, blue.isFinite ? blue : 0))
        self.alpha = min(1, max(0, alpha.isFinite ? alpha : 1))
    }

    init(_ color: NSColor?) {
        let source = color ?? .clear
        // Dynamic and grayscale colors do not necessarily expose RGB
        // components. Resolving through deviceRGB provides stable PDF values.
        let converted = source.usingColorSpace(.deviceRGB) ?? source
        self.init(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// AppKit may round the same sRGB color through floating-point device
    /// spaces (for example 0.270588 becomes 0.270398). PDF appearance does not
    /// change at that scale, and RGB channels are irrelevant when alpha is 0.
    func visuallyEquals(_ other: PDFTextColor, tolerance: CGFloat = 0.001) -> Bool {
        guard abs(alpha - other.alpha) <= tolerance else { return false }
        if alpha <= tolerance, other.alpha <= tolerance { return true }
        return abs(red - other.red) <= tolerance
            && abs(green - other.green) <= tolerance
            && abs(blue - other.blue) <= tolerance
    }
}

/// Appearance controls shared by new and existing app-owned FreeText objects.
struct InlineTextStyle: Equatable {
    static let minimumFontSize: CGFloat = 6
    static let maximumFontSize: CGFloat = 144

    var fontName: String
    var fontSize: CGFloat
    var textColor: PDFTextColor
    var backgroundColor: PDFTextColor
    var alignment: NSTextAlignment

    static func standard(for purpose: InlineTextEditPurpose) -> InlineTextStyle {
        let font = NSFont.systemFont(ofSize: 15)
        return InlineTextStyle(
            fontName: font.fontName,
            fontSize: 15,
            textColor: .black,
            // A visual replacement needs an opaque cover by default. Normal
            // notes remain transparent so they do not hide page content.
            backgroundColor: purpose == .visualReplacement ? .white : .clear,
            alignment: .left
        )
    }

    init(
        fontName: String,
        fontSize: CGFloat,
        textColor: PDFTextColor,
        backgroundColor: PDFTextColor,
        alignment: NSTextAlignment
    ) {
        self.fontName = fontName
        self.fontSize = Self.clampedFontSize(fontSize)
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.alignment = Self.supportedAlignment(alignment)
    }

    init(annotation: PDFAnnotation, purpose: InlineTextEditPurpose) {
        let fallback = Self.standard(for: purpose)
        self.init(
            fontName: annotation.font?.fontName ?? fallback.fontName,
            fontSize: annotation.font?.pointSize ?? fallback.fontSize,
            textColor: PDFTextColor(annotation.fontColor ?? fallback.textColor.nsColor),
            backgroundColor: PDFTextColor(annotation.color),
            alignment: annotation.alignment
        )
    }

    var font: NSFont {
        NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    }

    mutating func normalize() {
        fontSize = Self.clampedFontSize(fontSize)
        alignment = Self.supportedAlignment(alignment)
        if NSFont(name: fontName, size: fontSize) == nil {
            fontName = NSFont.systemFont(ofSize: fontSize).fontName
        }
    }

    private static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return 15 }
        return min(maximumFontSize, max(minimumFontSize, size))
    }

    private static func supportedAlignment(_ value: NSTextAlignment) -> NSTextAlignment {
        switch value {
        // PDF FreeText stores the specification's Q value, which supports
        // left, center, and right. PDFKit coerces other NSTextAlignment cases
        // inconsistently, so normalize them before the draft reaches the UI.
        case .left, .center, .right:
            return value
        case .justified, .natural:
            return .left
        @unknown default:
            return .left
        }
    }
}

/// A transactional draft displayed directly over the PDF canvas.
///
/// The draft is a value rather than an `NSTextView` reference. That keeps the
/// document model independent from view lifetime: switching tabs can rebuild
/// PDFKit without silently dropping what the user just typed.
struct PendingInlineTextEdit: Identifiable, Equatable {
    let id: UUID
    let pageIndex: Int
    var bounds: CGRect
    let isEditingExistingAnnotation: Bool
    let purpose: InlineTextEditPurpose
    var text: String
    var style: InlineTextStyle

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        bounds: CGRect,
        isEditingExistingAnnotation: Bool,
        purpose: InlineTextEditPurpose,
        text: String,
        style: InlineTextStyle
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.bounds = bounds
        self.isEditingExistingAnnotation = isEditingExistingAnnotation
        self.purpose = purpose
        self.text = text
        self.style = style
    }
}

/// Persistent marker for the intentionally non-destructive replacement layer.
/// It is namespaced as a custom PDF annotation key and survives save/reopen.
enum InlineTextAnnotationIdentity {
    private static let visualReplacementKey = PDFAnnotationKey(
        rawValue: "/HwattakPDFVisualTextReplacement"
    )

    static func setVisualReplacement(_ enabled: Bool, on annotation: PDFAnnotation) {
        if enabled {
            annotation.setValue(true, forAnnotationKey: visualReplacementKey)
        } else {
            annotation.removeValue(forAnnotationKey: visualReplacementKey)
        }
    }

    static func isVisualReplacement(_ annotation: PDFAnnotation) -> Bool {
        (annotation.value(forAnnotationKey: visualReplacementKey) as? Bool) == true
    }
}

/// Geometry rules are kept independent from PDFView so they can be tested
/// without opening a window. All values here are PDF page coordinates.
enum InlineTextGeometry {
    static let defaultWidth: CGFloat = 260
    static let defaultHeight: CGFloat = 64
    static let minimumWidth: CGFloat = 48
    static let minimumHeight: CGFloat = 24

    static func defaultBounds(at point: CGPoint, within pageBounds: CGRect) -> CGRect {
        let size = CGSize(
            width: min(defaultWidth, max(minimumWidth, pageBounds.width)),
            height: min(defaultHeight, max(minimumHeight, pageBounds.height))
        )
        return clamped(
            CGRect(
                x: point.x,
                // PDF coordinates grow upward. The click denotes the visual
                // top-left of the new text box, matching the old sheet path.
                y: point.y - size.height,
                width: size.width,
                height: size.height
            ),
            within: pageBounds
        )
    }

    static func clamped(_ requested: CGRect, within pageBounds: CGRect) -> CGRect {
        guard
            pageBounds.width > 0,
            pageBounds.height > 0,
            requested.origin.x.isFinite,
            requested.origin.y.isFinite,
            requested.width.isFinite,
            requested.height.isFinite
        else { return .zero }

        let width = min(pageBounds.width, max(minimumWidth, abs(requested.width)))
        let height = min(pageBounds.height, max(minimumHeight, abs(requested.height)))
        return CGRect(
            x: min(max(requested.minX, pageBounds.minX), pageBounds.maxX - width),
            y: min(max(requested.minY, pageBounds.minY), pageBounds.maxY - height),
            width: width,
            height: height
        )
    }

    /// Places the floating inspector inside the current PDF viewport.
    /// Narrow split views receive a narrower panel; their style controls live
    /// in a horizontally scrollable two-row strip, so no control is lost.
    static func editorPanelFrame(
        targetRect: CGRect,
        viewportBounds: CGRect,
        purpose: InlineTextEditPurpose
    ) -> CGRect {
        let margin: CGFloat = 12
        let availableWidth = max(1, viewportBounds.width - margin * 2)
        // Use the actual available width, even during a narrow split-view
        // animation, rather than drawing controls outside the viewport.
        let width = min(620, availableWidth)
        let height: CGFloat = purpose == .visualReplacement ? 246 : 216
        var x = targetRect.minX
        var y = targetRect.maxY + 8
        x = min(max(viewportBounds.minX + margin, x), viewportBounds.maxX - width - margin)
        if y + height > viewportBounds.maxY - 8 {
            y = targetRect.minY - height - 8
        }
        // When height is temporarily tiny during a split-view animation, pin
        // the panel to the viewport origin. The containing PDF view clips it
        // until the next normal layout rather than moving it offscreen.
        y = min(
            max(viewportBounds.minY + 8, y),
            max(viewportBounds.minY + 8, viewportBounds.maxY - height - 8)
        )
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Complete mutable state of a FreeText annotation.
///
/// Undo must restore more than `contents`: changing font, color, bounds, or the
/// app identity marker is equally a document edit. Capturing every field before
/// mutation makes one inline session exactly one reversible history command.
struct PDFTextAnnotationSnapshot {
    let contents: String?
    let bounds: CGRect
    let font: NSFont?
    let fontColor: NSColor?
    let color: NSColor
    let alignment: NSTextAlignment
    let name: Any?
    let storedKind: EditableAnnotationKind?
    let isVisualReplacement: Bool
    let modificationDate: Date?

    init(annotation: PDFAnnotation) {
        contents = annotation.contents
        bounds = annotation.bounds
        font = annotation.font
        fontColor = annotation.fontColor
        color = annotation.color
        alignment = annotation.alignment
        name = annotation.value(forAnnotationKey: .name)
        storedKind = EditableAnnotationIdentity.storedKind(of: annotation)
        isVisualReplacement = InlineTextAnnotationIdentity.isVisualReplacement(annotation)
        modificationDate = annotation.modificationDate
    }

    func apply(to annotation: PDFAnnotation) {
        annotation.contents = contents
        annotation.bounds = bounds
        annotation.font = font
        annotation.fontColor = fontColor
        annotation.color = color
        annotation.alignment = alignment
        if let name {
            annotation.setValue(name, forAnnotationKey: .name)
        } else {
            annotation.removeValue(forAnnotationKey: .name)
        }
        EditableAnnotationIdentity.restoreStoredKind(storedKind, to: annotation)
        InlineTextAnnotationIdentity.setVisualReplacement(isVisualReplacement, on: annotation)
        annotation.modificationDate = modificationDate
    }
}

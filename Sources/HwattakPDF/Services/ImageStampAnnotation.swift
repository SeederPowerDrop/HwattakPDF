// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

enum ImageAnnotationIdentity {
    static let namePrefix = "HwattakPDF-Image-"
    private static let legacyNamePrefix = "VibePDF-Annotation-"

    static func assign(to annotation: PDFAnnotation) -> String {
        let identifier = "\(namePrefix)\(UUID().uuidString)"
        annotation.setValue(identifier, forAnnotationKey: .name)
        EditableAnnotationIdentity.assign(.image, to: annotation)
        return identifier
    }

    static func isEditableImage(_ annotation: PDFAnnotation) -> Bool {
        let type = normalizedType(of: annotation)
        if let storedKind = EditableAnnotationIdentity.storedKind(of: annotation) {
            return storedKind == .image && type == "Stamp"
        }
        let identifier = annotation.value(forAnnotationKey: .name) as? String
        if EditableAnnotationIdentity.isSignatureIdentifier(identifier) {
            return false
        }
        if let identifier,
           identifier.hasPrefix(namePrefix) || identifier.hasPrefix(legacyNamePrefix)
        {
            return type == "Stamp"
        }
        return annotation is ImageStampAnnotation
    }

    private static func normalizedType(of annotation: PDFAnnotation) -> String? {
        annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum EditableAnnotationKind: String, Equatable {
    case image
    case signature
    case freeText

    var canResize: Bool {
        self == .image || self == .signature
    }

    var hasImageEditingMenu: Bool {
        self == .image
    }
}

/// Identifies page content that this app placed or explicitly adopted for
/// editing. Keeping this separate from `ImageAnnotationIdentity` prevents
/// image-only crop and layer operations from accidentally including signatures
/// or free-text annotations.
enum EditableAnnotationIdentity {
    private static let kindKey = PDFAnnotationKey(rawValue: "/HwattakPDFKind")
    private static let signaturePrefixes = ["VibePDF-Signature-", "HwattakPDF-Signature-"]
    private static let freeTextPrefixes = ["VibePDF-Annotation-", "HwattakPDF-Annotation-"]

    static func assign(_ kind: EditableAnnotationKind, to annotation: PDFAnnotation) {
        annotation.setValue(kind.rawValue, forAnnotationKey: kindKey)
    }

    /// Used by undo when an existing third-party FreeText annotation was
    /// temporarily adopted for app editing.
    static func restoreStoredKind(
        _ kind: EditableAnnotationKind?,
        to annotation: PDFAnnotation
    ) {
        if let kind {
            annotation.setValue(kind.rawValue, forAnnotationKey: kindKey)
        } else {
            annotation.removeValue(forAnnotationKey: kindKey)
        }
    }

    static func kind(of annotation: PDFAnnotation) -> EditableAnnotationKind? {
        let type = annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let identifier = annotation.value(forAnnotationKey: .name) as? String

        if let storedKind = storedKind(of: annotation) {
            switch (storedKind, type) {
            case (.image, "Stamp"), (.signature, "Stamp"), (.freeText, "FreeText"):
                return storedKind
            default:
                return nil
            }
        }
        if type == "Stamp", isSignatureIdentifier(identifier) {
            return .signature
        }
        if ImageAnnotationIdentity.isEditableImage(annotation) {
            return .image
        }
        if
            type == "FreeText",
            let identifier,
            freeTextPrefixes.contains(where: identifier.hasPrefix)
        {
            return .freeText
        }
        return nil
    }

    static func storedKind(of annotation: PDFAnnotation) -> EditableAnnotationKind? {
        guard let rawValue = annotation.value(forAnnotationKey: kindKey) as? String else {
            return nil
        }
        return EditableAnnotationKind(rawValue: rawValue)
    }

    fileprivate static func isSignatureIdentifier(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return signaturePrefixes.contains(where: identifier.hasPrefix)
    }
}

/// The source image is flattened into a normal PDF appearance when PDFKit
/// serializes the custom annotation. Do not archive this subclass as an app
/// object; only its PDF representation is persisted.
final class ImageStampAnnotation: PDFAnnotation {
    /// PDFKit asks an annotation to draw both on screen and while producing its
    /// saved appearance stream. Drawing the complete source into a clipped PDF
    /// rectangle would look correct, but the PDF image XObject could still
    /// contain every hidden pixel. This cache contains a *detached raster* of
    /// only the visible crop, so serialization never receives the original.
    private struct SanitizedRasterCache {
        let normalizedCropRect: CGRect
        let image: CGImage
    }

    private let sourceImage: NSImage
    private(set) var normalizedCropRect: CGRect
    private var sanitizedRasterCache: SanitizedRasterCache?

    var sourceImageAspectRatio: CGFloat {
        sourceImage.size.width / max(1, sourceImage.size.height)
    }

    init(image: NSImage, bounds: CGRect, normalizedCropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
        sourceImage = image
        self.normalizedCropRect = ImageAnnotationGeometry.unitRect(normalizedCropRect)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        PDFAnnotationPrivacy.clearImplicitAuthor(on: self)
        shouldDisplay = true
        shouldPrint = true
        modificationDate = Date()
    }

    required init?(coder: NSCoder) {
        // This subclass is intentionally reconstructed from the PDF appearance,
        // never from an NSKeyedArchive. Returning `nil` is important here: a
        // malformed or third-party archive should be rejected instead of
        // terminating the whole app with `fatalError`.
        return nil
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        // PDFKit's default Stamp renderer paints a placeholder box and an X.
        // Opaque inserted images happened to cover it, but it showed through
        // the transparent background of signatures. This subclass owns the
        // complete appearance.
        //
        // Security note: do not restore the old "draw full image outside the
        // bounds, then clip" implementation here. PDF clipping hides pixels
        // visually but does not remove them from the saved image XObject. The
        // helper below allocates a new pixel buffer containing only the crop.
        guard let croppedImage = privacySafeCroppedRaster() else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.clip(to: bounds)
        context.draw(croppedImage, in: bounds)
        context.restoreGState()
    }

    func updateCropRect(_ cropRect: CGRect) {
        let normalized = ImageAnnotationGeometry.unitRect(cropRect)
        guard normalized.width > 0, normalized.height > 0 else { return }
        normalizedCropRect = normalized
        // Always regenerate from `sourceImage`, never from the previous crop.
        // That keeps repeated crop/undo/redo operations from accumulating JPEG
        // or resampling loss while the document remains open.
        sanitizedRasterCache = nil
        modificationDate = Date()
    }

    /// Returns a raster whose backing provider contains no pixels outside the
    /// selected crop. `CGImage.cropping(to:)` may share its parent's data
    /// provider, so a second render into a newly allocated bitmap is deliberate
    /// rather than redundant: only that detached bitmap is handed to PDFKit.
    private func privacySafeCroppedRaster() -> CGImage? {
        let crop = normalizedCropRect
        guard crop.width > 0, crop.height > 0 else { return nil }
        if
            let cached = sanitizedRasterCache,
            cached.normalizedCropRect == crop
        {
            return cached.image
        }
        guard
            let source = sourceImage.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            ),
            source.width > 0,
            source.height > 0
        else {
            return nil
        }

        let pixelBounds = Self.pixelCropBounds(
            for: crop,
            imageWidth: source.width,
            imageHeight: source.height
        )
        guard
            pixelBounds.width >= 1,
            pixelBounds.height >= 1,
            let sharedCrop = source.cropping(to: pixelBounds),
            let detachedCrop = Self.detachedSRGBCopy(of: sharedCrop)
        else {
            return nil
        }

        sanitizedRasterCache = SanitizedRasterCache(
            normalizedCropRect: crop,
            image: detachedCrop
        )
        return detachedCrop
    }

    /// Converts the PDF/editor crop (origin at the visual bottom-left) to
    /// `CGImage` pixel coordinates (origin at the top-left). Rounding outward
    /// retains the edge pixels touched by a fractional crop. Every retained
    /// pixel is then stretched over the visible annotation bounds, so the PDF
    /// contains no additional clipped or otherwise hidden rows/columns.
    private static func pixelCropBounds(
        for crop: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let width = CGFloat(imageWidth)
        let height = CGFloat(imageHeight)
        let minimumX = max(0, min(width - 1, floor(crop.minX * width)))
        let maximumX = max(minimumX + 1, min(width, ceil(crop.maxX * width)))

        // The vertical conversion is intentionally expressed with maxY first:
        // the editor's top edge is row zero in a CGImage.
        let minimumY = max(0, min(height - 1, floor((1 - crop.maxY) * height)))
        let maximumY = max(minimumY + 1, min(height, ceil((1 - crop.minY) * height)))
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    /// Materializes a crop into its own standard 8-bit sRGB/alpha buffer.
    /// Copying at identical pixel dimensions avoids an extra scaling pass; a
    /// later crop is still derived from the in-memory original, not this copy.
    private static func detachedSRGBCopy(of image: CGImage) -> CGImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let bitmap = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }
        bitmap.setBlendMode(.copy)
        bitmap.interpolationQuality = .none
        bitmap.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return bitmap.makeImage()
    }
}

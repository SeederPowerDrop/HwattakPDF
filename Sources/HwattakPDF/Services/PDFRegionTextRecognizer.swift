// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Vision

/// Only the text visible inside a user-drawn region, in original PDF page coordinates.
struct PDFRegionTextFragment: Equatable, Sendable {
    let text: String
    let bounds: CGRect
}

/// An immutable bitmap is safe to hand to Vision without sharing live PDFKit objects.
/// `imageToPage` accepts pixel coordinates with a lower-left origin.
struct PDFRegionTextSnapshot: @unchecked Sendable {
    let image: CGImage
    let imageToPage: CGAffineTransform
}

enum PDFRegionTextRecognitionError: LocalizedError {
    case invalidRegion
    case renderingFailed
    case copyingNotAllowed

    var errorDescription: String? {
        switch self {
        case .invalidRegion:
            L10n.string("selection.region.invalid", defaultValue: "페이지 안에서 읽을 영역을 드래그해 주세요.")
        case .renderingFailed:
            L10n.string("selection.region.render_failed", defaultValue: "선택한 영역을 읽을 수 없습니다. 다시 시도해 주세요.")
        case .copyingNotAllowed:
            L10n.string("selection.region.copying_not_allowed", defaultValue: "이 PDF의 현재 권한으로는 텍스트를 복사할 수 없습니다.")
        }
    }
}

enum PDFRegionTextRecognizer {
    static let maximumDimension: CGFloat = 2_400
    static let maximumPixelCount: CGFloat = 6_000_000
    private static let preferredScale: CGFloat = 3

    /// Render just the requested region. No source bytes, OCR checkpoints, or
    /// rewritten PDFs are created, and the document's text layer is untouched.
    @MainActor
    static func snapshot(page: PDFPage, region: CGRect) throws -> PDFRegionTextSnapshot {
        if let document = page.document,
           document.isLocked || (document.isEncrypted
               && document.permissionsStatus != .owner && !document.allowsCopying) {
            throw PDFRegionTextRecognitionError.copyingNotAllowed
        }
        guard let source = page.pageRef else {
            throw PDFRegionTextRecognitionError.renderingFailed
        }
        let cropBox = source.getBoxRect(.cropBox)
        guard isUsable(region), isUsable(cropBox) else {
            throw PDFRegionTextRecognitionError.invalidRegion
        }
        let clippedRegion = region.standardized.intersection(cropBox)
        guard isUsable(clippedRegion) else {
            throw PDFRegionTextRecognitionError.invalidRegion
        }

        // After a PDFKit rotation edit, pageRef.rotationAngle can report the
        // new value while getDrawingTransform still applies the cached /Rotate.
        // Draw raw page coordinates using the live page rotation explicitly.
        let pageToDisplay = displayTransform(cropBox: cropBox, rotation: page.rotation)
        let displayRegion = clippedRegion.applying(pageToDisplay)
        guard isUsable(displayRegion) else {
            throw PDFRegionTextRecognitionError.invalidRegion
        }
        let dimensionScale = maximumDimension / max(displayRegion.width, displayRegion.height)
        let pixelScale = sqrt(maximumPixelCount / (displayRegion.width * displayRegion.height))
        let scale = min(preferredScale, dimensionScale, pixelScale)
        let width = max(1, Int((displayRegion.width * scale).rounded(.down)))
        let height = max(1, Int((displayRegion.height * scale).rounded(.down)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PDFRegionTextRecognitionError.renderingFailed
        }
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(imageRect)
        context.clip(to: imageRect)
        let pageToImage = pageToDisplay
            .concatenating(CGAffineTransform(
                translationX: -displayRegion.minX,
                y: -displayRegion.minY
            ))
            .concatenating(CGAffineTransform(
                scaleX: CGFloat(width) / displayRegion.width,
                y: CGFloat(height) / displayRegion.height
            ))
        context.concatenate(pageToImage)
        // PDFPage.draw includes displayed annotations (including opaque text
        // replacements). Cancel its own crop/rotation transform first because
        // pageToImage already maps original page coordinates to this bitmap.
        context.concatenate(page.transform(for: .cropBox).inverted())
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else {
            throw PDFRegionTextRecognitionError.renderingFailed
        }
        return PDFRegionTextSnapshot(image: image, imageToPage: pageToImage.inverted())
    }

    static func recognize(_ snapshot: PDFRegionTextSnapshot) async throws -> [PDFRegionTextFragment] {
        try Task.checkCancellation()
        let cancellation = PDFRegionRecognitionCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try autoreleasepool {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                cancellation.register(request)
                defer { cancellation.unregister() }
                try Task.checkCancellation()
                let handler = VNImageRequestHandler(
                    cgImage: snapshot.image,
                    orientation: .up,
                    options: [:]
                )
                try handler.perform([request])
                try Task.checkCancellation()
                let imageRect = CGRect(
                    x: 0, y: 0,
                    width: snapshot.image.width,
                    height: snapshot.image.height
                )
                // Vision returns observations in reading order. Keep that order
                // instead of sorting page coordinates, which would break /Rotate.
                return (request.results ?? []).prefix(2_048).compactMap { observation -> PDFRegionTextFragment? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    let normalized = observation.boundingBox
                    let pixelBounds = CGRect(
                        x: normalized.minX * imageRect.width,
                        y: normalized.minY * imageRect.height,
                        width: normalized.width * imageRect.width,
                        height: normalized.height * imageRect.height
                    ).intersection(imageRect)
                    guard isUsable(pixelBounds) else { return nil }
                    return PDFRegionTextFragment(
                        text: text,
                        bounds: pixelBounds.applying(snapshot.imageToPage)
                    )
                }
            }
        }
        return try await withTaskCancellationHandler {
            let fragments = try await worker.value
            try Task.checkCancellation()
            return fragments
        } onCancel: {
            worker.cancel()
            cancellation.cancel()
        }
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && !rect.isNull && !rect.isEmpty
    }

    private static func displayTransform(cropBox: CGRect, rotation: Int) -> CGAffineTransform {
        switch ((rotation % 360) + 360) % 360 {
        case 0:
            return CGAffineTransform(translationX: -cropBox.minX, y: -cropBox.minY)
        case 90:
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: -cropBox.minY, ty: cropBox.maxX)
        case 180:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: cropBox.maxX, ty: cropBox.maxY)
        case 270:
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: cropBox.maxY, ty: -cropBox.minX)
        default:
            // PDF /Rotate is defined in quarter turns. Keep an unusual live
            // value bounded and aligned if PDFKit permits one nevertheless.
            let transform = CGAffineTransform(rotationAngle: -CGFloat(rotation % 360) * .pi / 180)
            let rotatedCrop = cropBox.applying(transform)
            return transform.concatenating(CGAffineTransform(
                translationX: -rotatedCrop.minX,
                y: -rotatedCrop.minY
            ))
        }
    }
}

/// VNRequest performs synchronously, so cancelling only its detached task would
/// leave recognition running until completion. Forward cancellation to Vision.
private final class PDFRegionRecognitionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRecognizeTextRequest?
    private var isCancelled = false

    func register(_ request: VNRecognizeTextRequest) {
        lock.lock()
        self.request = request
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { request.cancel() }
    }

    func unregister() {
        lock.lock()
        request = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let current = request
        lock.unlock()
        current?.cancel()
    }
}

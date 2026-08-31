// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

enum AppPerformanceSettings {
    static let efficientRenderingEnabledKey = "performance.efficientRenderingEnabled"
    static let defaultEfficientRenderingEnabled = true

    static var isEfficientRenderingEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: efficientRenderingEnabledKey) != nil else {
            return defaultEfficientRenderingEnabled
        }
        return defaults.bool(forKey: efficientRenderingEnabledKey)
    }
}

/// Bounded raster policy shared by page thumbnails and tests.
///
/// PDF crop boxes are untrusted numbers. They may be non-finite or have an
/// extreme aspect ratio. Resolve those values before multiplying or converting
/// to `Int`, otherwise a tiny PDF can request a multi-gigabyte bitmap.
struct PDFThumbnailRenderingPolicy: Equatable {
    let efficientRenderingEnabled: Bool

    var cacheCountLimit: Int { efficientRenderingEnabled ? 80 : 144 }
    var cacheCostLimit: Int {
        (efficientRenderingEnabled ? 72 : 144) * 1_024 * 1_024
    }
    var maximumDimension: CGFloat { efficientRenderingEnabled ? 1_600 : 2_400 }
    var maximumPixelCount: CGFloat {
        efficientRenderingEnabled ? 2_400_000 : 5_000_000
    }
    var renderScale: CGFloat { efficientRenderingEnabled ? 0.8 : 1 }

    func targetSize(
        pageBounds: CGRect,
        rotation: Int,
        requestedWidth: CGFloat
    ) -> CGSize {
        let rawWidth = abs(pageBounds.width)
        let rawHeight = abs(pageBounds.height)
        let rotated = abs(rotation % 180) == 90
        let logicalWidth = rotated ? rawHeight : rawWidth
        let logicalHeight = rotated ? rawWidth : rawHeight
        let rawAspect = logicalWidth.isFinite
            && logicalHeight.isFinite
            && logicalWidth > 0
            && logicalHeight > 0
            ? logicalHeight / logicalWidth
            : 1.414
        let aspect = min(8, max(0.125, rawAspect.isFinite ? rawAspect : 1.414))
        let finiteRequested = requestedWidth.isFinite ? requestedWidth : 80
        var width = min(maximumDimension, max(80, finiteRequested * renderScale))
        var height = width * aspect

        let largest = max(width, height)
        if largest > maximumDimension {
            let reduction = maximumDimension / largest
            width *= reduction
            height *= reduction
        }
        let pixels = width * height
        if pixels.isFinite, pixels > maximumPixelCount {
            let reduction = sqrt(maximumPixelCount / pixels)
            width *= reduction
            height *= reduction
        }
        return CGSize(
            width: max(1, width.rounded(.up)),
            height: max(1, height.rounded(.up))
        )
    }

    func estimatedBitmapCost(for size: CGSize) -> Int {
        let pixels = max(1, min(maximumPixelCount, size.width * size.height))
        return max(1, min(cacheCostLimit, Int(pixels.rounded(.up)) * 4))
    }
}

/// A finite two-dimensional budget for operations that must rasterize a PDF
/// page. Dimension and total-pixel ceilings are both required: either one alone
/// still allows an extreme page aspect ratio to allocate excessive memory.
struct PDFRasterBudget: Equatable {
    let maximumDimension: CGFloat
    let maximumPixelCount: CGFloat

    func boundedPixelSize(logicalSize: CGSize, scale requestedScale: CGFloat) -> CGSize {
        let width = abs(logicalSize.width)
        let height = abs(logicalSize.height)
        let scale = requestedScale.isFinite && requestedScale > 0 ? requestedScale : 1
        guard
            width.isFinite,
            height.isFinite,
            width > 0,
            height > 0,
            maximumDimension.isFinite,
            maximumDimension > 0,
            maximumPixelCount.isFinite,
            maximumPixelCount > 0
        else {
            return CGSize(width: 1, height: 1)
        }

        // Normalize first so `width * scale` and `width * height` never need
        // to overflow before the budget has a chance to clamp them.
        let sourceLargest = max(width, height)
        let normalizedWidth = width / sourceLargest
        let normalizedHeight = height / sourceLargest
        guard
            normalizedWidth.isFinite,
            normalizedHeight.isFinite,
            normalizedWidth > 0,
            normalizedHeight > 0
        else {
            return CGSize(width: 1, height: 1)
        }
        let scaledLargest = scale <= maximumDimension / sourceLargest
            ? sourceLargest * scale
            : maximumDimension
        let pixelLimitedLargest = sqrt(
            maximumPixelCount / (normalizedWidth * normalizedHeight)
        )
        let targetLargest = min(maximumDimension, scaledLargest, pixelLimitedLargest)
        let pixelWidth = normalizedWidth * targetLargest
        let pixelHeight = normalizedHeight * targetLargest
        return CGSize(
            width: max(1, pixelWidth.rounded(.down)),
            height: max(1, pixelHeight.rounded(.down))
        )
    }
}

// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import ImageIO

enum BoundedImageLoadingError: LocalizedError {
    case unreadable
    case unsafeFile
    case sourceTooLarge
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .unreadable, .decodeFailed:
            L10n.string("error.image_open")
        case .unsafeFile:
            L10n.string(
                "error.image_unsafe_file",
                defaultValue: "일반 이미지 파일만 추가할 수 있습니다."
            )
        case .sourceTooLarge:
            L10n.string(
                "error.image_too_large",
                defaultValue: "이미지가 안전한 파일·픽셀 크기 제한을 초과했습니다. 더 작은 사본을 사용하세요."
            )
        }
    }
}

/// Reads image metadata without decoding, then creates one bounded first-frame
/// raster through ImageIO. This prevents compressed image bombs from asking
/// `NSImage(contentsOf:)` to materialize an arbitrary pixel buffer on the main
/// actor before the app can inspect it.
struct BoundedImageLoader {
    static let maximumFileBytes = 64 * 1_024 * 1_024
    static let maximumSourcePixelCount: UInt64 = 120_000_000

    let efficientRenderingEnabled: Bool

    init(
        efficientRenderingEnabled: Bool = AppPerformanceSettings.isEfficientRenderingEnabled
    ) {
        self.efficientRenderingEnabled = efficientRenderingEnabled
    }

    func load(at url: URL) throws -> NSImage {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            throw BoundedImageLoadingError.unreadable
        }
        guard
            values.isRegularFile == true,
            values.isDirectory != true,
            values.isSymbolicLink != true
        else {
            throw BoundedImageLoadingError.unsafeFile
        }
        guard let fileSize = values.fileSize, (1...Self.maximumFileBytes).contains(fileSize) else {
            throw BoundedImageLoadingError.sourceTooLarge
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber
        else {
            throw BoundedImageLoadingError.unreadable
        }

        let sourceWidth = widthNumber.uint64Value
        let sourceHeight = heightNumber.uint64Value
        let (sourcePixels, overflow) = sourceWidth.multipliedReportingOverflow(by: sourceHeight)
        guard
            !overflow,
            sourceWidth > 0,
            sourceHeight > 0,
            sourcePixels <= Self.maximumSourcePixelCount
        else {
            throw BoundedImageLoadingError.sourceTooLarge
        }

        let budget = efficientRenderingEnabled
            ? PDFRasterBudget(maximumDimension: 3_200, maximumPixelCount: 6_000_000)
            : PDFRasterBudget(maximumDimension: 4_096, maximumPixelCount: 12_000_000)
        let target = budget.boundedPixelSize(
            logicalSize: CGSize(width: CGFloat(sourceWidth), height: CGFloat(sourceHeight)),
            scale: 1
        )
        let maximumPixelSize = max(1, Int(max(target.width, target.height).rounded(.down)))
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw BoundedImageLoadingError.decodeFailed
        }
        return NSImage(
            cgImage: image,
            size: CGSize(width: image.width, height: image.height)
        )
    }
}

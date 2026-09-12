// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// The user-visible conversion trade-off and the concrete limits converters
/// should apply. Keeping these values in one type makes the UI estimate and the
/// eventual conversion use the same assumptions.
enum PDFProcessingProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case stability
    case speed

    var id: String { rawValue }

    /// Localization keys are exposed instead of embedding one language here.
    var titleLocalizationKey: String {
        switch self {
        case .stability: "builder.profile.stability"
        case .speed: "builder.profile.speed"
        }
    }

    var detailLocalizationKey: String {
        switch self {
        case .stability: "builder.profile.stability_detail"
        case .speed: "builder.profile.speed_detail"
        }
    }

    /// PDFKit work remains serial in both modes. Speed comes from smaller
    /// rasters, faster OCR and shorter HTML resource settling, while avoiding
    /// concurrent mutation of PDF documents.
    var maximumConcurrentPageOperations: Int {
        1
    }

    var recommendedOCRDPI: CGFloat {
        switch self {
        case .stability: 240
        case .speed: 160
        }
    }

    var usesAccurateOCRRecognition: Bool { self == .stability }

    func applying(to configuration: OCRConfiguration) -> OCRConfiguration {
        var result = configuration
        result.renderDPI = recommendedOCRDPI
        result.useLanguageCorrection = usesAccurateOCRRecognition
        result.recognitionQuality = usesAccurateOCRRecognition ? .accurate : .fast
        return result
    }

    var maximumDecodedImagePixels: Int {
        switch self {
        case .stability: 12_000_000
        case .speed: 6_000_000
        }
    }

    var htmlNavigationTimeout: TimeInterval {
        switch self {
        case .stability: 45
        case .speed: 20
        }
    }

    var htmlSettlingDelay: TimeInterval {
        switch self {
        case .stability: 0.6
        case .speed: 0.15
        }
    }
}

/// A lightweight, Sendable description of one conversion input. It contains
/// only metadata needed for estimation, so callers can calculate a plan without
/// decoding full-resolution images or loading HTML resources.
enum PDFConversionEstimateSource: Equatable, Sendable {
    case image(byteCount: Int64?, pixelCount: Int64?)
    case importedPDFPage(sourceFileByteCount: Int64?, sourcePageCount: Int?)
    case blankPage(widthPoints: Double, heightPoints: Double)
    case html(
        byteCount: Int64,
        linkedResourceByteCount: Int64,
        estimatedPageCount: Int
    )

    /// Reads only file metadata and the image header. Corrupt or inaccessible
    /// metadata remains nil and is handled by conservative estimator defaults.
    static func imageFile(at url: URL) -> Self {
        .image(
            byteCount: metadataByteCount(at: url),
            pixelCount: imagePixelCount(at: url)
        )
    }

    /// The estimator apportions the source PDF size across its pages.
    static func importedPDFPage(
        at url: URL,
        knownPageCount: Int? = nil
    ) -> Self {
        let pageCount = knownPageCount ?? PDFDocument(url: url)?.pageCount
        return .importedPDFPage(
            sourceFileByteCount: metadataByteCount(at: url),
            sourcePageCount: pageCount
        )
    }

    /// Builds a low-cost estimate descriptor without starting WebKit.
    static func htmlFile(
        at url: URL,
        linkedResourceByteCount: Int64 = 0,
        estimatedPageCount: Int? = nil
    ) -> Self {
        let bytes = metadataByteCount(at: url) ?? 0
        return .html(
            byteCount: bytes,
            linkedResourceByteCount: max(0, linkedResourceByteCount),
            estimatedPageCount: estimatedPageCount
                ?? inferredHTMLPageCount(byteCount: bytes)
        )
    }

    static func inferredHTMLPageCount(byteCount: Int64) -> Int {
        // Roughly 32 KiB of local markup per printed page, bounded because CSS,
        // fonts and remote resources can make byte count a poor page predictor.
        let normalizedBytes = max(0, min(byteCount, 512 * 1_024 * 1_024))
        let inferred = 1 + Int(normalizedBytes / (32 * 1_024))
        return min(500, max(1, inferred))
    }

    private static func metadataByteCount(at url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size >= 0
        else { return nil }
        return Int64(size)
    }

    private static func imagePixelCount(at url: URL) -> Int64? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
            width > 0,
            height > 0,
            width <= Int64.max / height
        else { return nil }
        return width * height
    }
}

struct PDFConversionEstimate: Equatable, Sendable {
    enum Confidence: String, Sendable {
        case high
        case medium
        case low

        var localizationKey: String {
            "builder.estimate.confidence.\(rawValue)"
        }
    }

    let profile: PDFProcessingProfile
    let pageCount: Int
    let inputByteCount: Int64
    let estimatedDuration: TimeInterval
    let durationRange: ClosedRange<TimeInterval>
    let estimatedOutputByteCount: Int64
    let outputByteRange: ClosedRange<Int64>
    let confidence: Confidence

    /// Compact strings suitable for a SwiftUI `Text` value. Ranges intentionally
    /// communicate uncertainty instead of presenting false single-value precision.
    var formattedDuration: String {
        Self.format(durationRange: durationRange)
    }

    var formattedOutputSize: String {
        Self.format(byteRange: outputByteRange)
    }

    var formattedEstimatedDuration: String {
        Self.format(duration: estimatedDuration)
    }

    var formattedEstimatedOutputSize: String {
        Self.format(bytes: estimatedOutputByteCount)
    }

    static func format(duration: TimeInterval) -> String {
        let value = max(0, duration)
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.currentLanguage.locale
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = value == 0 ? .pad : .dropAll
        if value >= 3_600 {
            formatter.allowedUnits = [.hour, .minute]
        } else if value >= 60 {
            formatter.allowedUnits = [.minute, .second]
        } else {
            formatter.allowedUnits = [.second]
        }
        if let formatted = formatter.string(from: ceil(value)) {
            return formatted
        }
        let fallback = MeasurementFormatter()
        fallback.locale = L10n.currentLanguage.locale
        fallback.unitStyle = .short
        fallback.unitOptions = .providedUnit
        fallback.numberFormatter.maximumFractionDigits = 0
        return fallback.string(
            from: Measurement(value: ceil(value), unit: UnitDuration.seconds)
        )
    }

    static func format(bytes: Int64) -> String {
        let byteCount = max(0, bytes)
        let value: Double
        let unit: UnitInformationStorage
        switch byteCount {
        case 1_000_000_000...:
            value = Double(byteCount) / 1_000_000_000
            unit = .gigabytes
        case 1_000_000...:
            value = Double(byteCount) / 1_000_000
            unit = .megabytes
        case 1_000...:
            value = Double(byteCount) / 1_000
            unit = .kilobytes
        default:
            value = Double(byteCount)
            unit = .bytes
        }
        let formatter = MeasurementFormatter()
        formatter.locale = L10n.currentLanguage.locale
        formatter.unitStyle = .short
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = unit == .bytes ? 0 : 1
        formatter.numberFormatter.minimumFractionDigits = 0
        return formatter.string(from: Measurement(value: value, unit: unit))
    }

    private static func format(durationRange: ClosedRange<TimeInterval>) -> String {
        let lower = format(duration: durationRange.lowerBound)
        let upper = format(duration: durationRange.upperBound)
        return lower == upper ? lower : "\(lower) - \(upper)"
    }

    private static func format(byteRange: ClosedRange<Int64>) -> String {
        let lower = format(bytes: byteRange.lowerBound)
        let upper = format(bytes: byteRange.upperBound)
        return lower == upper ? lower : "\(lower) - \(upper)"
    }
}

/// Produces deliberately bounded estimates. The values are planning hints, not
/// completion guarantees: disk speed, image codecs, HTML network resources and
/// Vision hardware can all move the actual result outside the displayed range.
enum PDFConversionEstimator {
    private enum Bound {
        static let maximumPages = 10_000
        static let maximumHTMLPagesPerDocument = 500
        static let maximumSourceBytes: Double = 16 * 1_024 * 1_024 * 1_024
        static let maximumPixelCount: Double = 160_000_000
        static let maximumDuration: TimeInterval = 24 * 60 * 60
        static let maximumOutputBytes: Double = 64 * 1_024 * 1_024 * 1_024
    }

    /// Convenience adapter for every source supported by the assembly model.
    static func sources(from items: [ImagePDFAssemblyItem]) -> [PDFConversionEstimateSource] {
        var pdfMetadata: [URL: (byteCount: Int64?, pageCount: Int?)] = [:]

        return items.map { item in
            switch item.source {
            case let .image(url):
                return .imageFile(at: url)

            case let .html(url):
                return .htmlFile(at: url)

            case let .pdfPage(url, _):
                let key = url.standardizedFileURL
                let metadata: (byteCount: Int64?, pageCount: Int?)
                if let cached = pdfMetadata[key] {
                    metadata = cached
                } else {
                    let descriptor = PDFConversionEstimateSource.importedPDFPage(at: url)
                    if case let .importedPDFPage(bytes, pages) = descriptor {
                        metadata = (bytes, pages)
                    } else {
                        metadata = (nil, nil)
                    }
                    pdfMetadata[key] = metadata
                }
                return .importedPDFPage(
                    sourceFileByteCount: metadata.byteCount,
                    sourcePageCount: metadata.pageCount
                )

            case let .blank(size):
                return .blankPage(
                    widthPoints: Double(size.width),
                    heightPoints: Double(size.height)
                )
            }
        }
    }

    static func estimate(
        assemblyItems: [ImagePDFAssemblyItem],
        additionalSources: [PDFConversionEstimateSource] = [],
        profile: PDFProcessingProfile,
        ocrEnabled: Bool,
        ocrLanguageCount: Int
    ) -> PDFConversionEstimate {
        estimate(
            sources: sources(from: assemblyItems) + additionalSources,
            profile: profile,
            ocrEnabled: ocrEnabled,
            ocrLanguageCount: ocrLanguageCount
        )
    }

    static func estimate(
        sources: [PDFConversionEstimateSource],
        profile: PDFProcessingProfile,
        ocrEnabled: Bool,
        ocrLanguageCount: Int
    ) -> PDFConversionEstimate {
        guard !sources.isEmpty else {
            return PDFConversionEstimate(
                profile: profile,
                pageCount: 0,
                inputByteCount: 0,
                estimatedDuration: 0,
                durationRange: 0...0,
                estimatedOutputByteCount: 0,
                outputByteRange: 0...0,
                confidence: .high
            )
        }

        var pageCount = 0
        var knownInputBytes = 0.0
        var duration = 0.25
        var outputBytes = 24.0 * 1_024
        var uncertainSourceCount = 0
        var htmlSourceCount = 0

        for source in sources {
            switch source {
            case let .image(byteCount, pixelCount):
                pageCount = boundedPageAdd(pageCount, 1)
                let bytes = boundedBytes(byteCount)
                let pixels = boundedPixels(pixelCount)
                knownInputBytes += bytes ?? 0
                if bytes == nil || pixels == nil { uncertainSourceCount += 1 }

                let megapixels = (pixels ?? 12_000_000) / 1_000_000
                let megabytes = (bytes ?? 4_000_000) / 1_000_000
                switch profile {
                case .stability:
                    duration += 0.42 + (megapixels * 0.075) + (megabytes * 0.012)
                case .speed:
                    duration += 0.18 + (megapixels * 0.032) + (megabytes * 0.006)
                }
                outputBytes += estimatedImageOutputBytes(
                    inputBytes: bytes,
                    pixelCount: pixels,
                    profile: profile
                )

            case let .importedPDFPage(sourceFileByteCount, sourcePageCount):
                pageCount = boundedPageAdd(pageCount, 1)
                let bytes = boundedBytes(sourceFileByteCount)
                let sourcePages = sourcePageCount.map { min(Bound.maximumPages, max(1, $0)) }
                if bytes == nil || sourcePages == nil { uncertainSourceCount += 1 }

                let apportionedBytes = (bytes ?? 2_000_000)
                    / Double(sourcePages ?? 1)
                knownInputBytes += apportionedBytes
                let pageMegabytes = apportionedBytes / 1_000_000
                duration += 0.19 + min(1.3, pageMegabytes * 0.032)
                outputBytes += min(20_000_000, max(24_000, apportionedBytes * 1.04))

            case let .blankPage(widthPoints, heightPoints):
                pageCount = boundedPageAdd(pageCount, 1)
                let area = boundedFinite(widthPoints * heightPoints, fallback: 501_155)
                let a4Scale = min(4, max(0.25, area / 501_155))
                duration += 0.025
                outputBytes += 4_000 + (4_000 * a4Scale)

            case let .html(byteCount, linkedResourceByteCount, estimatedPageCount):
                htmlSourceCount += 1
                let pages = min(
                    Bound.maximumHTMLPagesPerDocument,
                    max(1, estimatedPageCount)
                )
                pageCount = boundedPageAdd(pageCount, pages)
                let markupBytes = boundedBytes(byteCount) ?? 0
                let resourceBytes = boundedBytes(linkedResourceByteCount) ?? 0
                knownInputBytes += markupBytes + resourceBytes
                let totalMegabytes = (markupBytes + resourceBytes) / 1_000_000

                switch profile {
                case .stability:
                    duration += 1.35 + (Double(pages) * 0.68)
                        + min(8, totalMegabytes * 0.12)
                case .speed:
                    duration += 0.62 + (Double(pages) * 0.31)
                        + min(4, totalMegabytes * 0.055)
                }
                // Both WebKit modes use the same vector capture and PDF
                // composition. Their output size should therefore be equal
                // when the same local resources finish loading.
                outputBytes += (Double(pages) * 110_000)
                    + ((markupBytes + resourceBytes) * 0.60)
            }
        }

        let normalizedLanguageCount = ocrEnabled
            ? min(8, max(1, ocrLanguageCount))
            : 0
        if ocrEnabled, pageCount > 0 {
            let dpi = Double(profile.recommendedOCRDPI)
            let a4RenderedMegapixels = min(
                Double(profile.maximumDecodedImagePixels) / 1_000_000,
                (8.27 * 11.69 * dpi * dpi) / 1_000_000
            )
            let languageFactor: Double
            let secondsPerPage: Double
            switch profile {
            case .stability:
                languageFactor = 1 + (Double(normalizedLanguageCount - 1) * 0.10)
                secondsPerPage = 0.72 + (a4RenderedMegapixels * 0.24)
            case .speed:
                languageFactor = 1 + (Double(normalizedLanguageCount - 1) * 0.055)
                secondsPerPage = 0.31 + (a4RenderedMegapixels * 0.12)
            }
            duration += Double(pageCount) * secondsPerPage * languageFactor
            outputBytes += Double(pageCount)
                * Double(18_000 + (normalizedLanguageCount * 3_000))
        }

        // Account for final atomic write and reopen validation.
        duration += min(90, (outputBytes / 1_000_000) * 0.045)
        outputBytes += Double(pageCount) * 2_000

        duration = min(Bound.maximumDuration, max(0.5, duration))
        outputBytes = min(Bound.maximumOutputBytes, max(4_096, outputBytes))

        let unknownRatio = Double(uncertainSourceCount) / Double(max(1, sources.count))
        let htmlPenalty = htmlSourceCount > 0 ? 0.16 : 0
        let usesProfileSpecificProcessing = ocrEnabled || sources.contains { source in
            switch source {
            case .image, .html: true
            case .importedPDFPage, .blankPage: false
            }
        }
        let durationBaseUncertainty = usesProfileSpecificProcessing
            ? (profile == .stability ? 0.22 : 0.30)
            : 0.26
        let sizeBaseUncertainty = usesProfileSpecificProcessing
            ? (profile == .stability ? 0.27 : 0.34)
            : 0.30
        let durationUncertainty = min(
            0.68,
            durationBaseUncertainty
                + htmlPenalty
                + (unknownRatio * 0.24)
        )
        let sizeUncertainty = min(
            0.72,
            sizeBaseUncertainty
                + htmlPenalty
                + (unknownRatio * 0.22)
        )

        let durationLower = max(0.5, duration * (1 - durationUncertainty))
        let durationUpper = min(
            Bound.maximumDuration,
            max(durationLower, duration * (1 + durationUncertainty))
        )
        let outputLower = Int64(max(4_096, outputBytes * (1 - sizeUncertainty)))
        let outputUpper = Int64(min(
            Bound.maximumOutputBytes,
            max(Double(outputLower), outputBytes * (1 + sizeUncertainty))
        ))

        let confidence: PDFConversionEstimate.Confidence
        if htmlSourceCount > 0 || unknownRatio >= 0.5 {
            confidence = .low
        } else if uncertainSourceCount > 0 {
            confidence = .medium
        } else {
            confidence = .high
        }

        return PDFConversionEstimate(
            profile: profile,
            pageCount: pageCount,
            inputByteCount: Int64(min(Bound.maximumOutputBytes, knownInputBytes)),
            estimatedDuration: duration,
            durationRange: durationLower...durationUpper,
            estimatedOutputByteCount: Int64(outputBytes),
            outputByteRange: outputLower...outputUpper,
            confidence: confidence
        )
    }

    private static func estimatedImageOutputBytes(
        inputBytes: Double?,
        pixelCount: Double?,
        profile: PDFProcessingProfile
    ) -> Double {
        let effectivePixels = min(
            pixelCount ?? 12_000_000,
            Double(profile.maximumDecodedImagePixels)
        )
        let bytesPerMegapixel = profile == .stability ? 430_000.0 : 235_000.0
        let pixelEstimate = (effectivePixels / 1_000_000) * bytesPerMegapixel
        let blended = inputBytes.map { ($0 * 0.42) + (pixelEstimate * 0.58) }
            ?? pixelEstimate
        return min(25_000_000, max(40_000, blended + 18_000))
    }

    private static func boundedPageAdd(_ current: Int, _ addition: Int) -> Int {
        min(Bound.maximumPages, current + min(Bound.maximumPages, max(0, addition)))
    }

    private static func boundedBytes(_ value: Int64?) -> Double? {
        guard let value, value >= 0 else { return nil }
        return min(Bound.maximumSourceBytes, Double(value))
    }

    private static func boundedPixels(_ value: Int64?) -> Double? {
        guard let value, value > 0 else { return nil }
        return min(Bound.maximumPixelCount, Double(value))
    }

    private static func boundedFinite(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
        return min(4_000_000, value)
    }
}

// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class HTMLPDFConversionTests: XCTestCase {
    func testSuggestedFilenameReplacesHTMLOrHTMExtension() {
        XCTAssertEqual(
            HTMLPDFConverter.suggestedFileName(
                for: URL(fileURLWithPath: "/tmp/monthly.report.html")
            ),
            "monthly.report.pdf"
        )
        XCTAssertEqual(
            HTMLPDFConverter.suggestedFileName(
                for: URL(fileURLWithPath: "/tmp/archive.htm")
            ),
            "archive.pdf"
        )
    }

    @MainActor
    func testLocalHTMLWithCSSImageAndTextRendersAsMultipageA4PDF() async throws {
        // WKWebView does not need a visible window, but initializing NSApplication
        // here makes its process lifecycle deterministic under `swift test`.
        _ = NSApplication.shared

        let directory = try temporaryDirectory()
        let imageURL = directory.appendingPathComponent("local-marker.png")
        try imageData(
            size: CGSize(width: 160, height: 100),
            color: NSColor(calibratedRed: 0.95, green: 0.05, blue: 0.8, alpha: 1)
        ).write(to: imageURL, options: .atomic)

        let sectionParagraphs = (1...12).map { line in
            "<p>Layout verification line \(line): local HTML content remains searchable.</p>"
        }.joined(separator: "\n")
        let sections = (1...4).map { section in
            """
            <section class="segment">
              <h2>Section \(section)</h2>
              \(section == 1 ? #"<img class="marker" src="local-marker.png" alt="Local marker image">"# : "")
              \(sectionParagraphs)
              <p class="section-end">End of section \(section)</p>
            </section>
            """
        }.joined(separator: "\n")
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <style>
            * { box-sizing: border-box; }
            html, body { margin: 0; padding: 0; background: white; }
            body { color: #17233b; font: 16px -apple-system, sans-serif; }
            .segment {
              min-height: 680px;
              padding: 26px;
              border-left: 8px solid #2463eb;
              background: #f5f8ff;
            }
            h1, h2 { color: #163f9e; margin: 0 0 14px; }
            p { line-height: 1.42; margin: 7px 0; }
            .marker { display: block; width: 160px; height: 100px; margin: 12px 0; }
            .section-end { font-weight: 700; color: #6b21a8; }
          </style>
        </head>
        <body>
          <h1 style="padding: 20px 26px;">HTML Conversion Proof</h1>
          \(sections)
          <p>Final searchable HTML marker</p>
        </body>
        </html>
        """
        let htmlURL = directory.appendingPathComponent("styled-source.html")
        let htmlData = Data(html.utf8)
        try htmlData.write(to: htmlURL, options: .atomic)

        // Keep CI failure latency bounded while retaining the reliable profile's
        // one-page capture strategy and local-resource settling behavior.
        var configuration = HTMLPDFConversionConfiguration.preset(.reliable)
        configuration.navigationTimeout = 15
        configuration.resourceWaitTimeout = 5
        configuration.layoutSettleDelay = 0.2
        configuration.captureTimeout = 15
        configuration.totalTimeout = 60
        configuration.maximumPageCount = 20

        let output = try await HTMLPDFConverter.render(
            from: htmlURL,
            configuration: configuration
        )
        let document = try output.makeDocument()

        XCTAssertGreaterThanOrEqual(document.pageCount, 2)
        XCTAssertEqual(output.pageCount, document.pageCount)
        XCTAssertEqual(output.sourceByteCount, htmlData.count)
        XCTAssertEqual(output.outputByteCount, output.data.count)
        XCTAssertTrue(output.elapsedTime.isFinite)
        XCTAssertGreaterThanOrEqual(output.elapsedTime, 0)

        for pageIndex in 0..<document.pageCount {
            let bounds = try XCTUnwrap(document.page(at: pageIndex)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, 595.28, accuracy: 1.5)
            XCTAssertEqual(bounds.height, 841.89, accuracy: 1.5)
        }

        let searchableText = (0..<document.pageCount).compactMap {
            document.page(at: $0)?.string
        }.joined(separator: "\n")
        XCTAssertTrue(searchableText.contains("HTML Conversion Proof"))
        XCTAssertTrue(searchableText.contains("Section 1"))
        XCTAssertTrue(searchableText.contains("Final searchable HTML marker"))

        let firstPage = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(
            containsMagentaMarker(
                in: firstPage.thumbnail(
                    of: CGSize(width: 420, height: 594),
                    for: .mediaBox
                )
            ),
            "The relative local PNG should be present in the rendered PDF."
        )

        let generatedPDF = directory.appendingPathComponent("styled-source.pdf")
        try output.data.write(to: generatedPDF, options: .atomic)
        XCTAssertEqual(PDFDocument(url: generatedPDF)?.pageCount, output.pageCount)
        try copyQAOutputIfRequested(from: generatedPDF)
    }

    @MainActor
    func testPaginationKeepsBoundaryLineOnExactlyOnePage() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        let htmlURL = directory.appendingPathComponent("safe-boundary.html")
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <style>
            html, body { margin: 0; padding: 0; background: white; }
            .spacer-before { height: 700px; }
            .protected-line {
              height: 120px;
              line-height: 120px;
              break-inside: avoid;
              white-space: nowrap;
              padding: 0 12px;
              background: #22c55e;
              color: #0f172a;
              font: 28px/120px -apple-system, sans-serif;
            }
            .spacer-after { height: 900px; }
          </style>
        </head>
        <body>
          <div class="spacer-before"></div>
          <div class="protected-line">BOUNDARYSTART BOUNDARYEND</div>
          <div class="spacer-after"></div>
        </body>
        </html>
        """
        try Data(html.utf8).write(to: htmlURL, options: .atomic)

        var configuration = HTMLPDFConversionConfiguration.preset(.fast)
        configuration.maximumPageCount = 10
        let output = try await HTMLPDFConverter.render(
            from: htmlURL,
            configuration: configuration
        )
        let document = try output.makeDocument()
        let pageTexts = (0..<document.pageCount).map {
            document.page(at: $0)?.string ?? ""
        }
        let pagesContainingMarker = pageTexts.filter {
            $0.contains("BOUNDARYSTART") || $0.contains("BOUNDARYEND")
        }

        XCTAssertEqual(
            pagesContainingMarker.count,
            1,
            "Marker page texts: \(pageTexts.map(\.debugDescription))"
        )
        let markerPageText = try XCTUnwrap(pagesContainingMarker.first)
        XCTAssertTrue(markerPageText.contains("BOUNDARYSTART"))
        XCTAssertTrue(markerPageText.contains("BOUNDARYEND"))
        XCTAssertEqual(
            pageTexts.joined(separator: "\n").components(separatedBy: "BOUNDARYSTART").count - 1,
            1
        )
        XCTAssertEqual(
            pageTexts.joined(separator: "\n").components(separatedBy: "BOUNDARYEND").count - 1,
            1
        )
    }

    func testFastAndReliableHTMLPresetsMapToTheirProcessingProfiles() {
        let reliable = HTMLPDFConversionConfiguration.preset(.reliable)
        let fast = HTMLPDFConversionConfiguration.preset(.fast)

        XCTAssertGreaterThan(reliable.resourceWaitTimeout, fast.resourceWaitTimeout)
        XCTAssertGreaterThan(reliable.layoutSettleDelay, fast.layoutSettleDelay)
        XCTAssertGreaterThan(reliable.totalTimeout, fast.totalTimeout)
        XCTAssertEqual(
            reliable.navigationTimeout,
            PDFProcessingProfile.stability.htmlNavigationTimeout
        )
        XCTAssertEqual(
            fast.navigationTimeout,
            PDFProcessingProfile.speed.htmlNavigationTimeout
        )
        XCTAssertEqual(
            reliable.layoutSettleDelay,
            PDFProcessingProfile.stability.htmlSettlingDelay
        )
        XCTAssertEqual(
            fast.layoutSettleDelay,
            PDFProcessingProfile.speed.htmlSettlingDelay
        )

        XCTAssertEqual(PDFProcessingProfile.stability.maximumConcurrentPageOperations, 1)
        XCTAssertEqual(PDFProcessingProfile.speed.maximumConcurrentPageOperations, 1)
        XCTAssertGreaterThan(
            PDFProcessingProfile.stability.maximumDecodedImagePixels,
            PDFProcessingProfile.speed.maximumDecodedImagePixels
        )
        XCTAssertGreaterThan(
            PDFProcessingProfile.stability.htmlNavigationTimeout,
            PDFProcessingProfile.speed.htmlNavigationTimeout
        )
        XCTAssertGreaterThan(
            PDFProcessingProfile.stability.htmlSettlingDelay,
            PDFProcessingProfile.speed.htmlSettlingDelay
        )
    }

    func testEstimatorProducesFiniteNonnegativeRangesAndVisibleTradeoff() {
        let sources: [PDFConversionEstimateSource] = [
            .image(byteCount: 5_000_000, pixelCount: 16_000_000),
            .importedPDFPage(sourceFileByteCount: 12_000_000, sourcePageCount: 8),
            .blankPage(widthPoints: 595.28, heightPoints: 841.89),
            .html(
                byteCount: 180_000,
                linkedResourceByteCount: 2_400_000,
                estimatedPageCount: 4
            ),
        ]
        let stability = PDFConversionEstimator.estimate(
            sources: sources,
            profile: .stability,
            ocrEnabled: true,
            ocrLanguageCount: 3
        )
        let speed = PDFConversionEstimator.estimate(
            sources: sources,
            profile: .speed,
            ocrEnabled: true,
            ocrLanguageCount: 3
        )

        assertValidEstimate(stability, expectedPageCount: 7)
        assertValidEstimate(speed, expectedPageCount: 7)
        XCTAssertGreaterThanOrEqual(
            stability.estimatedDuration,
            speed.estimatedDuration
        )
        XCTAssertGreaterThanOrEqual(
            stability.estimatedOutputByteCount,
            speed.estimatedOutputByteCount
        )
        XCTAssertFalse(stability.formattedDuration.isEmpty)
        XCTAssertFalse(stability.formattedOutputSize.isEmpty)
        XCTAssertFalse(speed.formattedDuration.isEmpty)
        XCTAssertFalse(speed.formattedOutputSize.isEmpty)
    }

    func testEstimatorOnlyPromisesProfileDifferencesImplementedByConverters() {
        let unchangedSources: [PDFConversionEstimateSource] = [
            .importedPDFPage(sourceFileByteCount: 4_000_000, sourcePageCount: 4),
            .blankPage(widthPoints: 595.28, heightPoints: 841.89),
        ]
        let stableAssembly = PDFConversionEstimator.estimate(
            sources: unchangedSources,
            profile: .stability,
            ocrEnabled: false,
            ocrLanguageCount: 0
        )
        let fastAssembly = PDFConversionEstimator.estimate(
            sources: unchangedSources,
            profile: .speed,
            ocrEnabled: false,
            ocrLanguageCount: 0
        )
        XCTAssertEqual(
            stableAssembly.estimatedDuration,
            fastAssembly.estimatedDuration,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            stableAssembly.estimatedOutputByteCount,
            fastAssembly.estimatedOutputByteCount
        )
        XCTAssertEqual(stableAssembly.durationRange, fastAssembly.durationRange)
        XCTAssertEqual(stableAssembly.outputByteRange, fastAssembly.outputByteRange)

        let htmlSource: [PDFConversionEstimateSource] = [
            .html(
                byteCount: 80_000,
                linkedResourceByteCount: 320_000,
                estimatedPageCount: 3
            ),
        ]
        let stableHTML = PDFConversionEstimator.estimate(
            sources: htmlSource,
            profile: .stability,
            ocrEnabled: false,
            ocrLanguageCount: 0
        )
        let fastHTML = PDFConversionEstimator.estimate(
            sources: htmlSource,
            profile: .speed,
            ocrEnabled: false,
            ocrLanguageCount: 0
        )
        XCTAssertGreaterThan(stableHTML.estimatedDuration, fastHTML.estimatedDuration)
        XCTAssertEqual(
            stableHTML.estimatedOutputByteCount,
            fastHTML.estimatedOutputByteCount
        )
    }

    func testHTMLPageInferenceSaturatesAtDocumentLimits() {
        XCTAssertEqual(PDFConversionEstimateSource.inferredHTMLPageCount(byteCount: .min), 1)
        XCTAssertEqual(PDFConversionEstimateSource.inferredHTMLPageCount(byteCount: 0), 1)
        XCTAssertEqual(PDFConversionEstimateSource.inferredHTMLPageCount(byteCount: .max), 500)
    }

    func testHTMLFileBecomesEstimatorSourceWithRealMetadata() throws {
        let directory = try temporaryDirectory()
        let htmlURL = directory.appendingPathComponent("estimate.html")
        let data = Data("<html><body>Estimate me</body></html>".utf8)
        try data.write(to: htmlURL, options: .atomic)

        let explicit = PDFConversionEstimateSource.htmlFile(
            at: htmlURL,
            linkedResourceByteCount: 42_000,
            estimatedPageCount: 3
        )
        guard case let .html(bytes, linkedBytes, pages) = explicit else {
            return XCTFail("Expected an HTML estimate source.")
        }
        XCTAssertEqual(bytes, Int64(data.count))
        XCTAssertEqual(linkedBytes, 42_000)
        XCTAssertEqual(pages, 3)

        let item = ImagePDFAssemblyItem(source: .html(htmlURL))
        let mapped = try XCTUnwrap(PDFConversionEstimator.sources(from: [item]).first)
        guard case let .html(mappedBytes, mappedLinkedBytes, mappedPages) = mapped else {
            return XCTFail("HTML assembly items must remain HTML estimator sources.")
        }
        XCTAssertEqual(mappedBytes, Int64(data.count))
        XCTAssertEqual(mappedLinkedBytes, 0)
        XCTAssertGreaterThanOrEqual(mappedPages, 1)
    }

    func testProfilesExposeOCRQualityMapping() {
        XCTAssertGreaterThan(
            PDFProcessingProfile.stability.recommendedOCRDPI,
            PDFProcessingProfile.speed.recommendedOCRDPI
        )
        XCTAssertTrue(PDFProcessingProfile.stability.usesAccurateOCRRecognition)
        XCTAssertFalse(PDFProcessingProfile.speed.usesAccurateOCRRecognition)

        let stabilityOCR = PDFProcessingProfile.stability.applying(to: OCRConfiguration())
        let speedOCR = PDFProcessingProfile.speed.applying(to: OCRConfiguration())

        XCTAssertEqual(stabilityOCR.recognitionQuality, .accurate)
        XCTAssertTrue(stabilityOCR.useLanguageCorrection)
        XCTAssertEqual(speedOCR.recognitionQuality, .fast)
        XCTAssertFalse(speedOCR.useLanguageCorrection)
        XCTAssertGreaterThan(stabilityOCR.renderDPI, speedOCR.renderDPI)
    }

    private func assertValidEstimate(
        _ estimate: PDFConversionEstimate,
        expectedPageCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(estimate.pageCount, expectedPageCount, file: file, line: line)
        XCTAssertGreaterThanOrEqual(estimate.inputByteCount, 0, file: file, line: line)
        XCTAssertTrue(estimate.estimatedDuration.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(estimate.estimatedDuration, 0, file: file, line: line)
        XCTAssertTrue(estimate.durationRange.lowerBound.isFinite, file: file, line: line)
        XCTAssertTrue(estimate.durationRange.upperBound.isFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(estimate.durationRange.lowerBound, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            estimate.durationRange.upperBound,
            estimate.durationRange.lowerBound,
            file: file,
            line: line
        )
        XCTAssertTrue(
            estimate.durationRange.contains(estimate.estimatedDuration),
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            estimate.estimatedOutputByteCount,
            0,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(estimate.outputByteRange.lowerBound, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            estimate.outputByteRange.upperBound,
            estimate.outputByteRange.lowerBound,
            file: file,
            line: line
        )
        XCTAssertTrue(
            estimate.outputByteRange.contains(estimate.estimatedOutputByteCount),
            file: file,
            line: line
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-HTMLTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func imageData(size: CGSize, color: NSColor) throws -> Data {
        let image = NSImage(size: size, flipped: false) { bounds in
            color.setFill()
            bounds.fill()
            return true
        }
        let representation = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: representation))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func containsMagentaMarker(in image: NSImage) -> Bool {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return false }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                if color.redComponent > 0.7,
                   color.greenComponent < 0.5,
                   color.blueComponent > 0.55 {
                    return true
                }
            }
        }
        return false
    }

    private func copyQAOutputIfRequested(from generatedPDF: URL) throws {
        guard
            let rawPath = ProcessInfo.processInfo.environment["HWATTAK_HTML_QA_OUTPUT"],
            !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        var isDirectory: ObjCBool = false
        let requestedURL = URL(fileURLWithPath: rawPath).standardizedFileURL
        let exists = FileManager.default.fileExists(
            atPath: requestedURL.path,
            isDirectory: &isDirectory
        )
        let destination: URL
        if (exists && isDirectory.boolValue) || requestedURL.pathExtension.isEmpty {
            try FileManager.default.createDirectory(
                at: requestedURL,
                withIntermediateDirectories: true
            )
            destination = requestedURL.appendingPathComponent("html-conversion-qa.pdf")
        } else {
            try FileManager.default.createDirectory(
                at: requestedURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            destination = requestedURL
        }
        try Data(contentsOf: generatedPDF).write(to: destination, options: .atomic)
    }
}

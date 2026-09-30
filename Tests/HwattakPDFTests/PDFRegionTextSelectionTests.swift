// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFRegionTextSelectionTests: XCTestCase {
    @MainActor
    func testOrdinaryTextKeepsNativeSelectionIncludingRotatedCroppedPages() throws {
        for rotation in [0, 90, 180, 270] {
            let document = try makeDocument(ascent: 800, rotation: rotation)
            let page = try XCTUnwrap(document.page(at: 0))

            XCTAssertFalse(
                PDFTextSelectionGeometry.needsRegionSelection(on: page),
                "Ordinary text at rotation \(rotation) should retain native dragging."
            )
        }
    }

    @MainActor
    func testCorruptFontAscentTriggersFallbackDespiteReadableNativeText() throws {
        for rotation in [0, 90, 180, 270] {
            let document = try makeDocument(ascent: 67_306_242, rotation: rotation)
            let page = try XCTUnwrap(document.page(at: 0))
            let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))
            let bounds = selection.bounds(for: page)

            XCTAssertEqual(selection.string, "Choose")
            XCTAssertGreaterThan(max(bounds.width, bounds.height), 1_000_000)
            XCTAssertTrue(
                PDFTextSelectionGeometry.needsRegionSelection(on: page),
                "Readable text alone must not hide malformed font geometry at rotation \(rotation)."
            )
        }
    }

    @MainActor
    func testSnapshotMapsRotatedPixelsBackToOnlyTheRequestedPageRegion() throws {
        let region = CGRect(x: 80, y: 140, width: 180, height: 230)
        for rotation in [0, 90, 180, 270] {
            let document = try makeDocument(ascent: 800, rotation: rotation)
            let page = try XCTUnwrap(document.page(at: 0))
            let snapshot = try PDFRegionTextRecognizer.snapshot(page: page, region: region)
            let pixels = CGRect(
                x: 0,
                y: 0,
                width: snapshot.image.width,
                height: snapshot.image.height
            )

            assertEqual(pixels.applying(snapshot.imageToPage), region, accuracy: 0.1)
            XCTAssertLessThanOrEqual(max(snapshot.image.width, snapshot.image.height), 2_400)
            XCTAssertLessThanOrEqual(snapshot.image.width * snapshot.image.height, 6_000_000)
            if rotation == 90 || rotation == 270 {
                XCTAssertGreaterThan(snapshot.image.width, snapshot.image.height)
            } else {
                XCTAssertLessThan(snapshot.image.width, snapshot.image.height)
            }
        }
    }

    @MainActor
    func testSnapshotClipsSelectionToNonzeroCropBox() throws {
        let document = try makeDocument(ascent: 800, rotation: 270)
        let page = try XCTUnwrap(document.page(at: 0))
        let requested = CGRect(x: 0, y: 20, width: 160, height: 210)
        let expected = requested.intersection(page.bounds(for: .cropBox))
        let snapshot = try PDFRegionTextRecognizer.snapshot(page: page, region: requested)
        let pixels = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)

        assertEqual(pixels.applying(snapshot.imageToPage), expected, accuracy: 0.1)
    }

    @MainActor
    func testSnapshotIncludesRotationChangedInMemory() throws {
        let document = try makeDocument(ascent: 800, rotation: 0)
        let page = try XCTUnwrap(document.page(at: 0))
        let region = CGRect(x: 80, y: 140, width: 180, height: 230)
        page.rotation = 270

        let snapshot = try PDFRegionTextRecognizer.snapshot(page: page, region: region)
        let pixels = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)

        assertEqual(pixels.applying(snapshot.imageToPage), region, accuracy: 0.1)
        XCTAssertGreaterThan(snapshot.image.width, snapshot.image.height)
    }

    @MainActor
    func testSnapshotRespectsOpaqueAnnotationCoveringUnderlyingTextAtEveryRotation() throws {
        let region = CGRect(x: 35, y: 390, width: 260, height: 40)
        for rotation in [0, 90, 180, 270] {
            let document = try makeDocument(ascent: 800, rotation: rotation)
            let page = try XCTUnwrap(document.page(at: 0))
            let before = try PDFRegionTextRecognizer.snapshot(page: page, region: region)
            let originalDarkPixels = try darkPixelCount(in: before.image)
            XCTAssertGreaterThan(originalDarkPixels, 100, "Fixture text must be visible at rotation \(rotation).")

            let cover = PDFAnnotation(bounds: region, forType: .square, withProperties: nil)
            cover.interiorColor = .white
            cover.color = .white
            let border = PDFBorder()
            border.lineWidth = 0
            cover.border = border
            page.addAnnotation(cover)

            let after = try PDFRegionTextRecognizer.snapshot(page: page, region: region)
            XCTAssertLessThan(
                try darkPixelCount(in: after.image),
                max(1, originalDarkPixels / 20),
                "OCR must see the opaque displayed annotation, not hidden text, at rotation \(rotation)."
            )
        }
    }

    @MainActor
    func testRegionSelectionPreservesOriginalPageTextAndLineBounds() throws {
        let document = try makeDocument(ascent: 67_306_242)
        let page = try XCTUnwrap(document.page(at: 0))
        let fragments = [
            PDFRegionTextFragment(text: "Selected first line.", bounds: CGRect(x: 80, y: 220, width: 110, height: 12)),
            PDFRegionTextFragment(text: "Selected second line.", bounds: CGRect(x: 80, y: 200, width: 120, height: 12))
        ]
        let selection = PDFRegionTextSelection(document: document, page: page, fragments: fragments)

        XCTAssertEqual(selection.string, "Selected first line.\nSelected second line.")
        XCTAssertEqual(selection.attributedString?.string, selection.string)
        XCTAssertEqual(selection.pages.count, 1)
        XCTAssertTrue(selection.pages.first === page)
        XCTAssertEqual(document.index(for: try XCTUnwrap(selection.pages.first)), 0)
        assertEqual(selection.bounds(for: page), CGRect(x: 80, y: 200, width: 120, height: 32))

        let lines = selection.selectionsByLine()
        XCTAssertEqual(lines.map(\.string), fragments.map { Optional($0.text) })
        for (line, fragment) in zip(lines, fragments) {
            XCTAssertTrue(line.pages.first === page)
            assertEqual(line.bounds(for: page), fragment.bounds)
        }

        let copy = try XCTUnwrap(selection.copy() as? PDFSelection)
        XCTAssertEqual(copy.string, selection.string)
        XCTAssertTrue(copy.pages.first === page)
        assertEqual(copy.bounds(for: page), selection.bounds(for: page))
    }

    @MainActor
    func testAISelectionContextUsesOnlyRecognizedRegionAndOriginalPageCitation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-region-selection-\(UUID().uuidString).pdf")
        try fixtureData(ascent: 67_306_242).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        let loadedDocument = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(loadedDocument.page(at: 0))
        workspace.currentSelection = PDFRegionTextSelection(
            document: loadedDocument,
            page: page,
            fragments: [PDFRegionTextFragment(
                text: "Only this recognized region.",
                bounds: CGRect(x: 80, y: 200, width: 150, height: 16)
            )]
        )

        let context = try await PDFAIContextExtractor().extract(from: workspace, scope: .selection)

        XCTAssertEqual(context.includedPageIndices, [0])
        XCTAssertEqual(context.sources.count, 1)
        XCTAssertEqual(context.sources.first?.pageNumber, 1)
        XCTAssertEqual(context.sources.first?.text, "Only this recognized region.")
        XCTAssertFalse(context.promptText.contains("Choose only this phrase."))
    }

    private func makeDocument(ascent: Int, rotation: Int = 0) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: fixtureData(ascent: ascent, rotation: rotation)))
    }

    private func darkPixelCount(in image: CGImage) throws -> Int {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var count = 0
        for offset in stride(from: 0, to: image.width * image.height * 4, by: 4) {
            if bytes[offset] < 100, bytes[offset + 1] < 100, bytes[offset + 2] < 100 {
                count += 1
            }
        }
        return count
    }

    // Deliberately malformed font metadata reproduces the oversized native
    // selection independently of the user's PDF and any installed custom font.
    private func fixtureData(ascent: Int, rotation: Int = 0) -> Data {
        let content = "BT /F1 18 Tf 40 400 Td (Choose only this phrase.) Tj ET"
        let widths = Array(repeating: "500", count: 95).joined(separator: " ")
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 500] /CropBox [30 60 330 440] /Rotate \(rotation) /Resources << /Font << /F1 4 0 R >> >> /Contents 6 0 R >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /SelectionFixtureFont /FirstChar 32 /LastChar 126 /Widths [\(widths)] /Encoding /WinAnsiEncoding /FontDescriptor 5 0 R >>",
            "<< /Type /FontDescriptor /FontName /SelectionFixtureFont /Flags 32 /FontBBox [0 -200 1000 800] /ItalicAngle 0 /Ascent \(ascent) /Descent -200 /CapHeight 700 /StemV 80 >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let crossReferenceOffset = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(crossReferenceOffset)\n%%EOF\n".utf8))
        return data
    }

    private func assertEqual(
        _ actual: CGRect,
        _ expected: CGRect,
        accuracy: CGFloat = 0.001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }
}

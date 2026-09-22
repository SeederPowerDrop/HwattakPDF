// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PressureInkCopyTests: XCTestCase {
    private enum SourceState { case unsaved, saved, reopened }

    func testAnnotationCopyPreservesMetadataAndSurvivesSourceRelease() throws {
        var original: PressureInkAnnotation? = try makeStroke()
        weak var releasedOriginal = original
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        original?.contents = "Independent pressure stroke"
        original?.userName = "Test author"
        original?.modificationDate = date
        original?.shouldPrint = false
        let border = PDFBorder()
        border.lineWidth = 2
        original?.border = border
        let copied = try XCTUnwrap(original?.copy() as? PressureInkAnnotation)

        XCTAssertFalse(copied === original)
        XCTAssertNil(copied.page)
        XCTAssertEqual(copied.bounds, original?.bounds)
        XCTAssertEqual(copied.contents, "Independent pressure stroke")
        XCTAssertEqual(copied.userName, "Test author")
        XCTAssertEqual(copied.modificationDate, date)
        XCTAssertTrue(copied.shouldDisplay)
        XCTAssertFalse(copied.shouldPrint)
        XCTAssertEqual(copied.border?.lineWidth, 2)
        border.lineWidth = 9
        original?.contents = "Changed original"
        XCTAssertEqual(copied.border?.lineWidth, 2)
        XCTAssertEqual(copied.contents, "Independent pressure stroke")
        original = nil
        XCTAssertNil(releasedOriginal)

        copied.shouldPrint = true
        let output = try makeDocument(pageCount: 1)
        try XCTUnwrap(output.page(at: 0)).addAnnotation(copied)
        let reopened = try roundTrip(output)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.first?.userName, "Test author")
        try assertStrokeAppearance(on: reopened.page(at: 0))
    }

    func testUnattributedCopyAndExtractionNeverPublishImplicitAuthor() throws {
        let source = try makeDocument(pageCount: 1)
        let ink = try makeStroke()
        XCTAssertNil(ink.userName)
        try XCTUnwrap(source.page(at: 0)).addAnnotation(ink)

        let copied = try XCTUnwrap(ink.copy() as? PressureInkAnnotation)
        XCTAssertNil(copied.userName)
        let copiedDocument = try makeDocument(pageCount: 1)
        try XCTUnwrap(copiedDocument.page(at: 0)).addAnnotation(copied)
        let savedCopy = try XCTUnwrap(roundTrip(copiedDocument).page(at: 0)?.annotations.first)
        XCTAssertNil(savedCopy.userName)

        let extracted = try PDFPageOperations.extract(from: source, indexes: [0])
        XCTAssertNil(try XCTUnwrap(extracted.page(at: 0)?.annotations.first).userName)
        let savedExtraction = try XCTUnwrap(roundTrip(extracted).page(at: 0)?.annotations.first)
        XCTAssertNil(savedExtraction.userName)
        XCTAssertNil(ink.userName)
    }

    func testCombinedExtractionBeforeFirstSaveRetainsPressureAppearance() throws {
        try assertCombinedExtraction(sourceState: .unsaved)
    }

    func testCombinedExtractionAfterSavingLiveAnnotationRetainsPressureAppearance() throws {
        try assertCombinedExtraction(sourceState: .saved)
    }

    func testCombinedExtractionAfterSaveAndReopenRetainsPressureAppearance() throws {
        try assertCombinedExtraction(sourceState: .reopened)
    }

    func testIndividualExtractionBeforeFirstSaveRetainsPressureAppearance() throws {
        try assertIndividualExtraction(sourceState: .unsaved)
    }

    func testIndividualExtractionAfterSavingLiveAnnotationRetainsPressureAppearance() throws {
        try assertIndividualExtraction(sourceState: .saved)
    }

    func testIndividualExtractionAfterSaveAndReopenRetainsPressureAppearance() throws {
        try assertIndividualExtraction(sourceState: .reopened)
    }

    func testExtractedPressureIsIndependentOfOriginalUndoRedo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-PressureCopy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("original.pdf")
        XCTAssertTrue(try makeDocument(pageCount: 1).write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.study)
        let document = try XCTUnwrap(workspace.document)
        let page = try XCTUnwrap(document.page(at: 0))
        let ink = try makeStroke()
        ink.contents = "Original stroke"
        page.addAnnotation(ink)
        workspace.registerAddedAnnotation(ink, on: page, message: "Pressure copy test")

        let combined = try PDFPageOperations.extract(from: document, indexes: [0])
        let individual = try XCTUnwrap(
            PDFPageOperations.extractIndividually(from: document, indexes: [0]).first?.document
        )
        let copiedInk = try XCTUnwrap(combined.page(at: 0)?.annotations.first)
        XCTAssertFalse(copiedInk === ink)
        copiedInk.contents = "Changed extracted stroke"
        XCTAssertEqual(ink.contents, "Original stroke")

        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertFalse(workspace.isDirty)
        try assertStrokeAppearance(on: roundTrip(combined).page(at: 0))
        try assertStrokeAppearance(on: roundTrip(individual).page(at: 0))
        workspace.redo()
        XCTAssertTrue(page.annotations.first === ink)
        XCTAssertTrue(workspace.isDirty)
        let extractedPage = try XCTUnwrap(combined.page(at: 0))
        extractedPage.removeAnnotation(copiedInk)
        XCTAssertTrue(extractedPage.annotations.isEmpty)
        XCTAssertTrue(page.annotations.first === ink)
        try assertStrokeAppearance(on: roundTrip(document).page(at: 0))
    }

    private func assertCombinedExtraction(sourceState: SourceState) throws {
        let source = try annotatedDocument(sourceState: sourceState)
        let extracted = try PDFPageOperations.extract(from: source, indexes: [1, 0, 1])
        XCTAssertEqual(extracted.pageCount, 2)
        for index in 0..<2 {
            let sourcePage = try XCTUnwrap(source.page(at: index))
            let copiedPage = try XCTUnwrap(extracted.page(at: index))
            XCTAssertFalse(sourcePage === copiedPage)
            XCTAssertEqual(copiedPage.annotations.count, 1)
            XCTAssertFalse(copiedPage.annotations.first === sourcePage.annotations.first)
            XCTAssertTrue(copiedPage.annotations.first?.page === copiedPage)
        }
        let reopened = try roundTrip(extracted)
        try assertStrokeAppearance(on: reopened.page(at: 0))
        try assertDotAppearance(on: reopened.page(at: 1))
    }

    private func assertIndividualExtraction(sourceState: SourceState) throws {
        let source = try annotatedDocument(sourceState: sourceState)
        let extracted = try PDFPageOperations.extractIndividually(from: source, indexes: [1, 0, 1])
        XCTAssertEqual(extracted.map(\.sourcePageIndex), [0, 1])
        XCTAssertTrue(extracted.allSatisfy { $0.document.pageCount == 1 })
        try assertStrokeAppearance(on: roundTrip(extracted[0].document).page(at: 0))
        try assertDotAppearance(on: roundTrip(extracted[1].document).page(at: 0))
        for item in extracted {
            let sourcePage = try XCTUnwrap(source.page(at: item.sourcePageIndex))
            let copiedPage = try XCTUnwrap(item.document.page(at: 0))
            let copiedInk = try XCTUnwrap(copiedPage.annotations.first)
            copiedPage.removeAnnotation(copiedInk)
            XCTAssertTrue(copiedPage.annotations.isEmpty)
            XCTAssertEqual(sourcePage.annotations.count, 1)
        }
    }

    private func annotatedDocument(sourceState: SourceState) throws -> PDFDocument {
        let document = try makeDocument(pageCount: 2)
        try XCTUnwrap(document.page(at: 0)).addAnnotation(makeStroke())
        let dot = try XCTUnwrap(PressureInkAnnotation(
            points: [CGPoint(x: 100, y: 100)], pressures: [1], width: 12, color: .blue
        ))
        try XCTUnwrap(document.page(at: 1)).addAnnotation(dot)
        switch sourceState {
        case .unsaved:
            return document
        case .saved:
            // PDFKit may build an appearance on the authoring object during a
            // save. Exercise copying that live subclass as well as reopening it.
            _ = try XCTUnwrap(document.dataRepresentation())
            return document
        case .reopened:
            return try roundTrip(document)
        }
    }

    private func makeStroke() throws -> PressureInkAnnotation {
        try XCTUnwrap(PressureInkAnnotation(
            points: [CGPoint(x: 40, y: 100), CGPoint(x: 80, y: 100),
                     CGPoint(x: 120, y: 100), CGPoint(x: 160, y: 100)],
            pressures: [0.1, 0.1, 1, 1], width: 12, color: .blue
        ))
    }

    private func makeDocument(pageCount: Int) throws -> PDFDocument {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let writer = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<pageCount {
            writer.beginPDFPage(nil)
            writer.setFillColor(NSColor.white.cgColor)
            writer.fill(bounds)
            writer.endPDFPage()
        }
        writer.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func roundTrip(_ document: PDFDocument) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
    }

    private func bitmap(for optionalPage: PDFPage?) throws -> NSBitmapImageRep {
        let page = try XCTUnwrap(optionalPage)
        XCTAssertEqual(page.annotations.count, 1)
        XCTAssertEqual(page.annotations.first?.type, "Stamp")
        // PDFKit exposes PDF Name values with a leading slash after reopening.
        let stampName = (page.annotations.first?.value(forAnnotationKey: .iconName) as? String)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        XCTAssertEqual(stampName, PressureInkAnnotation.stampName)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        page.draw(with: .mediaBox, to: graphics.cgContext)
        graphics.flushGraphics()
        return bitmap
    }

    private func assertStrokeAppearance(on page: PDFPage?) throws {
        let image = try bitmap(for: page)
        let thinEdge = try XCTUnwrap(image.colorAt(x: 60, y: 104)?.usingColorSpace(.deviceRGB))
        let thickEdge = try XCTUnwrap(image.colorAt(x: 140, y: 104)?.usingColorSpace(.deviceRGB))
        let center = try XCTUnwrap(image.colorAt(x: 60, y: 100)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(thinEdge.redComponent, 0.8, "Low pressure keeps the edge white")
        XCTAssertLessThan(thickEdge.redComponent, 0.3, "High pressure keeps the thick blue stroke")
        XCTAssertGreaterThan(thickEdge.blueComponent, 0.8)
        XCTAssertLessThan(center.redComponent, 0.3, "Low pressure still draws the stroke center")
        XCTAssertGreaterThan(center.blueComponent, 0.8)
    }

    private func assertDotAppearance(on page: PDFPage?) throws {
        let image = try bitmap(for: page)
        let center = try XCTUnwrap(image.colorAt(x: 100, y: 100)?.usingColorSpace(.deviceRGB))
        let outside = try XCTUnwrap(image.colorAt(x: 100, y: 108)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(center.redComponent, 0.3)
        XCTAssertGreaterThan(center.blueComponent, 0.8)
        XCTAssertGreaterThan(outside.redComponent, 0.8, "The copied dot must keep its radius")
    }
}

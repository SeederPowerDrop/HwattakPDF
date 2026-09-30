// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class OCRPartialExportTests: XCTestCase {
    func testPartialExportKeepsWholeDocumentAndUntouchedPageObjectsEditable() throws {
        let document = try makeDocument()
        let sourceData = try XCTUnwrap(document.dataRepresentation())
        let sourcePages = try (0..<3).map { try XCTUnwrap(document.page(at: $0)) }
        let originalText = sourcePages.map { $0.string }
        var checkpoint = OCRCheckpoint(documentFingerprint: "partial", pageCount: 3)
        checkpoint.pages[1] = result(index: 1, text: "Corrected searchable pancreas")

        let output = try export(document, checkpoint: checkpoint)

        XCTAssertEqual(output.pageCount, 3)
        XCTAssertEqual(output.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Partial OCR fixture")
        XCTAssertTrue(output.page(at: 1)?.string?.contains("Corrected searchable pancreas") == true)
        let matches = output.findString("pancreas", withOptions: [])
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(matches.first?.pages.first === output.page(at: 1))
        XCTAssertFalse(output.page(at: 1)?.string?.contains("Page two incorrect") == true)
        XCTAssertTrue(output.page(at: 1)?.annotations.isEmpty == true)
        for index in [0, 2] {
            let page = try XCTUnwrap(output.page(at: index))
            XCTAssertEqual(page.string, originalText[index])
            XCTAssertEqual(page.bounds(for: .cropBox), sourcePages[index].bounds(for: .cropBox))
            XCTAssertEqual(page.bounds(for: .mediaBox), sourcePages[index].bounds(for: .mediaBox))
            XCTAssertEqual(page.rotation, sourcePages[index].rotation)
            let note = try XCTUnwrap(page.annotations.first { $0.type == "Text" })
            XCTAssertEqual(note.contents, "Editable note \(index)")
            note.contents = "Still editable"
            XCTAssertEqual(note.contents, "Still editable")
            let outline = try XCTUnwrap(output.outlineRoot?.child(at: index)?.destination)
            XCTAssertTrue(outline.page === page)
            XCTAssertEqual(outline.point, CGPoint(x: 70, y: 190))
            XCTAssertEqual(outline.zoom, 1.5)
        }
        let form = try XCTUnwrap(output.page(at: 2)?.annotations.first { $0.fieldName == "name" })
        XCTAssertEqual(form.widgetFieldType, .text)
        XCTAssertEqual(form.widgetStringValue, "Original value")
        form.widgetStringValue = "Edited value"
        XCTAssertEqual(form.widgetStringValue, "Edited value")
        let link = try XCTUnwrap(output.page(at: 0)?.annotations.first { $0.type == "Link" })
        XCTAssertEqual(link.url, URL(string: "https://example.com/kept"))
        for index in 0..<3 {
            XCTAssertTrue(document.page(at: index) === sourcePages[index])
            XCTAssertEqual(document.page(at: index)?.string, originalText[index])
            XCTAssertEqual(document.page(at: index)?.annotations.first?.contents, "Editable note \(index)")
        }
        XCTAssertEqual(PDFDocument(data: sourceData)?.pageCount, document.pageCount)
    }

    func testInternalLinksOnUntouchedPagesFollowBothReplacedAndRetainedTargets() throws {
        let document = try makeDocument()
        let first = try XCTUnwrap(document.page(at: 0))
        for index in [1, 2] {
            let link = PDFAnnotation(bounds: CGRect(x: 50, y: 110 + 25 * index, width: 80, height: 20),
                                     forType: .link, withProperties: nil)
            link.contents = "Target \(index)"
            let target = try XCTUnwrap(document.page(at: index))
            let destination = PDFDestination(page: target, at: CGPoint(x: 70, y: 190))
            destination.zoom = 1.5
            link.destination = destination
            first.addAnnotation(link)
        }
        var checkpoint = OCRCheckpoint(documentFingerprint: "linked-partial", pageCount: 3)
        checkpoint.pages[1] = result(index: 1, text: "New OCR text")

        let output = try export(document, checkpoint: checkpoint)

        for index in [1, 2] {
            let link = try XCTUnwrap(output.page(at: 0)?.annotations.first { $0.contents == "Target \(index)" })
            let destination = try XCTUnwrap(link.destination)
            XCTAssertTrue(destination.page === output.page(at: index))
            XCTAssertEqual(destination.point, CGPoint(x: 70, y: 190))
            XCTAssertEqual(destination.zoom, 1.5)
            let originalLink = try XCTUnwrap(first.annotations.first { $0.contents == "Target \(index)" })
            XCTAssertTrue(originalLink.destination?.page === document.page(at: index))
        }
    }

    func testSkippedAndEmptyResultsPreserveAnnotationsFormsAndGeometry() throws {
        let document = try makeDocument()
        var checkpoint = OCRCheckpoint(documentFingerprint: "no-new-text", pageCount: 3)
        checkpoint.pages[0] = result(index: 0, text: "Skipped text", skipped: true)
        checkpoint.pages[1] = result(index: 1, text: "")
        checkpoint.pages[2] = result(index: 2, text: " \n\t")
        XCTAssertTrue(PDFOCRApplication.replacementPageIndexes(checkpoint: checkpoint).isEmpty)

        let output = try export(document, checkpoint: checkpoint)

        for index in 0..<3 {
            let before = try XCTUnwrap(document.page(at: index))
            let after = try XCTUnwrap(output.page(at: index))
            XCTAssertEqual(after.string, before.string)
            XCTAssertEqual(after.annotations.count, before.annotations.count)
            XCTAssertEqual(after.rotation, before.rotation)
            XCTAssertEqual(after.bounds(for: .cropBox), before.bounds(for: .cropBox))
            XCTAssertEqual(output.outlineRoot?.child(at: index)?.destination?.point, CGPoint(x: 70, y: 190))
        }
        XCTAssertEqual(output.page(at: 2)?.annotations.first { $0.fieldName == "name" }?.widgetStringValue,
                       "Original value")
    }

    func testOutlineKeepsExactPointForRetainedPageAndMapsRotatedReplacement() throws {
        let document = try makeDocument()
        let first = try XCTUnwrap(document.page(at: 0))
        let second = try XCTUnwrap(document.page(at: 1))
        let third = try XCTUnwrap(document.page(at: 2))
        second.setBounds(CGRect(x: 20, y: 30, width: 240, height: 200), for: .cropBox)
        second.rotation = 90
        let replacement = PDFPage()
        replacement.setBounds(CGRect(x: 0, y: 0, width: 200, height: 240), for: .mediaBox)
        let copied = try XCTUnwrap(PDFOCRApplication.copyOutline(
            document.outlineRoot, from: document, to: [first, replacement, third]
        ))

        XCTAssertTrue(copied.child(at: 0)?.destination?.page === first)
        XCTAssertEqual(copied.child(at: 0)?.destination?.point, CGPoint(x: 70, y: 190))
        XCTAssertTrue(copied.child(at: 2)?.destination?.page === third)
        XCTAssertEqual(copied.child(at: 2)?.destination?.point, CGPoint(x: 70, y: 190))
        XCTAssertTrue(copied.child(at: 1)?.destination?.page === replacement)
        XCTAssertEqual(copied.child(at: 1)?.destination?.point, CGPoint(x: 160, y: 190))
        XCTAssertEqual(copied.child(at: 1)?.destination?.zoom, 1.5)
    }

    func testLinkDestinationChangeCanRestoreOriginalTargetForUndo() throws {
        let document = try makeDocument()
        let pages = try (0..<3).map { try XCTUnwrap(document.page(at: $0)) }
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                                 forType: .link, withProperties: nil)
        let destination = PDFDestination(page: pages[1], at: CGPoint(x: 80, y: 180))
        link.destination = destination
        pages[0].addAnnotation(link)
        let replacement = PDFPage()
        replacement.setBounds(CGRect(x: 0, y: 0, width: 320, height: 280), for: .mediaBox)
        let changes = PDFOCRApplication.linkDestinationChanges(from: pages, to: [pages[0], replacement, pages[2]])
        XCTAssertEqual(changes.count, 1)
        let change = try XCTUnwrap(changes.first)

        change.apply()
        XCTAssertTrue(link.destination?.page === replacement)
        XCTAssertEqual(link.destination?.point, CGPoint(x: 80, y: 180))
        change.restore()
        XCTAssertTrue(link.destination?.page === pages[1])
        XCTAssertEqual(link.destination?.point, CGPoint(x: 80, y: 180))
        change.apply()
        XCTAssertTrue(link.destination?.page === replacement)
    }

    func testMismatchedResultIndexCannotModifyDestination() throws {
        let document = try makeDocument()
        var checkpoint = OCRCheckpoint(documentFingerprint: "wrong-index", pageCount: 3)
        checkpoint.pages[1] = result(index: 0, text: "Misplaced text")
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("copy.pdf")
        let existing = Data("Existing file must survive".utf8)
        try existing.write(to: destination)

        XCTAssertThrowsError(try SearchablePDFExporter.export(
            document: document, checkpoint: checkpoint, to: destination
        ))
        XCTAssertEqual(try Data(contentsOf: destination), existing)
    }

    private func export(_ document: PDFDocument, checkpoint: OCRCheckpoint) throws -> PDFDocument {
        let destination = try makeDirectory().appendingPathComponent("partial-OCR.pdf")
        try SearchablePDFExporter.export(document: document, checkpoint: checkpoint, to: destination)
        return try XCTUnwrap(PDFDocument(url: destination))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-PartialOCRTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func result(index: Int, text: String, skipped: Bool = false) -> OCRPageResult {
        OCRPageResult(pageIndex: index, text: text, observations: text.isEmpty ? [] : [
            OCRWordBox(text: text, confidence: 1, x: 0.1, y: 0.5, width: 0.8, height: 0.1)
        ], completedAt: Date(), skippedBecauseTextExists: skipped)
    }

    private func makeDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 320, height: 280)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for text in ["Page one original", "Page two incorrect", "Page three original"] {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(box)
            let attributes = [
                kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 12, nil),
                kCTForegroundColorAttributeName: NSColor.black.cgColor
            ] as CFDictionary
            let string = try XCTUnwrap(CFAttributedStringCreate(nil, text as CFString, attributes))
            context.textPosition = CGPoint(x: 50, y: 180)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Partial OCR fixture"]
        let outline = PDFOutline()
        for index in 0..<3 {
            let page = try XCTUnwrap(document.page(at: index))
            let note = PDFAnnotation(bounds: CGRect(x: 50, y: 60, width: 20, height: 20),
                                     forType: .text, withProperties: nil)
            note.contents = "Editable note \(index)"
            page.addAnnotation(note)
            let section = PDFOutline()
            section.label = "Section \(index)"
            let destination = PDFDestination(page: page, at: CGPoint(x: 70, y: 190))
            destination.zoom = 1.5
            section.destination = destination
            outline.insertChild(section, at: index)
        }
        document.outlineRoot = outline
        let first = try XCTUnwrap(document.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 50, y: 100, width: 60, height: 20),
                                 forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/kept")
        first.addAnnotation(link)
        let third = try XCTUnwrap(document.page(at: 2))
        third.setBounds(CGRect(x: 20, y: 30, width: 270, height: 210), for: .cropBox)
        third.rotation = 90
        let widget = PDFAnnotation(bounds: CGRect(x: 50, y: 90, width: 120, height: 24),
                                   forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "name"
        widget.widgetStringValue = "Original value"
        third.addAnnotation(widget)
        return document
    }
}

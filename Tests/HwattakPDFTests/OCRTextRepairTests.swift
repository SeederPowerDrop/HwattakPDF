// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class OCRTextRepairTests: XCTestCase {
    private let correctText = "췌장액의 비밀"
    private let incorrectText = "훼장액의 비밀 그리고 춰|장의 소화 효소를 설명하는 기존의 잘못된 문자 정보"

    func testOCRDefaultsToRepairingPagesWithExistingText() {
        XCTAssertFalse(OCRConfiguration().skipPagesWithText)
    }

    func testRerecognizedKoreanTextReplacesIncorrectHiddenTextAndIsSearchable() async throws {
        let document = try makeScannedDocument()
        let sourcePage = try XCTUnwrap(document.page(at: 0))
        let originalText = try XCTUnwrap(sourcePage.string)
        XCTAssertTrue(originalText.contains("훼장"))
        XCTAssertFalse(originalText.contains("췌장"))
        XCTAssertGreaterThan(originalText.filter { !$0.isWhitespace }.count,
                             OCRConfiguration().minimumExistingCharacters)

        let engine = PDFSearchEngine()
        let before = try await engine.searchPage(
            in: document, pageIndex: 0, query: engine.prepare(query: "췌장"),
            remainingResultCapacity: 100
        )
        XCTAssertTrue(before.results.isEmpty)

        let exported = try export(document, skipped: false)
        let page = try XCTUnwrap(exported.page(at: 0))
        let repairedText = try XCTUnwrap(page.string)
        XCTAssertTrue(repairedText.contains(correctText), repairedText)
        XCTAssertFalse(repairedText.contains("훼장"), repairedText)
        XCTAssertFalse(repairedText.contains("춰|장"), repairedText)
        let after = try await engine.searchPage(
            in: exported, pageIndex: 0, query: engine.prepare(query: "췌장"),
            remainingResultCapacity: 100
        )
        XCTAssertEqual(after.results.count, 1)
        let result = try XCTUnwrap(after.results.first)
        XCTAssertEqual(result.matchedText, "췌장")
        XCTAssertEqual(page.selection(for: result.sourceRange)?.string, "췌장")
        XCTAssertEqual(sourcePage.string, originalText, "Export must leave the source text unchanged.")
    }

    func testExplicitlySkippedPageKeepsItsExistingText() async throws {
        let document = try makeScannedDocument()
        let originalText = try XCTUnwrap(document.page(at: 0)?.string)
        let exported = try export(document, skipped: true)
        let page = try XCTUnwrap(exported.page(at: 0))
        XCTAssertEqual(page.string, originalText)
        let engine = PDFSearchEngine()
        let outcome = try await engine.searchPage(
            in: exported, pageIndex: 0, query: engine.prepare(query: "훼장"),
            remainingResultCapacity: 100
        )
        XCTAssertEqual(outcome.results.count, 1)
    }

    func testPageWithNoNewRecognizedTextKeepsItsExistingText() throws {
        let document = try makeScannedDocument()
        let originalText = try XCTUnwrap(document.page(at: 0)?.string)
        let exported = try export(document, skipped: false, recognizedText: "")
        XCTAssertEqual(exported.page(at: 0)?.string, originalText)
    }

    func testRepairedRotatedCropPageKeepsVisibleSizeAndSelectableText() throws {
        let document = try makeScannedDocument()
        let source = try XCTUnwrap(document.page(at: 0))
        source.setBounds(CGRect(x: 20, y: 30, width: 320, height: 220), for: .cropBox)

        for rotation in [0, 90, 180, 270] {
            source.rotation = rotation
            let expectedSize = rotation % 180 == 90
                ? CGSize(width: 220, height: 320) : CGSize(width: 320, height: 220)
            let sourceInk = try visibleInkBounds(source, size: expectedSize)
            let exported = try export(document, skipped: false)
            let page = try XCTUnwrap(exported.page(at: 0))
            XCTAssertEqual(page.bounds(for: .mediaBox).size, expectedSize)
            XCTAssertEqual(page.rotation, 0)
            let text = try XCTUnwrap(page.string)
            XCTAssertTrue(text.contains(correctText), text)
            XCTAssertFalse(text.contains("훼장"), text)
            let range = (text as NSString).range(of: "췌장")
            XCTAssertNotEqual(range.location, NSNotFound)
            let selection = try XCTUnwrap(page.selection(for: range))
            let bounds = selection.bounds(for: page)
            XCTAssertGreaterThan(bounds.width, 0)
            XCTAssertGreaterThan(bounds.height, 0)
            XCTAssertTrue(page.bounds(for: .mediaBox).contains(bounds), "\(bounds)")
            let outputInk = try visibleInkBounds(page, size: expectedSize)
            XCTAssertEqual(outputInk.minX, sourceInk.minX, accuracy: 2, "rotation \(rotation)")
            XCTAssertEqual(outputInk.minY, sourceInk.minY, accuracy: 2, "rotation \(rotation)")
            XCTAssertEqual(outputInk.maxX, sourceInk.maxX, accuracy: 2, "rotation \(rotation)")
            XCTAssertEqual(outputInk.maxY, sourceInk.maxY, accuracy: 2, "rotation \(rotation)")
        }
    }

    private func export(
        _ document: PDFDocument, skipped: Bool, recognizedText: String? = nil
    ) throws -> PDFDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-OCRTextRepairTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("repaired-OCR.pdf")
        let newText = recognizedText ?? correctText
        var checkpoint = OCRCheckpoint(documentFingerprint: "repair-fixture", pageCount: 1)
        checkpoint.pages[0] = OCRPageResult(
            pageIndex: 0,
            text: skipped ? (document.page(at: 0)?.string ?? "") : newText,
            observations: skipped || newText.isEmpty ? [] : [
                OCRWordBox(text: newText, confidence: 1, x: 0.1, y: 0.6, width: 0.7, height: 0.12)
            ],
            completedAt: Date(), skippedBecauseTextExists: skipped
        )
        try SearchablePDFExporter.export(document: document, checkpoint: checkpoint, to: destination)
        return try XCTUnwrap(PDFDocument(url: destination))
    }

    private func visibleInkBounds(_ page: PDFPage, size: CGSize) throws -> CGRect {
        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        var thumbnailRect = CGRect(origin: .zero, size: size)
        let image = try XCTUnwrap(thumbnail.cgImage(
            forProposedRect: &thumbnailRect, context: nil, hints: nil
        ))
        let width = Int(size.width)
        let height = Int(size.height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard pixels[offset] < 96, pixels[offset + 1] < 96,
                      pixels[offset + 2] < 96 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxX, minX, "The page must still have visible text.")
        XCTAssertGreaterThan(maxY, minY, "The page must still have visible text.")
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// A scanned-looking page whose visible pixels say 췌장, but whose old,
    /// invisible OCR layer contains the same wrong words as the reported PDF.
    private func makeScannedDocument() throws -> PDFDocument {
        let size = CGSize(width: 360, height: 280)
        let imageContext = try XCTUnwrap(CGContext(
            data: nil, width: 720, height: 560, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        imageContext.scaleBy(x: 2, y: 2)
        imageContext.setFillColor(NSColor.white.cgColor)
        imageContext.fill(CGRect(origin: .zero, size: size))
        drawText(correctText, at: CGPoint(x: 36, y: 180), size: 32, in: imageContext)
        let image = try XCTUnwrap(imageContext.makeImage())

        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let pdfContext = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        pdfContext.beginPDFPage(nil)
        pdfContext.draw(image, in: box)
        pdfContext.setTextDrawingMode(.invisible)
        drawText(incorrectText, at: CGPoint(x: 36, y: 180), size: 8, in: pdfContext)
        pdfContext.endPDFPage()
        pdfContext.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func drawText(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Regular" as CFString, size, nil)
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: NSColor.black.cgColor]
            as CFDictionary
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)!
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
}

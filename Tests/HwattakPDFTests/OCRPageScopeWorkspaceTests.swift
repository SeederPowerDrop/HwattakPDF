// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class OCRPageScopeWorkspaceTests: XCTestCase {
    func testCurrentPageProgressUsesSelectedCountAndOriginalPageNumber() async throws {
        let fixture = try makeFixture()
        let workspace = fixture.workspace
        workspace.currentPageIndex = 2
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [2]

        workspace.startOCR(configuration: configuration)

        XCTAssertEqual(workspace.ocrState, .running(completed: 0, total: 1, page: 3))
        try await waitUntil { workspace.canUseCompletedOCRResult }
        XCTAssertEqual(workspace.ocrCheckpoint?.pageCount, 4)
        XCTAssertEqual(Set(workspace.ocrCheckpoint?.pages.keys.map { $0 } ?? []), [2])
        XCTAssertEqual(workspace.ocrState, .finished(recognizedPages: 1, skippedPages: 0))
    }

    func testPartialApplyPreservesOtherPageObjectsAnnotationsOutlineAndUndo() async throws {
        let fixture = try makeFixture()
        let workspace = fixture.workspace
        let document = try XCTUnwrap(workspace.document)
        let before = (0..<4).map { document.page(at: $0)! }
        let note = try XCTUnwrap(before[0].annotations.first)
        let link = try XCTUnwrap(before[0].annotations.first { $0.type == "Link" })
        let bytes = try Data(contentsOf: fixture.source)
        let outlinePoint = try XCTUnwrap(document.outlineRoot?.child(at: 0)?.destination?.point)
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [1]
        workspace.startOCR(configuration: configuration)
        try await waitUntil { workspace.canUseCompletedOCRResult }

        let applied = await workspace.applySearchableOCRToCurrentDocument()

        XCTAssertTrue(applied)
        XCTAssertEqual(document.pageCount, 4)
        for index in [0, 2, 3] {
            XCTAssertTrue(document.page(at: index) === before[index])
            XCTAssertTrue(document.page(at: index)?.string?.contains("Original page \(index + 1)") == true)
        }
        XCTAssertTrue(document.page(at: 0)?.annotations.first === note)
        XCTAssertFalse(document.page(at: 1) === before[1])
        XCTAssertTrue(document.page(at: 1)?.string?.contains("췌장 OCR page 2") == true)
        XCTAssertTrue(link.destination?.page === document.page(at: 1))
        XCTAssertEqual(document.outlineRoot?.child(at: 0)?.destination?.point, outlinePoint)
        XCTAssertTrue(document.outlineRoot?.child(at: 0)?.destination?.page === before[0])
        XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
        workspace.undo()
        for index in 0..<4 { XCTAssertTrue(document.page(at: index) === before[index]) }
        XCTAssertTrue(link.destination?.page === before[1])
        workspace.redo()
        XCTAssertTrue(document.page(at: 0) === before[0])
        XCTAssertTrue(document.page(at: 1)?.string?.contains("췌장 OCR page 2") == true)
        XCTAssertTrue(link.destination?.page === document.page(at: 1))
    }

    func testPartialSaveKeepsWholeDocumentAndDoesNotMutateOpenPages() async throws {
        let fixture = try makeFixture()
        let workspace = fixture.workspace
        let before = (0..<4).map { workspace.document!.page(at: $0)! }
        let bytes = try Data(contentsOf: fixture.source)
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [3, 1, 3]
        workspace.startOCR(configuration: configuration)
        try await waitUntil { workspace.canUseCompletedOCRResult }
        XCTAssertEqual(workspace.ocrConfiguration.pageIndexes, [1, 3])
        let destination = fixture.directory.appendingPathComponent("source-OCR.pdf")

        let saved = await workspace.exportSearchableOCRCopy(to: destination)

        XCTAssertTrue(saved)
        let result = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(result.pageCount, 4)
        for index in [1, 3] {
            XCTAssertTrue(result.page(at: index)?.string?.contains("췌장 OCR page \(index + 1)") == true)
        }
        for index in [0, 2] {
            XCTAssertTrue(result.page(at: index)?.string?.contains("Original page \(index + 1)") == true)
            XCTAssertEqual(result.page(at: index)?.annotations.first?.contents, "Keep note \(index)")
        }
        for index in 0..<4 { XCTAssertTrue(workspace.document?.page(at: index) === before[index]) }
        XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
        XCTAssertFalse(workspace.isDirty)
    }

    func testInvalidPageSelectionNeverStartsRecognition() throws {
        var calls = 0
        let fixture = try makeFixture(recognizer: { url, fingerprint, configuration, _ in
            calls += 1
            return try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
        })
        for selection in [[], [-1], [4], [0, Int.max]] {
            var configuration = OCRConfiguration()
            configuration.pageIndexes = selection
            fixture.workspace.startOCR(configuration: configuration)
            XCTAssertEqual(fixture.workspace.ocrState, .idle)
            XCTAssertNotNil(fixture.workspace.presentedError)
        }
        XCTAssertEqual(calls, 0)
    }

    func testApplyingEmptyRecognitionDoesNotCreateAnEdit() async throws {
        let fixture = try makeFixture(recognizer: { url, fingerprint, configuration, _ in
            var result = try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
            for index in result.pages.keys {
                result.pages[index] = OCRPageResult(pageIndex: index, text: "", observations: [],
                    completedAt: Date(), skippedBecauseTextExists: false)
            }
            return result
        })
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [1]
        let page = fixture.workspace.document?.page(at: 1)
        fixture.workspace.startOCR(configuration: configuration)
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }

        let applied = await fixture.workspace.applySearchableOCRToCurrentDocument()

        XCTAssertTrue(applied)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
        XCTAssertTrue(fixture.workspace.document?.page(at: 1) === page)
        XCTAssertEqual(fixture.workspace.statusMessage, L10n.string("status.ocr_no_changes"))
    }

    func testMissingOrExtraPageResultsCannotBeAppliedOrSaved() async throws {
        for returnedPages in [[1], [1, 2, 3]] {
            let fixture = try makeFixture(recognizer: { url, fingerprint, configuration, _ in
                try Self.checkpoint(url: url, fingerprint: fingerprint,
                    configuration: configuration, resultIndexes: returnedPages)
            })
            var configuration = OCRConfiguration()
            configuration.pageIndexes = [1, 3]
            fixture.workspace.startOCR(configuration: configuration)
            try await waitUntil { if case .finished = fixture.workspace.ocrState { return true }; return false }
            XCTAssertFalse(fixture.workspace.canUseCompletedOCRResult)
            let applied = await fixture.workspace.applySearchableOCRToCurrentDocument()
            let saved = await fixture.workspace.exportSearchableOCRCopy(to:
                fixture.directory.appendingPathComponent("invalid.pdf"))
            XCTAssertFalse(applied)
            XCTAssertFalse(saved)
            XCTAssertFalse(fixture.workspace.isDirty)
        }
    }

    func testChangingScopeReplacesCompletedSelectionWithoutReusingOtherPages() async throws {
        let fixture = try makeFixture()
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [0]
        fixture.workspace.startOCR(configuration: configuration)
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        let first = try XCTUnwrap(fixture.workspace.ocrCheckpoint?.configurationFingerprint)
        configuration.pageIndexes = [2, 3]
        fixture.workspace.startOCR(configuration: configuration)
        XCTAssertNil(fixture.workspace.ocrCheckpoint)
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        XCTAssertEqual(Set(fixture.workspace.ocrCheckpoint?.pages.keys.map { $0 } ?? []), [2, 3])
        XCTAssertNotEqual(fixture.workspace.ocrCheckpoint?.configurationFingerprint, first)
    }

    func testOpeningAnotherDocumentClearsPreviousPageScope() async throws {
        let fixture = try makeFixture()
        var configuration = OCRConfiguration()
        configuration.pageIndexes = [2, 3]
        configuration.languages = ["ko-KR"]
        fixture.workspace.startOCR(configuration: configuration)
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        let anotherSource = fixture.directory.appendingPathComponent("another.pdf")
        try FileManager.default.copyItem(at: fixture.source, to: anotherSource)

        XCTAssertTrue(fixture.workspace.open(url: anotherSource))

        XCTAssertNil(fixture.workspace.ocrConfiguration.pageIndexes)
        XCTAssertEqual(fixture.workspace.ocrConfiguration.languages, ["ko-KR"])
        XCTAssertNil(fixture.workspace.ocrCheckpoint)
        XCTAssertFalse(fixture.workspace.canUseCompletedOCRResult)
    }

    private func makeFixture(recognizer: WorkspaceOCRRecognizer? = nil) throws
        -> (directory: URL, source: URL, workspace: PDFWorkspaceState) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-OCRScopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let data = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 260)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &bounds, nil))
        for index in 0..<4 {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let text = NSAttributedString(string: "Original page \(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 20, y: 180)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        for index in 0..<4 {
            let note = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 25, height: 25), forType: .text, withProperties: nil)
            note.contents = "Keep note \(index)"
            document.page(at: index)?.addAnnotation(note)
        }
        let outline = PDFOutline()
        let child = PDFOutline()
        child.label = "Unchanged destination"
        child.destination = PDFDestination(page: document.page(at: 0)!, at: CGPoint(x: 17, y: 193))
        outline.insertChild(child, at: 0)
        document.outlineRoot = outline
        let link = PDFAnnotation(bounds: CGRect(x: 30, y: 80, width: 80, height: 20), forType: .link, withProperties: nil)
        link.action = PDFActionGoTo(destination: PDFDestination(page: document.page(at: 1)!, at: CGPoint(x: 21, y: 185)))
        document.page(at: 0)?.addAnnotation(link)
        let source = directory.appendingPathComponent("source.pdf")
        XCTAssertTrue(document.write(to: source))
        let workspace = PDFWorkspaceState(ocrRecognizer: recognizer ?? { url, fingerprint, configuration, _ in
            try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
        })
        XCTAssertTrue(workspace.open(url: source))
        workspace.setMode(.editing)
        return (directory, source, workspace)
    }

    private static func checkpoint(url: URL, fingerprint: String?, configuration: OCRConfiguration,
                                   resultIndexes: [Int]? = nil) throws -> OCRCheckpoint {
        let document = try XCTUnwrap(PDFDocument(url: url))
        var result = OCRCheckpoint(documentFingerprint: try fingerprint ?? VisionOCRService.fingerprint(for: url),
            pageCount: document.pageCount,
            configurationFingerprint: VisionOCRService.configurationFingerprint(for: configuration))
        for index in try resultIndexes ?? configuration.resolvedPageIndexes(pageCount: document.pageCount) {
            let text = "췌장 OCR page \(index + 1)"
            result.pages[index] = OCRPageResult(pageIndex: index, text: text, observations: [
                OCRWordBox(text: text, confidence: 1, x: 0.1, y: 0.6, width: 0.8, height: 0.1)
            ], completedAt: Date(), skippedBecauseTextExists: false)
        }
        return result
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for OCR result")
    }
}

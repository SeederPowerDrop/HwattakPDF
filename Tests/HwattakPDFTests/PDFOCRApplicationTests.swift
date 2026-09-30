// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFOCRApplicationTests: XCTestCase {
    func testApplyRerunsAnExistingQueryAgainstRecognizedText() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.searchText = "Searchable"
        workspace.performSearch()
        try await waitUntil { workspace.searchProgress.phase == .completed }
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil { workspace.canUseCompletedOCRResult }

        let applied = await workspace.applySearchableOCRToCurrentDocument()

        XCTAssertTrue(applied)
        try await waitUntil { workspace.searchProgress.phase == .completed }
        XCTAssertEqual(workspace.searchCompletedQuery, "Searchable")
        XCTAssertEqual(workspace.searchNavigatorResults.count, 1)
        XCTAssertEqual(workspace.activeSearchSelection?.string, "Searchable")
    }

    func testBackgroundExportYieldsToUIAndPreservesFileCreatedWhileRendering() async throws {
        let fixture = try makeWorkspace(pageCount: 12)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil { workspace.canUseCompletedOCRResult }
        let destination = fixture.directory.appendingPathComponent("document-OCR.pdf")
        let externalData = Data("A different file created while OCR was being saved.".utf8)
        var handledMainActorAction = false
        let observation = workspace.$isExportingOCR.dropFirst().sink { busy in
            guard busy else { return }
            Task { @MainActor in
                guard workspace.isExportingOCR else { return }
                handledMainActorAction = true
                XCTAssertFalse(workspace.canUseCompletedOCRResult)
                XCTAssertFalse(workspace.saveSynchronously())
                try externalData.write(to: destination)
            }
        }
        defer { observation.cancel() }

        let exported = await workspace.exportSearchableOCRCopy(to: destination)

        XCTAssertTrue(handledMainActorAction, "The UI must run while PDF rendering is suspended.")
        XCTAssertFalse(exported)
        XCTAssertEqual(try Data(contentsOf: destination), externalData)
        XCTAssertFalse(workspace.isExportingOCR)
        XCTAssertTrue(workspace.canUseCompletedOCRResult)
    }

    func testApplyIsSearchableUndoableAndDoesNotWriteSourceUntilSave() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let originalBytes = try Data(contentsOf: fixture.url)
        let originalDocument = try XCTUnwrap(workspace.document)
        let originalPage = try XCTUnwrap(originalDocument.page(at: 0))
        let originalAnnotation = try XCTUnwrap(originalPage.annotations.first)
        var configuration = OCRConfiguration()
        configuration.languages = ["fr-FR", "en-US"]
        workspace.startOCR(configuration: configuration)
        try await waitUntil { workspace.canUseCompletedOCRResult }
        XCTAssertEqual(workspace.ocrConfiguration, configuration)

        let applied = await workspace.applySearchableOCRToCurrentDocument()

        XCTAssertTrue(applied)
        XCTAssertFalse(workspace.isApplyingOCR)
        XCTAssertTrue(workspace.document === originalDocument)
        XCTAssertTrue(workspace.document?.string?.contains("Searchable OCR text") == true)
        XCTAssertTrue(workspace.document?.page(at: 0)?.annotations.isEmpty == true)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)
        XCTAssertFalse(workspace.canUseCompletedOCRResult)
        XCTAssertEqual(try Data(contentsOf: fixture.url), originalBytes)
        XCTAssertTrue(workspace.document?.outlineRoot?.child(at: 0)?.destination?.page === workspace.document?.page(at: 0))

        workspace.undo()
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(workspace.document?.page(at: 0) === originalPage)
        XCTAssertTrue(workspace.document?.page(at: 0)?.annotations.first === originalAnnotation)
        XCTAssertTrue(workspace.document?.outlineRoot?.child(at: 0)?.destination?.page === originalPage)
        workspace.redo()
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.document?.string?.contains("Searchable OCR text") == true)
        XCTAssertTrue(workspace.saveSynchronously())
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(PDFDocument(url: fixture.url)?.string?.contains("Searchable OCR text") == true)
    }

    func testCompleteResultExportsSeparateFileWithoutChangingWorkspaceOrSource() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try Data(contentsOf: fixture.url)
        fixture.workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        let copy = fixture.directory.appendingPathComponent("document-OCR.pdf")
        let savedCopy = await fixture.workspace.exportSearchableOCRCopy(to: copy)
        XCTAssertTrue(savedCopy)
        XCTAssertTrue(PDFDocument(url: copy)?.string?.contains("Searchable OCR text") == true)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
        XCTAssertFalse(fixture.workspace.isDirty)
        let overwrittenSource = await fixture.workspace.exportSearchableOCRCopy(to: fixture.url)
        XCTAssertFalse(overwrittenSource)
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
    }

    func testApplicationLargerThanHistoryPageBudgetRemainsUndoable() async throws {
        let count = PDFEditHistory.defaultRetainedPageLimit + 1
        let fixture = try makeWorkspace(pageCount: count)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalFirstPage = fixture.workspace.document?.page(at: 0)
        let originalLastPage = fixture.workspace.document?.page(at: count - 1)
        fixture.workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }

        let applied = await fixture.workspace.applySearchableOCRToCurrentDocument()

        XCTAssertTrue(applied)
        XCTAssertTrue(fixture.workspace.canUndo)
        fixture.workspace.undo()
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertEqual(fixture.workspace.pageCount, count)
        XCTAssertTrue(fixture.workspace.document?.page(at: 0) === originalFirstPage)
        XCTAssertTrue(fixture.workspace.document?.page(at: count - 1) === originalLastPage)
    }

    func testPartialAndMismatchedCheckpointCannotBeUsed() async throws {
        for invalidKind in 0..<3 {
            let fixture = try makeWorkspace(recognizer: { url, fingerprint, configuration, _ in
                var result = try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
                if invalidKind == 0 { result.pages = [:] }
                if invalidKind == 1 {
                    var mismatched = OCRCheckpoint(documentFingerprint: "another-document", pageCount: 1,
                                                   configurationFingerprint: result.configurationFingerprint)
                    mismatched.pages = result.pages
                    result = mismatched
                }
                if invalidKind == 2 {
                    let wrongPage = try XCTUnwrap(result.pages[0])
                    result.pages = [1: wrongPage]
                }
                return result
            })
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            fixture.workspace.startOCR(configuration: OCRConfiguration())
            try await waitUntil { fixture.workspace.ocrCheckpoint != nil }
            XCTAssertFalse(fixture.workspace.canUseCompletedOCRResult)
            let applied = await fixture.workspace.applySearchableOCRToCurrentDocument()
            XCTAssertFalse(applied)
            let output = fixture.directory.appendingPathComponent("rejected.pdf")
            let exported = await fixture.workspace.exportSearchableOCRCopy(to: output)
            XCTAssertFalse(exported)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertFalse(fixture.workspace.isDirty)
        }
    }

    func testEditInvalidatesFinishedResult() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        fixture.workspace.rotateSelectedPages(clockwise: true)
        XCTAssertNil(fixture.workspace.ocrCheckpoint)
        XCTAssertFalse(fixture.workspace.canUseCompletedOCRResult)
        XCTAssertEqual(fixture.workspace.ocrState, .idle)
        let applied = await fixture.workspace.applySearchableOCRToCurrentDocument()
        XCTAssertFalse(applied)
        XCTAssertEqual(fixture.workspace.document?.page(at: 0)?.rotation, 90)
    }

    func testChangedSourceRejectsApplicationWithoutLosingOriginalPages() async throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        fixture.workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil { fixture.workspace.canUseCompletedOCRResult }
        let originalPage = fixture.workspace.document?.page(at: 0)
        let outsideDocument = try makeDocument()
        outsideDocument.page(at: 0)?.rotation = 90
        XCTAssertTrue(outsideDocument.write(to: fixture.url))
        let changedBytes = try Data(contentsOf: fixture.url)

        let applied = await fixture.workspace.applySearchableOCRToCurrentDocument()

        XCTAssertFalse(applied)
        XCTAssertFalse(fixture.workspace.isApplyingOCR)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertTrue(fixture.workspace.document?.page(at: 0) === originalPage)
        XCTAssertEqual(try Data(contentsOf: fixture.url), changedBytes)
        XCTAssertNotNil(fixture.workspace.presentedError)
    }

    func testRestartClearsPreviousResultAndFailedRunCannotExportIt() async throws {
        var failNextRun = false
        let fixture = try makeWorkspace(recognizer: { url, fingerprint, configuration, _ in
            if failNextRun { throw WorkspaceError.operationFailed("recognition failed") }
            return try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
        })
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil { workspace.canUseCompletedOCRResult }
        failNextRun = true
        workspace.startOCR(configuration: OCRConfiguration())
        XCTAssertNil(workspace.ocrCheckpoint)
        XCTAssertFalse(workspace.canUseCompletedOCRResult)
        try await waitUntil { if case .failed = workspace.ocrState { return true }; return false }
        XCTAssertFalse(workspace.canUseCompletedOCRResult)
        XCTAssertNil(workspace.ocrCheckpoint)
    }

    private func makeWorkspace(pageCount: Int = 1, recognizer: WorkspaceOCRRecognizer? = nil) throws -> (directory: URL, url: URL, workspace: PDFWorkspaceState) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HwattakPDF-OCRApplyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("document.pdf")
        XCTAssertTrue(try makeDocument(pageCount: pageCount).write(to: url))
        let workspace = PDFWorkspaceState(ocrRecognizer: recognizer ?? { url, fingerprint, configuration, _ in
            try Self.checkpoint(url: url, fingerprint: fingerprint, configuration: configuration)
        })
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        return (directory, url, workspace)
    }

    private func makeDocument(pageCount: Int = 1) throws -> PDFDocument {
        let document = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        for _ in 0..<pageCount {
            let page = try XCTUnwrap(PDFPage(image: image))
            page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 20), forType: .text, withProperties: nil))
            document.insert(page, at: document.pageCount)
        }
        let page = try XCTUnwrap(document.page(at: 0))
        let root = PDFOutline()
        let section = PDFOutline()
        section.label = "Section"
        section.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 240))
        root.insertChild(section, at: 0)
        document.outlineRoot = root
        return document
    }

    private static func checkpoint(url: URL, fingerprint: String?, configuration: OCRConfiguration) throws -> OCRCheckpoint {
        let document = try XCTUnwrap(PDFDocument(url: url))
        var result = OCRCheckpoint(
            documentFingerprint: try fingerprint ?? VisionOCRService.fingerprint(for: url),
            pageCount: document.pageCount,
            configurationFingerprint: VisionOCRService.configurationFingerprint(for: configuration)
        )
        for index in 0..<document.pageCount {
            result.pages[index] = OCRPageResult(pageIndex: index, text: "Searchable OCR text", observations: [
                OCRWordBox(text: "Searchable OCR text", confidence: 1, x: 0.1, y: 0.5, width: 0.8, height: 0.1)
            ], completedAt: Date(), skippedBecauseTextExists: false)
        }
        return result
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for OCR state")
    }
}

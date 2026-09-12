// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

@MainActor
final class RecoverySchedulingTests: XCTestCase {
    private var root: URL!
    private var previousRecoverySetting: Any?

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryScheduling-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        previousRecoverySetting = UserDefaults.standard.object(forKey: PDFRecoveryStore.enabledKey)
        UserDefaults.standard.set(true, forKey: PDFRecoveryStore.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.set(previousRecoverySetting, forKey: PDFRecoveryStore.enabledKey)
        try? FileManager.default.removeItem(at: root)
    }

    private func makePDF() throws -> URL {
        let url = root.appendingPathComponent("\(UUID()).pdf")
        var bounds = CGRect(x: 0, y: 0, width: 120, height: 180)
        let writer = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        writer.beginPDFPage(nil)
        writer.setFillColor(NSColor.white.cgColor)
        writer.fill(bounds)
        writer.endPDFPage()
        writer.closePDF()
        return url
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 7) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for OCR/recovery state")
    }

    private enum Completion { case success, cancellation, failure }

    private func checkRecoveryAfterOCR(_ completion: Completion, disableRecovery: Bool = false) async throws {
        let gate = RecoveryOCRGate()
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let workspace = PDFWorkspaceState(ocrRecognizer: { _, _, _, _ in try await gate.wait() })
        defer { gate.finish(); workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: try makePDF()))
        workspace.configureRecovery(store: store)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil({ gate.isWaiting })
        // Exercise the production five-second timer while recognition is
        // deliberately suspended, independently of Vision speed/languages.
        try await Task.sleep(nanoseconds: 5_300_000_000)
        XCTAssertTrue(workspace.ocrState.isActivelyProcessing)
        XCTAssertTrue(store.records().isEmpty)
        if disableRecovery { UserDefaults.standard.set(false, forKey: PDFRecoveryStore.enabledKey) }
        switch completion {
        case .success: gate.finish()
        case .cancellation:
            workspace.cancelOCR()
            gate.finish()
        case .failure: gate.finish(error: RecoveryOCRGate.Failure.recognition)
        }
        try await waitUntil({ !workspace.ocrState.isActivelyProcessing })
        if disableRecovery {
            try await Task.sleep(nanoseconds: 5_300_000_000)
            XCTAssertTrue(store.records().isEmpty)
        } else {
            try await waitUntil({ !store.records().isEmpty })
            let record = try XCTUnwrap(store.records().first)
            XCTAssertEqual(PDFDocument(url: store.pdfURL(for: record))?.page(at: 0)?.rotation, 90)
            XCTAssertEqual(store.records().count, 1)
        }
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNil(workspace.recoveryWarning)
        switch completion {
        case .success: XCTAssertEqual(workspace.ocrState, .finished(recognizedPages: 0, skippedPages: 0))
        case .cancellation: XCTAssertEqual(workspace.ocrState, .idle)
        case .failure:
            guard case .failed = workspace.ocrState else { return XCTFail("OCR failure must remain visible") }
        }
    }

    func testOCRSuccessRearmsSkippedRecovery() async throws { try await checkRecoveryAfterOCR(.success) }
    func testOCRCancellationRearmsSkippedRecovery() async throws { try await checkRecoveryAfterOCR(.cancellation) }
    func testOCRFailureRearmsSkippedRecovery() async throws { try await checkRecoveryAfterOCR(.failure) }
    func testOCRCompletionRespectsDisabledRecovery() async throws {
        try await checkRecoveryAfterOCR(.success, disableRecovery: true)
    }

    func testOldOCRCompletionCannotClearReplacementRunOrRestoreOldDocument() async throws {
        let oldGate = RecoveryOCRGate(), newGate = RecoveryOCRGate()
        var run = 0
        let workspace = PDFWorkspaceState(ocrRecognizer: { _, _, _, _ in
            run += 1
            return try await (run == 1 ? oldGate : newGate).wait()
        })
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Recovery"))
        defer { oldGate.finish(); newGate.finish(); workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: try makePDF()))
        workspace.configureRecovery(store: store)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil({ oldGate.isWaiting })
        workspace.closeDiscardingChanges()
        let replacement = try makePDF()
        XCTAssertTrue(workspace.open(url: replacement))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        workspace.rotateSelectedPages(clockwise: true)
        workspace.startOCR(configuration: OCRConfiguration())
        try await waitUntil({ newGate.isWaiting })
        oldGate.finish()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(workspace.ocrState.isActivelyProcessing)
        XCTAssertEqual(workspace.documentURL, replacement)
        newGate.finish()
        try await waitUntil({ !store.records().isEmpty })
        let record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(store.records().count, 1)
        XCTAssertEqual(PDFDocument(url: store.pdfURL(for: record))?.page(at: 0)?.rotation, 180)
        XCTAssertEqual(record.displayName, replacement.lastPathComponent)
        XCTAssertEqual(workspace.ocrState, .finished(recognizedPages: 0, skippedPages: 0))
    }

    func testRecoveryConfiguredAfterMarkingLoadedCopyStillCreatesSnapshot() async throws {
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let workspace = PDFWorkspaceState()
        defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: try makePDF()))
        workspace.markAsRecoveredCopy()
        workspace.configureRecovery(store: store)
        try await waitUntil({ !store.records().isEmpty })
        XCTAssertEqual(store.records().count, 1)
    }

    func testResumingLazyRecoveredCopyArmsRecoveryAfterLoading() async throws {
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let workspace = PDFWorkspaceState()
        defer { workspace.closeDiscardingChanges() }
        workspace.restoreHibernated(url: try makePDF(), pageCount: 1)
        workspace.markAsRecoveredCopy()
        workspace.configureRecovery(store: store)
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertTrue(workspace.resumeIfNeeded())
        try await waitUntil({ !store.records().isEmpty })
        XCTAssertEqual(store.records().count, 1)
        XCTAssertTrue(workspace.isDirty)
    }
}

@MainActor
private final class RecoveryOCRGate {
    enum Failure: Error { case recognition }
    private var continuation: CheckedContinuation<OCRCheckpoint, Error>?
    var isWaiting: Bool { continuation != nil }

    func wait() async throws -> OCRCheckpoint {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(error: Error? = nil) {
        guard let pending = continuation else { return }
        continuation = nil
        if let error { pending.resume(throwing: error) }
        else { pending.resume(returning: OCRCheckpoint(documentFingerprint: "recovery-test", pageCount: 1)) }
    }
}

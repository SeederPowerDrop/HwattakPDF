// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

/// Regression coverage for the highest-risk save failure: silently replacing
/// edits that another application wrote after this workspace opened its PDF.
final class PDFExternalModificationConflictTests: XCTestCase {
    func testUnchangedSourceResolvesItsExactContentFingerprint() throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }

        let version = try PDFSourceFileVersion.capture(at: fixture.sourceURL)
        let resolved = OCRSourceFingerprintResolver.resolve(
            sourceURL: fixture.sourceURL,
            expectedVersion: version
        )

        XCTAssertEqual(resolved, try VisionOCRService.fingerprint(for: fixture.sourceURL))
    }

    func testExternalReplacementBeforeHashRejectsStaleSourceVersion() throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try PDFSourceFileVersion.capture(at: fixture.sourceURL)

        try replaceSourcePDF(at: fixture.sourceURL, pageCount: 2)

        XCTAssertNil(
            OCRSourceFingerprintResolver.resolve(
                sourceURL: fixture.sourceURL,
                expectedVersion: original
            )
        )
    }

    func testExternalReplacementDuringHashRejectsCompletedStaleHash() throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let original = try PDFSourceFileVersion.capture(at: fixture.sourceURL)

        let resolved = OCRSourceFingerprintResolver.resolve(
            sourceURL: fixture.sourceURL,
            expectedVersion: original,
            fingerprinter: { url in
                let fingerprint = try VisionOCRService.fingerprint(for: url)
                try self.replaceSourcePDF(at: url, pageCount: 2)
                return fingerprint
            }
        )

        XCTAssertNil(resolved)
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.pageCount, 2)
    }

    func testBackgroundSourceHashStopsWhenParentOperationIsCancelled() async throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let version = try PDFSourceFileVersion.capture(at: fixture.sourceURL)
        let started = DispatchSemaphore(value: 0)
        let task = Task<String?, Error> {
            try await OCRSourceFingerprintResolver.resolveInBackground(
                sourceURL: fixture.sourceURL,
                expectedVersion: version,
                fingerprinter: { _ in
                    started.signal()
                    // This represents a large streaming read. Production's
                    // fingerprinter performs the same check for every 1 MiB.
                    while true {
                        try Task.checkCancellation()
                    }
                }
            )
        }

        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelling OCR must also cancel the detached source hash.")
        } catch is CancellationError {
            // Expected: the worker exits at its next chunk cancellation check.
        }
    }

    @MainActor
    func testCancellationAfterRecognizerReturnsStillCleansUpAndAllowsRestart() async throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = OCRSuccessAfterCancellationGate()
        let workspace = PDFWorkspaceState(
            ocrRecognizer: { _, fingerprint, configuration, _ in
                await gate.waitForRelease()
                return OCRCheckpoint(
                    documentFingerprint: fingerprint ?? "snapshot-fingerprint",
                    pageCount: 1,
                    configurationFingerprint: VisionOCRService.configurationFingerprint(
                        for: configuration
                    )
                )
            }
        )
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))

        workspace.startOCR(configuration: OCRConfiguration())
        await gate.waitUntilStarted()
        workspace.cancelOCR()
        await gate.release()

        let returnedToIdle = await waitForOCRState(.idle, in: workspace)
        XCTAssertTrue(
            returnedToIdle,
            "A late cancellation must leave the OCR state machine reusable."
        )
        workspace.startOCR(configuration: OCRConfiguration())
        let restartedSuccessfully = await waitForOCRState(
            .finished(recognizedPages: 0, skippedPages: 0),
            in: workspace
        )
        XCTAssertTrue(
            restartedSuccessfully,
            "Clearing ocrTask after cancellation must allow another OCR run."
        )
    }

    @MainActor
    func testDirtyWorkspaceFallsBackToHashingExactOCRSnapshot() throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        XCTAssertNotNil(workspace.reusableOCRSourceVersion)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertNil(workspace.reusableOCRSourceVersion)

        let snapshotURL = fixture.directory.appendingPathComponent("dirty-snapshot.pdf")
        XCTAssertTrue(workspace.document?.write(to: snapshotURL) == true)
        let exactSnapshotFingerprint = try VisionOCRService.fingerprint(for: snapshotURL)

        XCTAssertEqual(
            try VisionOCRService.resolveDocumentFingerprint(
                for: snapshotURL,
                suppliedFingerprint: nil
            ),
            exactSnapshotFingerprint
        )
    }

    @MainActor
    func testExternalAtomicReplacementBlocksOverwriteAndPreservesBothVersions() throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(
            workspace.open(url: fixture.sourceURL),
            workspace.presentedError ?? "Open failed without an error message"
        )
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        try replaceSourcePDF(at: fixture.sourceURL, pageCount: 2)
        let externalBytes = try Data(contentsOf: fixture.sourceURL)

        XCTAssertFalse(workspace.saveSynchronously())
        XCTAssertTrue(workspace.isDirty, "The user's in-memory edits must remain recoverable.")
        XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), externalBytes)
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.pageCount, 2)
        XCTAssertEqual(
            workspace.presentedError,
            L10n.format("error.external_file_modified", fixture.sourceURL.lastPathComponent)
        )
    }

    @MainActor
    func testMissingOriginalFailsClosedInsteadOfSilentlyRecreatingIt() throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        try FileManager.default.removeItem(at: fixture.sourceURL)

        XCTAssertFalse(workspace.saveSynchronously())
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    }

    @MainActor
    func testSaveAsRemainsARecoveryPathAfterOriginalChangedExternally() throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        try replaceSourcePDF(at: fixture.sourceURL, pageCount: 2)
        let externalBytes = try Data(contentsOf: fixture.sourceURL)
        let copyURL = fixture.directory.appendingPathComponent("recovered-copy.pdf")

        XCTAssertTrue(workspace.saveSynchronously(as: copyURL))
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, copyURL)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), externalBytes)
        XCTAssertEqual(PDFDocument(url: copyURL)?.page(at: 0)?.rotation, 90)
    }

    @MainActor
    func testSuccessfulOverwriteRefreshesBaselineForTheNextSave() throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)

        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.saveSynchronously())
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.saveSynchronously())

        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.page(at: 0)?.rotation, 180)
    }

    @MainActor
    func testCleanHibernatedTabAdoptsExternalVersionWhenItResumes() throws {
        let fixture = try makeFixture(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        XCTAssertTrue(workspace.hibernateIfPossible())
        try replaceSourcePDF(at: fixture.sourceURL, pageCount: 2)

        XCTAssertTrue(workspace.resumeIfNeeded())
        XCTAssertEqual(workspace.pageCount, 2)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.saveSynchronously())
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.pageCount, 2)
    }

    private func makeFixture(pageCount: Int) throws -> (directory: URL, sourceURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Conflict-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("original.pdf")
        try writePDF(pageCount: pageCount, to: sourceURL)
        return (directory, sourceURL)
    }

    @MainActor
    private func waitForOCRState(
        _ expectedState: OCRRunState,
        in workspace: PDFWorkspaceState
    ) async -> Bool {
        // Poll briefly instead of sleeping for a fixed long interval. This
        // keeps the race test fast on developer Macs and tolerant of busy CI.
        for _ in 0..<200 {
            if workspace.ocrState == expectedState {
                return true
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return workspace.ocrState == expectedState
    }

    /// Writes a valid but structurally distinct PDF so the test verifies that
    /// the competing editor's complete bytes survive, not just its timestamp.
    private func replaceSourcePDF(at sourceURL: URL, pageCount: Int) throws {
        let replacementURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("external-\(UUID().uuidString).pdf")
        try writePDF(pageCount: pageCount, to: replacementURL)
        _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: replacementURL)
    }

    private func writePDF(pageCount: Int, to url: URL) throws {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
                (index.isMultiple(of: 2) ? NSColor.white : NSColor.lightGray).setFill()
                rect.fill()
                return true
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        guard document.write(to: url) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// Deterministically returns a successful OCR value only after the test has
/// issued cancellation, reproducing the success/cancel commit-window race.
private actor OCRSuccessAfterCancellationGate {
    private var didStart = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        didStart = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !didStart {
            await Task.yield()
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

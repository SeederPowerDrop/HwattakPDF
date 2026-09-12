// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

@MainActor
final class RecoveryLifecycleTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryLifecycle-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makePDF(_ name: String = UUID().uuidString) throws -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension("pdf")
        var bounds = CGRect(x: 0, y: 0, width: 120, height: 180)
        let writer = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        writer.beginPDFPage(nil)
        writer.setFillColor(NSColor.blue.cgColor)
        writer.fill(bounds)
        writer.endPDFPage()
        writer.closePDF()
        return url
    }

    private func lazyRecovery(at url: URL) -> PDFWorkspaceState {
        let workspace = PDFWorkspaceState()
        workspace.configureRecovery(store: PDFRecoveryStore(directory: root.appendingPathComponent("Recovery")))
        workspace.restoreHibernated(url: url, pageCount: 1)
        workspace.markAsRecoveredCopy()
        return workspace
    }

    func testClosingInactiveSessionRecoveryRequestsDecisionAndActuallyRemovesTab() throws {
        let persistence = RecoveryTestSessionPersistence()
        let first = MultiDocumentWorkspaceState(sessionStore: WorkspaceSessionStore(
            persistence: persistence, bookmarkCoder: RecoveryTestBookmarkCoder()))
        let normalID = try XCTUnwrap(first.addTab(opening: makePDF("normal")))
        let recoveredID = try XCTUnwrap(first.addTab(opening: makePDF("Recovered")))
        let recovered = try XCTUnwrap(first.activeWorkspace)
        recovered.configureRecovery(store: PDFRecoveryStore(directory: root.appendingPathComponent("Recovery")))
        recovered.markAsRecoveredCopy()
        first.selectTab(normalID)
        first.freezeSessionPersistenceAfterFlushing()
        let restored = MultiDocumentWorkspaceState(sessionStore: WorkspaceSessionStore(
            persistence: persistence, bookmarkCoder: RecoveryTestBookmarkCoder()))
        defer {
            first.allTabs.forEach { $0.workspace.closeDiscardingChanges() }
            restored.freezeSessionPersistenceAfterFlushing()
            restored.allTabs.forEach { $0.workspace.closeDiscardingChanges() }
        }
        let inactive = try XCTUnwrap(restored.tabs.first { $0.id == recoveredID }?.workspace)
        XCTAssertTrue(inactive.isRecoveryCopy && inactive.isDirty && inactive.isHibernated)
        var decisions = 0
        XCTAssertTrue(UnsavedChangesGuard.confirmAndClose(workspaces: [inactive], decisionProvider: { _ in
            decisions += 1
            return .dontSave
        }))
        XCTAssertEqual(decisions, 1)
        XCTAssertTrue(restored.closeTab(recoveredID))
        XCTAssertFalse(restored.tabs.contains { $0.id == recoveredID })
        XCTAssertEqual(restored.activeTabID, normalID)
    }

    func testSavingLazyRecoveryLoadsDocumentAndPreservesOriginal() throws {
        let source = try makePDF()
        let original = try Data(contentsOf: source)
        let workspace = lazyRecovery(at: source)
        defer { workspace.closeDiscardingChanges() }
        let output = root.appendingPathComponent("saved.pdf")
        XCTAssertTrue(UnsavedChangesGuard.confirmAndClose(workspaces: [workspace], decisionProvider: { _ in .saveCopy },
            copyDestinationProvider: { _ in output }))
        XCTAssertNotNil(PDFDocument(url: output))
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertFalse(workspace.hasOpenDocument)
        XCTAssertFalse(workspace.isDirty)
    }

    func testLazyRecoveryCancelDoesNotLoadOrDiscardIt() throws {
        let source = try makePDF()
        let workspace = lazyRecovery(at: source)
        defer { workspace.closeDiscardingChanges() }
        try FileManager.default.removeItem(at: source)
        var didClose = false
        XCTAssertFalse(UnsavedChangesGuard.confirmAndClose(workspaces: [workspace], decisionProvider: { _ in .cancel },
            beforeClosing: { didClose = true }))
        XCTAssertFalse(didClose)
        XCTAssertTrue(workspace.isDirty && workspace.isHibernated && workspace.isRecoveryCopy)
        XCTAssertNil(workspace.presentedError, "Cancel must not attempt to reopen a missing backing file")
    }

    func testFailedLazyRecoverySavePreservesEarlierPendingDiscard() throws {
        let first = lazyRecovery(at: try makePDF())
        let missing = try makePDF()
        let second = lazyRecovery(at: missing)
        defer { first.closeDiscardingChanges(); second.closeDiscardingChanges() }
        try FileManager.default.removeItem(at: missing)
        var didClose = false
        let output = root.appendingPathComponent("should-not-exist.pdf")
        XCTAssertFalse(UnsavedChangesGuard.confirmAndClose(workspaces: [first, second], decisionProvider: {
            $0 === first ? .dontSave : .saveCopy
        }, copyDestinationProvider: { _ in output }, beforeClosing: { didClose = true }))
        XCTAssertFalse(didClose)
        XCTAssertTrue(first.isDirty && first.isHibernated)
        XCTAssertTrue(second.isDirty && second.isHibernated)
        XCTAssertNotNil(second.presentedError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testLaterCancelPreservesEarlierLazyRecoveryDiscard() throws {
        let first = lazyRecovery(at: try makePDF())
        let second = lazyRecovery(at: try makePDF())
        defer { first.closeDiscardingChanges(); second.closeDiscardingChanges() }
        XCTAssertFalse(UnsavedChangesGuard.confirmAndClose(workspaces: [first, second], decisionProvider: {
            $0 === first ? .dontSave : .cancel
        }))
        XCTAssertTrue(first.isDirty && first.isHibernated)
        XCTAssertTrue(second.isDirty && second.isHibernated)
    }

    func testConfirmationOnlyIncludesLazyRecoveryWithoutClosingIt() throws {
        let workspace = lazyRecovery(at: try makePDF())
        defer { workspace.closeDiscardingChanges() }
        var count = 0
        XCTAssertTrue(UnsavedChangesGuard.confirmAndClose(workspaces: [workspace], decisionProvider: { _ in
            count += 1
            return .dontSave
        }, closeDocuments: false))
        XCTAssertEqual(count, 1)
        XCTAssertTrue(workspace.isDirty && workspace.isHibernated)
    }

    func testClosingCleanHibernatedImageRemovesPreviewWithoutReopening() throws {
        let source = root.appendingPathComponent("image.tiff")
        let image = NSImage(size: CGSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        let bytes = try XCTUnwrap(image.tiffRepresentation)
        try bytes.write(to: source)
        let preview = try ImagePDFConverter.makePreviewPDF(from: source)
        let workspace = PDFWorkspaceState()
        defer { workspace.closeDiscardingChanges() }
        XCTAssertTrue(workspace.open(url: preview))
        workspace.associateImageSource(source)
        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertTrue(UnsavedChangesGuard.confirmAndClose(workspaces: [workspace], decisionProvider: { _ in
            XCTFail("A clean image preview should not require an unsaved-edit decision")
            return .cancel
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.path))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertFalse(workspace.hasOpenDocument)
    }
}

private final class RecoveryTestSessionPersistence: WorkspaceSessionDataPersisting {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

private struct RecoveryTestBookmarkCoder: WorkspaceSessionBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }
}

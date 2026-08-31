// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import PDFKit
import XCTest
@testable import VibePDF

final class MultiDocumentEncryptedBatchTests: XCTestCase {
    @MainActor
    func testEncryptedBatchTabStaysLazyUntilItIsSelected() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let recentStore = makeRecentStore()
        var promptRejectionStates: [Bool] = []
        let encryptedWorkspace = PDFWorkspaceState(
            passwordProvider: { _, wasRejected in
                promptRejectionStates.append(wasRejected)
                return fixture.password
            }
        )
        let workspace = MultiDocumentWorkspaceState(
            initialWorkspace: encryptedWorkspace,
            recentDocumentsStore: recentStore
        )

        let opened = workspace.openPDFsInTabs(
            urls: [fixture.encryptedURL, fixture.plainURL]
        )

        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(promptRejectionStates.isEmpty)
        let encryptedTab = try XCTUnwrap(
            workspace.tabs.first { $0.workspace.documentURL == fixture.encryptedURL }
        )
        XCTAssertTrue(encryptedTab.workspace.isHibernated)
        XCTAssertNil(encryptedTab.workspace.document)
        XCTAssertEqual(workspace.activeWorkspace?.documentURL, fixture.plainURL)
        XCTAssertEqual(recentStore.documents.map(\.displayName), ["plain.pdf"])

        workspace.selectTab(encryptedTab.id)

        XCTAssertEqual(promptRejectionStates, [false])
        XCTAssertEqual(workspace.activeTabID, encryptedTab.id)
        XCTAssertNotNil(encryptedTab.workspace.document)
        XCTAssertFalse(encryptedTab.workspace.document?.isLocked ?? true)
        XCTAssertEqual(
            recentStore.documents.map(\.displayName),
            ["encrypted.pdf", "plain.pdf"]
        )
    }

    @MainActor
    func testCancellingEncryptedActivationLeavesNoGhostTabOrRecentDocument() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let recentStore = makeRecentStore()
        var promptRejectionStates: [Bool] = []
        let encryptedWorkspace = PDFWorkspaceState(
            passwordProvider: { _, wasRejected in
                promptRejectionStates.append(wasRejected)
                return nil
            }
        )
        let workspace = MultiDocumentWorkspaceState(
            initialWorkspace: encryptedWorkspace,
            recentDocumentsStore: recentStore
        )
        let originalTabID = try XCTUnwrap(workspace.activeTabID)

        let opened = workspace.openPDFsInTabs(urls: [fixture.encryptedURL])

        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(promptRejectionStates, [false])
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.tabs[0].id, originalTabID)
        XCTAssertEqual(workspace.activeTabID, workspace.tabs[0].id)
        XCTAssertFalse(workspace.tabs[0].workspace.hasOpenDocument)
        XCTAssertNil(workspace.tabs[0].workspace.presentedError)
        XCTAssertTrue(recentStore.documents.isEmpty)
    }

    @MainActor
    func testCancellingReunlockKeepsEstablishedHibernatedEncryptedTab() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let recentStore = makeRecentStore()
        var suppliedPasswords: [String?] = [fixture.password, nil]
        var promptRejectionStates: [Bool] = []
        let encryptedWorkspace = PDFWorkspaceState(
            passwordProvider: { _, wasRejected in
                promptRejectionStates.append(wasRejected)
                return suppliedPasswords.removeFirst()
            }
        )
        let workspace = MultiDocumentWorkspaceState(
            initialWorkspace: encryptedWorkspace,
            recentDocumentsStore: recentStore
        )

        let encryptedTabID = try XCTUnwrap(
            workspace.openPDFsInTabs(urls: [fixture.encryptedURL]).first
        )
        XCTAssertNotNil(encryptedWorkspace.document)
        XCTAssertTrue(encryptedWorkspace.hibernateIfPossible())
        let fallbackTabID = workspace.newTab()

        workspace.selectTab(encryptedTabID)

        XCTAssertEqual(promptRejectionStates, [false, false])
        XCTAssertEqual(
            Set(workspace.tabs.map(\.id)),
            Set([encryptedTabID, fallbackTabID])
        )
        XCTAssertEqual(workspace.activeTabID, fallbackTabID)
        XCTAssertTrue(encryptedWorkspace.isHibernated)
        XCTAssertNil(encryptedWorkspace.document)
        XCTAssertEqual(recentStore.documents.map(\.displayName), ["encrypted.pdf"])
    }

    @MainActor
    func testCancellationDuringUnlockRollsBackUIOwnedBatchAndRecentMutation() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let recentStore = makeRecentStore()
        weak var collection: MultiDocumentWorkspaceState?
        var promptCount = 0
        let encryptedWorkspace = PDFWorkspaceState(
            passwordProvider: { _, _ in
                promptCount += 1
                collection?.cancelPendingBatchOpen()
                return nil
            }
        )
        let workspace = MultiDocumentWorkspaceState(
            initialWorkspace: encryptedWorkspace,
            recentDocumentsStore: recentStore
        )
        collection = workspace
        let originalTabID = try XCTUnwrap(workspace.activeTabID)

        let task = workspace.beginOpeningPDFsInTabs(urls: [fixture.encryptedURL])
        let opened = await task.value

        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(promptCount, 1)
        XCTAssertFalse(workspace.hasPendingBatchOpen)
        XCTAssertEqual(workspace.tabs.map(\.id), [originalTabID])
        XCTAssertEqual(workspace.activeTabID, originalTabID)
        XCTAssertTrue(workspace.activeWorkspace === encryptedWorkspace)
        XCTAssertFalse(encryptedWorkspace.hasOpenDocument)
        XCTAssertNil(encryptedWorkspace.presentedError)
        XCTAssertTrue(recentStore.documents.isEmpty)
    }

    @MainActor
    func testNewerBatchWaitsForCancelledUnlockRollbackThenInstallsNormally() async throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let recentStore = makeRecentStore()
        weak var collection: MultiDocumentWorkspaceState?
        var replacementTask: Task<[UUID], Never>?
        let encryptedWorkspace = PDFWorkspaceState(
            passwordProvider: { _, _ in
                replacementTask = collection?.beginOpeningPDFsInTabs(
                    urls: [fixture.plainURL]
                )
                return nil
            }
        )
        let workspace = MultiDocumentWorkspaceState(
            initialWorkspace: encryptedWorkspace,
            recentDocumentsStore: recentStore
        )
        collection = workspace

        let supersededTask = workspace.beginOpeningPDFsInTabs(
            urls: [fixture.encryptedURL]
        )
        let supersededIDs = await supersededTask.value
        let replacement = try XCTUnwrap(replacementTask)
        let replacementIDs = await replacement.value

        XCTAssertTrue(supersededIDs.isEmpty)
        XCTAssertEqual(replacementIDs.count, 1)
        XCTAssertEqual(
            workspace.tabs.compactMap(\.workspace.documentURL),
            [fixture.plainURL]
        )
        XCTAssertEqual(workspace.activeTabID, replacementIDs.first)
        XCTAssertEqual(recentStore.documents.map(\.displayName), ["plain.pdf"])
        XCTAssertFalse(workspace.hasPendingBatchOpen)
    }

    @MainActor
    private func makeRecentStore() -> RecentDocumentsStore {
        RecentDocumentsStore(
            persistence: EncryptedBatchMemoryRecentPersistence(),
            bookmarkCoder: EncryptedBatchBookmarkCoder()
        )
    }

    private func makeFixture() throws -> (
        directory: URL,
        encryptedURL: URL,
        plainURL: URL,
        password: String
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Encrypted-Batch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encryptedURL = directory.appendingPathComponent("encrypted.pdf")
        let plainURL = directory.appendingPathComponent("plain.pdf")
        let password = "ReaderPass9"

        let encrypted = try makeOnePageDocument()
        let encryptionKeyLength = PDFDocumentWriteOption(
            rawValue: kCGPDFContextEncryptionKeyLength as String
        )
        XCTAssertTrue(
            encrypted.write(
                to: encryptedURL,
                withOptions: [
                    .ownerPasswordOption: "IndependentOwner9",
                    .userPasswordOption: password,
                    encryptionKeyLength: 128,
                ]
            )
        )
        XCTAssertTrue(try makeOnePageDocument().write(to: plainURL))
        return (directory, encryptedURL, plainURL, password)
    }

    private func makeOnePageDocument() throws -> PDFDocument {
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor.black.setFill()
            NSRect(x: 20, y: 30, width: 80, height: 8).fill()
            return true
        }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        return document
    }
}

private final class EncryptedBatchMemoryRecentPersistence: RecentDocumentsPersisting {
    var data: Data?
}

private struct EncryptedBatchBookmarkCoder: RecentDocumentBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data {
        try JSONEncoder().encode(url)
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        (try JSONDecoder().decode(URL.self, from: data), false)
    }
}

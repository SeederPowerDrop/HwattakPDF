// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import XCTest
@testable import VibePDF

final class RecentDocumentsStoreTests: XCTestCase {
    @MainActor
    func testRecordKeepsSevenNewestDocumentsAndMovesDuplicateToFront() throws {
        let fixture = try makeFiles(count: 8)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        var timestamp: TimeInterval = 100
        let store = RecentDocumentsStore(
            persistence: persistence,
            bookmarkCoder: coder,
            now: {
                defer { timestamp += 1 }
                return Date(timeIntervalSince1970: timestamp)
            }
        )

        for url in fixture.urls {
            try store.record(url: url)
        }

        XCTAssertEqual(store.documents.count, 7)
        XCTAssertEqual(store.documents.map(\.displayName), fixture.urls.dropFirst().reversed().map(\.lastPathComponent))
        let duplicateURL = fixture.urls[3]
        let originalID = try XCTUnwrap(
            store.documents.first(where: { $0.displayName == duplicateURL.lastPathComponent })?.id
        )

        let duplicate = try store.record(url: duplicateURL)

        XCTAssertEqual(store.documents.count, 7)
        XCTAssertEqual(store.documents.first?.id, originalID)
        XCTAssertEqual(duplicate.id, originalID)
        XCTAssertEqual(store.documents.first?.displayName, duplicateURL.lastPathComponent)

        let reloaded = RecentDocumentsStore(
            persistence: persistence,
            bookmarkCoder: coder
        )
        XCTAssertEqual(reloaded.documents, store.documents)
    }

    @MainActor
    func testRemoveAndClearPersistImmediately() throws {
        let fixture = try makeFiles(count: 3)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        try fixture.urls.forEach { try store.record(url: $0) }
        let removedID = try XCTUnwrap(store.documents.dropFirst().first?.id)

        store.remove(id: removedID)

        XCTAssertEqual(store.documents.count, 2)
        XCTAssertFalse(store.documents.contains(where: { $0.id == removedID }))
        XCTAssertEqual(
            RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder).documents,
            store.documents
        )

        store.clear()

        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertNil(persistence.data)
    }

    @MainActor
    func testResolvingStaleBookmarkRefreshesPersistedBookmark() throws {
        let fixture = try makeFiles(count: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryRecentDocumentsPersistence()
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        let recent = try store.record(url: fixture.urls[0])
        coder.staleGenerations.insert(1)

        let access = try store.resolve(id: recent.id)

        XCTAssertEqual(access.url.standardizedFileURL, fixture.urls[0].standardizedFileURL)
        XCTAssertEqual(coder.bookmarkCreationCount, 2)
        XCTAssertNil(store.lastError)

        let reloaded = RecentDocumentsStore(persistence: persistence, bookmarkCoder: coder)
        _ = try reloaded.resolve(id: recent.id)
        XCTAssertEqual(coder.bookmarkCreationCount, 2, "refreshed bookmark should no longer be stale")
    }

    @MainActor
    func testStaleBookmarkRefreshFailureDoesNotBlockValidResolvedFile() throws {
        let fixture = try makeFiles(count: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let coder = FakeRecentDocumentBookmarkCoder()
        let store = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: coder
        )
        let recent = try store.record(url: fixture.urls[0])
        coder.staleGenerations.insert(1)
        coder.failBookmarkCreation = true

        let access = try store.resolve(id: recent.id)

        XCTAssertEqual(access.url.standardizedFileURL, fixture.urls[0].standardizedFileURL)
        guard case .bookmarkCreationFailed = store.lastError else {
            return XCTFail("expected a non-blocking stale bookmark refresh warning")
        }
    }

    @MainActor
    func testResolveReportsMissingAndUnresolvableBookmarks() throws {
        let missingFixture = try makeFiles(count: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: missingFixture.directory) }
        let missingCoder = FakeRecentDocumentBookmarkCoder()
        let missingStore = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: missingCoder
        )
        let missing = try missingStore.record(url: missingFixture.urls[0])
        try FileManager.default.removeItem(at: missingFixture.urls[0])

        XCTAssertThrowsError(try missingStore.resolve(id: missing.id)) { error in
            guard case .fileMissing = error as? RecentDocumentsError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let invalidFixture = try makeFiles(count: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: invalidFixture.directory) }
        let invalidCoder = FakeRecentDocumentBookmarkCoder()
        let invalidStore = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: invalidCoder
        )
        let invalid = try invalidStore.record(url: invalidFixture.urls[0])
        invalidCoder.failResolution = true

        XCTAssertThrowsError(try invalidStore.resolve(id: invalid.id)) { error in
            guard case .bookmarkResolutionFailed = error as? RecentDocumentsError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testMultiDocumentWorkspaceRecordsOpensAndForwardsStoreChanges() throws {
        let fixture = try makePDFFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: FakeRecentDocumentBookmarkCoder()
        )
        let workspace = MultiDocumentWorkspaceState(recentDocumentsStore: store)
        var notificationCount = 0
        let observer = workspace.objectWillChange.sink {
            notificationCount += 1
        }

        let openedID = try XCTUnwrap(workspace.openPDFsInTabs(urls: [fixture.url]).first)

        XCTAssertEqual(workspace.recentDocuments.count, 1)
        XCTAssertGreaterThan(notificationCount, 0)
        let recentID = try XCTUnwrap(workspace.recentDocuments.first?.id)
        XCTAssertEqual(workspace.openRecentDocument(id: recentID), openedID)

        workspace.removeRecentDocument(id: recentID)
        XCTAssertTrue(workspace.recentDocuments.isEmpty)
        _ = observer
    }

    @MainActor
    func testAsyncBatchRecordsEachUniqueSuccessfulDocumentOnce() async throws {
        let fixture = try makePDFFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = RecentDocumentsStore(
            persistence: MemoryRecentDocumentsPersistence(),
            bookmarkCoder: FakeRecentDocumentBookmarkCoder()
        )
        let workspace = MultiDocumentWorkspaceState(recentDocumentsStore: store)

        let opened = await workspace.openPDFsInTabsAsync(
            urls: [fixture.url, fixture.url]
        )

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(workspace.recentDocuments.count, 1)
        XCTAssertEqual(workspace.recentDocuments.first?.displayName, fixture.url.lastPathComponent)
        XCTAssertEqual(workspace.activeTabID, opened.last)
    }

    private func makeFiles(count: Int) throws -> (directory: URL, urls: [URL]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try (0..<count).map { index in
            let url = directory.appendingPathComponent("document-\(index).pdf")
            try Data("fixture-\(index)".utf8).write(to: url)
            return url
        }
        return (directory, urls)
    }

    private func makePDFFixture() throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Recent-PDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("recent.pdf")
        let document = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(document.write(to: url))
        return (directory, url)
    }
}

private final class MemoryRecentDocumentsPersistence: RecentDocumentsPersisting {
    var data: Data?
}

private final class FakeRecentDocumentBookmarkCoder: RecentDocumentBookmarkCoding {
    private struct Payload: Codable {
        let url: URL
        let generation: Int
    }

    enum Failure: LocalizedError {
        case creation
        case resolution

        var errorDescription: String? {
            switch self {
            case .creation: "bookmark creation failed"
            case .resolution: "bookmark resolution failed"
            }
        }
    }

    var staleGenerations: Set<Int> = []
    var failBookmarkCreation = false
    var failResolution = false
    private(set) var bookmarkCreationCount = 0

    func makeBookmark(for url: URL) throws -> Data {
        if failBookmarkCreation { throw Failure.creation }
        bookmarkCreationCount += 1
        return try JSONEncoder().encode(
            Payload(url: url, generation: bookmarkCreationCount)
        )
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if failResolution { throw Failure.resolution }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.url, staleGenerations.contains(payload.generation))
    }
}

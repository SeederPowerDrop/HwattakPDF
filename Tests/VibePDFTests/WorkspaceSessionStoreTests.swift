// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

final class WorkspaceSessionStoreTests: XCTestCase {
    @MainActor
    func testImageSessionStoresOriginalAndRegeneratesDisposablePreview() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImageSession-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: CGSize(width: 100, height: 100), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        let original = folder.appendingPathComponent("study.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: original)
        let persistence = MemoryWorkspaceSessionPersistence()
        let coder = FakeWorkspaceSessionBookmarkCoder()
        let workspace = MultiDocumentWorkspaceState(sessionStore: WorkspaceSessionStore(persistence: persistence, bookmarkCoder: coder))
        _ = await workspace.beginOpeningViewableFilesInTabs(urls: [original]).value
        let preview = try XCTUnwrap(workspace.activeWorkspace?.documentURL)
        XCTAssertTrue(workspace.flushSessionPersistence())
        ImagePDFConverter.removePreview(at: preview)
        let restored = MultiDocumentWorkspaceState(sessionStore: WorkspaceSessionStore(persistence: persistence, bookmarkCoder: coder))
        XCTAssertEqual(restored.activeWorkspace?.imageSourceURL, original)
        XCTAssertEqual(restored.activeWorkspace?.pageCount, 1)
        XCTAssertTrue(restored.activeWorkspace?.requiresSaveDestination ?? false)
        XCTAssertNotEqual(restored.activeWorkspace?.documentURL, preview)
        workspace.activeWorkspace?.close()
        restored.activeWorkspace?.close()
    }

    @MainActor
    func testEmptyTabRestoresItsChosenWorkingMode() throws {
        let persistence = MemoryWorkspaceSessionPersistence()
        let store = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        let state = MultiDocumentWorkspaceState(sessionStore: store)
        state.activeWorkspace?.setMode(.study)
        state.activeWorkspace?.twoPageDisplayMode = .paged

        XCTAssertTrue(state.flushSessionPersistence())

        let restored = MultiDocumentWorkspaceState(
            sessionStore: WorkspaceSessionStore(
                persistence: persistence,
                bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
            )
        )
        XCTAssertEqual(restored.activeWorkspace?.mode, .study)
        XCTAssertEqual(restored.activeWorkspace?.twoPageDisplayMode, .paged)
        XCTAssertFalse(restored.activeWorkspace?.hasOpenDocument ?? true)
    }

    @MainActor
    func testRoundTripRestoresWorkspaceTabGroupAndViewStateFidelity() throws {
        let fixture = try makePDFFixture(
            namesAndPageCounts: [("alpha.pdf", 3), ("beta.pdf", 2), ("gamma.pdf", 4)]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryWorkspaceSessionPersistence()
        let coder = FakeWorkspaceSessionBookmarkCoder()
        let store = WorkspaceSessionStore(persistence: persistence, bookmarkCoder: coder)
        let state = MultiDocumentWorkspaceState(sessionStore: store)

        let firstWorkspaceID = state.activeWorkspaceID
        let firstWorkspaceTitle = try XCTUnwrap(state.activeWorkspaceDescriptor?.title)
        let firstTabIDs = state.openPDFsInTabs(urls: Array(fixture.urls.prefix(2)))
        XCTAssertEqual(firstTabIDs.count, 2)
        let groupID = try XCTUnwrap(
            state.createTabGroup(title: "  Research  ", tabIDs: firstTabIDs)
        )
        XCTAssertTrue(state.setTabGroupCollapsed(groupID, isCollapsed: true))
        state.selectTab(firstTabIDs[0])
        state.activeWorkspace?.currentPageIndex = 2
        state.activeWorkspace?.selectedPages = [1, 2]
        state.activeWorkspace?.pageColumns = 4
        state.activeWorkspace?.overviewScale = 1.45
        state.activeWorkspace?.sidebarVisible = false
        state.activeWorkspace?.gridLayoutMode = .singleRow
        state.activeWorkspace?.setMode(.study)
        state.activeWorkspace?.recordPDFViewport(
            autoScales: false,
            scaleFactor: 1.8,
            scrollProgress: PDFScrollProgress(horizontal: 0.24, vertical: 0.71)
        )
        state.activeWorkspace?.recordPDFViewport(
            autoScales: false,
            scaleFactor: 2.35,
            scrollProgress: PDFScrollProgress(horizontal: 0.82, vertical: 0.19),
            context: .comparison
        )

        let secondWorkspaceID = state.createWorkspace(title: "  Archive  ")
        let thirdTabID = try XCTUnwrap(
            state.openPDFsInTabs(urls: [fixture.urls[2]]).first
        )
        state.activeWorkspace?.currentPageIndex = 3
        state.activeWorkspace?.selectedPages = [3]
        state.activeWorkspace?.selectTwoPageDisplayMode(.paged)
        state.activeWorkspace?.overviewScale = 0.8
        state.activeWorkspace?.setMode(.editing)
        XCTAssertTrue(state.selectWorkspace(firstWorkspaceID))
        state.selectTab(firstTabIDs[0])

        XCTAssertTrue(state.flushSessionPersistence())
        XCTAssertEqual(persistence.writeCount, 1)
        let savedArchive = try JSONDecoder().decode(
            WorkspaceSessionArchive.self,
            from: try XCTUnwrap(persistence.data)
        )
        let savedPagedTab = try XCTUnwrap(
            savedArchive.workspaces
                .flatMap(\.tabs)
                .first(where: { $0.id == thirdTabID })
        )
        XCTAssertEqual(savedPagedTab.twoPageDisplayMode, "paged")

        let reloadedStore = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: coder
        )
        let restored = MultiDocumentWorkspaceState(sessionStore: reloadedStore)

        XCTAssertEqual(restored.workspaces.map(\.id), [firstWorkspaceID, secondWorkspaceID])
        XCTAssertEqual(restored.workspaces.map(\.title), [firstWorkspaceTitle, "Archive"])
        XCTAssertEqual(restored.activeWorkspaceID, firstWorkspaceID)
        XCTAssertEqual(restored.tabs.map(\.id), firstTabIDs)
        XCTAssertEqual(restored.activeTabID, firstTabIDs[0])
        XCTAssertEqual(restored.tabGroups.map(\.id), [groupID])
        XCTAssertEqual(restored.tabGroups.first?.title, "Research")
        XCTAssertEqual(restored.tabGroups.first?.tabIDs, firstTabIDs)
        XCTAssertEqual(restored.tabGroups.first?.isCollapsed, true)
        XCTAssertEqual(restored.activeWorkspace?.currentPageIndex, 2)
        XCTAssertEqual(restored.activeWorkspace?.selectedPages, [1, 2])
        XCTAssertEqual(restored.activeWorkspace?.pageColumns, 4)
        XCTAssertEqual(restored.activeWorkspace?.overviewScale ?? 0, 1.45, accuracy: 0.001)
        XCTAssertEqual(restored.activeWorkspace?.sidebarVisible, false)
        XCTAssertEqual(restored.activeWorkspace?.gridLayoutMode, .singleRow)
        XCTAssertEqual(restored.activeWorkspace?.mode, .study)
        XCTAssertEqual(restored.activeWorkspace?.pdfViewportState.autoScales, false)
        XCTAssertEqual(
            restored.activeWorkspace?.pdfViewportState.scaleFactor ?? 0,
            1.8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            restored.activeWorkspace?.pdfViewportState.scrollProgress?.horizontal ?? 0,
            0.24,
            accuracy: 0.001
        )
        XCTAssertEqual(
            restored.activeWorkspace?.pdfViewportState.scrollProgress?.vertical ?? 0,
            0.71,
            accuracy: 0.001
        )
        XCTAssertEqual(restored.activeWorkspace?.pdfViewportState.capturedPageIndex, 2)
        let restoredComparisonViewport = try XCTUnwrap(
            restored.activeWorkspace?.pdfViewportState(for: .comparison)
        )
        XCTAssertFalse(restoredComparisonViewport.autoScales)
        XCTAssertEqual(restoredComparisonViewport.scaleFactor ?? 0, 2.35, accuracy: 0.001)
        XCTAssertEqual(
            restoredComparisonViewport.scrollProgress?.horizontal ?? 0,
            0.82,
            accuracy: 0.001
        )
        XCTAssertEqual(
            restoredComparisonViewport.scrollProgress?.vertical ?? 0,
            0.19,
            accuracy: 0.001
        )
        XCTAssertEqual(restoredComparisonViewport.capturedPageIndex, 2)
        XCTAssertFalse(restored.activeWorkspace?.isHibernated ?? true)

        let secondTab = try XCTUnwrap(
            restored.tabs.first(where: { $0.id == firstTabIDs[1] })
        )
        XCTAssertTrue(secondTab.workspace.isHibernated)
        XCTAssertNil(secondTab.workspace.document)
        XCTAssertEqual(secondTab.workspace.pageCount, 2)

        let restoredSecond = try XCTUnwrap(
            restored.workspaces.first(where: { $0.id == secondWorkspaceID })
        )
        XCTAssertEqual(restoredSecond.tabs.map(\.id), [thirdTabID])
        XCTAssertTrue(restoredSecond.tabs[0].workspace.isHibernated)
        XCTAssertEqual(restoredSecond.tabs[0].workspace.currentPageIndex, 3)
        XCTAssertEqual(restoredSecond.tabs[0].workspace.selectedPages, [3])
        XCTAssertEqual(restoredSecond.tabs[0].workspace.pageColumns, 2)
        XCTAssertEqual(restoredSecond.tabs[0].workspace.twoPageDisplayMode, .paged)
        XCTAssertEqual(restoredSecond.tabs[0].workspace.overviewScale, 0.8, accuracy: 0.001)
        XCTAssertEqual(restoredSecond.tabs[0].workspace.mode, .editing)
    }

    @MainActor
    func testCorruptedAndUnsupportedArchivesFallBackToOneUsableWorkspace() throws {
        let corruptedPersistence = MemoryWorkspaceSessionPersistence(data: Data("bad-json".utf8))
        let corruptedStore = WorkspaceSessionStore(
            persistence: corruptedPersistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        let corruptedState = MultiDocumentWorkspaceState(sessionStore: corruptedStore)
        XCTAssertEqual(corruptedState.workspaces.count, 1)
        XCTAssertEqual(corruptedState.tabs.count, 1)
        XCTAssertFalse(corruptedState.tabs[0].workspace.hasOpenDocument)
        XCTAssertEqual(corruptedStore.lastError, .corrupted)

        let unsupported = WorkspaceSessionArchive(
            schemaVersion: 99,
            activeWorkspaceID: nil,
            workspaces: []
        )
        let unsupportedPersistence = MemoryWorkspaceSessionPersistence(
            data: try JSONEncoder().encode(unsupported)
        )
        let unsupportedStore = WorkspaceSessionStore(
            persistence: unsupportedPersistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        let unsupportedState = MultiDocumentWorkspaceState(sessionStore: unsupportedStore)
        XCTAssertEqual(unsupportedState.tabs.count, 1)
        XCTAssertEqual(unsupportedStore.lastError, .unsupportedVersion(99))
    }

    @MainActor
    func testDeniedBookmarkNeverFallsBackToLastKnownPath() throws {
        let fixture = try makePDFFixture(namesAndPageCounts: [("private.pdf", 1)])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let tabID = UUID()
        let workspaceID = UUID()
        let archive = WorkspaceSessionArchive(
            activeWorkspaceID: workspaceID,
            workspaces: [
                .init(
                    id: workspaceID,
                    title: "Secure",
                    activeTabID: tabID,
                    tabs: [
                        .init(
                            id: tabID,
                            document: .init(
                                bookmark: Data("denied".utf8),
                                lastKnownPath: fixture.urls[0].path,
                                pageCount: 1
                            ),
                            currentPageIndex: 0,
                            selectedPages: [0],
                            pageColumns: 1,
                            overviewScale: 1
                        )
                    ],
                    groups: []
                )
            ]
        )
        let persistence = MemoryWorkspaceSessionPersistence(
            data: try JSONEncoder().encode(archive)
        )
        let store = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: AlwaysFailingWorkspaceBookmarkCoder()
        )

        let restored = MultiDocumentWorkspaceState(sessionStore: store)

        XCTAssertEqual(restored.workspaces.count, 1)
        XCTAssertEqual(restored.tabs.count, 1)
        XCTAssertFalse(restored.tabs[0].workspace.hasOpenDocument)
        XCTAssertNil(restored.tabs[0].workspace.documentURL)
        XCTAssertEqual(
            store.lastError,
            .partiallyRestored(unavailableDocumentCount: 1)
        )
    }

    @MainActor
    func testRestoreNormalizesDuplicateURLsAndInvalidGroupsButPreservesUniqueEmptyTabs() throws {
        let fixture = try makePDFFixture(namesAndPageCounts: [("duplicate.pdf", 2)])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let coder = FakeWorkspaceSessionBookmarkCoder()
        let bookmark = try coder.makeBookmark(for: fixture.urls[0])
        let workspaceID = UUID()
        let documentTabID = UUID()
        let duplicateDocumentTabID = UUID()
        let emptyTabID = UUID()
        let extraEmptyTabID = UUID()
        let missingTabID = UUID()
        let groupID = UUID()
        let duplicateGroupID = groupID
        let archive = WorkspaceSessionArchive(
            activeWorkspaceID: workspaceID,
            workspaces: [
                .init(
                    id: workspaceID,
                    title: "  ",
                    activeTabID: missingTabID,
                    tabs: [
                        tabRecord(id: documentTabID, bookmark: bookmark, path: fixture.urls[0].path),
                        tabRecord(id: duplicateDocumentTabID, bookmark: bookmark, path: fixture.urls[0].path),
                        emptyTabRecord(id: emptyTabID),
                        emptyTabRecord(id: extraEmptyTabID)
                    ],
                    groups: [
                        .init(
                            id: groupID,
                            title: "  Stack  ",
                            tabIDs: [documentTabID, missingTabID, emptyTabID, emptyTabID],
                            isCollapsed: true
                        ),
                        .init(
                            id: duplicateGroupID,
                            title: "Ignored",
                            tabIDs: [duplicateDocumentTabID],
                            isCollapsed: false
                        )
                    ]
                ),
                .init(
                    id: workspaceID,
                    title: "Duplicate workspace",
                    activeTabID: nil,
                    tabs: [],
                    groups: []
                )
            ]
        )
        let persistence = MemoryWorkspaceSessionPersistence(
            data: try JSONEncoder().encode(archive)
        )
        let store = WorkspaceSessionStore(persistence: persistence, bookmarkCoder: coder)

        let restored = MultiDocumentWorkspaceState(sessionStore: store)

        XCTAssertEqual(restored.workspaces.count, 1)
        XCTAssertEqual(
            restored.tabs.map(\.id),
            [documentTabID, emptyTabID, extraEmptyTabID]
        )
        XCTAssertEqual(restored.activeTabID, documentTabID)
        XCTAssertEqual(restored.tabGroups.count, 1)
        XCTAssertEqual(restored.tabGroups[0].id, groupID)
        XCTAssertEqual(restored.tabGroups[0].title, "Stack")
        XCTAssertEqual(restored.tabGroups[0].tabIDs, [documentTabID, emptyTabID])
        XCTAssertTrue(restored.tabGroups[0].isCollapsed)
    }

    @MainActor
    func testMultipleEmptyTabsAndEmptyStackMembersRoundTripExactly() throws {
        let persistence = MemoryWorkspaceSessionPersistence()
        let coder = FakeWorkspaceSessionBookmarkCoder()
        let state = MultiDocumentWorkspaceState(
            sessionStore: WorkspaceSessionStore(
                persistence: persistence,
                bookmarkCoder: coder
            )
        )
        let firstID = try XCTUnwrap(state.activeTabID)
        let secondID = state.newTab()
        let thirdID = state.newTab()
        let groupID = try XCTUnwrap(
            state.createTabGroup(
                title: "Empty research",
                tabIDs: [firstID, secondID]
            )
        )
        XCTAssertTrue(state.setTabGroupCollapsed(groupID, isCollapsed: true))
        state.selectTab(secondID)
        XCTAssertTrue(state.flushSessionPersistence())

        let restored = MultiDocumentWorkspaceState(
            sessionStore: WorkspaceSessionStore(
                persistence: persistence,
                bookmarkCoder: coder
            )
        )

        XCTAssertEqual(restored.tabs.map(\.id), [firstID, secondID, thirdID])
        XCTAssertEqual(restored.activeTabID, secondID)
        XCTAssertEqual(restored.tabGroups.map(\.id), [groupID])
        XCTAssertEqual(restored.tabGroups[0].tabIDs, [firstID, secondID])
        XCTAssertTrue(restored.tabGroups[0].isCollapsed)
        XCTAssertTrue(restored.tabs.allSatisfy { !$0.workspace.hasOpenDocument })
    }

    @MainActor
    func testStaleBookmarkIsRefreshedAtomicallyWithoutBlockingRestore() throws {
        let fixture = try makePDFFixture(namesAndPageCounts: [("stale.pdf", 1)])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let coder = FakeWorkspaceSessionBookmarkCoder()
        let staleBookmark = try coder.encodedBookmark(for: fixture.urls[0], isStale: true)
        let workspaceID = UUID()
        let tabID = UUID()
        let archive = WorkspaceSessionArchive(
            activeWorkspaceID: workspaceID,
            workspaces: [
                .init(
                    id: workspaceID,
                    title: "Workspace",
                    activeTabID: tabID,
                    tabs: [tabRecord(id: tabID, bookmark: staleBookmark, path: fixture.urls[0].path)],
                    groups: []
                )
            ]
        )
        let persistence = MemoryWorkspaceSessionPersistence(
            data: try JSONEncoder().encode(archive)
        )
        let store = WorkspaceSessionStore(persistence: persistence, bookmarkCoder: coder)

        let restored = store.restore()

        XCTAssertNotNil(restored)
        XCTAssertEqual(persistence.writeCount, 1)
        XCTAssertEqual(coder.bookmarkCreationCount, 1)
        let rewrittenData = try XCTUnwrap(persistence.data)
        let rewritten = try JSONDecoder().decode(WorkspaceSessionArchive.self, from: rewrittenData)
        let refreshedBookmark = try XCTUnwrap(rewritten.workspaces[0].tabs[0].document?.bookmark)
        XCTAssertFalse(try coder.isStale(refreshedBookmark))
    }

    @MainActor
    func testSamePDFAcrossWorkspacesAndDetachedWindowSurviveAppWideSnapshot() throws {
        let fixture = try makePDFFixture(
            namesAndPageCounts: [("shared.pdf", 2), ("detached.pdf", 1)]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryWorkspaceSessionPersistence()
        let coder = FakeWorkspaceSessionBookmarkCoder()
        let store = WorkspaceSessionStore(persistence: persistence, bookmarkCoder: coder)
        let main = MultiDocumentWorkspaceState(sessionStore: store)
        let firstWorkspaceID = main.activeWorkspaceID
        main.openPDFsInTabs(urls: [fixture.urls[0]])

        let secondWorkspaceID = main.createWorkspace(title: "Second view")
        main.openPDFsInTabs(urls: [fixture.urls[0]])
        XCTAssertTrue(main.selectWorkspace(firstWorkspaceID))

        let detachedPDF = PDFWorkspaceState()
        XCTAssertTrue(detachedPDF.open(url: fixture.urls[1]))
        let detached = MultiDocumentWorkspaceState(
            initialWorkspace: detachedPDF,
            initialWorkspaceTitle: "Detached window"
        )
        let detachedWorkspaceID = detached.activeWorkspaceID

        XCTAssertTrue(main.flushSessionPersistence(including: [detached]))
        let restored = MultiDocumentWorkspaceState(
            sessionStore: WorkspaceSessionStore(
                persistence: persistence,
                bookmarkCoder: coder
            )
        )

        XCTAssertEqual(
            restored.workspaces.map(\.id),
            [firstWorkspaceID, secondWorkspaceID, detachedWorkspaceID]
        )
        XCTAssertEqual(
            restored.workspaces.compactMap { $0.tabs.first?.workspace.documentURL },
            [fixture.urls[0], fixture.urls[0], fixture.urls[1]]
        )
        XCTAssertEqual(restored.workspaces[2].title, "Detached window")
    }

    @MainActor
    func testRapidChangesAreDebouncedIntoOnePersistenceWrite() async throws {
        let persistence = MemoryWorkspaceSessionPersistence()
        let store = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        let state = MultiDocumentWorkspaceState(sessionStore: store)
        let firstWorkspaceID = state.activeWorkspaceID

        _ = state.newTab()
        _ = state.newTab()
        XCTAssertTrue(state.renameWorkspace(firstWorkspaceID, to: "Debounced"))
        state.selectAdjacentTab(forward: false)
        state.selectAdjacentTab(forward: true)

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(persistence.writeCount, 1)
    }

    @MainActor
    func testCloseFreezePreservesSnapshotAndReopenRestoresOriginalNotDirtyBytes() async throws {
        let fixture = try makePDFFixture(namesAndPageCounts: [("edited.pdf", 2)])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryWorkspaceSessionPersistence()
        let coder = FakeWorkspaceSessionBookmarkCoder()
        let store = WorkspaceSessionStore(persistence: persistence, bookmarkCoder: coder)
        let state = MultiDocumentWorkspaceState(sessionStore: store)
        state.openPDFsInTabs(urls: fixture.urls)
        state.activeWorkspace?.setMode(.editing)
        state.activeWorkspace?.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(state.activeWorkspace?.isDirty == true)

        let accepted = UnsavedChangesGuard.confirmAndClose(
            workspaces: state.allTabs.map(\.workspace),
            decisionProvider: { _ in .dontSave },
            beforeClosing: { state.freezeSessionPersistenceAfterFlushing() }
        )
        XCTAssertTrue(accepted)
        XCTAssertFalse(state.activeWorkspace?.hasOpenDocument ?? true)

        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(persistence.writeCount, 1, "teardown must not overwrite the frozen archive")

        state.resumeSessionPersistence()
        XCTAssertTrue(state.activeWorkspace?.hasOpenDocument == true)
        XCTAssertFalse(state.activeWorkspace?.isDirty ?? true)
        XCTAssertEqual(state.activeWorkspace?.document?.page(at: 0)?.rotation, 0)
    }

    @MainActor
    func testAlreadyFrozenMainAuthoritativelyMergesOpenDetachedWindows() throws {
        let fixture = try makePDFFixture(
            namesAndPageCounts: [
                ("main.pdf", 2),
                ("detached-after-close.pdf", 3),
                ("detached-then-closed.pdf", 1)
            ]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryWorkspaceSessionPersistence()
        let coder = FakeWorkspaceSessionBookmarkCoder()
        let store = WorkspaceSessionStore(persistence: persistence, bookmarkCoder: coder)
        let main = MultiDocumentWorkspaceState(sessionStore: store)
        let mainWorkspaceID = main.activeWorkspaceID
        main.openPDFsInTabs(urls: [fixture.urls[0]])

        let detachedPDF = PDFWorkspaceState()
        XCTAssertTrue(detachedPDF.open(url: fixture.urls[1]))
        detachedPDF.currentPageIndex = 2
        detachedPDF.selectedPages = [2]
        let detached = MultiDocumentWorkspaceState(
            initialWorkspace: detachedPDF,
            initialWorkspaceTitle: "Detached"
        )
        let detachedWorkspaceID = detached.activeWorkspaceID

        let laterClosedPDF = PDFWorkspaceState()
        XCTAssertTrue(laterClosedPDF.open(url: fixture.urls[2]))
        let laterClosed = MultiDocumentWorkspaceState(
            initialWorkspace: laterClosedPDF,
            initialWorkspaceTitle: "Closed detached"
        )
        let laterClosedWorkspaceID = laterClosed.activeWorkspaceID

        // First freeze models a main-window red-close while two tear-out
        // windows are open. Its live PDF is then torn down by the close guard.
        main.freezeSessionPersistenceAfterFlushing(
            including: [detached, laterClosed]
        )
        main.activeWorkspace?.closeDiscardingChanges()
        XCTAssertFalse(main.activeWorkspace?.hasOpenDocument ?? true)

        // A later app quit reaches freeze again while main is already
        // suspended. Only one tear-out remains open, so the saved main record
        // stays, that window refreshes, and the explicitly closed one is
        // authoritatively removed rather than resurrected next launch.
        main.freezeSessionPersistenceAfterFlushing(including: [detached])
        XCTAssertEqual(persistence.writeCount, 2)

        let restored = MultiDocumentWorkspaceState(
            sessionStore: WorkspaceSessionStore(
                persistence: persistence,
                bookmarkCoder: coder
            )
        )
        XCTAssertEqual(
            restored.workspaces.map(\.id),
            [mainWorkspaceID, detachedWorkspaceID]
        )
        XCTAssertFalse(
            restored.workspaces.contains { $0.id == laterClosedWorkspaceID }
        )
        XCTAssertEqual(
            restored.workspaces.compactMap { $0.tabs.first?.workspace.documentURL },
            Array(fixture.urls.prefix(2))
        )
        XCTAssertEqual(
            restored.workspaces[1].tabs[0].workspace.currentPageIndex,
            2
        )
        let finalData = try XCTUnwrap(persistence.data)
        let finalArchive = try JSONDecoder().decode(
            WorkspaceSessionArchive.self,
            from: finalData
        )
        XCTAssertEqual(finalArchive.detachedWorkspaceIDs, [detachedWorkspaceID])
    }

    @MainActor
    func testAlreadyFrozenMainRemovesAllDetachedRecordsWhenNoWindowsRemain() throws {
        let fixture = try makePDFFixture(
            namesAndPageCounts: [("main-only.pdf", 1), ("closed-window.pdf", 1)]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryWorkspaceSessionPersistence()
        let coder = FakeWorkspaceSessionBookmarkCoder()
        let main = MultiDocumentWorkspaceState(
            sessionStore: WorkspaceSessionStore(
                persistence: persistence,
                bookmarkCoder: coder
            )
        )
        let mainWorkspaceID = main.activeWorkspaceID
        main.openPDFsInTabs(urls: [fixture.urls[0]])

        let detachedPDF = PDFWorkspaceState()
        XCTAssertTrue(detachedPDF.open(url: fixture.urls[1]))
        let detached = MultiDocumentWorkspaceState(
            initialWorkspace: detachedPDF,
            initialWorkspaceTitle: "Will close"
        )
        let detachedWorkspaceID = detached.activeWorkspaceID

        main.freezeSessionPersistenceAfterFlushing(including: [detached])
        main.activeWorkspace?.closeDiscardingChanges()

        // At quit the registry is authoritatively empty because the user
        // explicitly closed the last tear-out after red-closing main.
        main.freezeSessionPersistenceAfterFlushing(including: [])
        XCTAssertEqual(persistence.writeCount, 2)

        let data = try XCTUnwrap(persistence.data)
        let archive = try JSONDecoder().decode(WorkspaceSessionArchive.self, from: data)
        XCTAssertEqual(archive.workspaces.map(\.id), [mainWorkspaceID])
        XCTAssertTrue(archive.detachedWorkspaceIDs.isEmpty)
        XCTAssertFalse(archive.workspaces.contains { $0.id == detachedWorkspaceID })

        let restored = MultiDocumentWorkspaceState(
            sessionStore: WorkspaceSessionStore(
                persistence: persistence,
                bookmarkCoder: coder
            )
        )
        XCTAssertEqual(restored.workspaces.map(\.id), [mainWorkspaceID])
        XCTAssertEqual(restored.activeWorkspace?.documentURL, fixture.urls[0])
    }

    func testSchemaV1WithoutOptionalWindowFieldsRemainsDecodable() throws {
        let legacyJSON = Data(
            """
            {
              "schemaVersion": 1,
              "activeWorkspaceID": "00000000-0000-0000-0000-000000000001",
              "workspaces": [
                {
                  "id": "00000000-0000-0000-0000-000000000001",
                  "title": "Legacy",
                  "activeTabID": "00000000-0000-0000-0000-000000000002",
                  "tabs": [
                    {
                      "id": "00000000-0000-0000-0000-000000000002",
                      "document": null,
                      "currentPageIndex": 0,
                      "selectedPages": [],
                      "pageColumns": 1,
                      "overviewScale": 1
                    }
                  ],
                  "groups": []
                }
              ],
              "detachedWorkspaceIDs": []
            }
            """.utf8
        )

        let archive = try JSONDecoder().decode(
            WorkspaceSessionArchive.self,
            from: legacyJSON
        )

        XCTAssertNil(archive.windowTopology)
        XCTAssertNil(archive.comparisonRecords)
        let legacyTab = try XCTUnwrap(archive.workspaces.first?.tabs.first)
        XCTAssertNil(legacyTab.comparisonPDFAutoScales)
        XCTAssertNil(legacyTab.comparisonPDFScaleFactor)
        XCTAssertNil(legacyTab.comparisonPDFHorizontalScrollProgress)
        XCTAssertNil(legacyTab.comparisonPDFVerticalScrollProgress)
        XCTAssertNil(legacyTab.comparisonPDFCapturedPageIndex)
        XCTAssertNil(legacyTab.twoPageDisplayMode)
    }

    @MainActor
    func testUnknownTwoPageModeFallsBackWithoutDiscardingArchive() throws {
        let workspaceID = UUID()
        let tabID = UUID()
        let archive = WorkspaceSessionArchive(
            activeWorkspaceID: workspaceID,
            workspaces: [
                .init(
                    id: workspaceID,
                    title: "Future",
                    activeTabID: tabID,
                    tabs: [
                        .init(
                            id: tabID,
                            document: nil,
                            currentPageIndex: 0,
                            selectedPages: [],
                            pageColumns: 2,
                            overviewScale: 1,
                            twoPageDisplayMode: "future-mode"
                        )
                    ],
                    groups: []
                )
            ]
        )
        let persistence = MemoryWorkspaceSessionPersistence(
            data: try JSONEncoder().encode(archive)
        )

        let restored = MultiDocumentWorkspaceState(
            sessionStore: WorkspaceSessionStore(
                persistence: persistence,
                bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
            )
        )

        XCTAssertEqual(restored.activeWorkspace?.twoPageDisplayMode, .continuous)
        XCTAssertEqual(restored.workspaces.first?.title, "Future")
    }

    @MainActor
    func testComparisonViewportRestoreReusesNormalFiniteAndClampRules() {
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(
            url: URL(fileURLWithPath: "/private/tmp/comparison-viewport.pdf"),
            pageCount: 3,
            currentPageIndex: 2
        )
        workspace.recordPDFViewport(
            autoScales: false,
            scaleFactor: 1.4,
            scrollProgress: PDFScrollProgress(horizontal: 0.3, vertical: 0.6)
        )

        workspace.restorePDFViewport(
            autoScales: false,
            scaleFactor: 500,
            horizontalScrollProgress: -2,
            verticalScrollProgress: 7,
            capturedPageIndex: 2,
            context: .comparison
        )

        var comparisonViewport = workspace.pdfViewportState(for: .comparison)
        XCTAssertFalse(comparisonViewport.autoScales)
        XCTAssertEqual(comparisonViewport.scaleFactor, 20)
        XCTAssertEqual(comparisonViewport.scrollProgress?.horizontal, 0)
        XCTAssertEqual(comparisonViewport.scrollProgress?.vertical, 1)
        XCTAssertEqual(comparisonViewport.capturedPageIndex, 2)
        XCTAssertEqual(workspace.pdfViewportState.scaleFactor, 1.4)
        XCTAssertEqual(workspace.pdfViewportState.scrollProgress?.vertical, 0.6)

        workspace.restorePDFViewport(
            autoScales: false,
            scaleFactor: .infinity,
            horizontalScrollProgress: .nan,
            verticalScrollProgress: 0.5,
            capturedPageIndex: 2,
            context: .comparison
        )

        comparisonViewport = workspace.pdfViewportState(for: .comparison)
        XCTAssertTrue(comparisonViewport.autoScales)
        XCTAssertNil(comparisonViewport.scaleFactor)
        XCTAssertNil(comparisonViewport.scrollProgress)
        XCTAssertNil(comparisonViewport.capturedPageIndex)
        XCTAssertEqual(workspace.pdfViewportState.scaleFactor, 1.4)
    }

    @MainActor
    func testAppWideCoordinatorDebouncesDetachedChangesAndRemovalIsAuthoritative() async throws {
        let persistence = MemoryWorkspaceSessionPersistence()
        let sessionStore = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        let main = MultiDocumentWorkspaceState(sessionStore: sessionStore)
        let mainWorkspaceID = main.activeWorkspaceID
        let tearOutStore = PDFTabTearOutStore()
        let coordinator = AppWideWorkspaceSessionCoordinator(
            mainWorkspace: main,
            sessionStore: sessionStore,
            tearOutStore: tearOutStore,
            debounceDuration: .milliseconds(40)
        )
        let writeCountBeforeOpeningWindow = persistence.writeCount
        let movedTabID = try XCTUnwrap(main.activeTabID)
        let requestID = try XCTUnwrap(
            tearOutStore.stageNewWindow(tabID: movedTabID, from: main)
        )
        let detached = try XCTUnwrap(tearOutStore.workspace(for: requestID))
        let detachedWorkspaceID = detached.activeWorkspaceID

        try await waitForPersistenceWriteCount(
            writeCountBeforeOpeningWindow + 1,
            in: persistence
        )
        var archive = try JSONDecoder().decode(
            WorkspaceSessionArchive.self,
            from: XCTUnwrap(persistence.data)
        )
        XCTAssertEqual(archive.detachedWorkspaceIDs, [detachedWorkspaceID])
        XCTAssertEqual(archive.windowTopology?.mainWorkspaceIDs, [mainWorkspaceID])
        XCTAssertEqual(
            archive.windowTopology?.detachedWindows,
            [
                .init(
                    windowID: requestID,
                    workspaceIDs: [detachedWorkspaceID],
                    activeWorkspaceID: detachedWorkspaceID
                )
            ]
        )

        let writeCountBeforeRapidChanges = persistence.writeCount
        XCTAssertTrue(detached.renameWorkspace(detachedWorkspaceID, to: "First"))
        XCTAssertTrue(detached.renameWorkspace(detachedWorkspaceID, to: "Final"))
        _ = detached.newTab()
        try await waitForPersistenceWriteCount(
            writeCountBeforeRapidChanges + 1,
            in: persistence
        )
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(persistence.writeCount, writeCountBeforeRapidChanges + 1)

        archive = try JSONDecoder().decode(
            WorkspaceSessionArchive.self,
            from: XCTUnwrap(persistence.data)
        )
        let detachedRecord = try XCTUnwrap(
            archive.workspaces.first { $0.id == detachedWorkspaceID }
        )
        XCTAssertEqual(detachedRecord.title, "Final")
        XCTAssertEqual(detachedRecord.tabs.count, 2)

        let writeCountBeforeRemoval = persistence.writeCount
        tearOutStore.releaseWindow(requestID)
        try await waitForPersistenceWriteCount(
            writeCountBeforeRemoval + 1,
            in: persistence
        )
        archive = try JSONDecoder().decode(
            WorkspaceSessionArchive.self,
            from: XCTUnwrap(persistence.data)
        )
        XCTAssertTrue(archive.detachedWorkspaceIDs.isEmpty)
        XCTAssertTrue(archive.windowTopology?.detachedWindows.isEmpty == true)
        XCTAssertEqual(archive.workspaces.map(\.id), [mainWorkspaceID])
        XCTAssertFalse(archive.workspaces.contains { $0.id == detachedWorkspaceID })
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testComparisonConfigurationNormalizesAndNilProviderPreservesIt() throws {
        let persistence = MemoryWorkspaceSessionPersistence()
        let sessionStore = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        let main = MultiDocumentWorkspaceState(sessionStore: sessionStore)
        let tabIDs = [try XCTUnwrap(main.activeTabID)] + (0..<5).map { _ in main.newTab() }
        let tearOutStore = PDFTabTearOutStore()
        let coordinator = AppWideWorkspaceSessionCoordinator(
            mainWorkspace: main,
            sessionStore: sessionStore,
            tearOutStore: tearOutStore
        )
        let missingID = UUID()
        coordinator.updateComparisonRecords(
            [
                .init(
                    windowID: nil,
                    workspaceID: main.activeWorkspaceID,
                    isComparing: true,
                    selectedDocumentIDs: [
                        tabIDs[0], tabIDs[0], missingID,
                        tabIDs[1], tabIDs[2], tabIDs[3], tabIDs[4]
                    ],
                    layout: "invalid-layout",
                    syncEnabled: true,
                    lockedDocumentIDs: [tabIDs[1], tabIDs[1], missingID],
                    sideBySideWeights: [
                        .init(documentID: tabIDs[0], weight: 1.5),
                        .init(documentID: tabIDs[0], weight: 2),
                        .init(documentID: missingID, weight: 1),
                        .init(documentID: tabIDs[1], weight: -.infinity)
                    ],
                    stackedWeights: [
                        .init(documentID: tabIDs[1], weight: 0.75)
                    ]
                )
            ]
        )
        XCTAssertTrue(coordinator.flushNow())

        var archive = try JSONDecoder().decode(
            WorkspaceSessionArchive.self,
            from: XCTUnwrap(persistence.data)
        )
        let normalized = try XCTUnwrap(archive.comparisonRecords?.first)
        XCTAssertEqual(
            normalized.selectedDocumentIDs,
            Array(tabIDs.prefix(4))
        )
        XCTAssertEqual(normalized.layout, "sideBySide")
        XCTAssertTrue(normalized.isComparing)
        XCTAssertEqual(normalized.lockedDocumentIDs, [tabIDs[1]])
        XCTAssertEqual(
            normalized.sideBySideWeights,
            [.init(documentID: tabIDs[0], weight: 1.5)]
        )
        XCTAssertEqual(
            normalized.stackedWeights,
            [.init(documentID: tabIDs[1], weight: 0.75)]
        )

        // A newly connected coordinator has no live comparison bridge yet.
        // Its nil snapshot must preserve the saved configuration, not write a
        // false default over it during launch bootstrap.
        let restoredStore = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        let restoredMain = MultiDocumentWorkspaceState(sessionStore: restoredStore)
        let passiveCoordinator = AppWideWorkspaceSessionCoordinator(
            mainWorkspace: restoredMain,
            sessionStore: restoredStore,
            tearOutStore: PDFTabTearOutStore()
        )
        archive = try JSONDecoder().decode(
            WorkspaceSessionArchive.self,
            from: XCTUnwrap(persistence.data)
        )
        XCTAssertEqual(archive.comparisonRecords, [normalized])
        withExtendedLifetime(coordinator) {}
        withExtendedLifetime(passiveCoordinator) {}
    }

    @MainActor
    func testAppWideCoordinatorHasNoStoreOrObserverRetainCycle() throws {
        let persistence = MemoryWorkspaceSessionPersistence()
        var sessionStore: WorkspaceSessionStore? = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        weak var weakSessionStore = sessionStore
        let main = MultiDocumentWorkspaceState(
            sessionStore: try XCTUnwrap(sessionStore)
        )
        let tearOutStore = PDFTabTearOutStore()
        var coordinator: AppWideWorkspaceSessionCoordinator? =
            AppWideWorkspaceSessionCoordinator(
                mainWorkspace: main,
                sessionStore: try XCTUnwrap(sessionStore),
                tearOutStore: tearOutStore
            )
        weak var weakCoordinator = coordinator

        sessionStore = nil
        XCTAssertNotNil(weakSessionStore, "The main workspace owns its store lifetime")
        coordinator = nil
        XCTAssertNil(weakCoordinator, "Weak provider/observer links must not form a cycle")
        XCTAssertTrue(main.flushSessionPersistence())
    }

    @MainActor
    func testCoordinatorPartitionsRestoredWindowTopologyWithoutDuplicatingSessions() throws {
        let mainFirstID = UUID()
        let mainActiveID = UUID()
        let detachedFirstID = UUID()
        let detachedActiveID = UUID()
        let requestID = UUID()
        let tabIDs = (0..<6).map { _ in UUID() }
        func record(
            id: UUID,
            title: String,
            tabs: [UUID],
            activeTabID: UUID
        ) -> WorkspaceSessionArchive.WorkspaceRecord {
            .init(
                id: id,
                title: title,
                activeTabID: activeTabID,
                tabs: tabs.map(emptyTabRecord),
                groups: []
            )
        }
        let archive = WorkspaceSessionArchive(
            activeWorkspaceID: mainActiveID,
            workspaces: [
                record(
                    id: mainFirstID,
                    title: "Main first",
                    tabs: [tabIDs[0]],
                    activeTabID: tabIDs[0]
                ),
                record(
                    id: mainActiveID,
                    title: "Main active",
                    tabs: [tabIDs[1], tabIDs[2]],
                    activeTabID: tabIDs[2]
                ),
                record(
                    id: detachedFirstID,
                    title: "Detached first",
                    tabs: [tabIDs[3]],
                    activeTabID: tabIDs[3]
                ),
                record(
                    id: detachedActiveID,
                    title: "Detached active",
                    tabs: [tabIDs[4], tabIDs[5]],
                    activeTabID: tabIDs[5]
                )
            ],
            detachedWorkspaceIDs: [detachedFirstID, detachedActiveID],
            windowTopology: .init(
                mainWorkspaceIDs: [mainFirstID, mainActiveID],
                detachedWindows: [
                    .init(
                        windowID: requestID,
                        workspaceIDs: [detachedFirstID, detachedActiveID],
                        activeWorkspaceID: detachedActiveID
                    )
                ]
            ),
            comparisonRecords: [
                .init(
                    windowID: nil,
                    workspaceID: mainActiveID,
                    isComparing: true,
                    selectedDocumentIDs: [tabIDs[1], tabIDs[2]],
                    layout: PDFComparisonLayout.sideBySide.rawValue,
                    syncEnabled: true,
                    lockedDocumentIDs: [tabIDs[2]],
                    sideBySideWeights: [
                        .init(documentID: tabIDs[1], weight: 0.4),
                        .init(documentID: tabIDs[2], weight: 0.6)
                    ],
                    stackedWeights: []
                ),
                .init(
                    windowID: requestID,
                    workspaceID: detachedActiveID,
                    isComparing: true,
                    selectedDocumentIDs: [tabIDs[4], tabIDs[5]],
                    layout: PDFComparisonLayout.stacked.rawValue,
                    syncEnabled: false,
                    lockedDocumentIDs: [],
                    sideBySideWeights: [],
                    stackedWeights: [
                        .init(documentID: tabIDs[4], weight: 0.3),
                        .init(documentID: tabIDs[5], weight: 0.7)
                    ]
                )
            ]
        )
        let persistence = MemoryWorkspaceSessionPersistence(
            data: try JSONEncoder().encode(archive)
        )
        let sessionStore = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        let main = MultiDocumentWorkspaceState(sessionStore: sessionStore)
        let tearOutStore = PDFTabTearOutStore()
        let coordinator = AppWideWorkspaceSessionCoordinator(
            mainWorkspace: main,
            sessionStore: sessionStore,
            tearOutStore: tearOutStore
        )

        XCTAssertEqual(main.workspaces.map(\.id), [mainFirstID, mainActiveID])
        XCTAssertEqual(main.activeWorkspaceID, mainActiveID)
        let detachedSnapshot = try XCTUnwrap(tearOutStore.windowSnapshots.first)
        XCTAssertEqual(detachedSnapshot.windowID, requestID)
        XCTAssertEqual(
            detachedSnapshot.workspace.workspaces.map(\.id),
            [detachedFirstID, detachedActiveID]
        )
        XCTAssertEqual(detachedSnapshot.workspace.activeWorkspaceID, detachedActiveID)

        let allSessions = main.allTabs + detachedSnapshot.workspace.allTabs
        XCTAssertEqual(allSessions.count, 6)
        XCTAssertEqual(
            Set(allSessions.map { ObjectIdentifier($0.workspace) }).count,
            allSessions.count
        )
        XCTAssertEqual(
            coordinator.comparisonPresentationState(
                windowID: nil,
                workspaceID: mainActiveID
            )?.configuration.lockedDocumentIDs,
            [tabIDs[2]]
        )
        let detachedComparison = try XCTUnwrap(
            coordinator.comparisonPresentationState(
                windowID: requestID,
                workspaceID: detachedActiveID
            )
        )
        XCTAssertTrue(detachedComparison.isComparing)
        XCTAssertEqual(detachedComparison.configuration.layout, .stacked)
        XCTAssertFalse(detachedComparison.configuration.syncEnabled)
        XCTAssertEqual(
            detachedComparison.configuration.panelFractions(for: .stacked),
            [0.3, 0.7]
        )

        var openedWindowIDs: [UUID] = []
        coordinator.openRestoredWindows { openedWindowIDs.append($0) }
        coordinator.openRestoredWindows { openedWindowIDs.append($0) }
        XCTAssertEqual(openedWindowIDs, [requestID])
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testMainWindowResumeDoesNotReinstallLiveDetachedWorkspace() throws {
        let fixture = try makePDFFixture(
            namesAndPageCounts: [("main.pdf", 1), ("detached.pdf", 1)]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let persistence = MemoryWorkspaceSessionPersistence()
        let sessionStore = WorkspaceSessionStore(
            persistence: persistence,
            bookmarkCoder: FakeWorkspaceSessionBookmarkCoder()
        )
        let main = MultiDocumentWorkspaceState(sessionStore: sessionStore)
        let mainWorkspaceID = main.activeWorkspaceID
        let openedTabIDs = main.openPDFsInTabs(urls: fixture.urls)
        XCTAssertEqual(openedTabIDs.count, 2)
        let tearOutStore = PDFTabTearOutStore()
        let coordinator = AppWideWorkspaceSessionCoordinator(
            mainWorkspace: main,
            sessionStore: sessionStore,
            tearOutStore: tearOutStore
        )
        let requestID = try XCTUnwrap(
            tearOutStore.stageNewWindow(
                tabID: openedTabIDs[1],
                from: main
            )
        )
        let detached = try XCTUnwrap(tearOutStore.workspace(for: requestID))
        let detachedWorkspaceID = detached.activeWorkspaceID
        let detachedPDFState = try XCTUnwrap(detached.activeWorkspace)
        XCTAssertTrue(coordinator.flushNow())

        main.freezeSessionPersistenceAfterFlushing(
            including: tearOutStore.allWindowWorkspaces
        )
        main.activeWorkspace?.closeDiscardingChanges()
        XCTAssertFalse(main.activeWorkspace?.hasOpenDocument ?? true)

        coordinator.resumeMainSessionPersistence()

        XCTAssertEqual(main.workspaces.map(\.id), [mainWorkspaceID])
        XCTAssertEqual(main.activeWorkspace?.documentURL, fixture.urls[0])
        XCTAssertFalse(main.workspaces.contains { $0.id == detachedWorkspaceID })
        XCTAssertTrue(tearOutStore.workspace(for: requestID) === detached)
        XCTAssertTrue(detached.activeWorkspace === detachedPDFState)
        XCTAssertEqual(detached.activeWorkspace?.documentURL, fixture.urls[1])
        XCTAssertEqual(
            Set((main.allTabs + detached.allTabs).map(\.id)).count,
            main.allTabs.count + detached.allTabs.count
        )
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    private func waitForPersistenceWriteCount(
        _ expectedCount: Int,
        in persistence: MemoryWorkspaceSessionPersistence
    ) async throws {
        for _ in 0..<200 {
            if persistence.writeCount >= expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(
            "Timed out waiting for persistence write count \(expectedCount); "
                + "received \(persistence.writeCount)"
        )
    }

    private func tabRecord(
        id: UUID,
        bookmark: Data,
        path: String
    ) -> WorkspaceSessionArchive.TabRecord {
        .init(
            id: id,
            document: .init(bookmark: bookmark, lastKnownPath: path, pageCount: 2),
            currentPageIndex: 0,
            selectedPages: [0],
            pageColumns: 1,
            overviewScale: 1
        )
    }

    private func emptyTabRecord(id: UUID) -> WorkspaceSessionArchive.TabRecord {
        .init(
            id: id,
            document: nil,
            currentPageIndex: 0,
            selectedPages: [],
            pageColumns: 1,
            overviewScale: 1
        )
    }

    private func makePDFFixture(
        namesAndPageCounts: [(String, Int)]
    ) throws -> (directory: URL, urls: [URL]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let urls = try namesAndPageCounts.map { name, pageCount in
            let document = PDFDocument()
            for index in 0..<pageCount {
                let image = NSImage(size: NSSize(width: 160, height: 220))
                image.lockFocus()
                NSColor.white.setFill()
                NSRect(origin: .zero, size: image.size).fill()
                NSString(string: "Page \(index + 1)").draw(at: NSPoint(x: 20, y: 20))
                image.unlockFocus()
                document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
            }
            let url = directory.appendingPathComponent(name)
            XCTAssertTrue(document.write(to: url))
            return url
        }
        return (directory, urls)
    }
}

private final class MemoryWorkspaceSessionPersistence: WorkspaceSessionDataPersisting {
    var data: Data?
    private(set) var writeCount = 0

    init(data: Data? = nil) {
        self.data = data
    }

    func read() throws -> Data? { data }

    func write(_ data: Data) throws {
        self.data = data
        writeCount += 1
    }
}

private final class FakeWorkspaceSessionBookmarkCoder: WorkspaceSessionBookmarkCoding {
    private struct Payload: Codable {
        var path: String
        var isStale: Bool
    }

    private(set) var bookmarkCreationCount = 0

    func makeBookmark(for url: URL) throws -> Data {
        bookmarkCreationCount += 1
        return try encodedBookmark(for: url, isStale: false)
    }

    func encodedBookmark(for url: URL, isStale: Bool) throws -> Data {
        try JSONEncoder().encode(Payload(path: url.path, isStale: isStale))
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (URL(fileURLWithPath: payload.path), payload.isStale)
    }

    func isStale(_ data: Data) throws -> Bool {
        try JSONDecoder().decode(Payload.self, from: data).isStale
    }
}

private struct AlwaysFailingWorkspaceBookmarkCoder: WorkspaceSessionBookmarkCoding {
    private struct Denied: Error {}

    func makeBookmark(for url: URL) throws -> Data { throw Denied() }
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) { throw Denied() }
}

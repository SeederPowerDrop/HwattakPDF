// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class MultiDocumentWorkspaceStateTests: XCTestCase {
    @MainActor
    func testInitialStateContainsOneActiveEmptyTab() {
        let workspace = MultiDocumentWorkspaceState()

        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.activeTabID, workspace.tabs[0].id)
        XCTAssertTrue(workspace.activeSession?.workspace === workspace.tabs[0].workspace)
        XCTAssertNil(workspace.activeWorkspace?.document)
        XCTAssertTrue(workspace.documentSessions.isEmpty)
        XCTAssertEqual(workspace.workspaces.count, 1)
        XCTAssertEqual(workspace.activeWorkspaceID, workspace.workspaces[0].id)
        XCTAssertEqual(workspace.workspaces[0].tabs.map(\.id), workspace.tabs.map(\.id))
    }

    @MainActor
    func testWorkspaceSwitchingIsolatesTabsGroupsAndRestoresDocumentState() throws {
        let fixture = try makePDFFixture(names: ["workspace-source.pdf"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = MultiDocumentWorkspaceState()
        let firstWorkspaceID = workspace.activeWorkspaceID
        let openedID = try XCTUnwrap(workspace.openPDFsInTabs(urls: fixture.urls).first)
        let secondTabID = workspace.newTab()
        let firstGroupID = try XCTUnwrap(
            workspace.createTabGroup(title: "Research", tabIDs: [openedID, secondTabID])
        )
        workspace.selectTab(openedID)
        let preservedDocumentState = try XCTUnwrap(workspace.activeWorkspace)
        preservedDocumentState.statusMessage = "preserved-state"

        let secondWorkspaceID = workspace.createWorkspace(title: "Contracts")
        let secondWorkspaceInitialTabID = try XCTUnwrap(workspace.activeTabID)
        let secondWorkspaceExtraTabID = workspace.newTab()
        let secondGroupID = try XCTUnwrap(
            workspace.createTabGroup(
                title: "Reviews",
                tabIDs: [secondWorkspaceInitialTabID, secondWorkspaceExtraTabID]
            )
        )
        workspace.selectTab(secondWorkspaceInitialTabID)

        XCTAssertTrue(workspace.selectWorkspace(firstWorkspaceID))
        XCTAssertEqual(workspace.tabs.map(\.id), [openedID, secondTabID])
        XCTAssertEqual(workspace.tabGroups.map(\.id), [firstGroupID])
        XCTAssertEqual(workspace.activeTabID, openedID)
        XCTAssertTrue(workspace.activeWorkspace === preservedDocumentState)
        XCTAssertNotNil(workspace.activeWorkspace?.document)
        XCTAssertEqual(workspace.activeWorkspace?.statusMessage, "preserved-state")

        XCTAssertTrue(workspace.selectWorkspace(secondWorkspaceID))
        XCTAssertEqual(
            workspace.tabs.map(\.id),
            [secondWorkspaceInitialTabID, secondWorkspaceExtraTabID]
        )
        XCTAssertEqual(workspace.tabGroups.map(\.id), [secondGroupID])
        XCTAssertEqual(workspace.activeTabID, secondWorkspaceInitialTabID)
        XCTAssertEqual(workspace.activeWorkspaceDescriptor?.title, "Contracts")
    }

    @MainActor
    func testWorkspaceCreationRenameAndDeletionMaintainMinimumAndActiveInvariant() throws {
        let workspace = MultiDocumentWorkspaceState()
        let firstWorkspaceID = workspace.activeWorkspaceID

        XCTAssertFalse(workspace.deleteWorkspace(firstWorkspaceID))

        let secondWorkspaceID = workspace.createWorkspace(title: "  Archive  ", activate: false)
        XCTAssertEqual(workspace.activeWorkspaceID, firstWorkspaceID)
        XCTAssertEqual(workspace.workspaces.count, 2)
        XCTAssertEqual(workspace.sessions(inWorkspace: secondWorkspaceID).count, 1)
        XCTAssertEqual(
            workspace.workspaces.first(where: { $0.id == secondWorkspaceID })?.title,
            "Archive"
        )

        XCTAssertTrue(workspace.renameWorkspace(secondWorkspaceID, to: "  Legal  "))
        XCTAssertEqual(
            workspace.workspaces.first(where: { $0.id == secondWorkspaceID })?.title,
            "Legal"
        )
        XCTAssertFalse(workspace.renameWorkspace(UUID(), to: "Missing"))

        XCTAssertTrue(workspace.deleteWorkspace(firstWorkspaceID))
        XCTAssertEqual(workspace.workspaces.count, 1)
        XCTAssertEqual(workspace.activeWorkspaceID, secondWorkspaceID)
        XCTAssertEqual(workspace.activeTabID, workspace.tabs.first?.id)
        XCTAssertFalse(workspace.deleteWorkspace(secondWorkspaceID))
    }

    @MainActor
    func testMovingTabAcrossWorkspacesPreservesSessionAndRepairsSourceActiveTab() throws {
        let workspace = MultiDocumentWorkspaceState()
        let sourceWorkspaceID = workspace.activeWorkspaceID
        let sourceFirstTabID = try XCTUnwrap(workspace.activeTabID)
        let movedTabID = workspace.newTab()
        let movedSession = try XCTUnwrap(workspace.activeSession)
        let destinationWorkspaceID = workspace.createWorkspace(
            title: "Destination",
            activate: false
        )
        XCTAssertEqual(workspace.sessions(inWorkspace: destinationWorkspaceID).count, 1)

        XCTAssertTrue(workspace.moveTab(movedTabID, toWorkspace: destinationWorkspaceID))
        XCTAssertEqual(workspace.activeWorkspaceID, sourceWorkspaceID)
        XCTAssertEqual(workspace.tabs.map(\.id), [sourceFirstTabID])
        XCTAssertEqual(workspace.activeTabID, sourceFirstTabID)
        XCTAssertEqual(
            workspace.sessions(inWorkspace: destinationWorkspaceID).map(\.id),
            [movedTabID]
        )
        XCTAssertEqual(workspace.allTabs.count, 2)

        XCTAssertTrue(workspace.selectWorkspace(destinationWorkspaceID))
        XCTAssertEqual(workspace.activeTabID, movedTabID)
        XCTAssertTrue(workspace.activeSession?.workspace === movedSession.workspace)
        XCTAssertEqual(workspace.workspace(containingTab: movedTabID)?.id, destinationWorkspaceID)
        XCTAssertFalse(workspace.moveTab(movedTabID, toWorkspace: destinationWorkspaceID))
    }

    @MainActor
    func testMovingOnlyTabOutOfWorkspaceLeavesFreshActiveReplacement() throws {
        let workspace = MultiDocumentWorkspaceState()
        let sourceWorkspaceID = workspace.activeWorkspaceID
        let onlyTabID = try XCTUnwrap(workspace.activeTabID)
        let destinationWorkspaceID = workspace.createWorkspace(
            title: "Destination",
            activate: false
        )

        XCTAssertTrue(workspace.moveTab(onlyTabID, toWorkspace: destinationWorkspaceID))
        XCTAssertEqual(workspace.activeWorkspaceID, sourceWorkspaceID)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.activeTabID, onlyTabID)
        XCTAssertEqual(workspace.activeTabID, workspace.tabs.first?.id)
        XCTAssertNil(workspace.activeWorkspace?.document)
    }

    @MainActor
    func testDeletingWorkspaceRejectsUnsavedChangesUnlessDiscardWasConfirmed() throws {
        let fixture = try makePDFFixture(names: ["unsaved-workspace.pdf"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = MultiDocumentWorkspaceState()
        let dirtyWorkspaceID = workspace.activeWorkspaceID
        _ = workspace.openPDFsInTabs(urls: fixture.urls)
        workspace.activeWorkspace?.setMode(.editing)
        workspace.activeWorkspace?.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.activeWorkspace?.isDirty == true)

        let replacementWorkspaceID = workspace.createWorkspace(
            title: "Replacement",
            activate: false
        )

        XCTAssertFalse(workspace.deleteWorkspace(dirtyWorkspaceID))
        XCTAssertEqual(workspace.workspaces.count, 2)
        XCTAssertEqual(workspace.activeWorkspaceID, dirtyWorkspaceID)
        XCTAssertNotNil(workspace.activeWorkspace?.document)

        XCTAssertTrue(
            workspace.deleteWorkspace(dirtyWorkspaceID, discardingChanges: true)
        )
        XCTAssertEqual(workspace.workspaces.count, 1)
        XCTAssertEqual(workspace.activeWorkspaceID, replacementWorkspaceID)
        XCTAssertEqual(workspace.activeTabID, workspace.tabs.first?.id)
    }

    @MainActor
    func testDeletingWorkspaceTreatsUnappliedReviewDraftAsUnsavedLifecycleState() throws {
        let fixture = try makePDFFixture(names: ["draft-workspace.pdf"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let collection = MultiDocumentWorkspaceState()
        let draftWorkspaceID = collection.activeWorkspaceID
        _ = collection.openPDFsInTabs(urls: fixture.urls)
        let documentWorkspace = try XCTUnwrap(collection.activeWorkspace)
        documentWorkspace.requestTextEdit(
            pageIndex: 0,
            point: CGPoint(x: 30, y: 90),
            annotation: nil
        )
        let draft = try XCTUnwrap(documentWorkspace.pendingTextEdit)
        documentWorkspace.updatePendingTextDraft(id: draft.id, text: "not applied yet")
        XCTAssertFalse(documentWorkspace.isDirty)
        XCTAssertTrue(documentWorkspace.hasPendingReviewTextDraft)

        let replacementID = collection.createWorkspace(
            title: "Replacement",
            activate: false
        )
        XCTAssertFalse(collection.deleteWorkspace(draftWorkspaceID))
        XCTAssertEqual(collection.workspaces.count, 2)
        XCTAssertEqual(documentWorkspace.pendingTextEdit?.initialText, "not applied yet")
        XCTAssertNotNil(documentWorkspace.document)

        // The destructive overload represents an already confirmed discard.
        XCTAssertTrue(
            collection.deleteWorkspace(draftWorkspaceID, discardingChanges: true)
        )
        XCTAssertEqual(collection.activeWorkspaceID, replacementID)
    }

    @MainActor
    func testOpeningTwoPDFsReusesInitialEmptyTabPreservesOrderAndActivatesLast() throws {
        let fixture = try makePDFFixture(names: ["first.pdf", "second.pdf"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = MultiDocumentWorkspaceState()
        let initialTabID = try XCTUnwrap(workspace.activeTabID)

        let openedIDs = workspace.openPDFsInTabs(urls: fixture.urls)

        XCTAssertEqual(openedIDs.count, 2)
        XCTAssertEqual(openedIDs.first, initialTabID)
        XCTAssertEqual(workspace.tabs.map(\.id), openedIDs)
        XCTAssertEqual(workspace.tabs.compactMap { $0.workspace.documentURL }, fixture.urls)
        XCTAssertEqual(workspace.documentSessions.map(\.id), openedIDs)
        XCTAssertEqual(workspace.activeTabID, openedIDs.last)
    }

    @MainActor
    func testOpeningPDFsIntoGroupReusesInitialTabAndKeepsGroupOrder() throws {
        let fixture = try makePDFFixture(names: ["group-first.pdf", "group-second.pdf"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = MultiDocumentWorkspaceState()
        let initialID = try XCTUnwrap(workspace.activeTabID)
        let groupID = try XCTUnwrap(
            workspace.createTabGroup(title: "프로젝트", tabIDs: [initialID])
        )

        let openedIDs = workspace.openPDFsInTabs(urls: fixture.urls, inGroup: groupID)

        XCTAssertEqual(openedIDs.count, 2)
        XCTAssertEqual(openedIDs.first, initialID)
        XCTAssertEqual(workspace.tabs.map(\.id), openedIDs)
        XCTAssertEqual(workspace.tabGroups.first?.tabIDs, openedIDs)
        XCTAssertEqual(workspace.orderedTabBarEntries.map(\.tabIDs), [openedIDs])
        XCTAssertEqual(workspace.activeTabID, openedIDs.last)
    }

    @MainActor
    func testOpeningTheSameURLDoesNotCreateADuplicateTab() throws {
        let fixture = try makePDFFixture(names: ["duplicate.pdf"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = MultiDocumentWorkspaceState()
        let url = try XCTUnwrap(fixture.urls.first)

        let batchIDs = workspace.openPDFsInTabs(urls: [url, url])
        let firstID = try XCTUnwrap(batchIDs.first)
        let reopenedIDs = workspace.openPDFsInTabs(urls: [url])

        XCTAssertEqual(batchIDs, [firstID])
        XCTAssertEqual(reopenedIDs, [firstID])
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.documentSessions.count, 1)
        XCTAssertEqual(workspace.activeTabID, firstID)
        XCTAssertEqual(workspace.activeWorkspace?.documentURL, url)
    }

    @MainActor
    func testInvalidPDFDoesNotLeaveAGhostTab() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Invalid-Tab-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let invalidURL = directory.appendingPathComponent("damaged.pdf")
        try Data("not a PDF".utf8).write(to: invalidURL)
        let workspace = MultiDocumentWorkspaceState()
        let initialID = try XCTUnwrap(workspace.activeTabID)

        let openedIDs = workspace.openPDFsInTabs(urls: [invalidURL])

        XCTAssertTrue(openedIDs.isEmpty)
        XCTAssertEqual(workspace.tabs.map(\.id), [initialID])
        XCTAssertNil(workspace.activeWorkspace?.document)
        XCTAssertNotNil(workspace.activeWorkspace?.presentedError)
    }

    @MainActor
    func testClosingCleanTabsSelectsAdjacentTabAndReplacesTheLastTab() throws {
        let fixture = try makePDFFixture(names: ["first.pdf", "second.pdf"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = MultiDocumentWorkspaceState()
        let openedIDs = workspace.openPDFsInTabs(urls: fixture.urls)
        XCTAssertEqual(openedIDs.count, 2)
        let firstID = openedIDs[0]
        let secondID = openedIDs[1]
        let emptyID = workspace.newTab()

        workspace.selectTab(firstID)
        XCTAssertTrue(workspace.closeTab(firstID))
        XCTAssertEqual(workspace.tabs.map(\.id), [secondID, emptyID])
        XCTAssertEqual(workspace.activeTabID, secondID)

        XCTAssertTrue(workspace.closeTab(secondID))
        XCTAssertEqual(workspace.tabs.map(\.id), [emptyID])
        XCTAssertEqual(workspace.activeTabID, emptyID)

        XCTAssertTrue(workspace.closeTab(emptyID))
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertNotEqual(workspace.tabs[0].id, emptyID)
        XCTAssertEqual(workspace.activeTabID, workspace.tabs[0].id)
        XCTAssertNil(workspace.activeWorkspace?.document)
    }

    @MainActor
    func testReorderingTabsWorksInBothDirections() {
        let workspace = MultiDocumentWorkspaceState()
        let firstID = workspace.tabs[0].id
        let secondID = workspace.newTab()
        let thirdID = workspace.newTab()

        workspace.moveTab(thirdID, before: firstID)
        XCTAssertEqual(workspace.tabs.map(\.id), [thirdID, firstID, secondID])

        workspace.moveTab(thirdID, before: secondID)
        XCTAssertEqual(workspace.tabs.map(\.id), [firstID, thirdID, secondID])
        XCTAssertEqual(workspace.activeTabID, thirdID)
    }

    @MainActor
    func testAdjacentTabSelectionWrapsInBothDirections() {
        let workspace = MultiDocumentWorkspaceState()
        let firstID = workspace.tabs[0].id
        let secondID = workspace.newTab()
        let thirdID = workspace.newTab()

        workspace.selectTab(firstID)
        workspace.selectAdjacentTab(forward: false)
        XCTAssertEqual(workspace.activeTabID, thirdID)

        workspace.selectAdjacentTab(forward: true)
        XCTAssertEqual(workspace.activeTabID, firstID)

        workspace.selectAdjacentTab(forward: true)
        XCTAssertEqual(workspace.activeTabID, secondID)

        workspace.selectTab(thirdID)
        workspace.selectAdjacentTab(forward: true)
        XCTAssertEqual(workspace.activeTabID, firstID)
    }

    private func makePDFFixture(names: [String]) throws -> (directory: URL, urls: [URL]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Multi-Document-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var urls: [URL] = []
        do {
            for (index, name) in names.enumerated() {
                let url = directory.appendingPathComponent(name)
                let document = PDFDocument()
                let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
                    let shade = CGFloat(index + 1) / CGFloat(names.count + 1)
                    NSColor(calibratedWhite: 0.82 + shade * 0.12, alpha: 1).setFill()
                    rect.fill()
                    return true
                }
                let page = try XCTUnwrap(PDFPage(image: image))
                document.insert(page, at: 0)
                guard document.write(to: url) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                urls.append(url)
            }
            return (directory, urls)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

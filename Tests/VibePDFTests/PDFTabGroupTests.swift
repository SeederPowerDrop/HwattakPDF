// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

final class PDFTabGroupTests: XCTestCase {
    func testWorkspaceRulesTrimTitlesAndKeepFallbacksUsable() {
        XCTAssertEqual(
            PDFDocumentWorkspaceRules.normalizedTitle("  Contracts  ", fallback: "Workspace"),
            "Contracts"
        )
        XCTAssertEqual(
            PDFDocumentWorkspaceRules.normalizedTitle(" \n ", fallback: "Workspace"),
            "Workspace"
        )
        XCTAssertFalse(PDFDocumentWorkspaceRules.defaultTitle(at: 0).isEmpty)
    }

    func testDropIntentUsesEdgesForReorderAndCenterForStacking() {
        XCTAssertEqual(PDFTabDropIntent.resolve(locationX: 0, width: 180), .before)
        XCTAssertEqual(PDFTabDropIntent.resolve(locationX: 35, width: 180), .before)
        XCTAssertEqual(PDFTabDropIntent.resolve(locationX: 36, width: 180), .createOrJoinGroup)
        XCTAssertEqual(PDFTabDropIntent.resolve(locationX: 144, width: 180), .createOrJoinGroup)
        XCTAssertEqual(PDFTabDropIntent.resolve(locationX: 145, width: 180), .after)
        XCTAssertEqual(PDFTabDropIntent.resolve(locationX: 180, width: 180), .after)
        XCTAssertEqual(PDFTabDropIntent.resolve(locationX: 20, width: 0), .createOrJoinGroup)
        XCTAssertEqual(
            PDFTabDropIntent.resolve(locationX: 0, width: 180, isRightToLeft: true),
            .after
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(locationX: 180, width: 180, isRightToLeft: true),
            .before
        )
    }

    func testDropIntentCenterBandIsStableAtBoundariesAndInRightToLeftLayout() {
        let width = 200.0

        XCTAssertEqual(
            PDFTabDropIntent.resolve(locationX: width * 0.20, width: width),
            .createOrJoinGroup
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(locationX: width * 0.50, width: width),
            .createOrJoinGroup
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(locationX: width * 0.80, width: width),
            .createOrJoinGroup
        )

        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: width * 0.20,
                width: width,
                isRightToLeft: true
            ),
            .createOrJoinGroup
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: width * 0.50,
                width: width,
                isRightToLeft: true
            ),
            .createOrJoinGroup
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: width * 0.80,
                width: width,
                isRightToLeft: true
            ),
            .createOrJoinGroup
        )
    }

    func testDropIntentHysteresisKeepsCenterAndEdgesStable() {
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 34,
                width: 180,
                previousIntent: .createOrJoinGroup
            ),
            .createOrJoinGroup
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 28,
                width: 180,
                previousIntent: .createOrJoinGroup
            ),
            .before
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 42,
                width: 180,
                previousIntent: .before
            ),
            .before
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 48,
                width: 180,
                previousIntent: .before
            ),
            .createOrJoinGroup
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 138,
                width: 180,
                previousIntent: .after
            ),
            .after
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 132,
                width: 180,
                previousIntent: .after
            ),
            .createOrJoinGroup
        )
    }

    func testDropIntentHysteresisMirrorsForRightToLeftLayout() {
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 34,
                width: 180,
                isRightToLeft: true,
                previousIntent: .createOrJoinGroup
            ),
            .createOrJoinGroup
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 28,
                width: 180,
                isRightToLeft: true,
                previousIntent: .createOrJoinGroup
            ),
            .after
        )
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 42,
                width: 180,
                isRightToLeft: true,
                previousIntent: .after
            ),
            .after
        )
    }

    func testDropIntentHysteresisResetsWhenHoverMovesToAnotherTarget() {
        let firstTarget = UUID()
        let secondTarget = UUID()

        XCTAssertEqual(
            PDFTabDropState.continuingIntent(
                currentTargetID: firstTarget,
                newTargetID: firstTarget,
                currentIntent: .before
            ),
            .before
        )
        XCTAssertNil(
            PDFTabDropState.continuingIntent(
                currentTargetID: firstTarget,
                newTargetID: secondTarget,
                currentIntent: .before
            )
        )

        // A fresh target uses the normal 20% threshold instead of inheriting
        // the previous target's wider 26% edge hysteresis.
        XCTAssertEqual(
            PDFTabDropIntent.resolve(
                locationX: 42,
                width: 180,
                previousIntent: nil
            ),
            .createOrJoinGroup
        )
    }

    func testTabDragPayloadUsesLocalStateForReliableHoverFeedback() {
        let draggedTabID = UUID()
        let unrelatedTabID = UUID()

        XCTAssertEqual(
            PDFTabDragPayload.resolve(
                localTabID: draggedTabID,
                providerSuggestedNames: []
            ),
            draggedTabID
        )
        XCTAssertEqual(
            PDFTabDragPayload.resolve(
                localTabID: draggedTabID,
                providerSuggestedNames: [
                    PDFTabDragPayload.suggestedName(for: unrelatedTabID)
                ]
            ),
            draggedTabID
        )
    }

    func testTabDragPayloadFallsBackToNamespacedProviderMetadata() {
        let draggedTabID = UUID()

        XCTAssertEqual(
            PDFTabDragPayload.resolve(
                localTabID: nil,
                providerSuggestedNames: [PDFTabDragPayload.suggestedName(for: draggedTabID)]
            ),
            draggedTabID
        )
        XCTAssertNil(
            PDFTabDragPayload.resolve(
                localTabID: nil,
                providerSuggestedNames: [draggedTabID.uuidString, "hwattak-tab-invalid"]
            )
        )
    }

    func testTabDragPayloadContentRejectsStaleMismatchAndForeignText() {
        let staleLocalID = UUID()
        let providerTabID = UUID()
        let encoded = PDFTabDragPayload.encodedValue(for: providerTabID)

        XCTAssertEqual(PDFTabDragPayload.decode(encoded), providerTabID)
        XCTAssertNotEqual(PDFTabDragPayload.decode(encoded), staleLocalID)
        XCTAssertNil(PDFTabDragPayload.decode(providerTabID.uuidString))
        XCTAssertNil(PDFTabDragPayload.decode("ordinary text dragged from another app"))
        XCTAssertNil(
            PDFTabDragPayload.decode(
                PDFComparisonPanelDragPayload.encodedValue(for: providerTabID)
            )
        )
    }

    func testWorkspaceTearOutDropRequiresLocalMembershipAndAuthoritativePayload() {
        let tabID = UUID()
        let otherID = UUID()
        let openTabIDs: Set<UUID> = [tabID]

        XCTAssertNil(
            PDFTabTearOutDropRules.localCandidate(
                draggedTabID: nil,
                openTabIDs: openTabIDs,
                hasCompatibleProvider: true
            )
        )
        XCTAssertNil(
            PDFTabTearOutDropRules.localCandidate(
                draggedTabID: otherID,
                openTabIDs: openTabIDs,
                hasCompatibleProvider: true
            )
        )
        XCTAssertEqual(
            PDFTabTearOutDropRules.localCandidate(
                draggedTabID: tabID,
                openTabIDs: openTabIDs,
                hasCompatibleProvider: true
            ),
            tabID
        )
        XCTAssertNil(
            PDFTabTearOutDropRules.localCandidate(
                draggedTabID: tabID,
                openTabIDs: openTabIDs,
                hasCompatibleProvider: false
            )
        )

        XCTAssertNil(
            PDFTabTearOutDropRules.authoritativeTabID(
                encodedValue: "ordinary external text",
                expectedTabID: tabID,
                openTabIDs: openTabIDs
            )
        )
        XCTAssertNil(
            PDFTabTearOutDropRules.authoritativeTabID(
                encodedValue: tabID.uuidString,
                expectedTabID: tabID,
                openTabIDs: openTabIDs
            )
        )
        XCTAssertNil(
            PDFTabTearOutDropRules.authoritativeTabID(
                encodedValue: PDFTabDragPayload.encodedValue(for: otherID),
                expectedTabID: tabID,
                openTabIDs: openTabIDs
            )
        )
        XCTAssertEqual(
            PDFTabTearOutDropRules.authoritativeTabID(
                encodedValue: PDFTabDragPayload.encodedValue(for: tabID),
                expectedTabID: tabID,
                openTabIDs: openTabIDs
            ),
            tabID
        )
        XCTAssertNil(
            PDFTabTearOutDropRules.authoritativeTabID(
                encodedValue: PDFTabDragPayload.encodedValue(for: tabID),
                expectedTabID: tabID,
                openTabIDs: []
            )
        )
    }

    func testTabStripOverflowKeepsInlinePlusUntilContentExceedsViewport() {
        XCTAssertFalse(
            PDFTabStripLayout.isOverflowing(
                contentWidth: 364,
                trailingActionWidth: 31,
                viewportWidth: 400
            )
        )
        XCTAssertTrue(
            PDFTabStripLayout.isOverflowing(
                contentWidth: 365.1,
                trailingActionWidth: 31,
                viewportWidth: 400
            )
        )
        XCTAssertFalse(
            PDFTabStripLayout.isOverflowing(
                contentWidth: 400,
                trailingActionWidth: 0,
                viewportWidth: 400
            )
        )
    }

    func testTabStripStepClampsAtBothEnds() {
        XCTAssertNil(PDFTabStripLayout.steppedIndex(from: 0, offset: 1, itemCount: 0))
        XCTAssertEqual(PDFTabStripLayout.steppedIndex(from: 0, offset: -1, itemCount: 5), 0)
        XCTAssertEqual(PDFTabStripLayout.steppedIndex(from: 2, offset: 1, itemCount: 5), 3)
        XCTAssertEqual(PDFTabStripLayout.steppedIndex(from: 4, offset: 1, itemCount: 5), 4)
    }

    func testTabStripMapsOnlyOrdinaryVerticalWheelInputToHorizontalMotion() {
        XCTAssertEqual(
            PDFTabStripLayout.mappedHorizontalWheelDelta(
                deltaX: 0,
                deltaY: -6,
                hasPreciseDeltas: true,
                hasBlockingModifier: false
            ),
            -6
        )
        XCTAssertEqual(
            PDFTabStripLayout.mappedHorizontalWheelDelta(
                deltaX: -2,
                deltaY: -6,
                hasPreciseDeltas: true,
                hasBlockingModifier: false
            ),
            -8
        )
        XCTAssertEqual(
            PDFTabStripLayout.mappedHorizontalWheelDelta(
                deltaX: 2,
                deltaY: -6,
                hasPreciseDeltas: true,
                hasBlockingModifier: false
            ),
            -6
        )
        XCTAssertEqual(
            PDFTabStripLayout.mappedHorizontalWheelDelta(
                deltaX: 0,
                deltaY: 1,
                hasPreciseDeltas: false,
                hasBlockingModifier: false
            ),
            PDFTabStripLayout.mouseWheelLineMultiplier
        )
        XCTAssertNil(
            PDFTabStripLayout.mappedHorizontalWheelDelta(
                deltaX: 8,
                deltaY: 2,
                hasPreciseDeltas: true,
                hasBlockingModifier: false
            ),
            "A native horizontal gesture must remain owned by the SwiftUI scroll view."
        )
        XCTAssertNil(
            PDFTabStripLayout.mappedHorizontalWheelDelta(
                deltaX: 0,
                deltaY: 5,
                hasPreciseDeltas: true,
                hasBlockingModifier: true
            )
        )
        XCTAssertNil(
            PDFTabStripLayout.mappedHorizontalWheelDelta(
                deltaX: 0,
                deltaY: .nan,
                hasPreciseDeltas: true,
                hasBlockingModifier: false
            )
        )
    }

    @MainActor
    func testTabStripWheelMonitorMovesAndClampsTheNativeClipView() {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 50)
        )
        scrollView.documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 50)
        )
        scrollView.contentView.scroll(to: NSPoint(x: 100, y: 0))

        XCTAssertTrue(
            PDFTabStripWheelMonitor.scrollHorizontally(
                wheelDelta: -25,
                in: scrollView
            )
        )
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 125, accuracy: 0.001)

        scrollView.contentView.scroll(to: NSPoint(x: 590, y: 0))
        XCTAssertTrue(
            PDFTabStripWheelMonitor.scrollHorizontally(
                wheelDelta: -40,
                in: scrollView
            )
        )
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 600, accuracy: 0.001)

        scrollView.documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: 180, height: 50)
        )
        XCTAssertFalse(
            PDFTabStripWheelMonitor.scrollHorizontally(
                wheelDelta: -20,
                in: scrollView
            )
        )
    }

    func testTabStripInstallsAPassiveVerticalWheelMonitor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tabBarSource = try String(
            contentsOf: root.appendingPathComponent("Sources/VibePDF/Views/PDFTabBar.swift"),
            encoding: .utf8
        )
        let monitorSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/VibePDF/Views/PDFTabStripWheelMonitor.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(tabBarSource.contains("PDFTabStripWheelMonitor(isEnabled: isOverflowing)"))
        XCTAssertTrue(monitorSource.contains("matching: .scrollWheel"))
        XCTAssertTrue(monitorSource.contains("override func hitTest(_ point: NSPoint) -> NSView?"))
        XCTAssertTrue(monitorSource.contains("static func dismantleNSView"))
        XCTAssertFalse(monitorSource.contains("matching: [.magnify"))
    }

    @MainActor
    func testCreatingGroupCompactsMembersAndKeepsActiveTab() throws {
        let workspace = MultiDocumentWorkspaceState()
        let first = try XCTUnwrap(workspace.activeTabID)
        let second = workspace.newTab()
        let third = workspace.newTab()
        let fourth = workspace.newTab()

        let groupID = try XCTUnwrap(
            workspace.createTabGroup(title: "  연구 자료  ", tabIDs: [second, fourth, second])
        )

        XCTAssertEqual(workspace.tabs.map(\.id), [first, second, fourth, third])
        XCTAssertEqual(workspace.tabGroups.map(\.id), [groupID])
        XCTAssertEqual(workspace.tabGroups[0].title, "연구 자료")
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [second, fourth])
        XCTAssertEqual(workspace.ungroupedTabs.map(\.id), [first, third])
        XCTAssertEqual(workspace.orderedTabBarEntries.map(\.tabIDs), [[first], [second, fourth], [third]])
        XCTAssertEqual(workspace.activeTabID, fourth)
    }

    @MainActor
    func testTearOutClaimMovesExactDirtySessionAndRepairsSourceStack() throws {
        let fixture = try makePDFFixture(names: ["tear-out-source.pdf"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let source = MultiDocumentWorkspaceState()
        let movedID = try XCTUnwrap(source.openPDFsInTabs(urls: fixture.urls).first)
        let movedSession = try XCTUnwrap(source.activeSession)
        movedSession.workspace.setMode(.editing)
        movedSession.workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(movedSession.workspace.isDirty)

        let remainingID = source.newTab()
        _ = try XCTUnwrap(
            source.createTabGroup(title: "분리", tabIDs: [movedID, remainingID])
        )

        let requestID = try XCTUnwrap(
            PDFTabTearOutStore.shared.stageNewWindow(tabID: movedID, from: source)
        )
        // Staging alone is lossless if SwiftUI cannot create the new window.
        XCTAssertTrue(source.tabs.contains(where: { $0.id == movedID }))

        let destination = try XCTUnwrap(
            PDFTabTearOutStore.shared.workspace(for: requestID)
        )
        defer { PDFTabTearOutStore.shared.releaseWindow(requestID) }

        XCTAssertFalse(source.tabs.contains(where: { $0.id == movedID }))
        XCTAssertEqual(source.tabs.map(\.id), [remainingID])
        XCTAssertTrue(source.tabGroups.isEmpty)
        XCTAssertEqual(destination.tabs.map(\.id), [movedID])
        XCTAssertTrue(destination.activeSession?.workspace === movedSession.workspace)
        XCTAssertTrue(destination.activeWorkspace?.isDirty == true)
    }

    @MainActor
    func testDroppingStackMemberAtTopLevelEndUngroupsAndDissolvesSingletonStack() throws {
        let workspace = MultiDocumentWorkspaceState()
        let first = try XCTUnwrap(workspace.activeTabID)
        let second = workspace.newTab()
        _ = try XCTUnwrap(
            workspace.createTabGroup(title: "스택", tabIDs: [first, second])
        )

        workspace.moveTabToEnd(first)

        XCTAssertEqual(workspace.tabs.map(\.id), [second, first])
        XCTAssertTrue(workspace.tabGroups.isEmpty)
        XCTAssertEqual(workspace.ungroupedTabs.map(\.id), [second, first])
    }

    @MainActor
    func testCenterDropBetweenUngroupedTabsCreatesOneContiguousStack() throws {
        let workspace = MultiDocumentWorkspaceState()
        let first = try XCTUnwrap(workspace.activeTabID)
        let dragged = workspace.newTab()
        let target = workspace.newTab()
        let trailing = workspace.newTab()

        XCTAssertEqual(
            PDFTabDropIntent.resolve(locationX: 90, width: 180),
            .createOrJoinGroup
        )
        let groupID = try XCTUnwrap(
            workspace.createTabGroup(
                title: PDFTabGroupRules.fallbackTitle,
                tabIDs: [target, dragged]
            )
        )

        XCTAssertEqual(workspace.group(containing: target)?.id, groupID)
        XCTAssertEqual(workspace.group(containing: dragged)?.id, groupID)
        XCTAssertEqual(workspace.tabGroups.first?.tabIDs, [dragged, target])
        XCTAssertEqual(workspace.tabs.map(\.id), [first, dragged, target, trailing])
        XCTAssertEqual(
            workspace.orderedTabBarEntries.map(\.tabIDs),
            [[first], [dragged, target], [trailing]]
        )
    }

    @MainActor
    func testCenterDropOnStackMemberJoinsThatStackAtHoveredPosition() throws {
        let workspace = MultiDocumentWorkspaceState()
        let first = try XCTUnwrap(workspace.activeTabID)
        let target = workspace.newTab()
        let lastMember = workspace.newTab()
        let dragged = workspace.newTab()
        let groupID = try XCTUnwrap(
            workspace.createTabGroup(title: "검토", tabIDs: [target, lastMember])
        )

        XCTAssertTrue(workspace.addTab(dragged, toGroup: groupID, after: target))

        XCTAssertEqual(workspace.group(containing: dragged)?.id, groupID)
        XCTAssertEqual(workspace.tabGroups.first?.tabIDs, [target, dragged, lastMember])
        XCTAssertEqual(workspace.tabs.map(\.id), [first, target, dragged, lastMember])
        XCTAssertEqual(workspace.activeTabID, dragged)
    }

    @MainActor
    func testCenterDropMovesTabsBetweenStacksWithoutDuplicateMembership() throws {
        let workspace = MultiDocumentWorkspaceState()
        let firstSource = try XCTUnwrap(workspace.activeTabID)
        let dragged = workspace.newTab()
        let target = workspace.newTab()
        let lastTarget = workspace.newTab()
        let sourceGroupID = try XCTUnwrap(
            workspace.createTabGroup(title: "원본", tabIDs: [firstSource, dragged])
        )
        let targetGroupID = try XCTUnwrap(
            workspace.createTabGroup(title: "대상", tabIDs: [target, lastTarget])
        )

        XCTAssertTrue(workspace.addTab(dragged, toGroup: targetGroupID, after: target))

        XCTAssertEqual(workspace.group(containing: dragged)?.id, targetGroupID)
        XCTAssertNil(workspace.tabGroups.first(where: { $0.id == sourceGroupID }))
        XCTAssertEqual(
            workspace.tabGroups.first(where: { $0.id == targetGroupID })?.tabIDs,
            [target, dragged, lastTarget]
        )
        XCTAssertEqual(workspace.tabs.map(\.id), [firstSource, target, dragged, lastTarget])
        XCTAssertEqual(
            workspace.tabGroups.flatMap(\.tabIDs).filter { $0 == dragged }.count,
            1
        )

        XCTAssertTrue(workspace.addTab(firstSource, toGroup: targetGroupID, after: dragged))

        XCTAssertNil(workspace.tabGroups.first(where: { $0.id == sourceGroupID }))
        XCTAssertEqual(workspace.tabGroups.count, 1)
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [target, dragged, firstSource, lastTarget])
        XCTAssertEqual(workspace.tabs.map(\.id), [target, dragged, firstSource, lastTarget])
    }

    @MainActor
    func testRenameCollapseMembershipAndWithinGroupReorderingPreserveActiveTab() throws {
        let workspace = MultiDocumentWorkspaceState()
        let first = try XCTUnwrap(workspace.activeTabID)
        let second = workspace.newTab()
        let third = workspace.newTab()
        let fourth = workspace.newTab()
        let groupID = try XCTUnwrap(
            workspace.createTabGroup(title: "초안", tabIDs: [first, second, third])
        )

        XCTAssertTrue(workspace.renameTabGroup(groupID, to: "   "))
        XCTAssertEqual(workspace.tabGroups[0].title, PDFTabGroupRules.fallbackTitle)
        XCTAssertTrue(workspace.setTabGroupCollapsed(groupID, isCollapsed: true))
        XCTAssertTrue(workspace.tabGroups[0].isCollapsed)
        XCTAssertTrue(workspace.toggleTabGroupCollapsed(groupID))
        XCTAssertFalse(workspace.tabGroups[0].isCollapsed)

        XCTAssertTrue(workspace.moveTab(third, withinGroup: groupID, before: first))
        XCTAssertEqual(workspace.tabs.map(\.id), [third, first, second, fourth])
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [third, first, second])

        XCTAssertTrue(workspace.moveTab(third, withinGroup: groupID, after: second))
        XCTAssertEqual(workspace.tabs.map(\.id), [first, second, third, fourth])
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [first, second, third])

        XCTAssertTrue(workspace.addTab(fourth, toGroup: groupID, after: first))
        XCTAssertEqual(workspace.tabs.map(\.id), [first, fourth, second, third])
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [first, fourth, second, third])
        XCTAssertEqual(workspace.activeTabID, fourth)

        XCTAssertTrue(workspace.removeTabFromGroup(fourth))
        XCTAssertEqual(workspace.tabs.map(\.id), [first, second, third, fourth])
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [first, second, third])
        XCTAssertEqual(workspace.activeTabID, fourth)

        XCTAssertTrue(workspace.removeTabFromGroup(first))
        XCTAssertTrue(workspace.removeTabFromGroup(second))
        XCTAssertTrue(workspace.tabGroups.isEmpty)
        XCTAssertNil(workspace.group(containing: third))
        XCTAssertEqual(Set(workspace.tabs.map(\.id)), Set([first, second, third, fourth]))
        XCTAssertEqual(workspace.activeTabID, fourth)
    }

    @MainActor
    func testFlatBeforeAndAfterMovesWorkBothDirectionsAndAcrossGroupBoundary() throws {
        let workspace = MultiDocumentWorkspaceState()
        let first = try XCTUnwrap(workspace.activeTabID)
        let second = workspace.newTab()
        let third = workspace.newTab()

        workspace.moveTab(first, after: second)
        XCTAssertEqual(workspace.tabs.map(\.id), [second, first, third])
        workspace.moveTab(first, before: second)
        XCTAssertEqual(workspace.tabs.map(\.id), [first, second, third])

        let groupID = try XCTUnwrap(
            workspace.createTabGroup(title: "그룹", tabIDs: [second, third])
        )
        workspace.moveTab(first, after: second)
        XCTAssertEqual(workspace.tabs.map(\.id), [second, first, third])
        XCTAssertEqual(workspace.group(containing: first)?.id, groupID)
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [second, first, third])

        XCTAssertTrue(workspace.removeTabFromGroup(first))
        workspace.moveTab(first, before: third)
        XCTAssertEqual(workspace.tabs.map(\.id), [second, first, third])
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [second, first, third])
    }

    @MainActor
    func testStripEdgeMovesStayOutsideTargetGroupAndPreserveContiguousMembers() throws {
        let workspace = MultiDocumentWorkspaceState()
        let first = try XCTUnwrap(workspace.activeTabID)
        let second = workspace.newTab()
        let third = workspace.newTab()
        let fourth = workspace.newTab()
        _ = try XCTUnwrap(
            workspace.createTabGroup(title: "그룹", tabIDs: [second, third])
        )

        workspace.moveTabAsUngrouped(fourth, before: third)
        XCTAssertEqual(workspace.tabs.map(\.id), [first, fourth, second, third])
        XCTAssertNil(workspace.group(containing: fourth))
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [second, third])

        workspace.moveTabAsUngrouped(first, after: second)
        XCTAssertEqual(workspace.tabs.map(\.id), [fourth, second, third, first])
        XCTAssertNil(workspace.group(containing: first))
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [second, third])

        workspace.moveTabAsUngrouped(second, after: third)
        XCTAssertEqual(workspace.tabs.map(\.id), [fourth, third, second, first])
        XCTAssertNil(workspace.group(containing: second))
        XCTAssertNil(workspace.group(containing: third))
        XCTAssertTrue(workspace.tabGroups.isEmpty)
    }

    @MainActor
    func testMovingWholeGroupsSynchronizesFlatAndPresentationOrder() throws {
        let workspace = MultiDocumentWorkspaceState()
        let first = try XCTUnwrap(workspace.activeTabID)
        let second = workspace.newTab()
        let third = workspace.newTab()
        let fourth = workspace.newTab()
        let fifth = workspace.newTab()
        let sixth = workspace.newTab()
        let firstGroup = try XCTUnwrap(
            workspace.createTabGroup(title: "하나", tabIDs: [second, third])
        )
        let secondGroup = try XCTUnwrap(
            workspace.createTabGroup(title: "둘", tabIDs: [fifth, sixth])
        )

        workspace.moveTabGroup(secondGroup, before: firstGroup)
        XCTAssertEqual(workspace.tabs.map(\.id), [first, fifth, sixth, second, third, fourth])
        XCTAssertEqual(workspace.tabGroups.map(\.id), [secondGroup, firstGroup])
        XCTAssertEqual(
            workspace.orderedTabBarEntries.map(\.tabIDs),
            [[first], [fifth, sixth], [second, third], [fourth]]
        )

        workspace.moveTabGroupToEnd(secondGroup)
        XCTAssertEqual(workspace.tabs.map(\.id), [first, second, third, fourth, fifth, sixth])
        XCTAssertEqual(workspace.tabGroups.map(\.id), [firstGroup, secondGroup])
        XCTAssertEqual(workspace.activeTabID, sixth)

        workspace.moveTabGroup(secondGroup, before: .tab(first))
        XCTAssertEqual(workspace.tabs.map(\.id), [fifth, sixth, first, second, third, fourth])

        workspace.moveTabGroup(secondGroup, after: .group(firstGroup))
        XCTAssertEqual(workspace.tabs.map(\.id), [first, second, third, fifth, sixth, fourth])
        XCTAssertEqual(
            workspace.orderedTabBarEntries.map(\.tabIDs),
            [[first], [second, third], [fifth, sixth], [fourth]]
        )
    }

    @MainActor
    func testNewCloseAndDeleteMaintainMembershipAndActiveInvariant() throws {
        let workspace = MultiDocumentWorkspaceState()
        let first = try XCTUnwrap(workspace.activeTabID)
        let second = workspace.newTab()
        let groupID = try XCTUnwrap(
            workspace.createTabGroup(title: "작업", tabIDs: [first, second])
        )
        let ungrouped = workspace.newTab()
        let groupedNewTab = workspace.newTab(inGroup: groupID)

        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [first, second, groupedNewTab])
        XCTAssertEqual(workspace.ungroupedTabs.map(\.id), [ungrouped])
        XCTAssertEqual(workspace.activeTabID, groupedNewTab)

        workspace.selectTab(ungrouped)
        XCTAssertTrue(workspace.closeTab(first))
        XCTAssertEqual(workspace.tabGroups[0].tabIDs, [second, groupedNewTab])
        XCTAssertEqual(workspace.activeTabID, ungrouped)
        XCTAssertTrue(workspace.closeTab(second))
        XCTAssertTrue(workspace.closeTab(groupedNewTab))
        XCTAssertTrue(workspace.tabGroups.isEmpty)
        XCTAssertEqual(workspace.tabs.map(\.id), [ungrouped])
        XCTAssertEqual(workspace.activeTabID, ungrouped)

        let replacementGroup = try XCTUnwrap(
            workspace.createTabGroup(title: "보관", tabIDs: [ungrouped])
        )
        XCTAssertTrue(workspace.deleteTabGroup(replacementGroup))
        XCTAssertTrue(workspace.tabGroups.isEmpty)
        XCTAssertEqual(workspace.tabs.map(\.id), [ungrouped])
        XCTAssertEqual(workspace.activeTabID, ungrouped)
    }

    func testGroupRulesRemoveInvalidDuplicateAndEmptyGroups() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let invalid = UUID()
        let duplicateGroupID = UUID()
        let otherGroupID = UUID()
        let groups = [
            PDFTabGroup(
                id: duplicateGroupID,
                title: "  ",
                tabIDs: [first, first, invalid]
            ),
            PDFTabGroup(
                id: duplicateGroupID,
                title: "중복 그룹",
                tabIDs: [second]
            ),
            PDFTabGroup(
                id: otherGroupID,
                title: "  다른 그룹  ",
                tabIDs: [first, second, third]
            ),
            PDFTabGroup(title: "비어 있음", tabIDs: [invalid])
        ]

        let normalized = PDFTabGroupRules.normalizedGroups(
            groups,
            validTabIDs: [first, second, third]
        )

        XCTAssertEqual(normalized.map(\.id), [duplicateGroupID, otherGroupID])
        XCTAssertEqual(normalized[0].title, PDFTabGroupRules.fallbackTitle)
        XCTAssertEqual(normalized[0].tabIDs, [first])
        XCTAssertEqual(normalized[1].title, "다른 그룹")
        XCTAssertEqual(normalized[1].tabIDs, [second, third])
    }

    private func makePDFFixture(names: [String]) throws -> (directory: URL, urls: [URL]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibePDF-Tab-Tear-Out-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let urls = try names.enumerated().map { index, name in
                let url = directory.appendingPathComponent(name)
                let document = PDFDocument()
                let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
                    NSColor(calibratedWhite: 0.84 + CGFloat(index) * 0.04, alpha: 1).setFill()
                    rect.fill()
                    return true
                }
                let page = try XCTUnwrap(PDFPage(image: image))
                document.insert(page, at: 0)
                guard document.write(to: url) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return url
            }
            return (directory, urls)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

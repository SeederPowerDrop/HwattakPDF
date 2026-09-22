// SPDX-License-Identifier: MPL-2.0

import SwiftUI
import XCTest
@testable import HwattakPDF

final class PageSidebarKeyboardNavigationTests: XCTestCase {
    func testScreenshotPage23MovesToItsVisibleNeighborsInGroupedSidebars() {
        for layout in [PageSidebarLayoutMode.facingPages, .fourPages] {
            for placement in [PageOverviewPlacement.left, .right] {
                XCTAssertEqual(target(layout, from: 22, direction: .right, placement: placement), 23)
                XCTAssertEqual(target(layout, from: 22, direction: .up, placement: placement), 20)
                XCTAssertEqual(target(layout, from: 22, direction: .down, placement: placement), 24)
                XCTAssertEqual(target(layout, from: 22, direction: .left, placement: placement), 21)
                XCTAssertEqual(target(layout, from: 23, direction: .left, placement: placement), 22)
                XCTAssertEqual(target(layout, from: 23, direction: .up, placement: placement), 21)
                XCTAssertEqual(target(layout, from: 23, direction: .down, placement: placement), 25)
            }
        }
    }

    func testGroupedSidebarsContinueHorizontalMovementAcrossRowsAndGroups() {
        for layout in [PageSidebarLayoutMode.facingPages, .fourPages] {
            for placement in [PageOverviewPlacement.left, .right] {
                XCTAssertEqual(target(layout, from: 1, direction: .right, placement: placement), 2)
                XCTAssertEqual(target(layout, from: 2, direction: .left, placement: placement), 1)
                XCTAssertEqual(target(layout, from: 2, direction: .right, placement: placement), 3)
                XCTAssertEqual(target(layout, from: 3, direction: .left, placement: placement), 2)
                XCTAssertEqual(target(layout, from: 3, direction: .right, placement: placement), 4)
                XCTAssertEqual(target(layout, from: 4, direction: .left, placement: placement), 3)
            }
        }
    }

    func testFourPageSidebarMovesVerticallyAcrossGroupBoundariesInTheSameColumn() {
        for placement in [PageOverviewPlacement.left, .right] {
            XCTAssertEqual(target(.fourPages, from: 2, direction: .down, placement: placement), 4)
            XCTAssertEqual(target(.fourPages, from: 3, direction: .down, placement: placement), 5)
            XCTAssertEqual(target(.fourPages, from: 4, direction: .up, placement: placement), 2)
            XCTAssertEqual(target(.fourPages, from: 5, direction: .up, placement: placement), 3)
        }
    }

    func testOddTrailingSlotsFallBackToRealPagesAndStopAtDocumentEnds() {
        for layout in [PageSidebarLayoutMode.facingPages, .fourPages] {
            for placement in [PageOverviewPlacement.left, .right] {
                XCTAssertEqual(target(layout, from: 1, direction: .up, placement: placement, pageCount: 5), 0)
                XCTAssertEqual(target(layout, from: 2, direction: .down, placement: placement, pageCount: 5), 4)
                XCTAssertEqual(target(layout, from: 4, direction: .up, placement: placement, pageCount: 5), 2)
                XCTAssertEqual(target(layout, from: 3, direction: .down, placement: placement, pageCount: 5), 4)
                XCTAssertEqual(target(layout, from: 4, direction: .left, placement: placement, pageCount: 5), 3)
                XCTAssertNil(target(layout, from: 4, direction: .right, placement: placement, pageCount: 5))
                XCTAssertNil(target(layout, from: 4, direction: .down, placement: placement, pageCount: 5))
            }
        }
    }

    func testSinglePageSidebarsUseAllFourArrowsForPreviousAndNextPages() {
        for placement in [PageOverviewPlacement.left, .right] {
            XCTAssertEqual(target(.single, from: 3, direction: .up, placement: placement), 2)
            XCTAssertEqual(target(.single, from: 3, direction: .down, placement: placement), 4)
            XCTAssertEqual(target(.single, from: 3, direction: .left, placement: placement), 2)
            XCTAssertEqual(target(.single, from: 3, direction: .right, placement: placement), 4)
        }
    }

    func testHorizontalPanelsUseVerticalArrowsAsPreviousAndNextInTheirSingleRow() {
        for layout in PageSidebarLayoutMode.allCases {
            for placement in [PageOverviewPlacement.top, .bottom] {
                XCTAssertEqual(target(layout, from: 1, direction: .right, placement: placement), 2)
                XCTAssertEqual(target(layout, from: 3, direction: .right, placement: placement), 4)
                XCTAssertEqual(target(layout, from: 4, direction: .left, placement: placement), 3)
                XCTAssertEqual(target(layout, from: 3, direction: .up, placement: placement), 2)
                XCTAssertEqual(target(layout, from: 3, direction: .down, placement: placement), 4)
                XCTAssertNil(target(layout, from: 0, direction: .left, placement: placement))
                XCTAssertNil(target(layout, from: 4, direction: .right, placement: placement, pageCount: 5))
            }
        }
    }

    func testRightToLeftSidebarsMirrorHorizontalNeighborsAndKeepVerticalNeighbors() {
        for layout in [PageSidebarLayoutMode.facingPages, .fourPages] {
            for placement in [PageOverviewPlacement.left, .right] {
                XCTAssertEqual(target(layout, from: 22, direction: .left, placement: placement, rtl: true), 23)
                XCTAssertEqual(target(layout, from: 23, direction: .right, placement: placement, rtl: true), 22)
                XCTAssertEqual(target(layout, from: 22, direction: .right, placement: placement, rtl: true), 21)
                XCTAssertEqual(target(layout, from: 23, direction: .left, placement: placement, rtl: true), 24)
                XCTAssertEqual(target(layout, from: 22, direction: .up, placement: placement, rtl: true), 20)
                XCTAssertEqual(target(layout, from: 22, direction: .down, placement: placement, rtl: true), 24)
            }
        }
    }

    func testRightToLeftHorizontalPanelsFollowVisibleLeftAndRightAcrossGroups() {
        for layout in PageSidebarLayoutMode.allCases {
            for placement in [PageOverviewPlacement.top, .bottom] {
                XCTAssertEqual(target(layout, from: 3, direction: .left, placement: placement, rtl: true), 4)
                XCTAssertEqual(target(layout, from: 4, direction: .right, placement: placement, rtl: true), 3)
                XCTAssertEqual(target(layout, from: 3, direction: .up, placement: placement, rtl: true), 2)
                XCTAssertEqual(target(layout, from: 3, direction: .down, placement: placement, rtl: true), 4)
                XCTAssertNil(target(layout, from: 0, direction: .right, placement: placement, rtl: true))
                XCTAssertNil(target(layout, from: 4, direction: .left, placement: placement, pageCount: 5, rtl: true))
            }
        }
    }

    func testEveryInteriorPageMovesInAllFourDirectionsAcrossEveryLayoutPlacementAndReadingDirection() throws {
        for pageCount in 3...12 {
            for layout in PageSidebarLayoutMode.allCases {
                for placement in PageOverviewPlacement.allCases {
                    for rtl in [false, true] {
                        for pageIndex in 1..<(pageCount - 1) {
                            for direction in PageSidebarNavigationDirection.allCases {
                                let context = "\(layout.rawValue), \(placement.rawValue), RTL=\(rtl), index=\(pageIndex), count=\(pageCount), \(direction)"
                                let destination = try XCTUnwrap(
                                    target(layout, from: pageIndex, direction: direction,
                                           placement: placement, pageCount: pageCount, rtl: rtl),
                                    context
                                )
                                XCTAssertTrue((0..<pageCount).contains(destination), context)
                                XCTAssertNotEqual(destination, pageIndex, context)
                                switch direction {
                                case .up:
                                    XCTAssertLessThan(destination, pageIndex, context)
                                case .down:
                                    XCTAssertGreaterThan(destination, pageIndex, context)
                                case .left:
                                    XCTAssertEqual(destination, pageIndex + (rtl ? 1 : -1), context)
                                case .right:
                                    XCTAssertEqual(destination, pageIndex + (rtl ? -1 : 1), context)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testOnlyDocumentBoundariesStopNavigationInEveryLayoutPlacementAndReadingDirection() {
        for layout in PageSidebarLayoutMode.allCases {
            for placement in PageOverviewPlacement.allCases {
                for rtl in [false, true] {
                    let backward: PageSidebarNavigationDirection = rtl ? .right : .left
                    let forward: PageSidebarNavigationDirection = rtl ? .left : .right
                    XCTAssertNil(target(layout, from: 0, direction: .up,
                                        placement: placement, pageCount: 5, rtl: rtl))
                    XCTAssertNil(target(layout, from: 0, direction: backward,
                                        placement: placement, pageCount: 5, rtl: rtl))
                    XCTAssertNil(target(layout, from: 4, direction: .down,
                                        placement: placement, pageCount: 5, rtl: rtl))
                    XCTAssertNil(target(layout, from: 4, direction: forward,
                                        placement: placement, pageCount: 5, rtl: rtl))
                }
            }
        }
    }

    func testEmptySinglePageAndInvalidCurrentIndicesHaveNoNeighbor() {
        for layout in PageSidebarLayoutMode.allCases {
            for placement in PageOverviewPlacement.allCases {
                for direction in PageSidebarNavigationDirection.allCases {
                    for (pageIndex, pageCount) in [(-1, 8), (8, 8), (0, -1), (0, 0), (0, 1)] {
                        XCTAssertNil(target(layout, from: pageIndex, direction: direction,
                                            placement: placement, pageCount: pageCount))
                    }
                }
            }
        }
    }

    @MainActor
    func testHandlerNavigatesWithEveryArrowInEveryLayoutAndPlacement() {
        for layout in PageSidebarLayoutMode.allCases {
            withLayout(layout) {
                for placement in PageOverviewPlacement.allCases {
                    let verticalStep = !placement.usesHorizontalPageStrip && layout != .single ? 2 : 1
                    let expectedPages: [(KeyEquivalent, Int)] = [
                        (.leftArrow, 2), (.rightArrow, 4),
                        (.upArrow, 3 - verticalStep), (.downArrow, 3 + verticalStep)
                    ]
                    for (key, expectedPage) in expectedPages {
                        let workspace = makeWorkspace()
                        let sidebar = makeSidebar(workspace: workspace, placement: placement)

                        XCTAssertEqual(sidebar.handlePagingKey(key, modifiers: []), .handled)
                        XCTAssertEqual(workspace.currentPageIndex, expectedPage, placement.rawValue)
                        XCTAssertEqual(workspace.selectedPages, [expectedPage], placement.rawValue)
                        XCTAssertFalse(workspace.isDirty)
                    }
                }
            }
        }
    }

    @MainActor
    func testRightSidebarFourPageLayoutMovesFromPage29WithEveryArrow() {
        withLayout(.fourPages) {
            let neighbors: [(KeyEquivalent, Int)] = [
                (.rightArrow, 30), (.downArrow, 31), (.leftArrow, 28), (.upArrow, 27)
            ]
            for (key, expectedPageNumber) in neighbors {
                let workspace = makeWorkspace(pageCount: 477, currentPageIndex: 28)
                let sidebar = makeSidebar(workspace: workspace, placement: .right)

                XCTAssertEqual(sidebar.handlePagingKey(key, modifiers: []), .handled)
                XCTAssertEqual(workspace.currentPageIndex + 1, expectedPageNumber)
                XCTAssertEqual(workspace.selectedPages, [expectedPageNumber - 1])
            }
        }
    }

    @MainActor
    func testGroupedHandlerUsesScreenshotNeighborsAndReplacesStaleMultiSelection() {
        for layout in [PageSidebarLayoutMode.facingPages, .fourPages] {
            withLayout(layout) {
                for placement in [PageOverviewPlacement.left, .right] {
                    for (key, expectedPage) in [(KeyEquivalent.rightArrow, 23), (.upArrow, 20), (.downArrow, 24), (.leftArrow, 21)] {
                        let workspace = makeWorkspace(pageCount: 477, currentPageIndex: 22)
                        workspace.selectedPages = [0, 1, 22, 30]
                        let sidebar = makeSidebar(workspace: workspace, placement: placement)

                        XCTAssertEqual(sidebar.handlePagingKey(key, modifiers: []), .handled)
                        XCTAssertEqual(workspace.currentPageIndex, expectedPage)
                        XCTAssertEqual(workspace.selectedPages, [expectedPage])
                        XCTAssertFalse(workspace.isDirty)
                    }
                }
            }
        }
    }

    @MainActor
    func testRepeatedGroupedNavigationFollowsSidebarLayoutInEveryWorkspaceMode() {
        withLayout(.fourPages) {
            for mode in PDFWorkspaceMode.allCases {
                for columns in [1, 2, 4] {
                    for placement in [PageOverviewPlacement.left, .bottom] {
                        let workspace = makeWorkspace(pageCount: 12, currentPageIndex: 1)
                        workspace.restoreModeFromSession(mode)
                        workspace.pageColumns = columns
                        workspace.gridLayoutMode = .singleRow
                        let sidebar = makeSidebar(workspace: workspace, placement: placement)
                        let key: KeyEquivalent = placement == .left ? .downArrow : .rightArrow
                        let expectedPages = placement == .left ? [3, 5, 7] : [2, 3, 4]

                        for expectedPage in expectedPages {
                            XCTAssertEqual(sidebar.handlePagingKey(key, modifiers: []), .handled)
                            XCTAssertEqual(workspace.currentPageIndex, expectedPage)
                            XCTAssertEqual(workspace.selectedPages, [expectedPage])
                        }
                        XCTAssertFalse(workspace.isDirty)
                    }
                }
            }
        }
    }

    @MainActor
    func testDocumentEndsConsumeRepeatedArrowsWithoutWrappingOrChangingSelection() {
        for layout in PageSidebarLayoutMode.allCases {
            withLayout(layout) {
                for placement in PageOverviewPlacement.allCases {
                    let workspace = makeWorkspace(pageCount: 5)
                    let sidebar = makeSidebar(workspace: workspace, placement: placement)
                    for (pageIndex, directions) in [
                        (0, [PageSidebarNavigationDirection.up, .left]),
                        (4, [PageSidebarNavigationDirection.down, .right])
                    ] {
                        for direction in directions {
                            workspace.setCurrentPage(pageIndex)
                            workspace.selectedPages = [0, 2, pageIndex]
                            let originalSelection = workspace.selectedPages

                            for _ in 0..<3 {
                                XCTAssertEqual(sidebar.handlePagingKey(key(for: direction), modifiers: []), .handled)
                                XCTAssertEqual(workspace.currentPageIndex, pageIndex)
                                XCTAssertEqual(workspace.selectedPages, originalSelection)
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func testModifiedArrowsAndOtherKeysRemainAvailableToExistingControls() {
        let modifiers: [EventModifiers] = [.command, .control, .option, .shift, [.command, .shift]]
        let otherKeys: [KeyEquivalent] = [.return, .escape, "a"]
        for layout in PageSidebarLayoutMode.allCases {
            withLayout(layout) {
                for placement in PageOverviewPlacement.allCases {
                    let workspace = makeWorkspace()
                    workspace.selectedPages = [1, 3]
                    let sidebar = makeSidebar(workspace: workspace, placement: placement)
                    for modifier in modifiers {
                        for direction in PageSidebarNavigationDirection.allCases {
                            XCTAssertEqual(sidebar.handlePagingKey(key(for: direction), modifiers: modifier), .ignored)
                            XCTAssertEqual(workspace.currentPageIndex, 3)
                            XCTAssertEqual(workspace.selectedPages, [1, 3])
                        }
                    }
                    for key in otherKeys {
                        XCTAssertEqual(sidebar.handlePagingKey(key, modifiers: []), .ignored)
                        XCTAssertEqual(workspace.currentPageIndex, 3)
                        XCTAssertEqual(workspace.selectedPages, [1, 3])
                    }
                }
            }
        }
    }

    @MainActor
    func testEmptyDocumentIgnoresAllArrowsAndSinglePageConsumesThemWithoutMoving() {
        for layout in PageSidebarLayoutMode.allCases {
            withLayout(layout) {
                for pageCount in [0, 1] {
                    for placement in PageOverviewPlacement.allCases {
                        let workspace = makeWorkspace(pageCount: pageCount, currentPageIndex: 0)
                        let sidebar = makeSidebar(workspace: workspace, placement: placement)
                        let expectedResult: KeyPress.Result = pageCount == 0 ? .ignored : .handled
                        let expectedSelection: Set<Int> = pageCount == 0 ? [] : [0]

                        for direction in PageSidebarNavigationDirection.allCases {
                            XCTAssertEqual(sidebar.handlePagingKey(key(for: direction), modifiers: []), expectedResult)
                            XCTAssertEqual(workspace.currentPageIndex, 0)
                            XCTAssertEqual(workspace.selectedPages, expectedSelection)
                        }
                    }
                }
            }
        }
    }

    private func target(
        _ layout: PageSidebarLayoutMode,
        from pageIndex: Int,
        direction: PageSidebarNavigationDirection,
        placement: PageOverviewPlacement = .left,
        pageCount: Int = 477,
        rtl: Bool = false
    ) -> Int? {
        layout.navigationTarget(from: pageIndex, direction: direction, placement: placement,
                                pageCount: pageCount, isRightToLeft: rtl)
    }

    private func key(for direction: PageSidebarNavigationDirection) -> KeyEquivalent {
        switch direction {
        case .up: .upArrow
        case .down: .downArrow
        case .left: .leftArrow
        case .right: .rightArrow
        }
    }

    @MainActor
    private func withLayout(_ layout: PageSidebarLayoutMode, perform body: () -> Void) {
        let key = PageSidebarPreferences.layoutModeKey
        let savedValue = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(layout.rawValue, forKey: key)
        defer {
            if let savedValue {
                UserDefaults.standard.set(savedValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    @MainActor
    private func makeWorkspace(pageCount: Int = 8, currentPageIndex: Int = 3) -> PDFWorkspaceState {
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(
            url: URL(fileURLWithPath: "/tmp/sidebar-keyboard-session-placeholder.pdf"),
            pageCount: pageCount,
            currentPageIndex: currentPageIndex
        )
        return workspace
    }

    @MainActor
    private func makeSidebar(workspace: PDFWorkspaceState, placement: PageOverviewPlacement) -> PageSidebarView {
        PageSidebarView(workspace: workspace, placement: placement, sidebarMode: .constant(.pages))
    }
}

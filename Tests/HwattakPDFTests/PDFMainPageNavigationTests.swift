// SPDX-License-Identifier: MPL-2.0

import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFMainPageNavigationTests: XCTestCase {
    func testSinglePageTurnsVisitEveryPageAndStopAtBothEnds() {
        XCTAssertNil(target(from: 0, count: 5, pagesPerTurn: 1, step: -1))
        for index in 0..<4 {
            XCTAssertEqual(target(from: index, count: 5, pagesPerTurn: 1, step: 1), index + 1)
            XCTAssertEqual(target(from: index + 1, count: 5, pagesPerTurn: 1, step: -1), index)
        }
        XCTAssertNil(target(from: 4, count: 5, pagesPerTurn: 1, step: 1))
    }

    func testTwoPageTurnsMoveToAdjacentSpreadsFromEitherSelectedPage() {
        for selectedPage in [2, 3] {
            XCTAssertEqual(target(from: selectedPage, count: 8, pagesPerTurn: 2, step: -1), 0)
            XCTAssertEqual(target(from: selectedPage, count: 8, pagesPerTurn: 2, step: 1), 4)
        }
        for selectedPage in [0, 1] {
            XCTAssertNil(target(from: selectedPage, count: 8, pagesPerTurn: 2, step: -1))
        }
        for selectedPage in [6, 7] {
            XCTAssertNil(target(from: selectedPage, count: 8, pagesPerTurn: 2, step: 1))
        }
    }

    func testOddLastPageIsReachableAndReturnsToPreviousFullSpread() {
        for selectedPage in [2, 3] {
            XCTAssertEqual(target(from: selectedPage, count: 5, pagesPerTurn: 2, step: 1), 4)
        }
        XCTAssertNil(target(from: 4, count: 5, pagesPerTurn: 2, step: 1))
        XCTAssertEqual(target(from: 4, count: 5, pagesPerTurn: 2, step: -1), 2)
    }

    func testDocumentsWithOnlyOneVisibleGroupCannotTurn() {
        for pagesPerTurn in [1, 2, 4, 12] {
            for pageCount in 1...pagesPerTurn {
                for pageIndex in 0..<pageCount {
                    XCTAssertNil(target(from: pageIndex, count: pageCount, pagesPerTurn: pagesPerTurn, step: -1))
                    XCTAssertNil(target(from: pageIndex, count: pageCount, pagesPerTurn: pagesPerTurn, step: 1))
                }
            }
        }
    }

    func testGridTurnsReachIncompleteLastGroupWithoutInventingBlankPages() {
        for pagesPerTurn in 3...12 {
            let lastPage = pagesPerTurn * 2
            XCTAssertEqual(
                target(from: lastPage - 1, count: lastPage + 1, pagesPerTurn: pagesPerTurn, step: 1),
                lastPage
            )
            XCTAssertNil(target(from: lastPage, count: lastPage + 1, pagesPerTurn: pagesPerTurn, step: 1))
            XCTAssertEqual(
                target(from: lastPage, count: lastPage + 1, pagesPerTurn: pagesPerTurn, step: -1),
                pagesPerTurn
            )
        }
    }

    func testUnavailableOrInvalidCurrentPageNeverProducesNavigation() {
        for step in [-1, 1] {
            XCTAssertNil(target(from: 0, count: 0, pagesPerTurn: 1, step: step))
            XCTAssertNil(target(from: -1, count: 5, pagesPerTurn: 2, step: step))
            XCTAssertNil(target(from: 5, count: 5, pagesPerTurn: 2, step: step))
            XCTAssertNil(target(from: 0, count: -1, pagesPerTurn: 1, step: step))
        }
        XCTAssertNil(target(from: 2, count: 5, pagesPerTurn: 2, step: 0))
    }

    func testLargePageCountDoesNotOverflowAtTheFinalSpread() {
        let lastPage = Int.max - 1
        XCTAssertEqual(target(from: lastPage - 1, count: Int.max, pagesPerTurn: 2, step: 1), lastPage)
        XCTAssertNil(target(from: lastPage, count: Int.max, pagesPerTurn: 2, step: 1))
        XCTAssertEqual(target(from: lastPage, count: Int.max, pagesPerTurn: 2, step: -1), lastPage - 2)
    }

    @MainActor
    func testHorizontalCanvasShowsOnePageOrOneSpreadForEitherTwoPagePreference() {
        for twoPageMode in PDFTwoPageDisplayMode.allCases {
            XCTAssertEqual(displayMode(columns: 1, twoPageMode: twoPageMode, navigation: .horizontalPaging), .singlePage)
            XCTAssertEqual(displayMode(columns: 2, twoPageMode: twoPageMode, navigation: .horizontalPaging), .twoUp)
        }
    }

    @MainActor
    func testVerticalCanvasRetainsContinuousAndExistingFixedSpreadModes() {
        for twoPageMode in PDFTwoPageDisplayMode.allCases {
            XCTAssertEqual(displayMode(columns: 1, twoPageMode: twoPageMode, navigation: .verticalScroll), .singlePageContinuous)
        }
        XCTAssertEqual(displayMode(columns: 2, twoPageMode: .continuous, navigation: .verticalScroll), .twoUpContinuous)
        XCTAssertEqual(displayMode(columns: 2, twoPageMode: .paged, navigation: .verticalScroll), .twoUp)
    }

    @MainActor
    func testComparisonAlwaysRetainsContinuousScrollingRegardlessOfMainPreference() {
        for navigation in PDFPageNavigationMode.allCases {
            for twoPageMode in PDFTwoPageDisplayMode.allCases {
                XCTAssertEqual(
                    displayMode(columns: 1, twoPageMode: twoPageMode, navigation: navigation, context: .comparison),
                    .singlePageContinuous
                )
                XCTAssertEqual(
                    displayMode(columns: 2, twoPageMode: twoPageMode, navigation: navigation, context: .comparison),
                    .twoUpContinuous
                )
            }
        }
    }

    @MainActor
    func testDefensiveGridRequestsDoNotBecomeNativePagedSpreads() {
        for columns in [3, 4, 12] {
            for navigation in PDFPageNavigationMode.allCases {
                for twoPageMode in PDFTwoPageDisplayMode.allCases {
                    XCTAssertEqual(displayMode(columns: columns, twoPageMode: twoPageMode, navigation: navigation), .twoUpContinuous)
                }
            }
        }
    }

    @MainActor
    func testHorizontalViewportKeepsItsPositionWhenTheSameModeIsAppliedAgain() {
        let workspace = hibernatedWorkspace()
        workspace.restorePDFViewport(
            autoScales: false,
            scaleFactor: 2.4,
            horizontalScrollProgress: 0.65,
            verticalScrollProgress: 0.8,
            capturedPageIndex: 3,
            navigationMode: .horizontalPaging
        )

        workspace.preparePDFViewportForNavigationMode(.horizontalPaging)

        XCTAssertEqual(workspace.pdfViewportState.navigationMode, .horizontalPaging)
        XCTAssertEqual(workspace.pdfViewportState.scaleFactor, 2.4)
        XCTAssertEqual(
            workspace.pdfViewportState.scrollProgress(forPageIndex: 3),
            PDFScrollProgress(horizontal: 0.65, vertical: 0.8)
        )
        XCTAssertNil(workspace.pdfViewportState.scrollProgress(forPageIndex: 4))
    }

    @MainActor
    func testChangingNavigationModeInvalidatesOnlyPositionAndKeepsZoomAndComparison() {
        let workspace = hibernatedWorkspace()
        let position = PDFScrollProgress(horizontal: 0.65, vertical: 0.8)
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 2.4, scrollProgress: position)
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.7, scrollProgress: position, context: .comparison)
        let comparisonViewport = workspace.pdfViewportState(for: .comparison)

        for mode in [PDFPageNavigationMode.horizontalPaging, .verticalScroll] {
            workspace.preparePDFViewportForNavigationMode(mode)
            XCTAssertEqual(workspace.pdfViewportState.navigationMode, mode)
            XCTAssertNil(workspace.pdfViewportState.scrollProgress)
            XCTAssertNil(workspace.pdfViewportState.capturedPageIndex)
            XCTAssertEqual(workspace.pdfViewportState.scaleFactor, 2.4)
            XCTAssertFalse(workspace.pdfViewportState.autoScales)
            XCTAssertEqual(workspace.pdfViewportState(for: .comparison), comparisonViewport)
            workspace.recordPDFViewport(autoScales: false, scaleFactor: 2.4, scrollProgress: position)
        }
    }

    @MainActor
    func testComparisonRestorationAlwaysUsesVerticalGeometry() {
        let workspace = hibernatedWorkspace()
        workspace.restorePDFViewport(
            autoScales: false,
            scaleFactor: 1.7,
            horizontalScrollProgress: 0.4,
            verticalScrollProgress: 0.6,
            capturedPageIndex: 3,
            navigationMode: .horizontalPaging,
            context: .comparison
        )

        XCTAssertEqual(workspace.pdfViewportState(for: .comparison).navigationMode, .verticalScroll)
        XCTAssertEqual(
            workspace.pdfViewportState(for: .comparison).scrollProgress(forPageIndex: 3),
            PDFScrollProgress(horizontal: 0.4, vertical: 0.6)
        )
    }

    @MainActor
    private func hibernatedWorkspace() -> PDFWorkspaceState {
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(
            url: URL(fileURLWithPath: "/private/tmp/main-page-navigation-viewport.pdf"),
            pageCount: 8,
            currentPageIndex: 3
        )
        return workspace
    }

    private func target(from index: Int, count: Int, pagesPerTurn: Int, step: Int) -> Int? {
        PDFPageNavigationMode.targetPage(from: index, pageCount: count, pagesPerTurn: pagesPerTurn, step: step)
    }

    @MainActor
    private func displayMode(
        columns: Int,
        twoPageMode: PDFTwoPageDisplayMode,
        navigation: PDFPageNavigationMode,
        context: PDFViewerViewportContext = .normal
    ) -> PDFDisplayMode {
        PDFKitViewer.requestedDisplayMode(
            pageColumns: columns,
            twoPageDisplayMode: twoPageMode,
            viewportContext: context,
            navigationMode: navigation
        )
    }
}

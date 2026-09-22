// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

final class PDFGridLayoutModeTests: XCTestCase {
    func testFourPageButtonEntersBalancedThenTogglesBothLayouts() {
        let firstSelection = PDFGridLayoutMode.singleRow
            .selectionAfterFourPageButton(currentPageCount: 2)
        XCTAssertEqual(firstSelection, PDFGridViewSelection(pageCount: 4, layoutMode: .balanced))

        let secondSelection = firstSelection.layoutMode
            .selectionAfterFourPageButton(currentPageCount: firstSelection.pageCount)
        XCTAssertEqual(secondSelection, PDFGridViewSelection(pageCount: 4, layoutMode: .singleRow))

        let thirdSelection = secondSelection.layoutMode
            .selectionAfterFourPageButton(currentPageCount: secondSelection.pageCount)
        XCTAssertEqual(thirdSelection, PDFGridViewSelection(pageCount: 4, layoutMode: .balanced))
    }

    func testBalancedFourPageLayoutFitsTwoByTwoWithinViewportAtDefaultScale() {
        let viewport = CGSize(width: 1_080, height: 700)
        let aspect: CGFloat = 1.414
        let metrics = PDFGridLayoutMetrics.resolve(
            viewportSize: viewport,
            requestedPageCount: 4,
            layoutMode: .balanced,
            overviewScale: 1,
            maximumPageAspect: aspect
        )

        XCTAssertEqual(metrics.columnCount, 2)
        XCTAssertFalse(metrics.enablesHorizontalScrolling)
        XCTAssertLessThanOrEqual(metrics.contentWidth, viewport.width)

        let tileHeight = metrics.estimatedTileHeight(maximumPageAspect: aspect)
        let fittedHeight = metrics.topPadding
            + tileHeight * 2
            + metrics.verticalSpacing
            + metrics.bottomPadding
        XCTAssertLessThanOrEqual(fittedHeight, viewport.height + 1)
    }

    func testSingleRowFourPageLayoutFitsWidthWithoutHorizontalScrollAtDefaultScale() {
        let viewport = CGSize(width: 1_080, height: 700)
        let aspect: CGFloat = 1.414
        let metrics = PDFGridLayoutMetrics.resolve(
            viewportSize: viewport,
            requestedPageCount: 4,
            layoutMode: .singleRow,
            overviewScale: 1,
            maximumPageAspect: aspect
        )

        XCTAssertEqual(metrics.columnCount, 4)
        XCTAssertFalse(metrics.enablesHorizontalScrolling)
        XCTAssertLessThanOrEqual(metrics.contentWidth, viewport.width)
        XCTAssertLessThanOrEqual(metrics.contentHeight, viewport.height + 1)
        XCTAssertGreaterThan(viewport.width - metrics.contentWidth, -1)
    }

    func testSingleRowOnlyEnablesHorizontalScrollAfterZoomCreatesOverflow() {
        let viewport = CGSize(width: 1_080, height: 700)
        let metrics = PDFGridLayoutMetrics.resolve(
            viewportSize: viewport,
            requestedPageCount: 4,
            layoutMode: .singleRow,
            overviewScale: 1.2,
            maximumPageAspect: 1.414
        )

        XCTAssertTrue(metrics.enablesHorizontalScrolling)
        XCTAssertGreaterThan(metrics.contentWidth, viewport.width)
    }

    func testWidthFitFillsWideViewportEvenWhenPagesNeedVerticalScrolling() {
        let viewport = CGSize(width: 1_600, height: 500)
        let metrics = PDFGridLayoutMetrics.resolve(
            viewportSize: viewport,
            requestedPageCount: 4,
            layoutMode: .balanced,
            overviewScale: 0.7,
            maximumPageAspect: 1.414,
            fitMode: .width
        )

        XCTAssertEqual(metrics.contentWidth, viewport.width, accuracy: 1)
        XCTAssertGreaterThan(metrics.contentHeight, viewport.height)
        XCTAssertGreaterThan(metrics.effectiveOverviewScale, 1.6)
        XCTAssertFalse(metrics.enablesHorizontalScrolling)
        XCTAssertFalse(metrics.fitsWithinViewport(viewport))
    }

    func testHeightFitFillsTallViewportAndAllowsHorizontalPan() {
        let viewport = CGSize(width: 600, height: 1_000)
        let metrics = PDFGridLayoutMetrics.resolve(
            viewportSize: viewport,
            requestedPageCount: 4,
            layoutMode: .singleRow,
            overviewScale: 1.6,
            maximumPageAspect: 1.414,
            fitMode: .height
        )

        XCTAssertEqual(metrics.contentHeight, viewport.height, accuracy: 1)
        XCTAssertGreaterThan(metrics.contentWidth, viewport.width)
        XCTAssertGreaterThan(metrics.effectiveOverviewScale, 1.6)
        XCTAssertTrue(metrics.enablesHorizontalScrolling)
        XCTAssertFalse(metrics.fitsWithinViewport(viewport))
    }

    func testBalancedHeightFitIncludesBothRowsAndTheirLabels() {
        let viewport = CGSize(width: 1_400, height: 850)
        let metrics = PDFGridLayoutMetrics.resolve(
            viewportSize: viewport,
            requestedPageCount: 4,
            layoutMode: .balanced,
            overviewScale: 0.7,
            maximumPageAspect: 1.5,
            fitMode: .height
        )

        XCTAssertEqual(metrics.contentHeight, viewport.height, accuracy: 1.5)
        XCTAssertLessThan(metrics.contentWidth, viewport.width)
        XCTAssertFalse(metrics.enablesHorizontalScrolling)
        XCTAssertTrue(metrics.fitsWithinViewport(viewport))
    }

    func testAxisFitResizesAndSupportsEveryCustomColumnCount() {
        for count in 3...12 where count != 4 {
            for size in [CGSize(width: 800, height: 600), CGSize(width: 1_600, height: 900)] {
                let width = PDFGridLayoutMetrics.resolve(
                    viewportSize: size,
                    requestedPageCount: count,
                    layoutMode: .balanced,
                    overviewScale: 1,
                    maximumPageAspect: 0.7,
                    fitMode: .width
                )
                let height = PDFGridLayoutMetrics.resolve(
                    viewportSize: size,
                    requestedPageCount: count,
                    layoutMode: .balanced,
                    overviewScale: 1,
                    maximumPageAspect: 0.7,
                    fitMode: .height
                )

                XCTAssertEqual(width.columnCount, count)
                XCTAssertEqual(width.contentWidth, size.width, accuracy: CGFloat(count) * 0.5)
                XCTAssertEqual(height.contentHeight, size.height, accuracy: 1)
                XCTAssertTrue(height.enablesHorizontalScrolling)
            }
        }
    }

    func testBalancedNavigationKeepsEverySelectedPageInItsFourPageGroup() {
        XCTAssertEqual(
            PDFGridLayoutMode.balanced.navigationTarget(for: 4, requestedPageCount: 4),
            4
        )
        XCTAssertEqual(
            PDFGridLayoutMode.balanced.navigationTarget(for: 6, requestedPageCount: 4),
            4
        )
        XCTAssertEqual(
            PDFGridLayoutMode.balanced.navigationTarget(for: 7, requestedPageCount: 4),
            4
        )
        XCTAssertEqual(
            PDFGridLayoutMode.singleRow.navigationTarget(for: 7, requestedPageCount: 4),
            4
        )
    }

    func testVisiblePageTiePrefersCurrentPageThenLowestIndex() {
        let equalAreas: [Int: CGFloat] = [4: 10_000, 5: 10_000, 6: 10_000, 7: 10_000]

        XCTAssertEqual(
            PDFGridVisibilityResolver.mostVisiblePage(
                from: equalAreas,
                currentPageIndex: 6
            ),
            6
        )
        XCTAssertEqual(
            PDFGridVisibilityResolver.mostVisiblePage(
                from: equalAreas,
                currentPageIndex: 20
            ),
            4
        )
        XCTAssertEqual(
            PDFGridVisibilityResolver.mostVisiblePage(
                from: [4: 10_000, 6: 10_100],
                currentPageIndex: 4
            ),
            6
        )
    }

    func testPageGroupsExposeExactlyFourSlotsAndMoveByFour() {
        let middle = PDFGridPageGroup(containing: 6, documentPageCount: 10)
        XCTAssertEqual(middle.startIndex, 4)
        XCTAssertEqual(middle.pageSlots, [4, 5, 6, 7])
        XCTAssertEqual(middle.previousStartIndex, 0)
        XCTAssertEqual(middle.nextStartIndex, 8)

        let last = PDFGridPageGroup(startIndex: 8, documentPageCount: 10)
        XCTAssertEqual(last.pageSlots, [8, 9, nil, nil])
        XCTAssertEqual(last.previousStartIndex, 4)
        XCTAssertNil(last.nextStartIndex)
    }

    func testPagingAccumulatorRequiresDominantAxisAndTriggersOncePerGesture() {
        var accumulator = PDFGridPagingAccumulator()

        XCTAssertNil(accumulator.consume(primaryDelta: -20, crossAxisDelta: -30))
        XCTAssertNil(accumulator.consume(primaryDelta: -24, crossAxisDelta: -2))
        XCTAssertEqual(accumulator.consume(primaryDelta: -25, crossAxisDelta: 0), 1)
        XCTAssertNil(accumulator.consume(primaryDelta: -100, crossAxisDelta: 0))

        accumulator.reset()
        XCTAssertEqual(accumulator.consume(primaryDelta: 50, crossAxisDelta: 1), -1)
    }

    func testPagingSessionKeepsOneTurnLatchedAcrossMomentumThenResets() {
        var session = PDFGridPagingGestureSession()
        session.beginTouchGesture()
        XCTAssertEqual(session.consume(primaryDelta: -50, crossAxisDelta: 1), 1)
        session.endTouchGesture()
        session.beginMomentum()
        XCTAssertNil(session.consume(primaryDelta: -100, crossAxisDelta: 0))

        session.endMomentum()
        session.beginTouchGesture()
        XCTAssertEqual(session.consume(primaryDelta: -50, crossAxisDelta: 0), 1)

        session.endTouchGesture()
        session.finishWaitingForMomentum()
        session.beginTouchGesture()
        XCTAssertEqual(session.consume(primaryDelta: 50, crossAxisDelta: 0), -1)
    }

    func testMagnificationAccumulatesAppKitChangesAgainstOneBaseline() {
        var magnification = PDFGridMagnificationAccumulator()
        XCTAssertEqual(magnification.consume(change: 0.2), 1.2, accuracy: 0.0001)
        XCTAssertEqual(magnification.consume(change: 0.1), 1.3, accuracy: 0.0001)
        XCTAssertEqual(magnification.consume(change: -2), 0.5, accuracy: 0.0001)

        magnification.reset()
        XCTAssertEqual(magnification.relativeFactor, 1, accuracy: 0.0001)
    }

    func testFourPageScrollTargetsWholeGroupWhileCustomOverviewTargetsCard() {
        XCTAssertEqual(
            PDFGridOverviewScrollTarget.resolve(
                pageIndex: 7,
                requestedPageCount: 4,
                documentPageCount: 259
            ),
            .pageGroup(4)
        )
        XCTAssertEqual(
            PDFGridOverviewScrollTarget.resolve(
                pageIndex: 258,
                requestedPageCount: 4,
                documentPageCount: 259
            ),
            .pageGroup(256)
        )
        XCTAssertEqual(
            PDFGridOverviewScrollTarget.resolve(
                pageIndex: 7,
                requestedPageCount: 6,
                documentPageCount: 259
            ),
            .page(7)
        )

        XCTAssertFalse(
            PDFGridOverviewScrollTarget.requiresNavigation(
                from: 4,
                to: 7,
                requestedPageCount: 4,
                documentPageCount: 259
            )
        )
        XCTAssertTrue(
            PDFGridOverviewScrollTarget.requiresNavigation(
                from: 7,
                to: 8,
                requestedPageCount: 4,
                documentPageCount: 259
            )
        )
        XCTAssertTrue(
            PDFGridOverviewScrollTarget.requiresNavigation(
                from: 4,
                to: 7,
                requestedPageCount: 6,
                documentPageCount: 259
            )
        )
    }

    func testFourPagePreviewAndCommittedZoomKeepCenteredGroupAnchor() {
        XCTAssertEqual(
            PDFGridOverviewScrollAnchorPolicy.resolve(
                requestedPageCount: 4,
                enablesHorizontalScrolling: false
            ),
            .center
        )
        XCTAssertEqual(
            PDFGridOverviewScrollAnchorPolicy.resolve(
                requestedPageCount: 4,
                enablesHorizontalScrolling: true
            ),
            .center
        )
        XCTAssertEqual(
            PDFGridOverviewScrollAnchorPolicy.resolve(
                requestedPageCount: 6,
                enablesHorizontalScrolling: true
            ),
            .leadingCenter
        )
    }
}

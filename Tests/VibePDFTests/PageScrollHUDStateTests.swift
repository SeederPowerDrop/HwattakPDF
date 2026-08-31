// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VibePDF

final class PageScrollHUDStateTests: XCTestCase {
    func testMetricsClampInvalidInputsAndDeriveThumbCenter() {
        let metrics = PDFVerticalScrollMetrics(
            progress: 2,
            visibleFraction: 0.2
        )

        XCTAssertEqual(metrics.progress, 1)
        XCTAssertEqual(metrics.visibleFraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(metrics.thumbCenterProgress, 0.9, accuracy: 0.0001)

        let invalid = PDFVerticalScrollMetrics(
            progress: .infinity,
            visibleFraction: -.infinity,
            thumbCenterProgress: .nan
        )
        XCTAssertEqual(invalid.progress, 0)
        XCTAssertEqual(invalid.visibleFraction, 0)
        XCTAssertEqual(invalid.thumbCenterProgress, 0)
    }

    func testPhysicalMetricsUseTopToBottomProgressForFlippedDocument() {
        let metrics = PDFVerticalScrollMetrics.physical(
            documentFrame: CGRect(x: 0, y: 0, width: 600, height: 1_000),
            visibleRect: CGRect(x: 0, y: 400, width: 600, height: 200),
            isDocumentFlipped: true
        )

        XCTAssertEqual(metrics.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(metrics.visibleFraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(metrics.thumbCenterProgress, 0.5, accuracy: 0.0001)
    }

    func testPhysicalMetricsUseTopToBottomProgressForUnflippedDocument() {
        let top = PDFVerticalScrollMetrics.physical(
            documentFrame: CGRect(x: 0, y: 0, width: 600, height: 1_000),
            visibleRect: CGRect(x: 0, y: 800, width: 600, height: 200),
            isDocumentFlipped: false
        )
        let bottom = PDFVerticalScrollMetrics.physical(
            documentFrame: CGRect(x: 0, y: 0, width: 600, height: 1_000),
            visibleRect: CGRect(x: 0, y: 0, width: 600, height: 200),
            isDocumentFlipped: false
        )

        XCTAssertEqual(top.progress, 0)
        XCTAssertEqual(top.thumbCenterProgress, 0.1, accuracy: 0.0001)
        XCTAssertEqual(bottom.progress, 1)
        XCTAssertEqual(bottom.thumbCenterProgress, 0.9, accuracy: 0.0001)
    }

    func testSemanticFourPageMetricsReachLastPartialGroup() {
        let middle = PDFVerticalScrollMetrics.semantic(
            pageIndex: 128,
            pageCount: 259,
            visiblePageCount: 4,
            pageStride: 4
        )
        let last = PDFVerticalScrollMetrics.semantic(
            pageIndex: 258,
            pageCount: 259,
            visiblePageCount: 4,
            pageStride: 4
        )

        XCTAssertEqual(middle.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(last.progress, 1)
        XCTAssertEqual(last.visibleFraction, 4.0 / 259.0, accuracy: 0.0001)
    }

    func testSemanticTwoPageMetricsMoveBySpread() {
        let first = PDFVerticalScrollMetrics.semantic(
            pageIndex: 1,
            pageCount: 5,
            visiblePageCount: 2,
            pageStride: 2
        )
        let middle = PDFVerticalScrollMetrics.semantic(
            pageIndex: 3,
            pageCount: 5,
            visiblePageCount: 2,
            pageStride: 2
        )
        let last = PDFVerticalScrollMetrics.semantic(
            pageIndex: 4,
            pageCount: 5,
            visiblePageCount: 2,
            pageStride: 2
        )

        XCTAssertEqual(first.progress, 0)
        XCTAssertEqual(middle.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(last.progress, 1)
        XCTAssertEqual(last.visibleFraction, 0.4, accuracy: 0.0001)
    }

    func testEachScrollRestartsExactDismissalDeadline() {
        var state = PageScrollHUDState()
        let metrics = PDFVerticalScrollMetrics(progress: 0.25, visibleFraction: 0.1)

        state.recordScroll(metrics: metrics, at: 10)
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.dismissalDeadline, 11.75)
        XCTAssertFalse(state.hideIfExpired(at: 11.749_999))

        state.recordScroll(metrics: metrics, at: 11)
        XCTAssertEqual(state.dismissalDeadline, 12.75)
        XCTAssertFalse(state.hideIfExpired(at: 11.75))
        XCTAssertTrue(state.hideIfExpired(at: 12.75))
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.dismissalDeadline)
    }

    func testHUDCenterTracksThumbWithinSafeRail() {
        let top = PageScrollHUDLayout.centerY(
            containerHeight: 500,
            metrics: PDFVerticalScrollMetrics(
                progress: 0,
                visibleFraction: 0.2
            )
        )
        let bottom = PageScrollHUDLayout.centerY(
            containerHeight: 500,
            metrics: PDFVerticalScrollMetrics(
                progress: 1,
                visibleFraction: 0.2
            )
        )

        // The 32-point HUD remains inside a 12-point safe inset.
        XCTAssertEqual(top, 50, accuracy: 0.0001)
        XCTAssertEqual(bottom, 450, accuracy: 0.0001)
    }

    @MainActor
    func testHUDControllerAcceptsTheSameActivityCallbackAfterReset() {
        let controller = PageScrollHUDController()
        let handler: (PDFVerticalScrollMetrics) -> Void = { metrics in
            controller.recordScroll(metrics)
        }

        handler(PDFVerticalScrollMetrics(progress: 0.2, visibleFraction: 0.1))
        XCTAssertTrue(controller.state.isVisible)
        XCTAssertEqual(controller.state.metrics.progress, 0.2, accuracy: 0.0001)

        controller.reset()
        XCTAssertFalse(controller.state.isVisible)

        handler(PDFVerticalScrollMetrics(progress: 0.8, visibleFraction: 0.1))
        XCTAssertTrue(controller.state.isVisible)
        XCTAssertEqual(controller.state.metrics.progress, 0.8, accuracy: 0.0001)
        controller.reset()
    }
}

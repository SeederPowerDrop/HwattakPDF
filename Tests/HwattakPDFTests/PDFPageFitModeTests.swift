// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

final class PDFPageFitModeTests: XCTestCase {
    func testWidthFillsAvailableWidthEvenWhenPageExtendsBelowViewport() throws {
        let scale = try XCTUnwrap(PDFPageFitMode.width.scaleFactor(
            viewportSize: CGSize(width: 1040, height: 600),
            pageSizes: [CGSize(width: 500, height: 800)], horizontalInsets: 20
        ))
        XCTAssertEqual(scale, 2)
        XCTAssertGreaterThan(scale * 800, 600)
    }

    func testHeightFillsViewportForLandscapeAndPortraitPages() throws {
        for width: CGFloat in [400, 1600] {
            let scale = try XCTUnwrap(PDFPageFitMode.height.scaleFactor(
                viewportSize: CGSize(width: 900, height: 615),
                pageSizes: [CGSize(width: width, height: 800)], verticalInsets: 20
            ))
            XCTAssertEqual(scale, 0.75)
        }
    }

    func testSpreadUsesBothWidthsAndTallestHeight() throws {
        let pages = [CGSize(width: 300, height: 800), CGSize(width: 500, height: 600)]
        XCTAssertEqual(try XCTUnwrap(PDFPageFitMode.width.scaleFactor(
            viewportSize: CGSize(width: 830, height: 615), pageSizes: pages,
            horizontalInsets: 20, pageSpacing: 10
        )), 1)
        XCTAssertEqual(try XCTUnwrap(PDFPageFitMode.height.scaleFactor(
            viewportSize: CGSize(width: 830, height: 615), pageSizes: pages,
            verticalInsets: 20
        )), 0.75)
    }

    func testResizeRecomputesSelectedAxis() throws {
        let page = [CGSize(width: 600, height: 800)]
        XCTAssertEqual(try XCTUnwrap(PDFPageFitMode.width.scaleFactor(
            viewportSize: CGSize(width: 1200, height: 600), pageSizes: page
        )), 2)
        XCTAssertEqual(try XCTUnwrap(PDFPageFitMode.width.scaleFactor(
            viewportSize: CGSize(width: 900, height: 900), pageSizes: page
        )), 1.5)
        XCTAssertEqual(try XCTUnwrap(PDFPageFitMode.height.scaleFactor(
            viewportSize: CGSize(width: 900, height: 1000), pageSizes: page
        )), 1.25)
    }

    func testInvalidGeometryWaitsForLayout() {
        for mode in PDFPageFitMode.allCases {
            XCTAssertNil(mode.scaleFactor(viewportSize: .zero, pageSizes: [CGSize(width: 500, height: 800)]))
            XCTAssertNil(mode.scaleFactor(viewportSize: CGSize(width: 800, height: 600), pageSizes: []))
            XCTAssertNil(mode.scaleFactor(viewportSize: CGSize(width: 800, height: 600), pageSizes: [.zero]))
            XCTAssertNil(mode.scaleFactor(viewportSize: CGSize(width: CGFloat.infinity, height: 600), pageSizes: [CGSize(width: 500, height: 800)]))
        }
    }

    @MainActor
    func testManualZoomExitsFitWithoutResettingScaleOrLayout() {
        let workspace = PDFWorkspaceState()
        workspace.pageColumns = 2
        workspace.selectPageFitMode(.width)
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.8, scrollProgress: nil)
        workspace.endPageFitForManualZoom()
        XCTAssertNil(workspace.pageFitMode)
        XCTAssertEqual(workspace.pageColumns, 2)
        XCTAssertEqual(workspace.pdfViewportState.scaleFactor, 1.8)
        XCTAssertFalse(workspace.pdfViewportState.autoScales)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testTurningFitOffRestoresAutomaticFitAndClearsOldPan() {
        let workspace = PDFWorkspaceState()
        workspace.selectPageFitMode(.height)
        workspace.recordPDFViewport(autoScales: false, scaleFactor: 1.2,
                                    scrollProgress: PDFScrollProgress(horizontal: 0.5, vertical: 0.8))
        workspace.selectPageFitMode(nil)
        XCTAssertNil(workspace.pageFitMode)
        XCTAssertTrue(workspace.pdfViewportState.autoScales)
        XCTAssertNil(workspace.pdfViewportState.scrollProgress)
    }
}

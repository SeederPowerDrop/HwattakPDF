// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

final class PDFPageDisplayRangeTests: XCTestCase {
    func testFourPageRangeStartsAtCurrentGroupBoundary() {
        let range = PDFPageDisplayRange.resolve(
            pageIndex: 14,
            pageCount: 259,
            groupSize: 4
        )

        XCTAssertEqual(range.firstPageNumber, 13)
        XCTAssertEqual(range.lastPageNumber, 16)
        XCTAssertEqual(range.compactDescription, "13–16 / 259")
    }

    func testFinalFourPageRangeStopsAtDocumentEnd() {
        let range = PDFPageDisplayRange.resolve(
            pageIndex: 258,
            pageCount: 259,
            groupSize: 4
        )

        XCTAssertEqual(range.firstPageNumber, 257)
        XCTAssertEqual(range.lastPageNumber, 259)
        XCTAssertEqual(range.compactDescription, "257–259 / 259")
    }

    func testPagedTwoPageRangeUsesExactSpreadsAndHandlesOddFinalPage() {
        XCTAssertEqual(
            PDFPageDisplayRange.resolve(pageIndex: 1, pageCount: 5, groupSize: 2),
            PDFPageDisplayRange(firstPageNumber: 1, lastPageNumber: 2, totalPageCount: 5)
        )
        XCTAssertEqual(
            PDFPageDisplayRange.resolve(pageIndex: 3, pageCount: 5, groupSize: 2),
            PDFPageDisplayRange(firstPageNumber: 3, lastPageNumber: 4, totalPageCount: 5)
        )
        XCTAssertEqual(
            PDFPageDisplayRange.resolve(pageIndex: 4, pageCount: 5, groupSize: 2),
            PDFPageDisplayRange(firstPageNumber: 5, lastPageNumber: 5, totalPageCount: 5)
        )
    }

    func testSinglePageDisplayPreservesExistingFormatForOtherViewCounts() {
        let range = PDFPageDisplayRange.resolve(
            pageIndex: 14,
            pageCount: 259,
            groupSize: 1
        )

        XCTAssertEqual(range.firstPageNumber, 15)
        XCTAssertEqual(range.lastPageNumber, 15)
        XCTAssertEqual(range.compactDescription, "15 / 259")
    }

    func testRangeClampsOutOfBoundsPageIndex() {
        XCTAssertEqual(
            PDFPageDisplayRange.resolve(pageIndex: 500, pageCount: 9, groupSize: 4),
            PDFPageDisplayRange(firstPageNumber: 9, lastPageNumber: 9, totalPageCount: 9)
        )
    }
}

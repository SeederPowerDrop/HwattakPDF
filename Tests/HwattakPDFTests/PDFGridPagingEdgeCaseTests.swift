// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

final class PDFGridPagingEdgeCaseTests: XCTestCase {
    func testGroupsNormalizeEveryDocumentBoundaryToFourPageStarts() {
        let expectations: [(pageCount: Int, pageIndex: Int, start: Int, slots: [Int?])] = [
            (1, 0, 0, [0, nil, nil, nil]),
            (3, 2, 0, [0, 1, 2, nil]),
            (4, 3, 0, [0, 1, 2, 3]),
            (5, 4, 4, [4, nil, nil, nil]),
            (7, 6, 4, [4, 5, 6, nil]),
            (8, 7, 4, [4, 5, 6, 7]),
            (259, 258, 256, [256, 257, 258, nil])
        ]

        for expectation in expectations {
            let group = PDFGridPageGroup(
                containing: expectation.pageIndex,
                documentPageCount: expectation.pageCount
            )
            XCTAssertEqual(group.startIndex, expectation.start)
            XCTAssertEqual(group.pageSlots, expectation.slots)
        }
    }

    func testGroupNavigationMovesExactlyFourAndStopsAtDocumentEdges() {
        let first = PDFGridPageGroup(startIndex: 0, documentPageCount: 259)
        XCTAssertNil(first.previousStartIndex)
        XCTAssertEqual(first.nextStartIndex, 4)

        let middle = PDFGridPageGroup(startIndex: 132, documentPageCount: 259)
        XCTAssertEqual(middle.previousStartIndex, 128)
        XCTAssertEqual(middle.nextStartIndex, 136)

        let last = PDFGridPageGroup(startIndex: 258, documentPageCount: 259)
        XCTAssertEqual(last.startIndex, 256)
        XCTAssertEqual(last.previousStartIndex, 252)
        XCTAssertNil(last.nextStartIndex)
    }

    func testBothFourPageArrangementsUseTheSameGroupStart() {
        for mode in PDFGridLayoutMode.allCases {
            XCTAssertEqual(mode.navigationTarget(for: 0, requestedPageCount: 4), 0)
            XCTAssertEqual(mode.navigationTarget(for: 3, requestedPageCount: 4), 0)
            XCTAssertEqual(mode.navigationTarget(for: 4, requestedPageCount: 4), 4)
            XCTAssertEqual(mode.navigationTarget(for: 7, requestedPageCount: 4), 4)
        }
    }

    func testMomentumSharesTheSameOnePageLatchAsItsTouchGesture() {
        var session = PDFGridPagingGestureSession()
        session.beginTouchGesture()
        XCTAssertEqual(
            session.consume(primaryDelta: -60, crossAxisDelta: 0),
            1
        )

        session.endTouchGesture()
        session.beginMomentum()
        XCTAssertNil(session.consume(primaryDelta: -200, crossAxisDelta: 0))

        session.endMomentum()
        session.beginTouchGesture()
        XCTAssertEqual(
            session.consume(primaryDelta: 60, crossAxisDelta: 0),
            -1
        )
    }
}

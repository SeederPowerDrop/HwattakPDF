// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class PDFPageJumpRequestTests: XCTestCase {
    func testValidOneBasedInputResolvesToZeroBasedIndex() {
        XCTAssertEqual(
            PDFPageJumpRequest.resolve("1", pageCount: 20),
            .destination(pageIndex: 0, pageNumber: 1)
        )
        XCTAssertEqual(
            PDFPageJumpRequest.resolve(" 015 ", pageCount: 20),
            .destination(pageIndex: 14, pageNumber: 15)
        )
        XCTAssertEqual(
            PDFPageJumpRequest.resolve("20", pageCount: 20),
            .destination(pageIndex: 19, pageNumber: 20)
        )
    }

    func testUnicodeDecimalDigitsResolveWithoutLocaleDependentParsing() {
        XCTAssertEqual(
            PDFPageJumpRequest.resolve(" ١٥ ", pageCount: 20),
            .destination(pageIndex: 14, pageNumber: 15)
        )
        XCTAssertEqual(
            PDFPageJumpRequest.resolve("۱۵", pageCount: 20),
            .destination(pageIndex: 14, pageNumber: 15)
        )
        XCTAssertEqual(
            PDFPageJumpRequest.resolve("０９", pageCount: 20),
            .destination(pageIndex: 8, pageNumber: 9)
        )
    }

    func testEmptyMalformedAndOutOfRangeInputsDoNotNavigate() {
        for input in ["", "   ", "page 3", "1.5", "0", "-1", "21"] {
            XCTAssertEqual(
                PDFPageJumpRequest.resolve(input, pageCount: 20),
                .invalid,
                "Unexpected resolution for \(input.debugDescription)"
            )
        }
        XCTAssertEqual(
            PDFPageJumpRequest.resolve(String(repeating: "9", count: 100), pageCount: 20),
            .invalid
        )
        for input in ["+١٥", "١ ٥", "١٫٥", "①⑤", "ⅩⅤ"] {
            XCTAssertEqual(
                PDFPageJumpRequest.resolve(input, pageCount: 20),
                .invalid,
                "Unicode non-Nd input must be rejected: \(input)"
            )
        }
        XCTAssertEqual(
            PDFPageJumpRequest.resolve(String(repeating: "٩", count: 100), pageCount: 20),
            .invalid
        )
        XCTAssertEqual(
            PDFPageJumpRequest.resolve("\(Int.max)0", pageCount: Int.max),
            .invalid
        )
        XCTAssertEqual(
            PDFPageJumpRequest.resolve("٩٢٢٣٣٧٢٠٣٦٨٥٤٧٧٥٨٠٧٠", pageCount: Int.max),
            .invalid
        )
    }

    func testEmptyDocumentIsUnavailable() {
        XCTAssertEqual(PDFPageJumpRequest.resolve("1", pageCount: 0), .unavailable)
        XCTAssertEqual(PDFPageJumpRequest.resolve("invalid", pageCount: -2), .unavailable)
    }

    @MainActor
    func testStrictFourPageNavigationKeepsExactRequestedPageAsWorkspaceCurrent() {
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(
            url: URL(fileURLWithPath: "/tmp/page-jump-session-placeholder.pdf"),
            pageCount: 20,
            currentPageIndex: 0
        )

        guard case let .destination(pageIndex, _) = PDFPageJumpRequest.resolve(
            "15",
            pageCount: workspace.pageCount
        ) else {
            return XCTFail("Expected a valid destination")
        }
        workspace.setCurrentPage(pageIndex)

        XCTAssertEqual(workspace.currentPageIndex, 14)
        XCTAssertEqual(
            PDFGridOverviewScrollTarget.resolve(
                pageIndex: workspace.currentPageIndex,
                requestedPageCount: 4,
                documentPageCount: workspace.pageCount
            ),
            .pageGroup(12)
        )
        XCTAssertEqual(workspace.currentPageIndex, 14)
    }
}

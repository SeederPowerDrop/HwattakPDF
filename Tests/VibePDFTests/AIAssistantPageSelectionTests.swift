// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VibePDF

final class AIAssistantPageSelectionTests: XCTestCase {
    func testMaximumCountMatchesPDFContextPageBudget() {
        XCTAssertEqual(
            AIPageSelectionSpecification.maximumCount,
            PDFAIContextBudget.standard.maximumPages
        )
        XCTAssertEqual(AIPageSelectionSpecification.maximumCount, 24)
    }

    func testSanitizedSortsDeduplicatesAndDropsOnlyOutOfBoundsIndices() {
        XCTAssertEqual(
            AIPageSelectionSpecification.sanitized(
                [4, -1, 2, 4, 0, 8, 2],
                pageCount: 5
            ),
            [0, 2, 4]
        )
        XCTAssertEqual(
            AIPageSelectionSpecification.sanitized([0, 1], pageCount: 0),
            []
        )
        XCTAssertEqual(
            AIPageSelectionSpecification.sanitized([0, 1], pageCount: -10),
            []
        )

        let moreThanRequestLimit = Array(0...AIPageSelectionSpecification.maximumCount)
        XCTAssertEqual(
            AIPageSelectionSpecification.sanitized(
                moreThanRequestLimit,
                pageCount: moreThanRequestLimit.count
            ),
            moreThanRequestLimit,
            "Sanitizing stored state must not silently discard valid pages."
        )
    }

    func testParseAcceptsCommaNewlineWhitespaceAndDuplicatePages() throws {
        XCTAssertEqual(
            try AIPageSelectionSpecification.parse(
                " 1, 3\n5, 3 ",
                pageCount: 8
            ),
            Set([0, 2, 4])
        )
        XCTAssertEqual(
            try AIPageSelectionSpecification.parse(
                "1\r\n2\r3",
                pageCount: 3
            ),
            Set([0, 1, 2])
        )
    }

    func testParseAcceptsEverySupportedInclusiveRangeSeparator() throws {
        let input = "1-2, 4–5, 7—8, 10~11"
        XCTAssertEqual(
            try AIPageSelectionSpecification.parse(input, pageCount: 12),
            Set([0, 1, 3, 4, 6, 7, 9, 10])
        )
        XCTAssertEqual(
            try AIPageSelectionSpecification.parse(" 2 - 4 ", pageCount: 5),
            Set([1, 2, 3])
        )
        XCTAssertEqual(
            try AIPageSelectionSpecification.parse("3–3", pageCount: 5),
            Set([2])
        )
    }

    func testParseCountsUniquePagesAgainstMaximum() throws {
        let maximum = AIPageSelectionSpecification.maximumCount
        XCTAssertEqual(
            try AIPageSelectionSpecification.parse("1-\(maximum)", pageCount: maximum + 10),
            Set(0..<maximum)
        )
        XCTAssertEqual(
            try AIPageSelectionSpecification.parse(
                "1-\(maximum), 1, 2, 3",
                pageCount: maximum + 10
            ),
            Set(0..<maximum),
            "Duplicates must not consume the unique-page allowance."
        )
        assertParseError(
            .tooMany,
            input: "1-\(maximum + 1)",
            pageCount: maximum + 10
        )
    }

    func testParseDistinguishesEmptyInput() {
        for input in ["", "   ", "\n\r\n"] {
            assertParseError(.empty, input: input, pageCount: 10)
        }
    }

    func testParseDistinguishesInvalidSyntax() {
        for input in [
            "one",
            "1 2",
            "1,,2",
            "1,\n2",
            "1-2-3",
            "4-2",
            "-2",
            "2-",
            "1.5",
            "１",
        ] {
            assertParseError(.invalidFormat, input: input, pageCount: 10)
        }
    }

    func testParseDistinguishesOutOfBoundsPages() {
        for input in [
            "0",
            "6",
            "1-6",
            "999999999999999999999999999999999999999999",
        ] {
            assertParseError(.outOfBounds, input: input, pageCount: 5)
        }
        assertParseError(.outOfBounds, input: "1", pageCount: 0)
        assertParseError(.outOfBounds, input: "1", pageCount: -1)
    }

    func testHugeRangeFailsBeforeExpansion() {
        let enormousUpperBound = String(repeating: "9", count: 100_000)
        assertParseError(
            .outOfBounds,
            input: "1-\(enormousUpperBound)",
            pageCount: Int.max
        )

        // A large but in-bounds range stops after maximumCount + 1 unique
        // insertions rather than allocating or iterating over the full range.
        assertParseError(
            .tooMany,
            input: "1-1000000000",
            pageCount: 1_000_000_000
        )
    }

    func testCompactDescriptionUsesOneBasedContiguousRanges() {
        XCTAssertEqual(
            AIPageSelectionSpecification.compactDescription(
                [9, 2, 1, 3, 6, 8, 2, -1]
            ),
            "2–4, 7, 9–10"
        )
        XCTAssertEqual(AIPageSelectionSpecification.compactDescription([0]), "1")
        XCTAssertEqual(
            AIPageSelectionSpecification.compactDescription([Int.max]),
            String(UInt(Int.max) + 1)
        )
        XCTAssertEqual(
            AIPageSelectionSpecification.compactDescription([Int]()),
            ""
        )
    }

    private func assertParseError(
        _ expected: AIPageSelectionError,
        input: String,
        pageCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AIPageSelectionSpecification.parse(input, pageCount: pageCount),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AIPageSelectionError,
                expected,
                "Unexpected error for input: \(input.prefix(80))",
                file: file,
                line: line
            )
        }
    }
}

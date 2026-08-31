// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import VibePDF

final class PDFShareNoteTests: XCTestCase {
    func testFragmentExcerptStopsAtBudgetWithoutJoiningEveryFragment() {
        var visited = 0
        let fragments = AnySequence<String> {
            var index = 0
            return AnyIterator<String> {
                guard index < 100 else { return nil }
                defer {
                    index += 1
                    visited += 1
                }
                return String(repeating: "가", count: 1_000)
            }
        }

        let excerpt = PDFShareNote.boundedExcerpt(fragments: fragments)

        XCTAssertEqual(excerpt.count, PDFShareNote.maximumExcerptCharacters)
        XCTAssertLessThan(visited, 100, "The lazy adapter must stop once the share budget is full.")
    }

    func testSharedTextContainsOnlyPreviewedExcerptAndMemo() {
        let note = PDFShareNote(
            excerpt: "Selected formula",
            memo: "Review this proof."
        )

        XCTAssertEqual(
            note.sharedText,
            "Selected formula\n\nReview this proof."
        )
        XCTAssertFalse(note.sharedText.contains("file://"))
    }

    func testSharedTextNeverAddsUnpreviewedFilenameOrPageMetadata() {
        // A filename can itself be sensitive. The model intentionally accepts
        // no title/page input, so an empty visible draft always shares nothing.
        let note = PDFShareNote(excerpt: nil)
        XCTAssertEqual(note.sharedText, "")
        XCTAssertFalse(note.sharedText.contains("김철수_HIV결과.pdf"))
    }

    func testExcerptAndMemoAreBoundedByUserVisibleCharacters() {
        let family = "👨‍👩‍👧‍👦"
        var note = PDFShareNote(
            excerpt: String(repeating: family, count: PDFShareNote.maximumExcerptCharacters + 20)
        )
        note.replaceMemo(
            with: String(repeating: "한", count: PDFShareNote.maximumMemoCharacters + 20)
        )

        XCTAssertEqual(note.excerpt.count, PDFShareNote.maximumExcerptCharacters)
        XCTAssertEqual(note.memo.count, PDFShareNote.maximumMemoCharacters)
        XCTAssertTrue(note.excerpt.hasSuffix(family))
    }

    func testWhitespaceDoesNotCreateEmptySections() {
        let note = PDFShareNote(
            excerpt: " \n ",
            memo: "  "
        )

        XCTAssertEqual(note.sharedText, "")
    }

    func testSinglePathologicalGraphemeCannotBypassEncodedShareBudgets() {
        // One visible Character can contain arbitrarily many combining marks.
        // Build enough UTF-16 units to exceed both the excerpt and memo caps.
        let pathological = "a" + String(
            repeating: "\u{0301}",
            count: PDFShareNote.memoBudget.maximumUTF16CodeUnits + 100
        )
        XCTAssertEqual(pathological.count, 1)

        var note = PDFShareNote(excerpt: pathological)
        note.replaceMemo(with: pathological)

        XCTAssertLessThanOrEqual(
            note.excerpt.utf8.count,
            PDFShareNote.excerptBudget.maximumUTF8Bytes
        )
        XCTAssertLessThanOrEqual(
            note.excerpt.utf16.count,
            PDFShareNote.excerptBudget.maximumUTF16CodeUnits
        )
        XCTAssertLessThanOrEqual(
            note.memo.utf8.count,
            PDFShareNote.memoBudget.maximumUTF8Bytes
        )
        XCTAssertLessThanOrEqual(
            note.memo.utf16.count,
            PDFShareNote.memoBudget.maximumUTF16CodeUnits
        )

        let fragments = PDFShareNote.boundedExcerpt(
            fragments: [pathological, "must-not-be-appended"]
        )
        XCTAssertLessThanOrEqual(
            fragments.utf8.count,
            PDFShareNote.excerptBudget.maximumUTF8Bytes
        )
        XCTAssertFalse(fragments.contains("must-not-be-appended"))
    }

    func testEncodedLimiterBacksOffAnIncompleteUTF8Scalar() {
        let result = EncodedTextLimiter.limit(
            "😀safe",
            budget: EncodedTextBudget(
                maximumCharacters: 10,
                maximumUTF8Bytes: 2,
                maximumUTF16CodeUnits: 10
            )
        )

        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.wasTruncated)
        XCTAssertNotNil(result.text.data(using: .utf8))
    }

    func testEncodedRatiosPreserveNormalMultilingualTextAndEmoji() {
        let ordinary = "English · 한국어 · 日本語 · 中文 · العربية · 👨‍👩‍👧‍👦"
        let result = EncodedTextLimiter.limit(
            ordinary,
            budget: EncodedTextBudget(maximumCharacters: ordinary.count)
        )

        XCTAssertEqual(result.text, ordinary)
        XCTAssertFalse(result.wasTruncated)
    }
}

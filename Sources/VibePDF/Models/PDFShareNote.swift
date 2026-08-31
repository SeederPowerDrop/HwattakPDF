// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// A small, value-only snapshot used by the Viewer/Study "note and share" flow.
///
/// The live `PDFSelection` is a PDFKit object tied to a resident document. A
/// share sheet can outlive the current tab or trigger memory hibernation, so it
/// must never retain that object. We copy only a bounded excerpt and ordinary
/// strings before presenting the sheet.
struct PDFShareNote: Equatable, Identifiable {
    static let maximumExcerptCharacters = 4_000
    static let maximumMemoCharacters = 8_000
    static let excerptBudget = EncodedTextBudget(
        maximumCharacters: maximumExcerptCharacters
    )
    static let memoBudget = EncodedTextBudget(
        maximumCharacters: maximumMemoCharacters
    )

    let id = UUID()
    let excerpt: String
    var memo: String

    init(
        excerpt: String?,
        memo: String = ""
    ) {
        self.excerpt = EncodedTextLimiter.limit(
            excerpt ?? "",
            budget: Self.excerptBudget
        ).text
        self.memo = EncodedTextLimiter.limit(
            memo,
            budget: Self.memoBudget
        ).text
    }

    /// TextEditor can briefly exceed its limit while an input method composes
    /// Korean, Japanese, Chinese, or Arabic text. Clamp the stored value without
    /// assuming one user-visible character equals one UTF-8/UTF-16 code unit.
    mutating func replaceMemo(with value: String) {
        memo = EncodedTextLimiter.limit(value, budget: Self.memoBudget).text
    }

    /// Reads only the prefix that the share sheet can actually display.
    ///
    /// Calling `PDFSelection.string` first can ask PDFKit to build a very large
    /// temporary String when someone selects an entire chapter. Walking the
    /// line selections lets us stop as soon as the 4,000-character privacy and
    /// memory budget is full. The fallback covers unusual PDF generators whose
    /// selection exposes text but no line fragments.
    @MainActor
    static func boundedExcerpt(from selection: PDFSelection?) -> String {
        guard let selection else { return "" }
        let fragments = selection.selectionsByLine().lazy.compactMap(\.string)
        let excerpt = boundedExcerpt(fragments: fragments)
        if !excerpt.isEmpty { return excerpt }
        return EncodedTextLimiter.limit(
            selection.string ?? "",
            budget: excerptBudget
        ).text
    }

    /// Pure fragment seam used by the PDFSelection adapter and unit tests.
    /// The shared accumulator tracks characters and both encoded sizes, so one
    /// giant combining sequence cannot bypass the same bound used by the UI.
    static func boundedExcerpt<S: Sequence>(fragments: S) -> String where S.Element == String {
        EncodedTextLimiter.joined(
            fragments: fragments,
            separator: "\n",
            budget: excerptBudget
        ).text
    }

    /// Produces a plain-text payload so macOS decides which installed sharing
    /// services are appropriate. No PDF bytes, file URL, or hidden page text is
    /// included—only the excerpt the user saw and the memo they typed. In
    /// particular, do not prepend the PDF filename or current page: filenames
    /// often contain names, diagnoses, case numbers, or other private metadata
    /// that the sheet does not preview.
    var sharedText: String {
        var sections: [String] = []

        let trimmedExcerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExcerpt.isEmpty {
            sections.append(trimmedExcerpt)
        }

        let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMemo.isEmpty {
            sections.append(trimmedMemo)
        }
        return sections.joined(separator: "\n\n")
    }

}

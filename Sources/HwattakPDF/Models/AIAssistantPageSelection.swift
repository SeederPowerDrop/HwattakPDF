// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Validation failures for the page-number field in the AI assistant.
///
/// Page numbers typed by the user are one-based. The returned selection is
/// zero-based so it can be passed directly to the PDF context extractor.
enum AIPageSelectionError: Error, Equatable {
    case empty
    case invalidFormat
    case outOfBounds
    case tooMany
}

/// Parses and presents the explicit page selection used by PDF AI requests.
///
/// Keeping this logic independent of SwiftUI and PDFKit makes the boundary
/// deterministic: malformed input cannot start extraction, enormous ranges
/// cannot cause an enormous allocation, and displayed page numbers always use
/// the same one-based convention as the PDF viewer.
enum AIPageSelectionSpecification {
    static let maximumCount = PDFAIContextBudget.standard.maximumPages

    private static let rangeSeparators: Set<Character> = ["-", "–", "—", "~"]

    /// Returns all unique, in-bounds indices in document order.
    ///
    /// This function deliberately does not cap the result at `maximumCount`.
    /// Silently dropping an otherwise valid page would make the scope shown to
    /// the user differ from the scope sent to AI. Interactive parsing and the
    /// request boundary reject an oversized selection explicitly instead.
    static func sanitized<S: Sequence>(
        _ indices: S,
        pageCount: Int
    ) -> [Int] where S.Element == Int {
        guard pageCount > 0 else { return [] }
        return Set(indices.lazy.filter { $0 >= 0 && $0 < pageCount }).sorted()
    }

    /// Parses comma- or newline-separated one-based pages and inclusive ranges.
    ///
    /// Accepted range separators are `-`, `–`, `—`, and `~`. At most
    /// `maximumCount` unique pages are accepted. Each range is expanded only
    /// until the unique-page limit is exceeded, so even an adversarially large
    /// range never causes proportional work or allocation.
    static func parse(_ input: String, pageCount: Int) throws -> Set<Int> {
        let normalized = input
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw AIPageSelectionError.empty }

        let components = normalized.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "," || $0 == "\n" }
        )
        var result: Set<Int> = []

        for rawComponent in components {
            let component = rawComponent.trimmingCharacters(in: .whitespaces)
            guard !component.isEmpty else {
                throw AIPageSelectionError.invalidFormat
            }

            let bounds = component.split(
                omittingEmptySubsequences: false,
                whereSeparator: { rangeSeparators.contains($0) }
            )
            guard bounds.count == 1 || bounds.count == 2 else {
                throw AIPageSelectionError.invalidFormat
            }

            let lower = try parsePageNumber(bounds[0], pageCount: pageCount)
            let upper: Int
            if bounds.count == 2 {
                upper = try parsePageNumber(bounds[1], pageCount: pageCount)
                guard lower <= upper else {
                    throw AIPageSelectionError.invalidFormat
                }
            } else {
                upper = lower
            }

            // Both bounds have already been checked against pageCount and are
            // at least one. Stop after the 25th unique value instead of ever
            // materializing a potentially huge ClosedRange.
            var pageNumber = lower
            while true {
                result.insert(pageNumber - 1)
                guard result.count <= maximumCount else {
                    throw AIPageSelectionError.tooMany
                }
                if pageNumber == upper { break }
                pageNumber += 1
            }
        }

        guard !result.isEmpty else { throw AIPageSelectionError.empty }
        return result
    }

    /// Produces a compact, one-based description such as `2–4, 7`.
    static func compactDescription<S: Sequence>(_ indices: S) -> String
    where S.Element == Int {
        let sorted = Set(indices.lazy.filter { $0 >= 0 }).sorted()
        guard let first = sorted.first else { return "" }

        var descriptions: [String] = []
        var rangeStart = first
        var rangeEnd = first

        func oneBased(_ index: Int) -> String {
            // `UInt(Int.max) + 1` is representable on supported 64-bit macOS,
            // avoiding an otherwise unnecessary overflow trap at the boundary.
            String(UInt(index) + 1)
        }

        func appendRange() {
            if rangeStart == rangeEnd {
                descriptions.append(oneBased(rangeStart))
            } else {
                descriptions.append("\(oneBased(rangeStart))–\(oneBased(rangeEnd))")
            }
        }

        for index in sorted.dropFirst() {
            if rangeEnd != Int.max, index == rangeEnd + 1 {
                rangeEnd = index
            } else {
                appendRange()
                rangeStart = index
                rangeEnd = index
            }
        }
        appendRange()
        return descriptions.joined(separator: ", ")
    }

    /// Parses only ASCII decimal page numbers while comparing against
    /// pageCount before multiplication can overflow Int.
    private static func parsePageNumber(
        _ rawValue: Substring,
        pageCount: Int
    ) throws -> Int {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { throw AIPageSelectionError.invalidFormat }

        let maximumPage = max(0, pageCount)
        var pageNumber = 0
        for character in value {
            guard
                let ascii = character.asciiValue,
                ascii >= Character("0").asciiValue!,
                ascii <= Character("9").asciiValue!
            else {
                throw AIPageSelectionError.invalidFormat
            }
            let digit = Int(ascii - Character("0").asciiValue!)
            guard
                pageNumber <= maximumPage / 10,
                pageNumber * 10 <= maximumPage - digit
            else {
                throw AIPageSelectionError.outOfBounds
            }
            pageNumber = pageNumber * 10 + digit
        }
        guard pageNumber >= 1, pageNumber <= maximumPage else {
            throw AIPageSelectionError.outOfBounds
        }
        return pageNumber
    }
}

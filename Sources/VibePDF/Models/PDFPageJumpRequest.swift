// SPDX-License-Identifier: MPL-2.0

import Foundation

enum PDFPageJumpResolution: Equatable {
    case unavailable
    case invalid
    case destination(pageIndex: Int, pageNumber: Int)
}

/// Resolves user-facing, 1-based page numbers without mutating workspace
/// state. The UI deliberately routes the resulting zero-based index through
/// `PDFWorkspaceState.setCurrentPage`, preserving every existing PDFKit/grid
/// and session synchronization path.
enum PDFPageJumpRequest {
    static func resolve(
        _ input: String,
        pageCount: Int
    ) -> PDFPageJumpResolution {
        guard pageCount > 0 else { return .unavailable }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let requestedPage = decimalPageNumber(from: trimmed) else {
            return .invalid
        }

        guard (1...pageCount).contains(requestedPage) else { return .invalid }
        let pageNumber = requestedPage
        return .destination(
            pageIndex: pageNumber - 1,
            pageNumber: pageNumber
        )
    }

    /// Parses Unicode decimal digits (General_Category=Nd), including ASCII,
    /// Arabic-Indic and Extended Arabic-Indic forms. Arithmetic is checked
    /// before every multiply/add so malformed or huge input cannot overflow.
    private static func decimalPageNumber(from input: String) -> Int? {
        let scalars = input.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 64 else { return nil }

        var value = 0
        for scalar in scalars {
            guard
                scalar.properties.generalCategory == .decimalNumber,
                let numericValue = scalar.properties.numericValue,
                numericValue >= 0,
                numericValue <= 9,
                numericValue.rounded(.towardZero) == numericValue
            else {
                return nil
            }
            let digit = Int(numericValue)
            guard value <= (Int.max - digit) / 10 else { return nil }
            value = value * 10 + digit
        }
        return value
    }
}

// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// One navigable occurrence in the current PDF.
///
/// Ranges use UTF-16 offsets because that is the coordinate space shared by
/// `NSString`, `PDFPage.selection(for:)`, and SwiftUI's `Range(_:in:)` bridge.
struct PDFSearchResult: Identifiable {
    let id: UUID
    let pageIndex: Int
    let pageLabel: String
    let snippet: String
    let snippetMatchRanges: [NSRange]
    let sourceRange: NSRange
    let matchedText: String

    init(
        id: UUID = UUID(),
        pageIndex: Int,
        pageLabel: String,
        snippet: String,
        snippetMatchRanges: [NSRange],
        sourceRange: NSRange,
        matchedText: String
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.pageLabel = pageLabel
        self.snippet = snippet
        self.snippetMatchRanges = snippetMatchRanges
        self.sourceRange = sourceRange
        self.matchedText = matchedText
    }
}

struct PDFSearchProgress: Equatable {
    enum Phase: Equatable {
        case idle
        case searching
        case completed
        case cancelled
    }

    var phase: Phase
    var completedPages: Int
    var totalPages: Int
    var resultCount: Int
    var isTruncated: Bool

    static let idle = PDFSearchProgress(
        phase: .idle,
        completedPages: 0,
        totalPages: 0,
        resultCount: 0,
        isTruncated: false
    )

    var fraction: Double {
        guard totalPages > 0 else { return phase == .completed ? 1 : 0 }
        return min(1, max(0, Double(completedPages) / Double(totalPages)))
    }
}

/// A bounded, page-at-a-time PDF text matcher.
///
/// PDFKit's whole-document `findString` call is synchronous and its public
/// search options do not include compatibility normalization. Searching the
/// extracted page text here gives us both cancellation/yield points and a
/// reliable source-range map for NFKC, whitespace, and script-specific folds.
struct PDFSearchEngine: Sendable {
    struct Configuration: Equatable, Sendable {
        var maximumResultCount = 20_000
        var maximumResultsPerPage = 2_000
        var snippetContextCharacters = 56
        var publicationPageBatch = 6
        var publicationResultBatch = 96

        static let standard = Configuration()
    }

    struct PreparedQuery: Equatable, Sendable {
        let source: String
        let normalized: String

        var isEmpty: Bool { normalized.isEmpty }
    }

    struct PageOutcome {
        let pageIndex: Int
        let results: [PDFSearchResult]
        let hasExtractableText: Bool
        let reachedPageLimit: Bool
    }

    private struct RawMatch: Sendable {
        let sourceRange: NSRange
        let snippet: String
        let snippetMatchRanges: [NSRange]
        let matchedText: String
    }

    private struct RawPageOutcome: Sendable {
        let matches: [RawMatch]
        let reachedPageLimit: Bool
    }

    let configuration: Configuration

    init(configuration: Configuration = .standard) {
        self.configuration = configuration
    }

    func prepare(query: String) -> PreparedQuery {
        let source = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return PreparedQuery(
            source: source,
            normalized: PDFUnicodeSearchNormalizer.normalizeQuery(source)
        )
    }

    @MainActor
    func searchPage(
        in document: PDFDocument,
        pageIndex: Int,
        query: PreparedQuery,
        remainingResultCapacity: Int
    ) async throws -> PageOutcome {
        guard
            !query.isEmpty,
            remainingResultCapacity > 0,
            pageIndex >= 0,
            pageIndex < document.pageCount,
            let page = document.page(at: pageIndex)
        else {
            return PageOutcome(
                pageIndex: pageIndex,
                results: [],
                hasExtractableText: false,
                reachedPageLimit: false
            )
        }

        let pageText = page.string ?? ""
        let hasExtractableText = !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasExtractableText else {
            return PageOutcome(
                pageIndex: pageIndex,
                results: [],
                hasExtractableText: false,
                reachedPageLimit: false
            )
        }

        let resultLimit = min(
            remainingResultCapacity,
            max(1, configuration.maximumResultsPerPage)
        )
        let contextCharacters = configuration.snippetContextCharacters
        let worker = Task.detached(priority: .userInitiated) {
            try Self.matchPageText(
                pageText,
                normalizedQuery: query.normalized,
                resultLimit: resultLimit,
                contextCharacters: contextCharacters
            )
        }
        let rawOutcome = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }

        try Task.checkCancellation()
        let pageLabel = page.label ?? String(pageIndex + 1)
        // Keep every source-valid lightweight result in the navigator. Some
        // malformed PDFs disagree about `page.string` UTF-16 length and
        // `numberOfCharacters`; activation validates that Objective-C boundary
        // and can still navigate to the page without attempting a bad range.
        let results = rawOutcome.matches.map { rawMatch in
            PDFSearchResult(
                pageIndex: pageIndex,
                pageLabel: pageLabel,
                snippet: rawMatch.snippet,
                snippetMatchRanges: rawMatch.snippetMatchRanges,
                sourceRange: rawMatch.sourceRange,
                matchedText: rawMatch.matchedText
            )
        }

        return PageOutcome(
            pageIndex: pageIndex,
            results: results,
            hasExtractableText: true,
            reachedPageLimit: rawOutcome.reachedPageLimit
        )
    }

    private static func matchPageText(
        _ pageText: String,
        normalizedQuery: String,
        resultLimit: Int,
        contextCharacters: Int
    ) throws -> RawPageOutcome {
        let normalizedPage = try PDFUnicodeSearchNormalizer.normalizeDocumentText(pageText)
        guard !normalizedPage.text.isEmpty else {
            return RawPageOutcome(matches: [], reachedPageLimit: false)
        }

        let normalizedNSString = normalizedPage.text as NSString
        let normalizedQueryNSString = normalizedQuery as NSString
        var searchRange = NSRange(location: 0, length: normalizedNSString.length)
        var matches: [RawMatch] = []
        matches.reserveCapacity(min(32, resultLimit))
        var encounteredAdditionalMatch = false
        var iteration = 0

        while
            searchRange.length >= normalizedQueryNSString.length,
            normalizedQueryNSString.length > 0
        {
            if iteration.isMultiple(of: 64) {
                try Task.checkCancellation()
            }
            iteration += 1
            let found = normalizedNSString.range(
                of: normalizedQuery,
                options: [.literal],
                range: searchRange
            )
            guard found.location != NSNotFound else { break }

            if matches.count >= resultLimit {
                encounteredAdditionalMatch = true
                break
            }

            if
                let sourceRange = normalizedPage.sourceRange(forNormalizedRange: found),
                sourceRange.location >= 0,
                sourceRange.length > 0,
                sourceRange.location + sourceRange.length <= (pageText as NSString).length
            {
                let snippet = PDFSearchSnippetBuilder.make(
                    pageText: pageText,
                    matchRange: sourceRange,
                    contextCharacters: contextCharacters
                )
                matches.append(
                    RawMatch(
                        sourceRange: sourceRange,
                        snippet: snippet.text,
                        snippetMatchRanges: snippet.matchRanges,
                        matchedText: (pageText as NSString).substring(with: sourceRange)
                    )
                )
            }

            let nextLocation = found.location + max(1, found.length)
            guard nextLocation <= normalizedNSString.length else { break }
            searchRange = NSRange(
                location: nextLocation,
                length: normalizedNSString.length - nextLocation
            )
        }

        return RawPageOutcome(
            matches: matches,
            reachedPageLimit: encounteredAdditionalMatch
        )
    }
}

struct PDFNormalizedSearchText {
    let text: String
    /// One source range for every UTF-16 code unit in `text`.
    let sourceRanges: [NSRange]

    func sourceRange(forNormalizedRange range: NSRange) -> NSRange? {
        guard
            range.location != NSNotFound,
            range.length > 0,
            range.location >= 0,
            range.location + range.length <= sourceRanges.count
        else { return nil }

        let mapped = sourceRanges[range.location..<(range.location + range.length)]
        guard
            let first = mapped.first,
            let last = mapped.last
        else { return nil }
        let start = first.location
        let end = max(start, last.location + last.length)
        return NSRange(location: start, length: end - start)
    }
}

enum PDFUnicodeSearchNormalizer {
    private struct SourceUnit {
        let text: String
        let range: NSRange

        var isWhitespace: Bool {
            text.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }

        var containsNewline: Bool {
            text.unicodeScalars.contains { CharacterSet.newlines.contains($0) }
        }

        var isSoftLineHyphen: Bool {
            text == "-" || text == "\u{2010}" || text == "\u{2011}" || text == "\u{00AD}"
        }
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    static func normalizeQuery(_ text: String) -> String {
        // Queries are UI-sized. Cancellation-aware document normalization is
        // reserved for the potentially very large page text below.
        (try? normalize(
            text,
            dehyphenatingLineBreaks: false,
            checkingCancellation: false
        ).text) ?? ""
    }

    static func normalizeDocumentText(_ text: String) throws -> PDFNormalizedSearchText {
        try normalize(
            text,
            dehyphenatingLineBreaks: true,
            checkingCancellation: true
        )
    }

    private static func normalize(
        _ text: String,
        dehyphenatingLineBreaks: Bool,
        checkingCancellation: Bool
    ) throws -> PDFNormalizedSearchText {
        let units = try sourceUnits(
            in: text,
            checkingCancellation: checkingCancellation
        )
        var normalized = ""
        var mappings: [NSRange] = []
        mappings.reserveCapacity((text as NSString).length)
        var index = 0

        while index < units.count {
            if checkingCancellation, index.isMultiple(of: 512) {
                try Task.checkCancellation()
            }
            let unit = units[index]

            if
                dehyphenatingLineBreaks,
                unit.isSoftLineHyphen,
                let whitespaceEnd = lineBreakWhitespaceEnd(after: index, in: units)
            {
                // A PDF line-wrap such as "inter-\nnational" should be found
                // by the natural query "international". The selected source
                // range still spans the original hyphen and line break.
                index = whitespaceEnd
                continue
            }

            if unit.isWhitespace {
                var endIndex = index + 1
                var sourceEnd = unit.range.location + unit.range.length
                while endIndex < units.count, units[endIndex].isWhitespace {
                    sourceEnd = units[endIndex].range.location + units[endIndex].range.length
                    endIndex += 1
                }
                if !normalized.isEmpty, normalized.last != " " {
                    append(" ", sourceRange: NSRange(
                        location: unit.range.location,
                        length: sourceEnd - unit.range.location
                    ), to: &normalized, mappings: &mappings)
                }
                index = endIndex
                continue
            }

            let folded = fold(unit.text)
            if !folded.isEmpty {
                append(folded, sourceRange: unit.range, to: &normalized, mappings: &mappings)
            }
            index += 1
        }

        while normalized.last == " ", !mappings.isEmpty {
            normalized.removeLast()
            mappings.removeLast()
        }
        return PDFNormalizedSearchText(text: normalized, sourceRanges: mappings)
    }

    private static func sourceUnits(
        in text: String,
        checkingCancellation: Bool
    ) throws -> [SourceUnit] {
        var units: [SourceUnit] = []
        units.reserveCapacity(text.count)
        var cursor = text.startIndex
        var unitCount = 0
        while cursor < text.endIndex {
            if checkingCancellation, unitCount.isMultiple(of: 512) {
                try Task.checkCancellation()
            }
            let next = text.index(after: cursor)
            units.append(
                SourceUnit(
                    text: String(text[cursor..<next]),
                    range: NSRange(cursor..<next, in: text)
                )
            )
            cursor = next
            unitCount += 1
        }
        return units
    }

    private static func lineBreakWhitespaceEnd(
        after hyphenIndex: Int,
        in units: [SourceUnit]
    ) -> Int? {
        var cursor = hyphenIndex + 1
        var foundNewline = false
        while cursor < units.count, units[cursor].isWhitespace {
            foundNewline = foundNewline || units[cursor].containsNewline
            cursor += 1
        }
        guard foundNewline, cursor < units.count else { return nil }
        return cursor
    }

    private static func fold(_ source: String) -> String {
        let compatibility = source.precomposedStringWithCompatibilityMapping
        let folded = compatibility.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: foldingLocale
        ).lowercased(with: foldingLocale)

        let filteredScalars = folded.unicodeScalars.filter { scalar in
            if scalar.value == 0x0640 { return false } // Arabic tatweel
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark, .format, .control:
                return false
            default:
                return true
            }
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    private static func append(
        _ fragment: String,
        sourceRange: NSRange,
        to output: inout String,
        mappings: inout [NSRange]
    ) {
        output.append(fragment)
        mappings.append(
            contentsOf: repeatElement(sourceRange, count: (fragment as NSString).length)
        )
    }
}

private enum PDFSearchSnippetBuilder {
    struct Snippet {
        let text: String
        let matchRanges: [NSRange]
    }

    static func make(
        pageText: String,
        matchRange: NSRange,
        contextCharacters: Int
    ) -> Snippet {
        guard
            let matchStringRange = Range(matchRange, in: pageText),
            !pageText.isEmpty
        else { return Snippet(text: "", matchRanges: []) }

        let context = max(8, contextCharacters)
        let start = pageText.index(
            matchStringRange.lowerBound,
            offsetBy: -context,
            limitedBy: pageText.startIndex
        ) ?? pageText.startIndex
        let end = pageText.index(
            matchStringRange.upperBound,
            offsetBy: context,
            limitedBy: pageText.endIndex
        ) ?? pageText.endIndex
        let hasLeadingEllipsis = start > pageText.startIndex
        let hasTrailingEllipsis = end < pageText.endIndex

        var output = hasLeadingEllipsis ? "…" : ""
        var matchStart: Int?
        var matchEnd: Int?
        var cursor = start
        var pendingWhitespace = false
        var pendingWhitespaceMatches = false

        func flushWhitespaceIfNeeded() {
            guard pendingWhitespace, !output.isEmpty, output.last != " " else {
                pendingWhitespace = false
                pendingWhitespaceMatches = false
                return
            }
            let location = (output as NSString).length
            output.append(" ")
            if pendingWhitespaceMatches {
                matchStart = matchStart ?? location
                matchEnd = location + 1
            }
            pendingWhitespace = false
            pendingWhitespaceMatches = false
        }

        while cursor < end {
            let next = pageText.index(after: cursor)
            let fragment = String(pageText[cursor..<next])
            let fragmentRange = NSRange(cursor..<next, in: pageText)
            let intersectsMatch = NSIntersectionRange(fragmentRange, matchRange).length > 0
            let whitespace = fragment.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }

            if whitespace {
                pendingWhitespace = true
                pendingWhitespaceMatches = pendingWhitespaceMatches || intersectsMatch
            } else {
                flushWhitespaceIfNeeded()
                let location = (output as NSString).length
                output.append(fragment)
                if intersectsMatch {
                    matchStart = matchStart ?? location
                    matchEnd = (output as NSString).length
                }
            }
            cursor = next
        }
        if hasTrailingEllipsis {
            output.append("…")
        }

        let ranges: [NSRange]
        if let matchStart, let matchEnd, matchEnd > matchStart {
            ranges = [NSRange(location: matchStart, length: matchEnd - matchStart)]
        } else {
            ranges = []
        }
        return Snippet(text: output, matchRanges: ranges)
    }
}

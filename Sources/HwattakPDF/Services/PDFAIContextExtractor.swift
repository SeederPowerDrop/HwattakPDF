// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

@MainActor
struct PDFAIContextExtractor {
    private struct RawPageText {
        let text: String
        let wasTruncated: Bool
    }

    func extract(
        from workspace: PDFWorkspaceState,
        scope: PDFAIContextScope,
        budget: PDFAIContextBudget = .standard
    ) async throws -> PDFAIContextBundle {
        try Task.checkCancellation()
        guard let document = workspace.document else {
            throw PDFAIContextExtractionError.noDocument
        }

        // A filename is shown in consent and repeated in each source marker.
        // Bound it with the same encoded-first policy as PDF body text; a local
        // path is still never included in the transmitted prompt.
        let title = EncodedTextLimiter.limit(
            workspace.displayName,
            budget: PDFAIContextBudget.documentTitleBudget
        ).text
        let url = workspace.documentURL
        let pageCount = document.pageCount
        let currentPageIndex = workspace.currentPageIndex
        let selectedPages = workspace.selectedPages
        let selection = workspace.currentSelection
        let requestedPageIndices: [Int]
        let rawTextByPage: [Int: RawPageText]
        let kind: PDFAIContextSourceKind

        switch scope {
        case .selection:
            guard let selection else {
                throw PDFAIContextExtractionError.selectionUnavailable
            }
            let selectionContext = try await selectionTextByPage(
                selection,
                in: document,
                pageCount: pageCount,
                currentPageIndex: currentPageIndex,
                budget: budget
            )
            rawTextByPage = selectionContext.textByPage
            requestedPageIndices = selectionContext.requestedPageIndices
            kind = .selection

        case .currentPage:
            requestedPageIndices = validPageIndices(
                [currentPageIndex],
                pageCount: pageCount
            )
            rawTextByPage = try await pageText(
                at: requestedPageIndices,
                in: document,
                rawTextBudget: rawTextBudget(for: budget)
            )
            kind = .pageText

        case .selectedPages:
            requestedPageIndices = validPageIndices(
                selectedPages.sorted(),
                pageCount: pageCount
            )
            let sampledIndices = PDFRepresentativePageSampler.indices(
                from: requestedPageIndices,
                maximumCount: budget.maximumPages,
                preferred: [currentPageIndex]
            )
            rawTextByPage = try await pageText(
                at: sampledIndices,
                in: document,
                rawTextBudget: rawTextBudget(for: budget)
            )
            kind = .pageText

        case let .pageIndices(indices):
            requestedPageIndices = validPageIndices(
                indices.sorted(),
                pageCount: pageCount
            )
            let sampledIndices = PDFRepresentativePageSampler.indices(
                from: requestedPageIndices,
                maximumCount: budget.maximumPages,
                preferred: [currentPageIndex]
            )
            rawTextByPage = try await pageText(
                at: sampledIndices,
                in: document,
                rawTextBudget: rawTextBudget(for: budget)
            )
            kind = .pageText

        case let .pageRange(range):
            requestedPageIndices = validPageIndices(
                in: range,
                pageCount: pageCount
            )
            guard !requestedPageIndices.isEmpty else {
                throw PDFAIContextExtractionError.pageRangeUnavailable
            }
            let sampledIndices = PDFRepresentativePageSampler.indices(
                from: requestedPageIndices,
                maximumCount: budget.maximumPages,
                preferred: [currentPageIndex]
            )
            rawTextByPage = try await pageText(
                at: sampledIndices,
                in: document,
                rawTextBudget: rawTextBudget(for: budget)
            )
            kind = .pageText

        case .wholeDocument:
            requestedPageIndices = Array(0..<pageCount)
            let sampledIndices = PDFRepresentativePageSampler.indices(
                from: requestedPageIndices,
                maximumCount: budget.maximumPages,
                preferred: [currentPageIndex]
            )
            rawTextByPage = try await pageText(
                at: sampledIndices,
                in: document,
                rawTextBudget: rawTextBudget(for: budget)
            )
            kind = .pageText
        }

        guard !requestedPageIndices.isEmpty else {
            throw scope == .selection
                ? PDFAIContextExtractionError.selectionUnavailable
                : PDFAIContextExtractionError.noExtractableText
        }

        let availableIndices = rawTextByPage.keys.sorted()
        let sampledIndices = PDFRepresentativePageSampler.indices(
            from: availableIndices,
            maximumCount: budget.maximumPages,
            preferred: [currentPageIndex]
        )
        var remainingCharacters = budget.maximumCharacters
        var remainingUTF8Bytes = budget.maximumUTF8Bytes
        var remainingUTF16CodeUnits = budget.maximumUTF16CodeUnits
        var sources: [PDFAIContextSource] = []
        var truncatedByCharacters = false

        for (offset, pageIndex) in sampledIndices.enumerated() {
            try Task.checkCancellation()
            if offset > 0 {
                await Task.yield()
                try Task.checkCancellation()
            }
            guard
                remainingCharacters > 0,
                remainingUTF8Bytes > 0,
                remainingUTF16CodeUnits > 0
            else {
                truncatedByCharacters = true
                break
            }
            guard let rawText = rawTextByPage[pageIndex] else { continue }
            let normalized = Self.normalizedText(rawText.text)
            guard !normalized.isEmpty else { continue }

            let pageTextBudget = EncodedTextBudget(
                maximumCharacters: min(
                    budget.maximumCharactersPerPage,
                    remainingCharacters
                ),
                maximumUTF8Bytes: min(
                    budget.maximumUTF8BytesPerPage,
                    remainingUTF8Bytes
                ),
                maximumUTF16CodeUnits: min(
                    budget.maximumUTF16CodeUnitsPerPage,
                    remainingUTF16CodeUnits
                )
            )
            let limited = EncodedTextLimiter.limit(
                normalized,
                budget: pageTextBudget
            )
            let excerpt = limited.text
            // A prior page can leave 1–3 UTF-8 bytes (or one UTF-16 unit),
            // which is not enough for the next page's first scalar. Do not add
            // a citation header with an empty body or claim that empty text is
            // an extractable source; stop at the last complete scalar instead.
            guard !excerpt.isEmpty else {
                truncatedByCharacters = true
                break
            }
            let pageWasTruncated = rawText.wasTruncated
                || limited.wasTruncated
            sources.append(
                PDFAIContextSource(
                    citationID: "S\(sources.count + 1)",
                    documentURL: url,
                    documentTitle: title,
                    pageIndex: pageIndex,
                    pageNumber: pageIndex + 1,
                    text: excerpt,
                    kind: kind,
                    wasTruncated: pageWasTruncated
                )
            )
            remainingCharacters -= excerpt.count
            remainingUTF8Bytes -= excerpt.utf8.count
            remainingUTF16CodeUnits -= excerpt.utf16.count
            truncatedByCharacters = truncatedByCharacters || pageWasTruncated
        }

        guard !sources.isEmpty else {
            throw scope == .selection
                ? PDFAIContextExtractionError.selectionUnavailable
                : PDFAIContextExtractionError.noExtractableText
        }

        let includedIndices = Set(sources.map(\.pageIndex))
        let omittedPageCount = max(
            0,
            Set(requestedPageIndices).subtracting(includedIndices).count
        )
        let didSamplePages = sampledIndices.count < Set(requestedPageIndices).count

        return PDFAIContextBundle(
            scope: scope,
            documentTitle: title,
            documentURL: url,
            documentPageCount: pageCount,
            sources: sources,
            omittedPageCount: omittedPageCount,
            wasTruncated: truncatedByCharacters || didSamplePages || omittedPageCount > 0,
            promptTextBudget: budget.promptTextBudget
        )
    }

    private func selectionTextByPage(
        _ selection: PDFSelection,
        in document: PDFDocument,
        pageCount: Int,
        currentPageIndex: Int,
        budget: PDFAIContextBudget
    ) async throws -> (
        requestedPageIndices: [Int],
        textByPage: [Int: RawPageText]
    ) {
        let requestedPageIndices = validPageIndices(
            selection.pages.map(document.index(for:)),
            pageCount: pageCount
        )
        let sampledPageIndices = PDFRepresentativePageSampler.indices(
            from: requestedPageIndices,
            maximumCount: budget.maximumPages,
            preferred: [currentPageIndex]
        )
        let sampledPageSet = Set(sampledPageIndices)
        let rawBudget = rawTextBudget(for: budget)
        var textByPage: [Int: EncodedTextAccumulator] = [:]
        var truncatedPages: Set<Int> = []
        var saturatedPages: Set<Int> = []

        // Avoid asking PDFKit to materialize `selection.string` up front. Line
        // strings are retained only for representative pages and only up to
        // the same bounded raw-text limit used for ordinary page extraction.
        for (lineOffset, line) in selection.selectionsByLine().enumerated() {
            if lineOffset.isMultiple(of: 64) {
                try Task.checkCancellation()
                if lineOffset > 0 {
                    await Task.yield()
                    try Task.checkCancellation()
                }
            }
            guard
                let page = line.pages.first
            else { continue }
            let pageIndex = document.index(for: page)
            guard
                pageIndex != NSNotFound,
                sampledPageSet.contains(pageIndex)
            else { continue }
            guard let lineText = line.string else { continue }

            var pageText = textByPage[pageIndex]
                ?? EncodedTextAccumulator(budget: rawBudget)
            guard !pageText.isSaturated else {
                truncatedPages.insert(pageIndex)
                saturatedPages.insert(pageIndex)
                if saturatedPages.count == sampledPageSet.count { break }
                continue
            }

            let acceptedWholeLine = pageText.append(lineText, separator: "\n")
            textByPage[pageIndex] = pageText
            if !acceptedWholeLine {
                truncatedPages.insert(pageIndex)
                saturatedPages.insert(pageIndex)
                if saturatedPages.count == sampledPageSet.count { break }
            }
        }

        if !textByPage.isEmpty {
            var boundedTextByPage: [Int: RawPageText] = [:]
            for (pageIndex, accumulator) in textByPage {
                boundedTextByPage[pageIndex] = RawPageText(
                    text: accumulator.text,
                    wasTruncated: truncatedPages.contains(pageIndex)
                        || accumulator.wasTruncated
                )
            }
            return (requestedPageIndices, boundedTextByPage)
        }

        try Task.checkCancellation()
        guard let text = selection.string else {
            return (requestedPageIndices, [:])
        }
        let pageIndex = selection.pages.first.map(document.index(for:))
            ?? NSNotFound
        guard pageIndex != NSNotFound else {
            return (requestedPageIndices, [:])
        }
        let bounded = EncodedTextLimiter.limit(text, budget: rawBudget)
        return (
            requestedPageIndices.isEmpty ? [pageIndex] : requestedPageIndices,
            [
                pageIndex: RawPageText(
                    text: bounded.text,
                    wasTruncated: bounded.wasTruncated
                )
            ]
        )
    }

    private func pageText(
        at indices: [Int],
        in document: PDFDocument,
        rawTextBudget: EncodedTextBudget
    ) async throws -> [Int: RawPageText] {
        var result: [Int: RawPageText] = [:]
        for (offset, index) in indices.enumerated() {
            try Task.checkCancellation()
            autoreleasepool {
                if let text = document.page(at: index)?.string {
                    // PDFKit must materialize `page.string` on the main actor,
                    // but avoid carrying a multi-megabyte page through several
                    // normalization copies when only a bounded excerpt can be
                    // transmitted.
                    let bounded = EncodedTextLimiter.limit(
                        text,
                        budget: rawTextBudget
                    )
                    result[index] = RawPageText(
                        text: bounded.text,
                        wasTruncated: bounded.wasTruncated
                    )
                }
            }
            if offset + 1 < indices.count {
                await Task.yield()
                try Task.checkCancellation()
            }
        }
        return result
    }

    private func rawTextBudget(for budget: PDFAIContextBudget) -> EncodedTextBudget {
        let scaledLimit = budget.maximumCharactersPerPage > 32_000
            ? 64_000
            : budget.maximumCharactersPerPage * 2
        return EncodedTextBudget(
            maximumCharacters: min(64_000, max(8_000, scaledLimit))
        )
    }

    private func validPageIndices(
        _ indices: [Int],
        pageCount: Int
    ) -> [Int] {
        var seen: Set<Int> = []
        return indices.filter {
            $0 >= 0 && $0 < pageCount && seen.insert($0).inserted
        }
    }

    private func validPageIndices(
        in range: ClosedRange<Int>,
        pageCount: Int
    ) -> [Int] {
        guard pageCount > 0 else { return [] }
        let lowerBound = max(0, range.lowerBound)
        let upperBound = min(pageCount - 1, range.upperBound)
        guard lowerBound <= upperBound else { return [] }
        return Array(lowerBound...upperBound)
    }

    nonisolated static func normalizedText(_ text: String) -> String {
        let canonical = text
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var output: [String] = []
        var priorWasBlank = false

        for rawLine in canonical.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = rawLine
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if line.isEmpty {
                if !priorWasBlank, !output.isEmpty {
                    output.append("")
                }
                priorWasBlank = true
            } else {
                output.append(line)
                priorWasBlank = false
            }
        }
        while output.last?.isEmpty == true {
            output.removeLast()
        }
        return output.joined(separator: "\n")
    }
}

enum PDFRepresentativePageSampler {
    /// Selects a stable document-wide sample while preserving document order.
    /// With three or more slots, first, last, and the preferred/current page
    /// are all retained before evenly spaced pages fill the remaining budget.
    static func indices(
        from requestedIndices: [Int],
        maximumCount: Int,
        preferred: [Int] = []
    ) -> [Int] {
        var seen: Set<Int> = []
        let candidates = requestedIndices.filter { seen.insert($0).inserted }
        let limit = min(max(0, maximumCount), candidates.count)
        guard limit > 0 else { return [] }
        guard candidates.count > limit else { return candidates }

        let candidateSet = Set(candidates)
        var selected: Set<Int> = []
        func add(_ index: Int?) {
            guard
                selected.count < limit,
                let index,
                candidateSet.contains(index)
            else { return }
            selected.insert(index)
        }

        // Endpoints make long-document summaries representative. The current
        // page is next in priority and is included whenever the budget permits.
        add(candidates.first)
        if limit > 1 { add(candidates.last) }
        for index in preferred where selected.count < limit {
            add(index)
        }

        if selected.count < limit {
            let denominator = max(1, limit - 1)
            for slot in 0..<limit where selected.count < limit {
                let position = Int(
                    (Double(slot) * Double(candidates.count - 1)
                        / Double(denominator)).rounded()
                )
                add(candidates[position])
            }
        }

        // Rounding and preselected pages can collide. Fill remaining slots in
        // document order, which is deterministic and allocation-light.
        if selected.count < limit {
            for index in candidates where selected.count < limit {
                add(index)
            }
        }
        return candidates.filter(selected.contains)
    }
}

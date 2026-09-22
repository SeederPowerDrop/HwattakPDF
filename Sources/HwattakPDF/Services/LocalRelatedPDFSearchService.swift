// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Searches only PDFs the user already opened or explicitly granted through a
/// recent-document bookmark. No query, text sample, or result leaves the Mac.
@MainActor
struct LocalRelatedPDFSearchService {
    private struct Candidate: Sendable {
        let url: URL
        let displayName: String
        let source: PDFRelatedDocumentSource
        let preferredPageIndices: [Int]
        let ordinal: Int
    }

    private struct IndexedCandidate: Sendable {
        let candidate: Candidate
        let sample: PDFLocalTextSample
    }

    private let sampler: any PDFLocalTextSampling

    init(sampler: any PDFLocalTextSampling = TransientPDFTextSampler()) {
        self.sampler = sampler
    }

    func search(
        query: String,
        workspace: MultiDocumentWorkspaceState,
        excluding excludedURL: URL? = nil,
        budget: PDFRelatedSearchBudget = .standard
    ) async -> [PDFRelatedDocumentResult] {
        let queryTerms = PDFLexicalRelevanceEngine.orderedTerms(
            in: query,
            limit: budget.maximumQueryTerms
        )
        guard !queryTerms.isEmpty else { return [] }

        let excludedPath = excludedURL.map(Self.canonicalPath(for:))
        var candidates: [Candidate] = []
        var paths: Set<String> = []
        var retainedRecentAccesses: [RecentDocumentAccess] = []

        for session in workspace.allTabs {
            guard let url = session.workspace.documentURL else { continue }
            let path = Self.canonicalPath(for: url)
            guard path != excludedPath, paths.insert(path).inserted else { continue }
            candidates.append(
                Candidate(
                    url: url,
                    displayName: session.workspace.displayName,
                    source: .openTab(session.id),
                    preferredPageIndices: [session.workspace.currentPageIndex],
                    ordinal: candidates.count
                )
            )
        }

        if let recentStore = workspace.recentDocumentsStore {
            for recent in workspace.recentDocuments {
                guard let access = try? recentStore.resolve(id: recent.id) else {
                    continue
                }
                retainedRecentAccesses.append(access)
                let path = Self.canonicalPath(for: access.url)
                guard path != excludedPath, paths.insert(path).inserted else { continue }
                candidates.append(
                    Candidate(
                        url: access.url,
                        displayName: recent.displayName,
                        source: .recentDocument(recent.id),
                        preferredPageIndices: [],
                        ordinal: candidates.count
                    )
                )
            }
        }

        defer { withExtendedLifetime(retainedRecentAccesses) {} }
        let candidatesToScan = preRankedCandidates(
            candidates,
            queryTerms: queryTerms,
            maximumCount: budget.maximumDocumentsScanned
        )
        var indexed: [IndexedCandidate] = []
        indexed.reserveCapacity(candidatesToScan.count)

        for candidate in candidatesToScan {
            guard !Task.isCancelled else { break }
            let request = PDFLocalTextSampleRequest(
                preferredPageIndices: candidate.preferredPageIndices,
                maximumPages: budget.maximumPagesPerDocument,
                maximumCharactersPerPage: budget.maximumCharactersPerPage,
                maximumCharacters: budget.maximumCharactersPerDocument
            )
            guard let sample = try? await sampler.sample(
                url: candidate.url,
                request: request
            ) else { continue }
            indexed.append(
                IndexedCandidate(candidate: candidate, sample: sample)
            )
        }

        guard !Task.isCancelled else { return [] }
        return PDFLexicalRelevanceEngine.rank(
            query: query,
            queryTerms: queryTerms,
            candidates: indexed.map { indexed in
                PDFLexicalRelevanceEngine.Candidate(
                    url: indexed.candidate.url,
                    displayName: indexed.candidate.displayName,
                    source: indexed.candidate.source,
                    sample: indexed.sample
                )
            },
            maximumResults: budget.maximumResults
        )
    }

    private func preRankedCandidates(
        _ candidates: [Candidate],
        queryTerms: [String],
        maximumCount: Int
    ) -> [Candidate] {
        let querySet = Set(queryTerms)
        return candidates.sorted { lhs, rhs in
            let lhsMatches = querySet.intersection(
                PDFLexicalRelevanceEngine.tokens(in: lhs.displayName)
            ).count
            let rhsMatches = querySet.intersection(
                PDFLexicalRelevanceEngine.tokens(in: rhs.displayName)
            ).count
            if lhsMatches != rhsMatches { return lhsMatches > rhsMatches }

            let lhsIsOpen: Bool
            if case .openTab = lhs.source { lhsIsOpen = true } else { lhsIsOpen = false }
            let rhsIsOpen: Bool
            if case .openTab = rhs.source { rhsIsOpen = true } else { rhsIsOpen = false }
            if lhsIsOpen != rhsIsOpen { return lhsIsOpen }
            return lhs.ordinal < rhs.ordinal
        }
        .prefix(maximumCount)
        .map { $0 }
    }

    private static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
    }
}

enum PDFLexicalRelevanceEngine {
    struct Candidate: Sendable {
        let url: URL
        let displayName: String
        let source: PDFRelatedDocumentSource
        let sample: PDFLocalTextSample
    }

    private struct DocumentIndex {
        let candidate: Candidate
        let frequencies: [String: Int]
        let tokenCount: Int
        let titleTerms: Set<String>
        let pages: [(page: PDFLocalTextPage, frequencies: [String: Int])]
    }

    static func rank(
        query: String,
        queryTerms: [String],
        candidates: [Candidate],
        maximumResults: Int
    ) -> [PDFRelatedDocumentResult] {
        guard !queryTerms.isEmpty, !candidates.isEmpty else { return [] }
        let queryFrequencies = frequencies(queryTerms)
        let orderedUniqueTerms = orderedUnique(queryTerms)
        let indices = candidates.map { candidate -> DocumentIndex in
            let titleTokens = tokens(in: candidate.displayName)
            let pageIndices = candidate.sample.pages.map { page in
                (page, frequencies(tokens(in: page.text)))
            }
            var documentFrequencies = frequencies(titleTokens)
            var tokenCount = titleTokens.count
            for pageIndex in pageIndices {
                for (term, count) in pageIndex.1 {
                    documentFrequencies[term, default: 0] += count
                    tokenCount += count
                }
            }
            return DocumentIndex(
                candidate: candidate,
                frequencies: documentFrequencies,
                tokenCount: tokenCount,
                titleTerms: Set(titleTokens),
                pages: pageIndices
            )
        }
        let nonemptyIndices = indices.filter { !$0.frequencies.isEmpty }
        guard !nonemptyIndices.isEmpty else { return [] }

        let documentCount = Double(nonemptyIndices.count)
        let averageLength = max(
            1,
            Double(nonemptyIndices.reduce(0) { $0 + $1.tokenCount }) / documentCount
        )
        var inverseDocumentFrequency: [String: Double] = [:]
        for term in orderedUniqueTerms {
            let containingCount = Double(
                nonemptyIndices.count { ($0.frequencies[term] ?? 0) > 0 }
            )
            inverseDocumentFrequency[term] = log(
                1 + (documentCount - containingCount + 0.5) / (containingCount + 0.5)
            )
        }

        let compactQuery = normalizedForPhraseMatch(query)
        var results: [PDFRelatedDocumentResult] = []
        for index in nonemptyIndices {
            let length = Double(max(1, index.tokenCount))
            var score = 0.0
            var matchedTerms: Set<String> = []
            for term in orderedUniqueTerms {
                let count = index.frequencies[term] ?? 0
                guard count > 0 else { continue }
                matchedTerms.insert(term)
                let termFrequency = Double(count)
                let k1 = 1.35
                let b = 0.72
                let normalizedFrequency = termFrequency * (k1 + 1) / (
                    termFrequency + k1 * (1 - b + b * length / averageLength)
                )
                let queryWeight = 1 + log(Double(queryFrequencies[term] ?? 1))
                score += (inverseDocumentFrequency[term] ?? 0) * normalizedFrequency * queryWeight
            }
            guard !matchedTerms.isEmpty else { continue }

            let titleMatchCount = index.titleTerms.intersection(matchedTerms).count
            score += Double(titleMatchCount) * 0.9
            score *= 1 + 0.35 * Double(matchedTerms.count) / Double(orderedUniqueTerms.count)

            if compactQuery.count >= 4, compactQuery.count <= 180 {
                let combinedText = normalizedForPhraseMatch(
                    index.candidate.sample.pages.map(\.text).joined(separator: " ")
                )
                if combinedText.contains(compactQuery) {
                    score += 2.0
                }
            }

            let matches = pageMatches(
                for: index,
                queryTerms: orderedUniqueTerms,
                inverseDocumentFrequency: inverseDocumentFrequency
            )
            results.append(
                PDFRelatedDocumentResult(
                    documentURL: index.candidate.url,
                    displayName: index.candidate.displayName,
                    pageCount: index.candidate.sample.pageCount,
                    source: index.candidate.source,
                    score: score,
                    matches: matches
                )
            )
        }

        return results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        .prefix(max(1, maximumResults))
        .map { $0 }
    }

    static func orderedTerms(in text: String, limit: Int) -> [String] {
        Array(orderedUnique(tokens(in: text)).prefix(max(1, limit)))
    }

    static func tokens(in text: String) -> [String] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var words: [String] = []
        var buffer = ""

        func appendBuffer() {
            guard !buffer.isEmpty else { return }
            let characters = Array(buffer)
            if characters.count >= 2 {
                words.append(buffer)
            }
            if containsCJKOrHangul(buffer), characters.count >= 2 {
                for index in 0..<(characters.count - 1) {
                    words.append(String(characters[index...index + 1]))
                }
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                buffer.unicodeScalars.append(scalar)
            } else {
                appendBuffer()
            }
        }
        appendBuffer()

        // A one-character query is still useful for a chemical symbol or a
        // variable. Document tokenization keeps the normal two-character
        // threshold to avoid an enormous noisy index.
        if words.isEmpty {
            let compact = folded.trimmingCharacters(in: .whitespacesAndNewlines)
            if compact.count == 1 { return [compact] }
        }
        return words
    }

    private static func pageMatches(
        for index: DocumentIndex,
        queryTerms: [String],
        inverseDocumentFrequency: [String: Double]
    ) -> [PDFRelatedPageMatch] {
        index.pages.compactMap { page, frequencies -> PDFRelatedPageMatch? in
            let matched = queryTerms.filter { (frequencies[$0] ?? 0) > 0 }
            guard !matched.isEmpty else { return nil }
            let score = matched.reduce(0.0) { partial, term in
                partial + (inverseDocumentFrequency[term] ?? 0)
                    * (1 + log(Double(frequencies[term] ?? 1)))
            }
            return PDFRelatedPageMatch(
                pageIndex: page.pageIndex,
                pageNumber: page.pageIndex + 1,
                snippet: snippet(from: page.text, around: matched),
                matchedTerms: Array(matched.prefix(8)),
                score: score
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.pageIndex < rhs.pageIndex
        }
        .prefix(3)
        .map { $0 }
    }

    private static func snippet(from text: String, around terms: [String]) -> String {
        let compact = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !compact.isEmpty else { return "" }
        let firstRange = terms.compactMap {
            compact.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }
        .min { lhs, rhs in lhs.lowerBound < rhs.lowerBound }

        let center = firstRange?.lowerBound ?? compact.startIndex
        let centerOffset = compact.distance(from: compact.startIndex, to: center)
        let startOffset = max(0, centerOffset - 90)
        let endOffset = min(compact.count, max(startOffset + 1, centerOffset + 170))
        let start = compact.index(compact.startIndex, offsetBy: startOffset)
        let end = compact.index(compact.startIndex, offsetBy: endOffset)
        let prefix = startOffset > 0 ? "…" : ""
        let suffix = endOffset < compact.count ? "…" : ""
        return prefix + String(compact[start..<end]) + suffix
    }

    private static func frequencies(_ tokens: [String]) -> [String: Int] {
        tokens.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func orderedUnique(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        return terms.filter { seen.insert($0).inserted }
    }

    private static func normalizedForPhraseMatch(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    }

    private static func containsCJKOrHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0x3040...0x30FF:
                true
            default:
                false
            }
        }
    }
}

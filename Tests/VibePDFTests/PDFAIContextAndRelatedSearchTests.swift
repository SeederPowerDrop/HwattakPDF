// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

final class PDFAIContextAndRelatedSearchTests: XCTestCase {
    func testRepresentativeSamplingIncludesDocumentEndsAndCurrentPage() {
        XCTAssertEqual(
            PDFRepresentativePageSampler.indices(
                from: Array(0..<100),
                maximumCount: 5,
                preferred: [50]
            ),
            [0, 25, 50, 74, 99]
        )
        XCTAssertEqual(
            PDFRepresentativePageSampler.indices(
                from: Array(0..<10),
                maximumCount: 3,
                preferred: [5]
            ),
            [0, 5, 9]
        )
    }

    @MainActor
    func testWholeDocumentContextIsBoundedAndKeepsPageCitations() async throws {
        let fixture = try makeTextPDF(
            pages: (0..<10).map { "Page \($0 + 1) unique material for analysis." }
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.setCurrentPage(5)

        let context = try await PDFAIContextExtractor().extract(
            from: workspace,
            scope: .wholeDocument,
            budget: PDFAIContextBudget(
                maximumCharacters: 10_000,
                maximumPages: 3,
                maximumCharactersPerPage: 2_000
            )
        )

        XCTAssertEqual(context.includedPageIndices, [0, 5, 9])
        XCTAssertEqual(context.sources.map(\.pageNumber), [1, 6, 10])
        XCTAssertEqual(context.sources.map(\.citationID), ["S1", "S2", "S3"])
        XCTAssertEqual(context.omittedPageCount, 7)
        XCTAssertTrue(context.wasTruncated)
        XCTAssertTrue(context.promptText.contains("[S2 | context.pdf | p.6]"))
        XCTAssertFalse(context.promptText.contains(fixture.directory.path))
    }

    @MainActor
    func testSelectionContextContainsOnlySelectedText() async throws {
        let fixture = try makeTextPDF(
            pages: ["Public introduction. SelectedPhrase. Closing material."]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        let selection = try XCTUnwrap(
            workspace.document?.findString(
                "SelectedPhrase",
                withOptions: []
            ).first
        )
        workspace.currentSelection = selection

        let context = try await PDFAIContextExtractor().extract(
            from: workspace,
            scope: .selection
        )

        XCTAssertEqual(context.sources.count, 1)
        XCTAssertEqual(context.sources[0].kind, .selection)
        XCTAssertTrue(context.sources[0].text.contains("SelectedPhrase"))
        XCTAssertFalse(context.sources[0].text.contains("Public introduction"))
    }

    @MainActor
    func testExplicitPageIndicesDoNotReadMutableWorkspacePageSelection() async throws {
        let fixture = try makeTextPDF(
            pages: (1...4).map { "Explicit page \($0) private context." }
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.selectedPages = [1, 2]
        workspace.setCurrentPage(2)

        let context = try await PDFAIContextExtractor().extract(
            from: workspace,
            scope: .pageIndices([3, 0, 3])
        )

        XCTAssertEqual(context.scope, .pageIndices([3, 0, 3]))
        XCTAssertEqual(context.includedPageIndices, [0, 3])
        XCTAssertEqual(context.sources.map(\.pageNumber), [1, 4])
        XCTAssertTrue(context.sources[0].text.contains("Explicit page 1"))
        XCTAssertTrue(context.sources[1].text.contains("Explicit page 4"))
        XCTAssertFalse(context.includedPageIndices.contains(1))
        XCTAssertFalse(context.includedPageIndices.contains(2))
    }

    @MainActor
    func testContextNeverExceedsCharacterBudgets() async throws {
        let fixture = try makeTextPDF(
            pages: [String(repeating: "abcdef ", count: 100), String(repeating: "uvwxyz ", count: 100)]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))

        let context = try await PDFAIContextExtractor().extract(
            from: workspace,
            scope: .wholeDocument,
            budget: PDFAIContextBudget(
                maximumCharacters: 75,
                maximumPages: 2,
                maximumCharactersPerPage: 50
            )
        )

        XCTAssertLessThanOrEqual(context.characterCount, 75)
        XCTAssertLessThanOrEqual(context.sources[0].text.count, 50)
        XCTAssertTrue(context.wasTruncated)
    }

    func testPathologicalGraphemeCannotBypassPDFContextOrPromptBudgets() {
        let budget = PDFAIContextBudget(
            maximumCharacters: 120,
            maximumPages: 1,
            maximumCharactersPerPage: 80
        )
        let pathological = "a" + String(
            repeating: "\u{0301}",
            count: budget.maximumUTF16CodeUnitsPerPage + 100
        )
        XCTAssertEqual(pathological.count, 1)

        let boundedSource = EncodedTextLimiter.limit(
            pathological,
            budget: budget.perPageTextBudget
        )
        let source = PDFAIContextSource(
            citationID: "S1",
            documentURL: nil,
            documentTitle: "context.pdf",
            pageIndex: 0,
            pageNumber: 1,
            text: boundedSource.text,
            kind: .pageText,
            wasTruncated: boundedSource.wasTruncated
        )
        let context = PDFAIContextBundle(
            scope: .currentPage,
            documentTitle: "context.pdf",
            documentURL: nil,
            documentPageCount: 1,
            sources: [source],
            omittedPageCount: 0,
            wasTruncated: boundedSource.wasTruncated,
            promptTextBudget: budget.promptTextBudget
        )

        XCTAssertTrue(context.wasTruncated)
        XCTAssertLessThanOrEqual(
            source.text.utf8.count,
            budget.maximumUTF8BytesPerPage
        )
        XCTAssertLessThanOrEqual(
            source.text.utf16.count,
            budget.maximumUTF16CodeUnitsPerPage
        )
        XCTAssertLessThanOrEqual(
            context.promptText.utf8.count,
            budget.promptTextBudget.maximumUTF8Bytes
        )
        XCTAssertEqual(context.promptTextUTF8ByteCount, context.promptText.utf8.count)
    }

    @MainActor
    func testExtractorRejectsHeaderOnlySourceWhenFirstScalarExceedsEncodedBudget() async throws {
        // Hangul starts with a three-byte UTF-8 scalar. A two-byte extraction
        // budget therefore cannot accept even the first scalar. Exercise the
        // real extractor (not only the limiter) so a regression cannot append
        // an empty source body, emit a citation-only prompt, or keep advancing
        // through pages without consuming any budget.
        let fixture = try makeTextPDF(pages: ["한글 문서"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))

        do {
            _ = try await PDFAIContextExtractor().extract(
                from: workspace,
                scope: .currentPage,
                budget: PDFAIContextBudget(
                    maximumCharacters: 20,
                    maximumPages: 1,
                    maximumCharactersPerPage: 20,
                    maximumUTF8Bytes: 2,
                    maximumUTF16CodeUnits: 20,
                    maximumUTF8BytesPerPage: 2,
                    maximumUTF16CodeUnitsPerPage: 20
                )
            )
            XCTFail("An empty source must not be represented as extractable text.")
        } catch let error as PDFAIContextExtractionError {
            XCTAssertEqual(error, .noExtractableText)
        }
    }

    @MainActor
    func testHugePageRangeIsClampedBeforeIndexAllocation() async throws {
        let fixture = try makeTextPDF(
            pages: (0..<5).map { "Bounded page \($0 + 1)" }
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.setCurrentPage(2)

        let context = try await PDFAIContextExtractor().extract(
            from: workspace,
            scope: .pageRange(Int.min...Int.max),
            budget: PDFAIContextBudget(
                maximumCharacters: 10_000,
                maximumPages: 3,
                maximumCharactersPerPage: 2_000
            )
        )

        XCTAssertEqual(context.includedPageIndices, [0, 2, 4])
        XCTAssertEqual(context.omittedPageCount, 2)
    }

    func testLexicalRankingSupportsKoreanAndReturnsPageSnippet() {
        let relatedURL = URL(fileURLWithPath: "/tmp/quantum.pdf")
        let unrelatedURL = URL(fileURLWithPath: "/tmp/recipe.pdf")
        let results = PDFLexicalRelevanceEngine.rank(
            query: "양자 역학 파동 함수",
            queryTerms: PDFLexicalRelevanceEngine.orderedTerms(
                in: "양자 역학 파동 함수",
                limit: 50
            ),
            candidates: [
                .init(
                    url: unrelatedURL,
                    displayName: "요리법.pdf",
                    source: .recentDocument(UUID()),
                    sample: PDFLocalTextSample(
                        documentURL: unrelatedURL,
                        pageCount: 1,
                        pages: [
                            PDFLocalTextPage(
                                pageIndex: 0,
                                text: "채소를 볶고 소금으로 간한다.",
                                wasTruncated: false
                            )
                        ]
                    )
                ),
                .init(
                    url: relatedURL,
                    displayName: "양자역학 강의.pdf",
                    source: .openTab(UUID()),
                    sample: PDFLocalTextSample(
                        documentURL: relatedURL,
                        pageCount: 8,
                        pages: [
                            PDFLocalTextPage(
                                pageIndex: 3,
                                text: "양자 역학에서 파동 함수는 상태와 확률 진폭을 나타낸다.",
                                wasTruncated: false
                            )
                        ]
                    )
                )
            ],
            maximumResults: 5
        )

        XCTAssertEqual(results.map(\.documentURL), [relatedURL])
        XCTAssertEqual(results[0].matches.first?.pageNumber, 4)
        XCTAssertTrue(results[0].matches.first?.snippet.contains("파동 함수") == true)
    }

    func testLexicalRankingCanFindScannedPDFByFilenameOnly() {
        let url = URL(fileURLWithPath: "/tmp/고분자화학 연구.pdf")
        let results = PDFLexicalRelevanceEngine.rank(
            query: "고분자 화학",
            queryTerms: PDFLexicalRelevanceEngine.orderedTerms(
                in: "고분자 화학",
                limit: 20
            ),
            candidates: [
                .init(
                    url: url,
                    displayName: "고분자화학 연구.pdf",
                    source: .recentDocument(UUID()),
                    sample: PDFLocalTextSample(
                        documentURL: url,
                        pageCount: 50,
                        pages: []
                    )
                )
            ],
            maximumResults: 5
        )

        XCTAssertEqual(results.first?.documentURL, url)
        XCTAssertTrue(results.first?.matches.isEmpty == true)
    }

    @MainActor
    func testRelatedSearchDoesNotResumeHibernatedTabAndKeepsTabReference() async throws {
        let url = URL(fileURLWithPath: "/tmp/hibernated-related.pdf")
        let hibernated = PDFWorkspaceState()
        hibernated.restoreHibernated(
            url: url,
            pageCount: 120,
            currentPageIndex: 77,
            selectedPages: [77]
        )
        let workspace = MultiDocumentWorkspaceState(initialWorkspace: hibernated)
        let sessionID = try XCTUnwrap(workspace.activeTabID)
        let sampler = StubPDFTextSampler(
            samples: [
                url: PDFLocalTextSample(
                    documentURL: url,
                    pageCount: 120,
                    pages: [
                        PDFLocalTextPage(
                            pageIndex: 77,
                            text: "행렬 고유값과 선형대수 문제 풀이",
                            wasTruncated: false
                        )
                    ]
                )
            ]
        )

        let results = await LocalRelatedPDFSearchService(sampler: sampler).search(
            query: "행렬 고유값",
            workspace: workspace
        )

        XCTAssertTrue(hibernated.isHibernated)
        XCTAssertNil(hibernated.document)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].source, .openTab(sessionID))
        let requests = await sampler.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].request.preferredPageIndices, [77])
    }

    @MainActor
    func testTransientSamplerReadsOnlyRepresentativePagesWithinBudget() async throws {
        let fixture = try makeTextPDF(
            pages: (0..<10).map { "Sampler page \($0 + 1) distinctive content." }
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let sampler = TransientPDFTextSampler(maximumCachedSamples: 2)

        let sample = try await sampler.sample(
            url: fixture.url,
            request: PDFLocalTextSampleRequest(
                preferredPageIndices: [5],
                maximumPages: 3,
                maximumCharactersPerPage: 1_000,
                maximumCharacters: 3_000
            )
        )

        XCTAssertEqual(sample.pageCount, 10)
        XCTAssertEqual(sample.pages.map(\.pageIndex), [0, 5, 9])
        XCTAssertTrue(sample.pages[1].text.contains("Sampler page 6"))
    }

    func testTransientSamplerBoundsPathologicalCombiningAndZWJTextBeforeCaching() {
        let rawBudget = EncodedTextBudget(
            maximumCharacters: 64,
            maximumUTF8Bytes: 256,
            maximumUTF16CodeUnits: 128
        )
        let outputBudget = EncodedTextBudget(
            maximumCharacters: 16,
            maximumUTF8Bytes: 64,
            maximumUTF16CodeUnits: 32
        )
        let combiningGrapheme = "a" + String(
            repeating: "\u{0301}",
            count: 2_000
        )
        let zwjGrapheme = "👩" + String(
            repeating: "\u{200D}👩",
            count: 1_000
        )

        // Both inputs look like one user-perceived Character, which proves a
        // grapheme-only prefix would not be a meaningful memory/cache limit.
        XCTAssertEqual(combiningGrapheme.count, 1)
        XCTAssertEqual(zwjGrapheme.count, 1)

        for pathologicalText in [combiningGrapheme, zwjGrapheme] {
            let excerpt = TransientPDFTextSampler.boundedNormalizedExcerpt(
                pathologicalText,
                rawBudget: rawBudget,
                outputBudget: outputBudget
            )

            XCTAssertTrue(excerpt.wasTruncated)
            XCTAssertLessThanOrEqual(
                excerpt.characterCount,
                outputBudget.maximumCharacters
            )
            XCTAssertLessThanOrEqual(
                excerpt.utf8ByteCount,
                outputBudget.maximumUTF8Bytes
            )
            XCTAssertLessThanOrEqual(
                excerpt.utf16CodeUnitCount,
                outputBudget.maximumUTF16CodeUnits
            )
        }
    }

    @MainActor
    private func makeTextPDF(pages: [String]) throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-AI-Context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("context.pdf")
        let result = PDFDocument()

        for (index, text) in pages.enumerated() {
            let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 480, height: 640))
            textView.backgroundColor = .white
            textView.textColor = .black
            textView.font = .systemFont(ofSize: 18)
            textView.string = text
            let data = textView.dataWithPDF(inside: textView.bounds)
            let pageDocument = try XCTUnwrap(PDFDocument(data: data))
            let page = try XCTUnwrap(pageDocument.page(at: 0))
            result.insert(page, at: index)
        }
        XCTAssertTrue(result.write(to: url))
        return (directory, url)
    }
}

private actor StubPDFTextSampler: PDFLocalTextSampling {
    struct Invocation: Sendable {
        let url: URL
        let request: PDFLocalTextSampleRequest
    }

    let samples: [URL: PDFLocalTextSample]
    private(set) var requests: [Invocation] = []

    init(samples: [URL: PDFLocalTextSample]) {
        self.samples = samples
    }

    func sample(
        url: URL,
        request: PDFLocalTextSampleRequest
    ) async throws -> PDFLocalTextSample {
        requests.append(Invocation(url: url, request: request))
        guard let sample = samples[url] else {
            throw PDFLocalTextSamplingError.unreadable(url)
        }
        return sample
    }
}

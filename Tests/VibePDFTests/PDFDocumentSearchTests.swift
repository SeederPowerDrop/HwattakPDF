// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

final class PDFDocumentSearchTests: XCTestCase {
    func testUnicodeNormalizerCoversKoreanEnglishJapaneseChineseAndArabic() throws {
        let cases: [(document: String, query: String, expected: String)] = [
            ("한글 검색", "한글 검색", "한글 검색"),
            ("CAFÉ ﬁle", "cafe file", "cafe file"),
            ("ＡＩとｶﾀｶﾅ", "aiとカタカナ", "aiとカタカナ"),
            ("长篇文档 分析", "长篇文档 分析", "长篇文档 分析"),
            ("ﻻ اَلْعِلْمُ", "لا العلم", "لا العلم")
        ]

        for item in cases {
            let document = try PDFUnicodeSearchNormalizer
                .normalizeDocumentText(item.document).text
            let query = PDFUnicodeSearchNormalizer.normalizeQuery(item.query)
            XCTAssertEqual(document, item.expected)
            XCTAssertEqual(query, item.expected)
            XCTAssertNotEqual(
                (document as NSString).range(of: query).location,
                NSNotFound,
                "Expected \(item.query) to match \(item.document)"
            )
        }
    }

    func testNormalizerMatchesPhrasesAcrossWhitespaceAndLineWrapHyphen() throws {
        let whitespace = try PDFUnicodeSearchNormalizer.normalizeDocumentText(
            "first\n\t   second"
        )
        XCTAssertEqual(whitespace.text, "first second")
        XCTAssertEqual(
            PDFUnicodeSearchNormalizer.normalizeQuery("first   second"),
            "first second"
        )

        let hyphenatedSource = "international research can be inter-\nnational too"
        let hyphenated = try PDFUnicodeSearchNormalizer.normalizeDocumentText(hyphenatedSource)
        let query = PDFUnicodeSearchNormalizer.normalizeQuery("international")
        let secondMatch = (hyphenated.text as NSString).range(
            of: query,
            options: [],
            range: NSRange(
                location: query.utf16.count,
                length: hyphenated.text.utf16.count - query.utf16.count
            )
        )
        let sourceRange = try XCTUnwrap(
            hyphenated.sourceRange(forNormalizedRange: secondMatch)
        )
        XCTAssertEqual(
            (hyphenatedSource as NSString).substring(with: sourceRange),
            "inter-\nnational"
        )
    }

    @MainActor
    func testDocumentSearchBuildsPageNavigatorSnippetsAndExactSelection() async throws {
        let fixture = try makeTextPDF(pages: [
            "Alpha needle one.",
            "This page is unrelated.",
            "Second NEEDLE context. Another needle follows."
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))

        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        XCTAssertEqual(workspace.searchCompletedQuery, "needle")
        XCTAssertEqual(workspace.searchNavigatorResults.map(\.pageIndex), [0, 2, 2])
        XCTAssertEqual(workspace.searchProgress.completedPages, 3)
        XCTAssertEqual(workspace.searchProgress.totalPages, 3)
        XCTAssertEqual(workspace.searchProgress.resultCount, 3)
        XCTAssertFalse(workspace.searchResultsWereTruncated)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)

        for result in workspace.searchNavigatorResults {
            XCTAssertFalse(result.snippet.isEmpty)
            let range = try XCTUnwrap(result.snippetMatchRanges.first)
            XCTAssertNotNil(Range(range, in: result.snippet))
            XCTAssertEqual(result.matchedText.lowercased(), "needle")
        }

        let lastID = try XCTUnwrap(workspace.searchNavigatorResults.last?.id)
        workspace.selectSearchResult(id: lastID)
        XCTAssertEqual(workspace.currentPageIndex, 2)
        XCTAssertEqual(workspace.searchResultIndex, 2)
        XCTAssertEqual(workspace.searchResults.count, 1)
        XCTAssertTrue(workspace.activeSearchSelection === workspace.searchResults.first)
        XCTAssertEqual(workspace.activeSearchSelection?.string?.lowercased(), "needle")

        workspace.showNextSearchResult()
        XCTAssertEqual(workspace.searchResultIndex, 0)
        XCTAssertEqual(workspace.currentPageIndex, 0)
        workspace.showNextSearchResult(backwards: true)
        XCTAssertEqual(workspace.searchResultIndex, 2)
        XCTAssertEqual(workspace.currentPageIndex, 2)
    }

    @MainActor
    func testSearchResultActivationAndResetOwnCurrentSelectionByIdentity() async throws {
        let fixture = try makeTextPDF(pages: ["prefix needle middle needle suffix"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        let first = try XCTUnwrap(workspace.activeSearchSelection)
        XCTAssertTrue(workspace.currentSelection === first)

        workspace.showNextSearchResult()
        let second = try XCTUnwrap(workspace.activeSearchSelection)
        XCTAssertFalse(second === first)
        XCTAssertTrue(workspace.currentSelection === second)

        workspace.clearSearch()
        XCTAssertNil(workspace.activeSearchSelection)
        XCTAssertNil(
            workspace.currentSelection,
            "Clearing search must remove the exact selection that search installed."
        )

        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)
        let searchSelection = try XCTUnwrap(workspace.activeSearchSelection)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let ordinarySelection = try XCTUnwrap(
            page.selection(for: NSRange(location: 0, length: 6))
        )
        XCTAssertFalse(ordinarySelection === searchSelection)
        workspace.currentSelection = ordinarySelection

        workspace.clearSearch()
        XCTAssertNil(workspace.activeSearchSelection)
        XCTAssertTrue(
            workspace.currentSelection === ordinarySelection,
            "A newer user selection must survive search reset."
        )
    }

    @MainActor
    func testInvalidSearchResultClearsOnlyTheSelectionStillOwnedBySearch() async throws {
        let ownedFixture = try makeTextPDF(pages: ["prefix needle suffix"])
        addTeardownBlock { try? FileManager.default.removeItem(at: ownedFixture.directory) }
        let ownedWorkspace = PDFWorkspaceState()
        XCTAssertTrue(ownedWorkspace.open(url: ownedFixture.url))
        ownedWorkspace.searchText = "needle"
        ownedWorkspace.performSearch()
        await waitForSearchToFinish(ownedWorkspace)
        let ownedSelection = try XCTUnwrap(ownedWorkspace.activeSearchSelection)
        XCTAssertTrue(ownedWorkspace.currentSelection === ownedSelection)

        ownedWorkspace.document?.removePage(at: 0)
        ownedWorkspace.selectSearchResult(at: 0)
        XCTAssertNil(ownedWorkspace.activeSearchSelection)
        XCTAssertNil(ownedWorkspace.currentSelection)

        let userFixture = try makeTextPDF(pages: ["prefix needle suffix"])
        addTeardownBlock { try? FileManager.default.removeItem(at: userFixture.directory) }
        let userWorkspace = PDFWorkspaceState()
        XCTAssertTrue(userWorkspace.open(url: userFixture.url))
        userWorkspace.searchText = "needle"
        userWorkspace.performSearch()
        await waitForSearchToFinish(userWorkspace)
        let page = try XCTUnwrap(userWorkspace.document?.page(at: 0))
        let ordinarySelection = try XCTUnwrap(
            page.selection(for: NSRange(location: 0, length: 6))
        )
        userWorkspace.currentSelection = ordinarySelection

        userWorkspace.document?.removePage(at: 0)
        userWorkspace.selectSearchResult(at: 0)
        XCTAssertNil(userWorkspace.activeSearchSelection)
        XCTAssertTrue(
            userWorkspace.currentSelection === ordinarySelection,
            "Invalidating a result must not erase a newer user selection."
        )
    }

    @MainActor
    func testSearchNavigationSynchronizesPDFViewAndWorkspaceSelection() async throws {
        let fixture = try makeTextPDF(pages: ["prefix needle middle needle suffix"])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "needle"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        let first = try XCTUnwrap(workspace.activeSearchSelection)
        workspace.currentSelection = nil

        let pdfView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        pdfView.document = workspace.document
        let coordinator = PDFKitViewer.Coordinator(state: workspace)
        coordinator.attach(to: pdfView)
        defer { coordinator.detach() }
        coordinator.applySearchSelection(first, to: pdfView)

        XCTAssertTrue(workspace.currentSelection === first)
        XCTAssertTrue(pdfView.currentSelection === first)

        workspace.showNextSearchResult()
        let second = try XCTUnwrap(workspace.activeSearchSelection)
        XCTAssertFalse(second === first)
        XCTAssertTrue(
            workspace.currentSelection === second,
            "The model must update as soon as a new search result becomes active."
        )
        coordinator.applySearchSelection(second, to: pdfView)
        XCTAssertTrue(pdfView.currentSelection === second)

        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let ordinarySelection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))
        workspace.currentSelection = ordinarySelection
        pdfView.setCurrentSelection(ordinarySelection, animate: false)
        workspace.clearSearch()
        coordinator.applySearchSelection(nil, to: pdfView)

        XCTAssertTrue(workspace.currentSelection === ordinarySelection)
        XCTAssertTrue(pdfView.currentSelection === ordinarySelection)
    }

    @MainActor
    func testPDFBackedMultilingualSearchNavigatesEachLanguagePage() async throws {
        let fixtures: [(text: String, query: String)] = [
            ("한국어 문서 검색 연습", "문서 검색"),
            ("Reviewing a CAFÉ document", "cafe document"),
            ("日本語の資料を検索します", "資料を検索"),
            ("中文长篇文档分析", "文档分析"),
            ("تحليل اَلْعِلْمُ والدراسة", "العلم")
        ]
        let fixture = try makeTextPDF(pages: fixtures.map(\.text))
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))

        for (pageIndex, item) in fixtures.enumerated() {
            workspace.searchText = item.query
            workspace.performSearch()
            await waitForSearchToFinish(workspace)
            XCTAssertEqual(
                workspace.searchNavigatorResults.first?.pageIndex,
                pageIndex,
                "Failed query: \(item.query)"
            )
            XCTAssertNotNil(workspace.activeSearchSelection)
            XCTAssertEqual(workspace.currentPageIndex, pageIndex)
        }
    }

    @MainActor
    func testQueryChangeCancelAndMutationCannotCommitStaleResults() async throws {
        let page = String(repeating: "first needle filler ", count: 4_000)
        let fixture = try makeTextPDF(pages: Array(repeating: page, count: 12))
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.setMode(.editing)

        workspace.searchText = "first"
        workspace.performSearch()
        XCTAssertTrue(workspace.isSearching)
        workspace.searchText = "second"
        XCTAssertFalse(workspace.isSearching)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertNil(workspace.activeSearchQuery)
        XCTAssertNil(workspace.searchCompletedQuery)

        workspace.performSearch()
        workspace.cancelSearch()
        XCTAssertFalse(workspace.isSearching)
        XCTAssertEqual(workspace.searchProgress.phase, .cancelled)
        XCTAssertFalse(workspace.isDirty)

        workspace.searchText = "needle"
        workspace.performSearch()
        workspace.movePage(from: 0, before: 2)
        XCTAssertFalse(workspace.isSearching)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertNil(workspace.activeSearchSelection)

        // Give the detached worker enough time to attempt a late return. Its
        // captured generation/revision must prevent any stale publication.
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertFalse(workspace.isSearching)
    }

    @MainActor
    func testImageOnlyDocumentOffersOCROnlyAfterFullScan() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scan.pdf")
        let document = PDFDocument()
        for index in 0..<2 {
            let image = NSImage(size: CGSize(width: 240, height: 320), flipped: false) { rect in
                (index == 0 ? NSColor.white : NSColor.lightGray).setFill()
                rect.fill()
                return true
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        XCTAssertTrue(document.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.searchText = "unavailable"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertEqual(workspace.searchUnsearchablePageCount, 2)
        XCTAssertTrue(workspace.searchRequiresOCR)
    }

    @MainActor
    func testBlankPageInOtherwiseSearchablePDFDoesNotClaimWholeDocumentNeedsOCR() async throws {
        let fixture = try makeTextPDF(pages: ["This page has a searchable text layer."])
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let document = try XCTUnwrap(PDFDocument(url: fixture.url))
        let blankImage = NSImage(size: CGSize(width: 240, height: 320), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        document.insert(try XCTUnwrap(PDFPage(image: blankImage)), at: 1)
        XCTAssertTrue(document.write(to: fixture.url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "not present anywhere"
        workspace.performSearch()
        await waitForSearchToFinish(workspace)

        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertEqual(workspace.searchUnsearchablePageCount, 1)
        XCTAssertFalse(workspace.searchRequiresOCR)
    }

    @MainActor
    func testLocalizationRefreshCancelsGenerationWithoutLeavingBusyOrLateResults() async throws {
        let densePage = String(repeating: "searchable localization text ", count: 4_000)
        let fixture = try makeTextPDF(pages: Array(repeating: densePage, count: 8))
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        workspace.searchText = "localization"
        workspace.performSearch()
        XCTAssertTrue(workspace.isSearching)

        workspace.refreshLocalization()
        XCTAssertFalse(workspace.isSearching)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
        XCTAssertNil(workspace.activeSearchSelection)
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertFalse(workspace.isSearching)
        XCTAssertTrue(workspace.searchNavigatorResults.isEmpty)
    }

    @MainActor
    func testPerPageSafetyLimitReportsOnlyActualTruncation() async throws {
        var configuration = PDFSearchEngine.Configuration.standard
        configuration.maximumResultsPerPage = 2
        let engine = PDFSearchEngine(configuration: configuration)

        let exactFixture = try makeTextPDF(pages: ["needle needle"])
        addTeardownBlock { try? FileManager.default.removeItem(at: exactFixture.directory) }
        let exactDocument = try XCTUnwrap(PDFDocument(url: exactFixture.url))
        let exact = try await engine.searchPage(
            in: exactDocument,
            pageIndex: 0,
            query: engine.prepare(query: "needle"),
            remainingResultCapacity: 10
        )
        XCTAssertEqual(exact.results.count, 2)
        XCTAssertFalse(exact.reachedPageLimit)

        let overflowFixture = try makeTextPDF(pages: ["needle needle needle"])
        addTeardownBlock { try? FileManager.default.removeItem(at: overflowFixture.directory) }
        let overflowDocument = try XCTUnwrap(PDFDocument(url: overflowFixture.url))
        let overflow = try await engine.searchPage(
            in: overflowDocument,
            pageIndex: 0,
            query: engine.prepare(query: "needle"),
            remainingResultCapacity: 10
        )
        XCTAssertEqual(overflow.results.count, 2)
        XCTAssertTrue(overflow.reachedPageLimit)
    }

    @MainActor
    func testGlobalLimitDistinguishesExactFinalMatchFromActualOmission() async throws {
        var configuration = PDFSearchEngine.Configuration.standard
        configuration.maximumResultCount = 4
        configuration.maximumResultsPerPage = 2
        configuration.publicationPageBatch = 1

        let exactFixture = try makeTextPDF(pages: [
            "needle needle",
            "needle needle"
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: exactFixture.directory) }
        let exactWorkspace = PDFWorkspaceState(searchEngineConfiguration: configuration)
        XCTAssertTrue(exactWorkspace.open(url: exactFixture.url))
        exactWorkspace.searchText = "needle"
        exactWorkspace.performSearch()
        await waitForSearchToFinish(exactWorkspace)
        XCTAssertEqual(exactWorkspace.searchNavigatorResults.count, 4)
        XCTAssertEqual(exactWorkspace.searchProgress.completedPages, 2)
        XCTAssertFalse(exactWorkspace.searchResultsWereTruncated)

        let unscannedFixture = try makeTextPDF(pages: [
            "needle needle",
            "needle needle",
            "needle needle"
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: unscannedFixture.directory) }
        let unscannedWorkspace = PDFWorkspaceState(searchEngineConfiguration: configuration)
        XCTAssertTrue(unscannedWorkspace.open(url: unscannedFixture.url))
        unscannedWorkspace.searchText = "needle"
        unscannedWorkspace.performSearch()
        await waitForSearchToFinish(unscannedWorkspace)
        XCTAssertEqual(unscannedWorkspace.searchNavigatorResults.count, 4)
        XCTAssertEqual(unscannedWorkspace.searchProgress.completedPages, 2)
        XCTAssertTrue(unscannedWorkspace.searchResultsWereTruncated)

        let samePageOverflowFixture = try makeTextPDF(pages: [
            "needle needle",
            "needle needle needle"
        ])
        addTeardownBlock {
            try? FileManager.default.removeItem(at: samePageOverflowFixture.directory)
        }
        let overflowWorkspace = PDFWorkspaceState(searchEngineConfiguration: configuration)
        XCTAssertTrue(overflowWorkspace.open(url: samePageOverflowFixture.url))
        overflowWorkspace.searchText = "needle"
        overflowWorkspace.performSearch()
        await waitForSearchToFinish(overflowWorkspace)
        XCTAssertEqual(overflowWorkspace.searchNavigatorResults.count, 4)
        XCTAssertEqual(overflowWorkspace.searchProgress.completedPages, 2)
        XCTAssertTrue(overflowWorkspace.searchResultsWereTruncated)
    }

    @MainActor
    private func waitForSearchToFinish(
        _ workspace: PDFWorkspaceState,
        timeoutIterations: Int = 1_000
    ) async {
        for _ in 0..<timeoutIterations {
            if !workspace.isSearching { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Search did not finish before the test timeout")
    }

    @MainActor
    private func makeTextPDF(pages: [String]) throws -> (directory: URL, url: URL) {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("multilingual-search.pdf")
        let result = PDFDocument()

        for (index, text) in pages.enumerated() {
            let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 720, height: 900))
            textView.backgroundColor = .white
            textView.textColor = .black
            textView.font = .systemFont(ofSize: 17)
            textView.isHorizontallyResizable = false
            textView.textContainer?.containerSize = CGSize(
                width: 680,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.widthTracksTextView = true
            textView.string = text
            let data = textView.dataWithPDF(inside: textView.bounds)
            let pageDocument = try XCTUnwrap(PDFDocument(data: data))
            result.insert(try XCTUnwrap(pageDocument.page(at: 0)), at: index)
        }
        XCTAssertTrue(result.write(to: url))
        return (directory, url)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-SearchTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

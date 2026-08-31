// SPDX-License-Identifier: MPL-2.0

import SwiftUI
import XCTest
@testable import VibePDF

final class SearchNavigatorPresentationTests: XCTestCase {
    func testReturnNavigatesForwardAndShiftReturnNavigatesBackward() {
        XCTAssertFalse(SearchKeyboardNavigation.isBackwards(modifiers: []))
        XCTAssertTrue(SearchKeyboardNavigation.isBackwards(modifiers: [.shift]))
        XCTAssertTrue(SearchKeyboardNavigation.isBackwards(modifiers: [.shift, .option]))
        XCTAssertFalse(SearchKeyboardNavigation.isBackwards(modifiers: [.command]))
    }

    func testSearchModeKeepsAReadableMinimumPanelSize() {
        XCTAssertEqual(
            DocumentSidebarMode.search.minimumPanelDimension(for: .left),
            250
        )
        XCTAssertEqual(
            DocumentSidebarMode.search.minimumPanelDimension(for: .right),
            250
        )
        XCTAssertEqual(
            DocumentSidebarMode.search.minimumPanelDimension(for: .top),
            210
        )
        XCTAssertEqual(
            DocumentSidebarMode.search.minimumPanelDimension(for: .bottom),
            210
        )
        XCTAssertNil(DocumentSidebarMode.pages.minimumPanelDimension(for: .left))
    }

    func testSearchResizePathsUseModeMinimumsInsteadOfThumbnailLayoutMinimums() {
        let thumbnailScale = PageSidebarPreferences.maximumThumbnailScale
        let layoutMode = PageSidebarLayoutMode.fourPages
        let verticalMinimum = DocumentSidebarMode.search.minimumPanelDimension(for: .left)!
        let horizontalMinimum = DocumentSidebarMode.search.minimumPanelDimension(for: .top)!

        XCTAssertGreaterThan(
            PageSidebarResizeMetrics.minimumPanelDimension(
                for: .left,
                layoutMode: layoutMode,
                thumbnailScale: thumbnailScale
            ),
            verticalMinimum,
            "This setup must exercise the former thumbnail-derived minimum regression."
        )
        XCTAssertLessThan(
            PageSidebarResizeMetrics.minimumPanelDimension(
                for: .top,
                layoutMode: layoutMode,
                thumbnailScale: thumbnailScale
            ),
            horizontalMinimum,
            "The compact page strip is shorter than search mode, so the search override must raise its minimum."
        )

        let resolved = PageSidebarResizeMetrics.resolvedDimension(
            preferredDimension: 100,
            placement: .left,
            availableLength: 1_200,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale,
            minimumDimensionOverride: verticalMinimum
        )
        let dragged = PageSidebarResizeMetrics.resizedDimension(
            startingDimension: 300,
            translation: -200,
            placement: .left,
            availableLength: 1_200,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale,
            minimumDimensionOverride: verticalMinimum
        )
        let keyboardAdjusted = PageSidebarResizeMetrics.adjustedDimension(
            250,
            steps: -1,
            placement: .left,
            availableLength: 1_200,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale,
            minimumDimensionOverride: verticalMinimum
        )
        let horizontalResolved = PageSidebarResizeMetrics.resolvedDimension(
            preferredDimension: 100,
            placement: .top,
            availableLength: 900,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale,
            minimumDimensionOverride: horizontalMinimum
        )

        XCTAssertEqual(resolved, 250)
        XCTAssertEqual(dragged, 250)
        XCTAssertEqual(keyboardAdjusted, 250)
        XCTAssertEqual(horizontalResolved, 210)
    }

    func testSearchResizeOverridePreservesPageModeAndCanvasConstraints() {
        let layoutMode = PageSidebarLayoutMode.fourPages
        let thumbnailScale = PageSidebarPreferences.maximumThumbnailScale
        let pageMinimum = PageSidebarResizeMetrics.minimumPanelDimension(
            for: .left,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale
        )
        let pageModeResolved = PageSidebarResizeMetrics.resolvedDimension(
            preferredDimension: 100,
            placement: .left,
            availableLength: 1_200,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale
        )
        let constrainedSearchResolved = PageSidebarResizeMetrics.resolvedDimension(
            preferredDimension: 500,
            placement: .left,
            availableLength: 800,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale,
            minimumDimensionOverride: 250
        )

        XCTAssertEqual(pageModeResolved, pageMinimum)
        XCTAssertEqual(
            constrainedSearchResolved,
            800 - PageSidebarResizeMetrics.minimumDocumentWidth
                - PageSidebarResizeMetrics.dividerHitLength
        )
    }

    func testWorkspacePassesSearchMinimumIntoEveryResizePath() throws {
        let workspaceSource = try source("Sources/VibePDF/Views/WorkspaceView.swift")
        let overrideCallCount = workspaceSource.components(
            separatedBy: "minimumDimensionOverride: sidebarMode.minimumPanelDimension"
        ).count - 1

        XCTAssertEqual(
            overrideCallCount,
            5,
            "Resolved, live drag, drag completion, accessibility/keyboard, and move-command paths must share the mode minimum."
        )
    }

    func testNoResultsDistinguishesPartialAndFullyUnsearchableDocuments() {
        XCTAssertEqual(
            SearchNavigatorEmptyContent.resolve(
                isSearching: false,
                queryIsEmpty: false,
                wasCancelled: false,
                completedPages: 3,
                totalPages: 10,
                requiresOCR: false,
                unsearchablePageCount: 3
            ),
            .partialOCR(unsearchablePageCount: 3)
        )
        XCTAssertEqual(
            SearchNavigatorEmptyContent.resolve(
                isSearching: false,
                queryIsEmpty: false,
                wasCancelled: false,
                completedPages: 3,
                totalPages: 3,
                requiresOCR: true,
                unsearchablePageCount: 3
            ),
            .fullOCR,
            "A fully textless document keeps the primary OCR state."
        )
        XCTAssertEqual(
            SearchNavigatorEmptyContent.resolve(
                isSearching: false,
                queryIsEmpty: false,
                wasCancelled: false,
                completedPages: 10,
                totalPages: 10,
                requiresOCR: false,
                unsearchablePageCount: 0
            ),
            .noMatches
        )
        XCTAssertEqual(
            SearchNavigatorEmptyContent.resolve(
                isSearching: false,
                queryIsEmpty: false,
                wasCancelled: true,
                completedPages: 5,
                totalPages: 100,
                requiresOCR: false,
                unsearchablePageCount: 2
            ),
            .cancelled(completedPages: 5, totalPages: 100),
            "Cancellation must take precedence over no-results and partial OCR claims."
        )
    }

    func testFindCommandIsScopedToAnAvailableFocusedDocumentScene() throws {
        let appSource = try source("Sources/VibePDF/App/VibePDFApp.swift")
        let tabSource = try source("Sources/VibePDF/Views/TabbedWorkspaceView.swift")
        let toolbarSource = try source("Sources/VibePDF/Views/WorkspaceToolbar.swift")

        XCTAssertTrue(appSource.contains("keyboardShortcut(\"f\", modifiers: .command)"))
        XCTAssertTrue(appSource.contains("documentSearchAvailable != true"))
        XCTAssertTrue(tabSource.contains("!isComparing && workspace.activeWorkspace?.document != nil"))
        XCTAssertTrue(toolbarSource.contains("for: .focusDocumentSearch"))
        XCTAssertTrue(toolbarSource.contains("target === workspace"))
    }

    func testFocusViewPreservesChromePreferencesAndCommandFFindsTheDocument() throws {
        let workspaceSource = try source("Sources/VibePDF/Views/WorkspaceView.swift")
        let tabSource = try source("Sources/VibePDF/Views/TabbedWorkspaceView.swift")
        let toolbarSource = try source("Sources/VibePDF/Views/WorkspaceToolbar.swift")

        XCTAssertTrue(tabSource.contains("if !isFocusMode {"))
        XCTAssertTrue(tabSource.contains("focus-mode-exit"))
        XCTAssertTrue(tabSource.contains("if isFocusMode {"))
        XCTAssertTrue(workspaceSource.contains("workspace.sidebarVisible && !isFocusMode"))
        XCTAssertTrue(workspaceSource.contains("if !isFocusMode, aiPanelVisible"))
        XCTAssertTrue(workspaceSource.contains(".frame(height: isFocusMode ? 0 : nil)"))
        XCTAssertTrue(workspaceSource.contains("for: .focusDocumentSearch"))
        XCTAssertTrue(workspaceSource.contains("setFocusMode(false)"))
        XCTAssertTrue(toolbarSource.contains("for: .focusDocumentSearch"))
        XCTAssertFalse(
            workspaceSource.contains("workspace.sidebarVisible = false"),
            "Focus View must temporarily suppress the sidebar without overwriting its saved state."
        )
    }

    func testLargeResultRowsUseLazyStacksAndCachedOrdinals() throws {
        let navigatorSource = try source(
            "Sources/VibePDF/Views/SearchNavigatorSidebarView.swift"
        )
        let pageSidebarSource = try source("Sources/VibePDF/Views/PageSidebarView.swift")

        XCTAssertTrue(navigatorSource.contains("LazyVStack(alignment: .leading"))
        XCTAssertTrue(navigatorSource.contains("LazyHStack(alignment: .top"))
        XCTAssertFalse(navigatorSource.contains("searchNavigatorResults.firstIndex"))
        XCTAssertTrue(navigatorSource.contains("let ordinal: Int"))
        XCTAssertTrue(navigatorSource.contains("selectSearchResult(at: globalIndex)"))
        XCTAssertTrue(navigatorSource.contains("onReceive(workspace.$searchNavigatorResults)"))
        XCTAssertTrue(pageSidebarSource.contains("onReceive(workspace.$searchNavigatorResults)"))
        XCTAssertTrue(
            pageSidebarSource.contains(
                "PageSidebarLayoutMetrics.horizontalScrollerTopPadding"
            )
        )
        XCTAssertTrue(
            pageSidebarSource.contains(
                "PageSidebarLayoutMetrics.horizontalScrollerBottomPadding"
            )
        )
    }

    func testSearchResultsRedirectVerticalWheelOnlyInHorizontalPlacement() throws {
        let navigatorSource = try source(
            "Sources/VibePDF/Views/SearchNavigatorSidebarView.swift"
        )
        let verticalStart = try XCTUnwrap(
            navigatorSource.range(of: "private var verticalResults: some View")
        )
        let horizontalStart = try XCTUnwrap(
            navigatorSource.range(
                of: "private var horizontalResults: some View",
                range: verticalStart.upperBound..<navigatorSource.endIndex
            )
        )
        let horizontalEnd = try XCTUnwrap(
            navigatorSource.range(
                of: "private var shouldShowResults: Bool",
                range: horizontalStart.upperBound..<navigatorSource.endIndex
            )
        )
        let verticalResults = navigatorSource[
            verticalStart.lowerBound..<horizontalStart.lowerBound
        ]
        let horizontalResults = navigatorSource[
            horizontalStart.lowerBound..<horizontalEnd.lowerBound
        ]

        XCTAssertFalse(verticalResults.contains("PDFTabStripWheelMonitor"))
        XCTAssertTrue(
            horizontalResults.contains("PDFTabStripWheelMonitor(isEnabled: true)"),
            "Top/bottom search strips should map ordinary vertical wheel input to horizontal movement."
        )
        XCTAssertTrue(horizontalResults.contains("ScrollView(.horizontal)"))
        XCTAssertTrue(verticalResults.contains("ScrollView(.vertical)"))
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

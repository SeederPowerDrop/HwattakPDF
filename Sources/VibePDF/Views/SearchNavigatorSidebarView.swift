// SPDX-License-Identifier: MPL-2.0

import Foundation
import SwiftUI

extension Notification.Name {
    /// 메뉴의 ⌘F처럼 SwiftUI view 계층 밖 명령이 현재 검색 필드에 focus를
    /// 요청할 때 사용하는 앱 내부 알림이다.
    static let focusDocumentSearch = Notification.Name("HwattakPDF.focusDocumentSearch")
}

private struct DocumentSearchAvailableFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var documentSearchAvailable: Bool? {
        get { self[DocumentSearchAvailableFocusedValueKey.self] }
        set { self[DocumentSearchAvailableFocusedValueKey.self] = newValue }
    }
}

/// 같은 resizable panel을 페이지 썸네일과 검색 결과가 공유하게 하는 화면 모드다.
enum DocumentSidebarMode: String, CaseIterable, Identifiable {
    case pages
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pages:
            L10n.string("search.navigator.mode.pages", defaultValue: "페이지")
        case .search:
            L10n.string("search.navigator.mode.search", defaultValue: "검색")
        }
    }

    var systemImage: String {
        switch self {
        case .pages: "rectangle.grid.1x2"
        case .search: "text.magnifyingglass"
        }
    }

    /// 검색 행의 문맥이 읽힐 최소 크기다. 페이지 모드는 `nil`을 반환해 썸네일
    /// 배율과 묶음 방식이 계산한 최소 크기를 사용한다.
    func minimumPanelDimension(for placement: PageOverviewPlacement) -> Double? {
        guard self == .search else { return nil }
        return placement.usesHorizontalPageStrip ? 210 : 250
    }
}

struct DocumentSidebarModePicker: View {
    @Binding var selection: DocumentSidebarMode

    var body: some View {
        Picker(
            L10n.string("search.navigator.mode", defaultValue: "사이드바 내용"),
            selection: $selection
        ) {
            ForEach(DocumentSidebarMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel(
            L10n.string("search.navigator.mode", defaultValue: "사이드바 내용")
        )
        .accessibilityValue(selection.title)
    }
}

/// 검색 결과가 없을 때 단순히 "0건"이라고만 하지 않고 이유를 구분한다.
/// 취소된 부분 검색, 텍스트 층이 없는 스캔, 일부 페이지만 스캔인 경우는 사용자가
/// 취할 다음 행동이 서로 다르기 때문이다.
enum SearchNavigatorEmptyContent: Equatable {
    case searching
    case queryPrompt
    case cancelled(completedPages: Int, totalPages: Int)
    case fullOCR
    case partialOCR(unsearchablePageCount: Int)
    case noMatches

    static func resolve(
        isSearching: Bool,
        queryIsEmpty: Bool,
        wasCancelled: Bool,
        completedPages: Int,
        totalPages: Int,
        requiresOCR: Bool,
        unsearchablePageCount: Int
    ) -> SearchNavigatorEmptyContent {
        if isSearching { return .searching }
        if queryIsEmpty { return .queryPrompt }
        if wasCancelled {
            return .cancelled(
                completedPages: completedPages,
                totalPages: totalPages
            )
        }
        if requiresOCR { return .fullOCR }
        if unsearchablePageCount > 0 {
            return .partialOCR(unsearchablePageCount: unsearchablePageCount)
        }
        return .noMatches
    }
}

/// A document-wide result navigator that intentionally shares the existing
/// resizable page-panel container. Switching modes never reconstructs or
/// alters the thumbnail drag/drop implementation.
struct SearchNavigatorSidebarView: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let placement: PageOverviewPlacement
    @Binding var sidebarMode: DocumentSidebarMode
    let onRequestOCR: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var groups: [SearchNavigatorPageGroup] = []

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }
    private var query: String {
        workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// 최대 20,000개 결과를 body 재평가 때마다 묶으면 UI가 느려진다. 결과 배열이
    /// publish될 때 한 번만 O(n)으로 페이지 그룹과 ordinal을 만들어 @State에 둔다.
    private static func groupedResults(
        _ results: [PDFSearchResult]
    ) -> [SearchNavigatorPageGroup] {
        var grouped: [Int: [SearchNavigatorIndexedResult]] = [:]
        for (ordinal, result) in results.enumerated() {
            grouped[result.pageIndex, default: []].append(
                SearchNavigatorIndexedResult(result: result, ordinal: ordinal)
            )
        }
        return grouped.keys.sorted().compactMap { pageIndex in
            guard let results = grouped[pageIndex], let first = results.first else { return nil }
            return SearchNavigatorPageGroup(
                pageIndex: pageIndex,
                pageLabel: first.result.pageLabel,
                results: results
            )
        }
    }
    private var activeResultID: PDFSearchResult.ID? {
        guard workspace.searchNavigatorResults.indices.contains(workspace.searchResultIndex) else {
            return nil
        }
        return workspace.searchNavigatorResults[workspace.searchResultIndex].id
    }

    var body: some View {
        Group {
            if placement.usesHorizontalPageStrip {
                horizontalPanel
            } else {
                verticalPanel
            }
        }
        .background(theme.sidebar)
        .foregroundStyle(theme.primaryText)
        .onExitCommand(perform: escapeSearch)
        .onReceive(workspace.$searchNavigatorResults) { results in
            // Group only when the result publication changes. Progress and
            // unrelated workspace updates must not regroup up to 20k rows.
            groups = Self.groupedResults(results)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.string("search.navigator.title", defaultValue: "검색 결과 탐색기")
        )
    }

    private var verticalPanel: some View {
        VStack(spacing: 0) {
            navigatorHeader
            divider(horizontal: true)
            navigatorStatus
            divider(horizontal: true)
            verticalResults
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var horizontalPanel: some View {
        HStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    navigatorHeader
                    divider(horizontal: true)
                    navigatorStatus
                }
            }
            .frame(width: 250)

            divider(horizontal: false)
            horizontalResults
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
    }

    private var navigatorHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label(
                    L10n.string("search.navigator.title", defaultValue: "검색 결과"),
                    systemImage: "text.magnifyingglass"
                )
                .font(.headline.weight(.semibold))
                .lineLimit(1)

                Spacer(minLength: 4)

                if !workspace.searchNavigatorResults.isEmpty {
                    Text(
                        workspace.searchResultsWereTruncated
                            ? "\(workspace.searchNavigatorResults.count)+"
                            : "\(workspace.searchNavigatorResults.count)"
                    )
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(theme.dropHighlight, in: Capsule())
                        .accessibilityLabel(resultsCountAccessibilityLabel)
                }
            }

            DocumentSidebarModePicker(selection: $sidebarMode)

            if !query.isEmpty {
                Text(L10n.format("search.navigator.query", query))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityLabel(
                        L10n.format("search.navigator.query_accessibility", query)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var navigatorStatus: some View {
        VStack(alignment: .leading, spacing: 9) {
            if workspace.isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("search.navigator.searching", defaultValue: "문서 검색 중"))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Button(L10n.string("search.navigator.cancel", defaultValue: "취소")) {
                        workspace.cancelSearch()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                ProgressView(value: workspace.searchProgress.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(
                        L10n.string("search.navigator.progress_label", defaultValue: "검색 진행률")
                    )
                    .accessibilityValue(progressText)

                Text(progressText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
            } else if !workspace.searchNavigatorResults.isEmpty {
                HStack(spacing: 8) {
                    Text(
                        L10n.format(
                            "search.navigator.current_position",
                            workspace.searchResultIndex + 1,
                            workspace.searchNavigatorResults.count
                        )
                    )
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)

                    Spacer(minLength: 4)

                    navigatorButton(backwards: true)
                    navigatorButton(backwards: false)
                }
            } else {
                Text(
                    query.isEmpty
                        ? L10n.string(
                            "search.navigator.enter_query_message",
                            defaultValue: "⌘F로 검색어를 입력하세요."
                        )
                        : L10n.string(
                            "search.navigator.no_position",
                            defaultValue: "선택할 검색 결과가 없습니다."
                        )
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            if !workspace.isSearching, workspace.searchResultsWereTruncated {
                Label(
                    L10n.string(
                        "search.navigator.truncated",
                        defaultValue: "결과가 너무 많아 일부만 표시합니다."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    L10n.string(
                        "search.navigator.truncated_accessibility",
                        defaultValue: "검색 결과 한도에 도달해 일부 결과가 생략되었습니다."
                    )
                )
            }

            if
                !workspace.isSearching,
                !workspace.searchNavigatorResults.isEmpty,
                workspace.searchUnsearchablePageCount > 0
            {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Label(
                            L10n.format(
                                "search.navigator.unsearchable_pages",
                                workspace.searchUnsearchablePageCount
                            ),
                            systemImage: "text.viewfinder"
                        )
                        .font(.caption2)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 3)

                        Button(L10n.string("search.navigator.ocr_short_action", defaultValue: "OCR")) {
                            onRequestOCR()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2.weight(.semibold))
                        .accessibilityHint(
                            "\(L10n.string("search.navigator.ocr_message")) \(L10n.string("search.navigator.ocr_supported_languages"))"
                        )
                    }

                    ocrLanguageSupportText
                }
            }

            if
                !workspace.searchNavigatorResults.isEmpty,
                workspace.searchProgress.phase == .cancelled
            {
                VStack(alignment: .leading, spacing: 5) {
                    Label(
                        L10n.format(
                            "search.navigator.cancelled_message",
                            workspace.searchProgress.completedPages,
                            workspace.searchProgress.totalPages
                        ),
                        systemImage: "stop.circle.fill"
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)

                    retrySearchButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var progressText: String {
        L10n.format(
            "search.navigator.progress",
            workspace.searchProgress.completedPages,
            workspace.searchProgress.totalPages
        )
    }

    private func navigatorButton(backwards: Bool) -> some View {
        Button {
            workspace.showNextSearchResult(backwards: backwards)
        } label: {
            Image(systemName: backwards ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 25, height: 25)
                .background(theme.card, in: Circle())
                .overlay { Circle().stroke(theme.border, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .help(
            backwards
                ? L10n.string("이전 검색 결과")
                : L10n.string("다음 검색 결과")
        )
        .accessibilityLabel(
            backwards
                ? L10n.string("이전 검색 결과")
                : L10n.string("다음 검색 결과")
        )
    }

    @ViewBuilder
    private var verticalResults: some View {
        if shouldShowResults {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 11) {
                        ForEach(groups) { group in
                            resultGroup(group, horizontal: false)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                }
                .onChange(of: activeResultID) { _, newValue in
                    scrollToActiveResult(newValue, proxy: proxy)
                }
            }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var horizontalResults: some View {
        if shouldShowResults {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(groups) { group in
                            resultGroup(group, horizontal: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                // Top/bottom placement turns the navigator into a horizontal
                // strip. Reuse the tab strip's passive wheel bridge so an
                // ordinary mouse-wheel or vertical trackpad gesture travels
                // left/right, while a genuine horizontal gesture stays native.
                // Left/right placement uses `verticalResults` and therefore
                // keeps normal vertical scrolling without this monitor.
                .background {
                    PDFTabStripWheelMonitor(isEnabled: true)
                }
                .onChange(of: activeResultID) { _, newValue in
                    scrollToActiveResult(newValue, proxy: proxy)
                }
            }
        } else {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var shouldShowResults: Bool {
        !workspace.searchNavigatorResults.isEmpty
    }

    private func resultGroup(
        _ group: SearchNavigatorPageGroup,
        horizontal: Bool
    ) -> some View {
        Group {
            if horizontal {
                VStack(alignment: .leading, spacing: 7) {
                    resultGroupHeader(group)
                    LazyHStack(alignment: .top, spacing: 7) {
                        ForEach(group.results) { indexedResult in
                            resultRow(indexedResult)
                                .frame(width: 250)
                        }
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 7) {
                    resultGroupHeader(group)
                    ForEach(group.results) { indexedResult in
                        resultRow(indexedResult)
                    }
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card.opacity(0.56), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(theme.border.opacity(0.8), lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
    }

    private func resultGroupHeader(_ group: SearchNavigatorPageGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .foregroundStyle(theme.accent)
            Text(
                L10n.format(
                    "search.navigator.page_heading",
                    group.pageLabel,
                    group.results.count
                )
            )
            .font(.caption.weight(.bold))
            .lineLimit(1)
            Spacer(minLength: 2)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func resultRow(_ indexedResult: SearchNavigatorIndexedResult) -> some View {
        let result = indexedResult.result
        let isActive = result.id == activeResultID
        let globalIndex = indexedResult.ordinal
        return Button {
            workspace.selectSearchResult(at: globalIndex)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isActive ? theme.ribbon : theme.dropHighlight)
                        .frame(width: 20, height: 20)
                    Text("\(globalIndex + 1)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(isActive ? Color.white : theme.primaryText)
                        .minimumScaleFactor(0.65)
                }
                .accessibilityHidden(true)

                SearchResultSnippetText(
                    text: result.snippet,
                    matchRanges: result.snippetMatchRanges,
                    theme: theme
                )
                .font(.caption)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

                if isActive {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.ribbon)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                isActive ? theme.dropHighlight : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isActive ? theme.accent.opacity(0.75) : Color.clear, lineWidth: 1.2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(result.id)
        .accessibilityLabel(
            L10n.format(
                "search.navigator.result_accessibility",
                result.pageLabel,
                globalIndex + 1,
                workspace.searchNavigatorResults.count,
                result.snippet
            )
        )
        .accessibilityHint(
            L10n.string(
                "search.navigator.result_hint",
                defaultValue: "클릭하면 해당 페이지의 일치 위치로 이동합니다."
            )
        )
        .accessibilityValue(
            isActive
                ? L10n.string("search.navigator.current_result", defaultValue: "현재 결과")
                : ""
        )
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var resultsCountAccessibilityLabel: String {
        if workspace.searchResultsWereTruncated {
            return L10n.format(
                "search.navigator.truncated_count",
                workspace.searchNavigatorResults.count
            )
        }
        return L10n.format(
            "search.navigator.results_count",
            workspace.searchNavigatorResults.count
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            switch emptyContent {
            case .searching:
                ProgressView()
                    .controlSize(.regular)
                Text(L10n.string("search.navigator.searching", defaultValue: "문서 검색 중"))
                    .font(.headline)

            case .queryPrompt:
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(theme.secondaryText)
                Text(
                    L10n.string(
                        "search.navigator.enter_query_title",
                        defaultValue: "찾을 단어나 문장을 입력하세요"
                    )
                )
                .font(.headline)
                Text(
                    L10n.string(
                        "search.navigator.enter_query_message",
                        defaultValue: "⌘F로 검색 필드를 열고 Enter를 누르세요."
                    )
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)

            case .cancelled(let completedPages, let totalPages):
                Image(systemName: "stop.circle")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(theme.warning)
                Text(
                    L10n.string(
                        "search.navigator.cancelled_title",
                        defaultValue: "검색이 취소되었습니다"
                    )
                )
                .font(.headline)
                Text(
                    L10n.format(
                        "search.navigator.cancelled_message",
                        completedPages,
                        totalPages
                    )
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                retrySearchButton

            case .fullOCR:
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(theme.warning)
                Text(L10n.string("search.navigator.ocr_title", defaultValue: "검색할 텍스트 층이 없습니다"))
                    .font(.headline)
                Text(
                    L10n.string(
                        "search.navigator.ocr_message",
                        defaultValue: "로컬 OCR 후 검색 가능한 사본을 내보내고, 그 사본을 열어 검색하세요."
                    )
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                ocrLanguageSupportText
                ocrActionButton

            case .partialOCR(let unsearchablePageCount):
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(theme.warning)
                Text(
                    L10n.string(
                        "search.navigator.partial_ocr_title",
                        defaultValue: "일부 페이지는 검색하지 못했습니다"
                    )
                )
                .font(.headline)
                Text(
                    L10n.format(
                        "search.navigator.partial_ocr_message",
                        unsearchablePageCount
                    )
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                ocrLanguageSupportText
                ocrActionButton

            case .noMatches:
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(theme.secondaryText)
                Text(L10n.string("search.navigator.empty_title", defaultValue: "일치하는 내용이 없습니다"))
                    .font(.headline)
                Text(
                    L10n.string(
                        "search.navigator.empty_message",
                        defaultValue: "단어의 일부나 다른 표기로 다시 검색해 보세요."
                    )
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        // Keep the OCR call-to-action independently reachable by VoiceOver.
        .accessibilityElement(children: .contain)
    }

    private var emptyContent: SearchNavigatorEmptyContent {
        SearchNavigatorEmptyContent.resolve(
            isSearching: workspace.isSearching,
            queryIsEmpty: query.isEmpty,
            wasCancelled: workspace.searchProgress.phase == .cancelled,
            completedPages: workspace.searchProgress.completedPages,
            totalPages: workspace.searchProgress.totalPages,
            requiresOCR: workspace.searchRequiresOCR,
            unsearchablePageCount: workspace.searchUnsearchablePageCount
        )
    }

    private var ocrActionButton: some View {
        Button(action: onRequestOCR) {
            Label(
                L10n.string("search.navigator.ocr_action", defaultValue: "로컬 OCR 실행"),
                systemImage: "text.viewfinder"
            )
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var ocrLanguageSupportText: some View {
        Text(
            L10n.string(
                "search.navigator.ocr_supported_languages",
                defaultValue: "현재 OCR은 한국어·영어·일본어를 지원합니다."
            )
        )
        .font(.caption2)
        .foregroundStyle(theme.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var retrySearchButton: some View {
        Button {
            workspace.performSearch()
        } label: {
            Label(
                L10n.string(
                    "search.navigator.retry",
                    defaultValue: "처음부터 다시 검색"
                ),
                systemImage: "arrow.clockwise"
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func scrollToActiveResult(
        _ id: PDFSearchResult.ID?,
        proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        guard let id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func escapeSearch() {
        if workspace.isSearching {
            workspace.cancelSearch()
        }
        workspace.clearSearch()
        sidebarMode = .pages
    }

    private func divider(horizontal: Bool) -> some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
    }
}

private struct SearchNavigatorPageGroup: Identifiable {
    let pageIndex: Int
    let pageLabel: String
    let results: [SearchNavigatorIndexedResult]

    var id: Int { pageIndex }
}

private struct SearchNavigatorIndexedResult: Identifiable {
    let result: PDFSearchResult
    let ordinal: Int

    var id: PDFSearchResult.ID { result.id }
}

private struct SearchResultSnippetText: View {
    let text: String
    let matchRanges: [NSRange]
    let theme: VibePDFTheme

    var body: some View {
        Text(highlightedText)
    }

    private var highlightedText: AttributedString {
        let fallback = text.isEmpty
            ? L10n.string("search.navigator.snippet_unavailable", defaultValue: "미리보기 없음")
            : text
        var attributed = AttributedString(fallback)
        guard !text.isEmpty else { return attributed }

        for nsRange in matchRanges {
            guard
                let stringRange = Range(nsRange, in: text),
                let lower = AttributedString.Index(stringRange.lowerBound, within: attributed),
                let upper = AttributedString.Index(stringRange.upperBound, within: attributed),
                lower < upper
            else { continue }
            attributed[lower..<upper].backgroundColor = theme.warning.opacity(0.38)
            attributed[lower..<upper].foregroundColor = theme.primaryText
        }
        return attributed
    }
}

// SPDX-License-Identifier: MPL-2.0

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct PDFGridOverview: View {
    @ObservedObject var workspace: PDFWorkspaceState
    @AppStorage(PDFWheelZoomModifier.defaultsKey)
    private var wheelZoomModifierValue = PDFWheelZoomModifier.defaultValue.rawValue
    var layoutMode: PDFGridLayoutMode = .balanced
    var pagingDirection: PDFGridPagingDirection = .vertical
    var onPageGroupChange: (Int) -> Void = { _ in }
    var onScrollActivity: (PDFVerticalScrollMetrics) -> Void = { _ in }
    var onVisiblePageChange: (Int) -> Void = { _ in }
    var onPageDoubleClick: (Int) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme
    @State private var pageDragSession: PDFPageDragSession?
    @State private var pageReportedFromScroll: Int?
    @State private var hasEstablishedInitialPosition = false
    @State private var initialPositionGeneration = 0
    @State private var transientMagnification: CGFloat = 1
    @State private var magnificationBaseline: CGFloat?

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }
    /// Cards remain selectable in every mode. A page drag, however, changes
    /// document structure and must be authorized by Editing mode.
    private var canEditPages: Bool { workspace.allows(.pageEditing) }

    var body: some View {
        GeometryReader { geometry in
            let pageGroupSize = max(3, min(12, workspace.pageColumns))
            let metrics = PDFGridLayoutMetrics.resolve(
                viewportSize: geometry.size,
                requestedPageCount: workspace.pageColumns,
                layoutMode: layoutMode,
                overviewScale: workspace.overviewScale,
                maximumPageAspect: maximumPageAspect(inGroupOf: pageGroupSize)
            )
            let scrollAxes: Axis.Set = metrics.enablesHorizontalScrolling
                ? [.vertical, .horizontal]
                : .vertical

            ScrollViewReader { proxy in
                ScrollView(scrollAxes) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(
                                .fixed(metrics.tileWidth),
                                spacing: metrics.horizontalSpacing,
                                alignment: .top
                            ),
                            count: metrics.columnCount
                        ),
                        alignment: .center,
                        spacing: metrics.verticalSpacing
                    ) {
                        gridItems(metrics: metrics)
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, metrics.topPadding)
                    .padding(.bottom, metrics.bottomPadding)
                    .frame(
                        width: max(geometry.size.width, metrics.contentWidth),
                        alignment: metrics.enablesHorizontalScrolling ? .topLeading : .top
                    )
                    .frame(minHeight: geometry.size.height, alignment: .center)
                    .background {
                        PDFGridLiveScrollObserver(
                            onScrollActivity: reportNativeScrollActivity
                        )
                        .accessibilityHidden(true)
                    }
                    .scaleEffect(transientMagnification, anchor: .center)
                    .id(gridContainerScrollTarget)
                }
                .coordinateSpace(name: OverviewScrollCoordinateSpace.name)
                .background(theme.canvas)
                .onPreferenceChange(OverviewPageFramePreferenceKey.self) { pageFrames in
                    reportMostVisiblePage(
                        from: pageFrames,
                        viewportSize: geometry.size
                    )
                }
                .onChange(of: workspace.currentPageIndex) { oldValue, newValue in
                    guard hasEstablishedInitialPosition else {
                        establishInitialPosition(using: proxy, metrics: metrics)
                        return
                    }
                    if !PDFGridOverviewScrollTarget.requiresNavigation(
                        from: oldValue,
                        to: newValue,
                        requestedPageCount: workspace.pageColumns,
                        documentPageCount: workspace.pageCount
                    ) {
                        // Selecting another card in the current group must not
                        // reset a user's zoomed two-finger pan position.
                        return
                    }
                    if pageReportedFromScroll == newValue {
                        pageReportedFromScroll = nil
                        if !isFourPagePager {
                            return
                        }
                    }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(
                            navigationTarget(for: newValue),
                            anchor: navigationAnchor(for: metrics)
                        )
                    }
                }
                .onChange(of: workspace.pageColumns) { _, _ in
                    establishInitialPosition(using: proxy, metrics: metrics)
                }
                .onChange(of: layoutMode) { _, _ in
                    establishInitialPosition(using: proxy, metrics: metrics)
                }
                .onChange(of: pagingDirection) { _, _ in
                    establishInitialPosition(using: proxy, metrics: metrics)
                }
                .onChange(of: workspace.overviewScale) { _, _ in
                    establishInitialPosition(using: proxy, metrics: metrics)
                }
                .onAppear {
                    establishInitialPosition(using: proxy, metrics: metrics)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $workspace.overviewScale, in: 0.7...1.6, step: 0.05)
                    .frame(width: 130)
                    .accessibilityLabel("개요 페이지 크기")
                    .accessibilityValue(
                        L10n.format("value.percent", Int(workspace.overviewScale * 100))
                    )
                Image(systemName: "plus.magnifyingglass")
            }
            .foregroundStyle(theme.secondaryText)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.card, in: Capsule())
            .overlay { Capsule().stroke(theme.border, lineWidth: 1) }
            .shadow(color: theme.elevatedShadow, radius: 12, y: 4)
            .padding(18)
        }
        .overlay(alignment: isFourPagePager ? .topLeading : .top) {
            Label(
                overviewDescription,
                systemImage: "info.circle"
            )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(theme.card.opacity(0.96), in: Capsule())
                .overlay { Capsule().stroke(theme.border, lineWidth: 1) }
                .padding(12)
        }
        .overlay {
            if isFourPagePager {
                groupPagingControls
            }
        }
        .overlay {
            PDFGridInputMonitor(
                pagingEnabled: isFourPagePager && workspace.overviewScale <= 1.0001,
                pagingDirection: pagingDirection,
                wheelZoomModifier: PDFWheelZoomModifier(
                    rawValue: wheelZoomModifierValue
                ) ?? .defaultValue,
                onMagnificationChanged: previewMagnification,
                onMagnificationEnded: commitMagnification,
                onScrollActivity: reportScrollActivity,
                onPageStep: requestPageGroupFromScroll(offset:)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityHidden(true)
        }
        .focusable()
        .onKeyPress(
            keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown]
        ) { keyPress in
            handlePagingKey(keyPress.key)
        }
        .onDisappear {
            transientMagnification = 1
            magnificationBaseline = nil
            pageDragSession = nil
        }
        .onChange(of: workspace.mode) { _, _ in
            if !canEditPages {
                pageDragSession = nil
            }
        }
        .modifier(
            GridPageEndDropTargetModifier(
                isEnabled: pageDragSession != nil,
                pageDragSession: $pageDragSession,
                workspace: workspace
            )
        )
    }

    @ViewBuilder
    private func gridItems(metrics: PDFGridLayoutMetrics) -> some View {
        if isFourPagePager {
            ForEach(Array(currentPageGroup.pageSlots.enumerated()), id: \.offset) { slot in
                if
                    let index = slot.element,
                    let page = workspace.document?.page(at: index)
                {
                    trackedGridPage(
                        page,
                        index: index,
                        width: metrics.tileWidth,
                        exposesScrollTarget: false
                    )
                } else {
                    Color.clear
                        .frame(
                            width: metrics.tileWidth,
                            height: metrics.estimatedTileHeight(
                                maximumPageAspect: maximumPageAspect(inGroupOf: 4)
                            )
                        )
                        .accessibilityHidden(true)
                }
            }
        } else {
            ForEach(0..<workspace.pageCount, id: \.self) { index in
                if let page = workspace.document?.page(at: index) {
                    trackedGridPage(
                        page,
                        index: index,
                        width: metrics.tileWidth,
                        exposesScrollTarget: true
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func trackedGridPage(
        _ page: PDFPage,
        index: Int,
        width: CGFloat,
        exposesScrollTarget: Bool
    ) -> some View {
        let trackedPage = gridPage(page, index: index, width: width)
            .background {
                GeometryReader { pageGeometry in
                    Color.clear.preference(
                        key: OverviewPageFramePreferenceKey.self,
                        value: [
                            index: pageGeometry.frame(
                                in: .named(OverviewScrollCoordinateSpace.name)
                            )
                        ]
                    )
                }
            }

        if exposesScrollTarget {
            trackedPage.id(PDFGridOverviewScrollTarget.page(index))
        } else {
            trackedPage
        }
    }

    private var isFourPagePager: Bool {
        workspace.pageColumns == PDFGridPageGroup.pageCountPerGroup
    }

    private var currentPageGroup: PDFGridPageGroup {
        PDFGridPageGroup(
            containing: workspace.currentPageIndex,
            documentPageCount: workspace.pageCount
        )
    }

    private var gridContainerScrollTarget: PDFGridOverviewScrollTarget {
        isFourPagePager
            ? .pageGroup(currentPageGroup.startIndex)
            : .overviewContainer
    }

    @ViewBuilder
    private var groupPagingControls: some View {
        switch pagingDirection {
        case .vertical:
            VStack {
                pagingButton(groupOffset: -1, systemImage: "chevron.up")
                Spacer()
                pagingButton(groupOffset: 1, systemImage: "chevron.down")
            }
            .padding(.vertical, 12)
        case .horizontal:
            HStack {
                pagingButton(groupOffset: -1, systemImage: "chevron.left")
                Spacer()
                pagingButton(groupOffset: 1, systemImage: "chevron.right")
            }
            .padding(.horizontal, 12)
        }
    }

    private func pagingButton(groupOffset: Int, systemImage: String) -> some View {
        let isPrevious = groupOffset < 0
        let targetStart = currentPageGroup.targetStartIndex(groupOffset: groupOffset)

        return Button {
            requestPageGroup(offset: groupOffset)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .frame(width: 30, height: 30)
                .background(theme.card.opacity(0.96), in: Circle())
                .overlay { Circle().stroke(theme.border, lineWidth: 1) }
                .shadow(color: theme.elevatedShadow, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(targetStart == nil)
        .opacity(targetStart == nil ? 0.32 : 1)
        .help(isPrevious ? L10n.string("이전 4페이지") : L10n.string("다음 4페이지"))
        .accessibilityLabel(isPrevious ? L10n.string("이전 4페이지") : L10n.string("다음 4페이지"))
        .accessibilityValue(pageGroupAccessibilityValue(startIndex: targetStart))
        .accessibilityHint(
            L10n.string(
                targetStart == nil
                    ? "이동할 페이지 그룹이 없습니다."
                    : "현재 페이지에서 4페이지 단위로 이동합니다."
            )
        )
    }

    private func pageGroupAccessibilityValue(startIndex: Int?) -> String {
        guard let startIndex, workspace.pageCount > 0 else {
            return L10n.string("view.grid.no_group")
        }
        let endIndex = min(startIndex + PDFGridPageGroup.pageCountPerGroup, workspace.pageCount)
        return L10n.format("page.range_from_to", startIndex + 1, endIndex)
    }

    private func requestPageGroup(offset: Int) {
        guard
            isFourPagePager,
            let target = currentPageGroup.targetStartIndex(groupOffset: offset)
        else {
            return
        }
        onPageGroupChange(target)
    }

    private func requestPageGroupFromScroll(offset: Int) {
        guard
            isFourPagePager,
            let target = currentPageGroup.targetStartIndex(groupOffset: offset)
        else {
            return
        }
        // The monitor first emits every raw wheel pulse for deadline refresh.
        // Once the gesture crosses a group threshold, immediately move the
        // synthetic thumb to the target group as well.
        onScrollActivity(scrollMetrics(pageIndex: target))
        onPageGroupChange(target)
    }

    private func reportScrollActivity() {
        let visibleIndex = pageReportedFromScroll ?? workspace.currentPageIndex
        onScrollActivity(scrollMetrics(pageIndex: visibleIndex))
    }

    private func reportNativeScrollActivity(_ metrics: PDFVerticalScrollMetrics) {
        if isFourPagePager {
            // At fit and zoomed pan scales, the strict pager represents a
            // document group rather than an internal pixel offset.
            reportScrollActivity()
        } else {
            onScrollActivity(metrics)
        }
    }

    private func scrollMetrics(pageIndex: Int) -> PDFVerticalScrollMetrics {
        PDFVerticalScrollMetrics.semantic(
            pageIndex: pageIndex,
            pageCount: workspace.pageCount,
            visiblePageCount: isFourPagePager
                ? PDFGridPageGroup.pageCountPerGroup
                : max(1, workspace.pageColumns),
            pageStride: isFourPagePager
                ? PDFGridPageGroup.pageCountPerGroup
                : 1
        )
    }

    private func handlePagingKey(_ key: KeyEquivalent) -> KeyPress.Result {
        guard isFourPagePager else { return .ignored }

        let offset: Int?
        if key == .pageUp {
            offset = -1
        } else if key == .pageDown {
            offset = 1
        } else {
            switch pagingDirection {
            case .vertical:
                if key == .upArrow {
                    offset = -1
                } else if key == .downArrow {
                    offset = 1
                } else {
                    offset = nil
                }
            case .horizontal:
                if key == .leftArrow {
                    offset = -1
                } else if key == .rightArrow {
                    offset = 1
                } else {
                    offset = nil
                }
            }
        }

        guard let offset else { return .ignored }
        requestPageGroup(offset: offset)
        return .handled
    }

    private func previewMagnification(_ factor: CGFloat) {
        let baseline = magnificationBaseline ?? workspace.overviewScale
        if magnificationBaseline == nil {
            magnificationBaseline = baseline
        }
        let targetScale = clampedOverviewScale(baseline * factor)
        transientMagnification = baseline > 0 ? targetScale / baseline : 1
    }

    private func commitMagnification(_ factor: CGFloat) {
        let baseline = magnificationBaseline ?? workspace.overviewScale
        let targetScale = clampedOverviewScale(baseline * factor)
        transientMagnification = 1
        magnificationBaseline = nil
        if abs(workspace.overviewScale - targetScale) > 0.0001 {
            workspace.overviewScale = targetScale
        }
    }

    private func clampedOverviewScale(_ scale: CGFloat) -> CGFloat {
        min(1.6, max(0.7, scale.isFinite ? scale : 1))
    }

    @ViewBuilder
    private func gridPage(_ page: PDFPage, index: Int, width: CGFloat) -> some View {
        let selected = workspace.selectedPages.contains(index)
        let card = PDFGridPageCard(
            page: page,
            pageIndex: index,
            width: width,
            revision: workspace.revision,
            selected: selected,
            theme: theme
        )
        .contentShape(Rectangle())
        .focusable()

        let modeAwareCard = Group {
            if canEditPages {
                card
                    .onDrag {
                        let session = PDFPageDragSession(
                            sourceIndex: index,
                            documentRevision: workspace.revision
                        )
                        pageDragSession = session
                        return PDFPageDragPayload.itemProvider(for: session)
                    }
                    .modifier(
                        GridPageReorderDropTargetModifier(
                            isEnabled: pageDragSession != nil,
                            target: index,
                            pageDragSession: $pageDragSession,
                            workspace: workspace
                        )
                    )
            } else {
                // No drag modifier means no ghost drag and no edit action in
                // the accessibility tree while reading or studying.
                card
            }
        }

        let clickableCard = modeAwareCard
        .gesture(
            TapGesture(count: 2)
                .exclusively(before: TapGesture(count: 1))
                .onEnded { result in
                    switch result {
                    case .first:
                        onPageDoubleClick(index)
                    case .second:
                        selectPage(index, selected: selected)
                    }
                }
        )
        .onKeyPress(.return) {
            selectPage(index, selected: selected)
            return .handled
        }

        let accessibleCard = clickableCard
        .accessibilityLabel(L10n.format("page.number", index + 1))
        .accessibilityValue(
            selected ? L10n.string("selection.selected") : L10n.string("selection.not_selected")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Return 키로 선택하고, 두 번 클릭하면 편집 보기로 전환합니다.")
        .accessibilityAction {
            selectPage(index, selected: selected)
        }
        .accessibilityAction(named: "편집 보기로 전환") {
            onPageDoubleClick(index)
        }

        if canEditPages {
            accessibleCard
                .accessibilityAction(named: "앞으로 이동") {
                    workspace.selectedPages = [index]
                    workspace.moveSelectedPage(by: -1)
                }
                .accessibilityAction(named: "뒤로 이동") {
                    workspace.selectedPages = [index]
                    workspace.moveSelectedPage(by: 1)
                }
        } else {
            accessibleCard
        }
    }

    private func selectPage(_ index: Int, selected: Bool) {
        let flags = (NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)
        if flags.contains(.command) {
            if selected {
                workspace.selectedPages.remove(index)
            } else {
                workspace.selectedPages.insert(index)
            }
        } else {
            workspace.selectedPages = [index]
        }
        workspace.setCurrentPage(index)
    }

    private func reportMostVisiblePage(
        from pageFrames: [Int: CGRect],
        viewportSize: CGSize
    ) {
        guard hasEstablishedInitialPosition else { return }
        let viewport = CGRect(origin: .zero, size: viewportSize)
        let visibleAreas = pageFrames.reduce(into: [Int: CGFloat]()) { result, element in
            let (index, frame) = element
            let intersection = frame.intersection(viewport)
            guard !intersection.isNull, !intersection.isEmpty else { return }
            result[index] = intersection.width * intersection.height
        }
        let visibleCandidate = PDFGridVisibilityResolver.mostVisiblePage(
            from: visibleAreas,
            currentPageIndex: workspace.currentPageIndex
        )
        let candidate = visibleCandidate.map { index in
            isFourPagePager
                ? PDFGridPageGroup(
                    containing: index,
                    documentPageCount: workspace.pageCount
                ).startIndex
                : index
        }

        guard let candidate, pageReportedFromScroll != candidate else { return }
        pageReportedFromScroll = candidate
        onVisiblePageChange(candidate)
    }

    private var overviewDescription: String {
        let pageCount = max(3, min(12, workspace.pageColumns))
        if pageCount == 4 {
            let start = currentPageGroup.startIndex + 1
            let end = min(
                currentPageGroup.startIndex + PDFGridPageGroup.pageCountPerGroup,
                workspace.pageCount
            )
            let range = workspace.pageCount > 0
                ? L10n.format("page.range", start, end)
                : L10n.string("page.none")
            return L10n.format("view.grid.four_overview", range, layoutMode.title)
        }
        return L10n.format("view.grid.overview", pageCount)
    }

    private func maximumPageAspect(inGroupOf groupSize: Int) -> CGFloat {
        guard let document = workspace.document, document.pageCount > 0 else { return 1.414 }
        let anchor = min(
            max(0, pageReportedFromScroll ?? workspace.currentPageIndex),
            document.pageCount - 1
        )
        let safeGroupSize = max(1, groupSize)
        let start = (anchor / safeGroupSize) * safeGroupSize
        let end = min(document.pageCount, start + safeGroupSize)

        return (start..<end).reduce(CGFloat(1)) { maximum, index in
            guard let page = document.page(at: index) else { return maximum }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width > 0, bounds.height > 0 else { return maximum }
            let rotated = abs(page.rotation % 180) == 90
            let aspect = rotated
                ? bounds.width / bounds.height
                : bounds.height / bounds.width
            return max(maximum, aspect)
        }
    }

    private func navigationAnchor(for metrics: PDFGridLayoutMetrics) -> UnitPoint {
        switch PDFGridOverviewScrollAnchorPolicy.resolve(
            requestedPageCount: workspace.pageColumns,
            enablesHorizontalScrolling: metrics.enablesHorizontalScrolling
        ) {
        case .center:
            return .center
        case .leadingCenter:
            return UnitPoint(x: 0, y: 0.5)
        }
    }

    private func navigationTarget(for pageIndex: Int) -> PDFGridOverviewScrollTarget {
        PDFGridOverviewScrollTarget.resolve(
            pageIndex: pageIndex,
            requestedPageCount: workspace.pageColumns,
            documentPageCount: workspace.pageCount
        )
    }

    private func establishInitialPosition(
        using proxy: ScrollViewProxy,
        metrics: PDFGridLayoutMetrics
    ) {
        initialPositionGeneration += 1
        let generation = initialPositionGeneration
        let currentPage = min(max(0, workspace.currentPageIndex), max(0, workspace.pageCount - 1))
        let target = navigationTarget(for: currentPage)
        hasEstablishedInitialPosition = false
        pageReportedFromScroll = nil

        DispatchQueue.main.async {
            guard generation == initialPositionGeneration else { return }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(target, anchor: navigationAnchor(for: metrics))
            }
            DispatchQueue.main.async {
                guard generation == initialPositionGeneration else { return }
                hasEstablishedInitialPosition = true
            }
        }
    }
}

private struct PDFGridPageCard: View {
    let page: PDFPage
    let pageIndex: Int
    let width: CGFloat
    let revision: UUID
    let selected: Bool
    let theme: VibePDFTheme

    var body: some View {
        VStack(spacing: 9) {
            PageThumbnailView(
                page: page,
                pageIndex: pageIndex,
                width: max(80, (width - PDFGridLayoutMetrics.thumbnailHorizontalInset) * 2),
                revision: revision,
                showPageNumber: false
            )
            .frame(width: max(1, width - PDFGridLayoutMetrics.thumbnailHorizontalInset))

            Text("\(pageIndex + 1)")
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .frame(height: 14)
        }
        .padding(10)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? theme.dropHighlight : Color.clear)
        )
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                    .background(theme.card, in: Circle())
                    .padding(7)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(selected ? theme.accent : Color.clear, lineWidth: 1.5)
        )
        .overlay(alignment: .bottom) {
            if selected {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(theme.ribbon)
                    .frame(height: 3)
                    .padding(.horizontal, 16)
            }
        }
    }
}

private enum OverviewScrollCoordinateSpace {
    static let name = "pdf-grid-overview-scroll"
}

private struct GridPageReorderDropTargetModifier: ViewModifier {
    let isEnabled: Bool
    let target: Int
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(
                of: [PDFPageDragPayload.typeIdentifier],
                delegate: GridPageReorderDropDelegate(
                    target: target,
                    pageDragSession: $pageDragSession,
                    workspace: workspace
                )
            )
        } else {
            content
        }
    }
}

private struct GridPageEndDropTargetModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(
                of: [PDFPageDragPayload.typeIdentifier],
                delegate: GridPageEndDropDelegate(
                    pageDragSession: $pageDragSession,
                    workspace: workspace
                )
            )
        } else {
            content
        }
    }
}

private struct OverviewPageFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
    }
}

private struct GridPageReorderDropDelegate: DropDelegate {
    let target: Int
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    func validateDrop(info: DropInfo) -> Bool {
        guard !info.hasItemsConforming(to: [UTType.fileURL.identifier]) else {
            return false
        }
        guard info.hasItemsConforming(to: [PDFPageDragPayload.typeIdentifier]),
              workspace.allows(.pageEditing),
              let session = pageDragSession,
              session.documentRevision == workspace.revision,
              (0..<workspace.pageCount).contains(session.sourceIndex),
              (0..<workspace.pageCount).contains(target)
        else { return false }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let localSession = pageDragSession
        let scheduled = PDFPageDragPayload.loadEncodedValue(
            from: info.itemProviders(for: [PDFPageDragPayload.typeIdentifier])
        ) { encodedValue in
            defer { clearSession(ifMatching: localSession) }
            guard
                workspace.allows(.pageEditing),
                workspace.document != nil,
                let source = PDFPageDragPayload.validatedSourceIndex(
                    encodedValue: encodedValue,
                    localSession: localSession,
                    currentDocumentRevision: workspace.revision,
                    currentPageCount: workspace.pageCount,
                    targetIndex: target
                )
            else { return }
            workspace.movePage(from: source, before: target)
        }
        guard scheduled else {
            clearSession(ifMatching: localSession)
            return false
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    private func clearSession(ifMatching session: PDFPageDragSession?) {
        guard pageDragSession?.token == session?.token else { return }
        pageDragSession = nil
    }
}

private struct GridPageEndDropDelegate: DropDelegate {
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    func validateDrop(info: DropInfo) -> Bool {
        guard !info.hasItemsConforming(to: [UTType.fileURL.identifier]) else {
            return false
        }
        guard info.hasItemsConforming(to: [PDFPageDragPayload.typeIdentifier]),
              workspace.allows(.pageEditing),
              let session = pageDragSession,
              session.documentRevision == workspace.revision,
              (0..<workspace.pageCount).contains(session.sourceIndex)
        else { return false }
        return true
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        let localSession = pageDragSession
        let scheduled = PDFPageDragPayload.loadEncodedValue(
            from: info.itemProviders(for: [PDFPageDragPayload.typeIdentifier])
        ) { encodedValue in
            defer { clearSession(ifMatching: localSession) }
            guard
                workspace.allows(.pageEditing),
                workspace.document != nil,
                let source = PDFPageDragPayload.validatedSourceIndex(
                    encodedValue: encodedValue,
                    localSession: localSession,
                    currentDocumentRevision: workspace.revision,
                    currentPageCount: workspace.pageCount
                )
            else { return }
            workspace.movePageToEnd(from: source)
        }
        guard scheduled else {
            clearSession(ifMatching: localSession)
            return false
        }
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .move)
    }

    private func clearSession(ifMatching session: PDFPageDragSession?) {
        guard pageDragSession?.token == session?.token else { return }
        pageDragSession = nil
    }
}

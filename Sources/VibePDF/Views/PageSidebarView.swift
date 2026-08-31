// SPDX-License-Identifier: MPL-2.0

import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// 문서의 모든 페이지를 썸네일로 보여 주고 선택·재정렬·삭제를 돕는 사이드바다.
///
/// 배치 위치에 따라 세로 `LazyVStack` 또는 가로 `LazyHStack`만 바뀌고, 각 실제
/// 페이지는 언제나 원래 page index를 ID와 drag target으로 유지한다. 2장/4장
/// 묶음의 빈 slot은 보기용일 뿐 선택이나 drop 대상이 아니다.
struct PageSidebarView: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let placement: PageOverviewPlacement
    @Binding var sidebarMode: DocumentSidebarMode
    /// drag 시작 시 문서 revision과 난수 token을 함께 캡처한다. drop 시 이 값과
    /// provider payload를 모두 검증해 취소된 drag나 외부 텍스트가 페이지를
    /// 뜻밖에 이동시키지 못하게 한다.
    @State private var pageDragSession: PDFPageDragSession?
    @State private var magnificationBaseline: Double?
    @State private var searchHitCountsByPage: [Int: Int] = [:]
    // 묶음 방식과 썸네일 배율은 PDF 내용이 아니라 사용자 보기 선호이므로
    // 문서 undo/session 대신 UserDefaults를 감싼 @AppStorage에 보관한다.
    @AppStorage(PageSidebarPreferences.layoutModeKey)
    private var layoutModeValue = PageSidebarLayoutMode.single.rawValue
    @AppStorage(PageSidebarPreferences.thumbnailScaleKey)
    private var thumbnailScaleValue = PageSidebarPreferences.defaultThumbnailScale
    @Environment(\.colorScheme) private var colorScheme

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }
    private var layoutMode: PageSidebarLayoutMode {
        PageSidebarLayoutMode(rawValue: layoutModeValue) ?? .single
    }
    private var thumbnailScale: Double {
        PageSidebarPreferences.clampedThumbnailScale(thumbnailScaleValue)
    }
    /// Selecting and navigating pages is available in every mode. Reordering,
    /// rotating, and deleting change PDF structure and belong to Editing only.
    private var canEditPages: Bool { workspace.allows(.pageEditing) }
    /// 실제 페이지 배열을 바꾸지 않고 표시용 그룹만 계산한다.
    private var pageGroups: [PageSidebarPageGroup] {
        layoutMode.groups(pageCount: workspace.pageCount)
    }
    var body: some View {
        Group {
            if placement.usesHorizontalPageStrip {
                horizontalPagePanel
            } else {
                verticalPagePanel
            }
        }
        .background(theme.sidebar)
        .foregroundStyle(theme.primaryText)
        .onAppear(perform: normalizeSavedPreferences)
        .onChange(of: layoutModeValue) { _, _ in
            normalizeSavedPreferences()
        }
        .onChange(of: thumbnailScaleValue) { _, newValue in
            let clamped = PageSidebarPreferences.clampedThumbnailScale(newValue)
            if clamped != newValue {
                thumbnailScaleValue = clamped
            }
        }
        .onReceive(workspace.$searchNavigatorResults) { results in
            // Compute once per published result batch. Looking this up from
            // every thumbnail must stay O(results + pages), even for a large
            // study document with thousands of matches.
            searchHitCountsByPage = Dictionary(grouping: results, by: \.pageIndex)
                .mapValues(\.count)
        }
        .onChange(of: workspace.mode) { _, _ in
            // A drag may have begun a moment before a Control-number shortcut
            // changed mode. Discard its local token so a later drop cannot use
            // the previous mode's authority.
            if !canEditPages {
                pageDragSession = nil
            }
        }
    }

    private var verticalPagePanel: some View {
        VStack(spacing: 0) {
            sidebarHeader
            horizontalDivider
            sidebarDisplayControls
            horizontalDivider
            verticalPageScroller
            if canEditPages {
                horizontalDivider
                sidebarFooter
            }
        }
        .frame(
            minWidth: PageSidebarPreferences.minimumVerticalPanelWidth(
                layoutMode: layoutMode,
                thumbnailScale: thumbnailScale
            ),
            maxWidth: .infinity,
            maxHeight: .infinity
        )
    }

    private var horizontalPagePanel: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                sidebarHeader
                horizontalDivider
                sidebarDisplayControls
            }
            .frame(width: 214)
            verticalDivider
            horizontalPageScroller
            if canEditPages {
                verticalDivider
                sidebarFooter
                    .frame(width: 112)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: PageSidebarPreferences.minimumHorizontalPanelHeight(
                layoutMode: layoutMode,
                thumbnailScale: thumbnailScale
            ),
            maxHeight: .infinity
        )
    }

    private var verticalPageScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 12) {
                    ForEach(pageGroups) { group in
                        verticalPageGroup(group)
                    }

                    if workspace.pageCount > 1, canEditPages {
                        pageEndDropTarget(horizontal: false)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 16)
            }
            .onChange(of: workspace.currentPageIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onChange(of: layoutModeValue) { _, _ in
                proxy.scrollTo(workspace.currentPageIndex, anchor: .center)
            }
            .simultaneousGesture(thumbnailMagnificationGesture)
        }
    }

    private var horizontalPageScroller: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(pageGroups) { group in
                        horizontalPageGroup(group)
                    }

                    if workspace.pageCount > 1, canEditPages {
                        pageEndDropTarget(horizontal: true)
                    }
                }
                .padding(.horizontal, 16)
                .padding(
                    .top,
                    CGFloat(PageSidebarLayoutMetrics.horizontalScrollerTopPadding)
                )
                .padding(
                    .bottom,
                    CGFloat(PageSidebarLayoutMetrics.horizontalScrollerBottomPadding)
                )
            }
            .onChange(of: workspace.currentPageIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
            .onChange(of: layoutModeValue) { _, _ in
                proxy.scrollTo(workspace.currentPageIndex, anchor: .center)
            }
            .simultaneousGesture(thumbnailMagnificationGesture)
        }
    }

    private var horizontalDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(height: 1)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1)
    }

    private var sidebarHeader: some View {
        VStack(spacing: 10) {
            HStack {
                headerTitle
                    .layoutPriority(0)
                Spacer(minLength: 6)
                PageJumpControl(workspace: workspace)
                    .layoutPriority(1)
            }

            DocumentSidebarModePicker(selection: $sidebarMode)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("페이지")
                .font(.headline.weight(.semibold))
                .lineLimit(1)
            Text(
                canEditPages
                    ? L10n.string("page.sidebar.edit_hint", defaultValue: "드래그하여 순서 변경")
                    : L10n.string("page.sidebar.view_hint", defaultValue: "선택하여 페이지 이동")
            )
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var sidebarDisplayControls: some View {
        VStack(spacing: 8) {
            Picker(
                L10n.string("page.sidebar.layout", defaultValue: "페이지 묶음 보기"),
                selection: layoutModeBinding
            ) {
                ForEach(PageSidebarLayoutMode.allCases) { mode in
                    Image(systemName: mode.symbolName)
                        .help(mode.title)
                        .accessibilityLabel(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(
                L10n.string("page.sidebar.layout", defaultValue: "페이지 묶음 보기")
            )
            .accessibilityValue(layoutMode.title)
            .help(
                L10n.string(
                    "page.sidebar.layout_help",
                    defaultValue: "좌우 2페이지는 1–2, 3–4 순서로 묶어 표시합니다."
                )
            )

            HStack(spacing: 6) {
                Button {
                    adjustThumbnailScale(by: -1)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("page.sidebar.zoom_out", defaultValue: "페이지 축소"))
                .accessibilityLabel(
                    L10n.string("page.sidebar.zoom_out", defaultValue: "페이지 축소")
                )
                .disabled(
                    thumbnailScale <= PageSidebarPreferences.minimumThumbnailScale + 0.0001
                )

                Slider(
                    value: thumbnailScaleBinding,
                    in: PageSidebarPreferences.minimumThumbnailScale
                        ... PageSidebarPreferences.maximumThumbnailScale,
                    step: 0.05
                )
                .controlSize(.small)
                .accessibilityLabel(
                    L10n.string("page.sidebar.thumbnail_size", defaultValue: "페이지 미리보기 크기")
                )
                .accessibilityValue("\(thumbnailScalePercent)%")

                Button {
                    adjustThumbnailScale(by: 1)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(L10n.string("page.sidebar.zoom_in", defaultValue: "페이지 확대"))
                .accessibilityLabel(
                    L10n.string("page.sidebar.zoom_in", defaultValue: "페이지 확대")
                )
                .disabled(
                    thumbnailScale >= PageSidebarPreferences.maximumThumbnailScale - 0.0001
                )

                Text("\(thumbnailScalePercent)%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 34, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var layoutModeBinding: Binding<PageSidebarLayoutMode> {
        Binding(
            get: { layoutMode },
            set: { layoutModeValue = $0.rawValue }
        )
    }

    private var thumbnailScaleBinding: Binding<Double> {
        Binding(
            get: { thumbnailScale },
            set: {
                thumbnailScaleValue = PageSidebarPreferences.clampedThumbnailScale($0)
            }
        )
    }

    private var thumbnailScalePercent: Int {
        Int((thumbnailScale * 100).rounded())
    }

    private var verticalThumbnailWidth: CGFloat {
        let baseWidth: CGFloat = layoutMode == .single ? 148 : 72
        return baseWidth * CGFloat(thumbnailScale)
    }

    private var horizontalThumbnailWidth: CGFloat {
        let baseWidth: CGFloat = layoutMode == .single ? 108 : 72
        return baseWidth * CGFloat(thumbnailScale)
    }

    @ViewBuilder
    private func verticalPageGroup(_ group: PageSidebarPageGroup) -> some View {
        switch layoutMode {
        case .single:
            pageSlot(group.slots.first ?? nil, thumbnailWidth: verticalThumbnailWidth)

        case .facingPages:
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(group.slots.enumerated()), id: \.offset) { _, pageIndex in
                    pageSlot(pageIndex, thumbnailWidth: verticalThumbnailWidth)
                }
            }
            .modifier(PageSidebarGroupCard(theme: theme))

        case .fourPages:
            LazyVGrid(
                columns: [
                    GridItem(.fixed(verticalThumbnailWidth + 16), spacing: 6),
                    GridItem(.fixed(verticalThumbnailWidth + 16), spacing: 6)
                ],
                alignment: .center,
                spacing: 6
            ) {
                ForEach(Array(group.slots.enumerated()), id: \.offset) { _, pageIndex in
                    pageSlot(pageIndex, thumbnailWidth: verticalThumbnailWidth)
                }
            }
            .modifier(PageSidebarGroupCard(theme: theme))
        }
    }

    @ViewBuilder
    private func horizontalPageGroup(_ group: PageSidebarPageGroup) -> some View {
        if layoutMode == .single {
            pageSlot(group.slots.first ?? nil, thumbnailWidth: horizontalThumbnailWidth)
        } else {
            HStack(alignment: .top, spacing: 6) {
                ForEach(Array(group.slots.enumerated()), id: \.offset) { _, pageIndex in
                    pageSlot(pageIndex, thumbnailWidth: horizontalThumbnailWidth)
                }
            }
            .modifier(PageSidebarGroupCard(theme: theme))
        }
    }

    @ViewBuilder
    private func pageSlot(_ pageIndex: Int?, thumbnailWidth: CGFloat) -> some View {
        if
            let pageIndex,
            let page = workspace.document?.page(at: pageIndex)
        {
            pageRow(page: page, index: pageIndex, thumbnailWidth: thumbnailWidth)
                .frame(width: thumbnailWidth + 16)
                .id(pageIndex)
        } else {
            Color.clear
                .frame(
                    width: thumbnailWidth + 16,
                    height: thumbnailWidth * 1.35 + 25
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func pageRow(page: PDFPage, index: Int, thumbnailWidth: CGFloat) -> some View {
        let selected = workspace.selectedPages.contains(index)
        let searchHitCount = searchHitCountsByPage[index] ?? 0
        let pageButton = Button {
            updateSelection(index)
        } label: {
            PageThumbnailView(
                page: page,
                pageIndex: index,
                width: thumbnailWidth,
                revision: workspace.revision
            )
            .frame(width: thumbnailWidth)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? theme.dropHighlight : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? theme.accent : Color.clear, lineWidth: 1.5)
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(theme.ribbon)
                        .frame(width: 3)
                        .padding(.vertical, 12)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.accent)
                        .background(theme.card, in: Circle())
                        .padding(7)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if searchHitCount > 0 {
                    Label("\(searchHitCount)", systemImage: "magnifyingglass")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(theme.card.opacity(0.96), in: Capsule())
                        .overlay {
                            Capsule().stroke(theme.accent.opacity(0.55), lineWidth: 1)
                        }
                        .padding(7)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.format("page.number", index + 1))
        .accessibilityValue(
            pageAccessibilityValue(selected: selected, searchHitCount: searchHitCount)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])

        let contextualPageButton = pageButton.contextMenu {
            Menu(L10n.string("menu.export_selected_pages")) {
                Button(L10n.string("menu.export_selected_pages.combined")) {
                    exportSelectedPagesCombined(clickedIndex: index)
                }
                Button(L10n.string("menu.export_selected_pages.individual")) {
                    exportSelectedPagesIndividually(clickedIndex: index)
                }
            }
            .disabled(!workspace.canExtractPages)

            if canEditPages {
                Divider()
                Button(L10n.string("왼쪽으로 회전")) {
                    prepareContextSelection(for: index)
                    workspace.rotateSelectedPages(clockwise: false)
                }
                Button(L10n.string("오른쪽으로 회전")) {
                    prepareContextSelection(for: index)
                    workspace.rotateSelectedPages(clockwise: true)
                }
                Divider()
                Button(L10n.string("선택 페이지 삭제"), role: .destructive) {
                    prepareContextSelection(for: index)
                    workspace.deleteSelectedPages()
                }
            }
        }

        if canEditPages {
            contextualPageButton
                .accessibilityHint(
                    L10n.string("page.sidebar.edit_accessibility_hint")
                )
                .onDrag {
                    let session = PDFPageDragSession(
                        sourceIndex: index,
                        documentRevision: workspace.revision
                    )
                    pageDragSession = session
                    return PDFPageDragPayload.itemProvider(for: session)
                }
                .modifier(
                    PageReorderDropTargetModifier(
                        isEnabled: pageDragSession != nil,
                        target: index,
                        pageDragSession: $pageDragSession,
                        workspace: workspace
                    )
                )
        } else {
            // Read-only page export remains available in Viewer and Study;
            // mutation-only drag, rotate, and delete affordances stay absent.
            contextualPageButton
                .accessibilityHint(
                    L10n.string("page.sidebar.view_accessibility_hint")
                )
        }
    }

    private func pageAccessibilityValue(selected: Bool, searchHitCount: Int) -> String {
        let selection = selected
            ? L10n.string("selection.selected")
            : L10n.string("selection.not_selected")
        guard searchHitCount > 0 else { return selection }
        return "\(selection), \(L10n.format("search.navigator.page_hit_count", searchHitCount))"
    }

    private func prepareContextSelection(for index: Int) {
        if !workspace.selectedPages.contains(index) {
            workspace.selectedPages = [index]
        }
        workspace.setCurrentPage(index)
    }

    private func exportSelectedPagesCombined(clickedIndex: Int) {
        guard workspace.canExtractPages else { return }
        prepareContextSelection(for: clickedIndex)
        guard !workspace.selectedPages.isEmpty else { return }
        if let url = WorkspaceFilePanels.chooseSavePDF(
            suggestedName: SelectedPagePDFExporter.combinedFileName(
                for: workspace.documentURL
            ),
            title: L10n.string("panel.title.save_selected_pages_combined")
        ) {
            workspace.exportSelectedPagesAsCombinedPDF(to: url)
        }
    }

    private func exportSelectedPagesIndividually(clickedIndex: Int) {
        guard workspace.canExtractPages else { return }
        prepareContextSelection(for: clickedIndex)
        guard !workspace.selectedPages.isEmpty else { return }
        if let directory = WorkspaceFilePanels.chooseDirectory(
            title: L10n.string("panel.title.choose_individual_pages_folder"),
            message: L10n.format(
                "panel.message.export_individual_pages",
                workspace.selectedPages.count
            )
        ) {
            workspace.exportSelectedPagesAsIndividualPDFs(to: directory)
        }
    }

    private func pageEndDropTarget(horizontal: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(pageDragSession == nil ? Color.clear : theme.dropHighlight)
            .frame(width: horizontal ? 74 : nil, height: horizontal ? 150 : 36)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        pageDragSession == nil ? Color.clear : theme.accent.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
            .overlay {
                if pageDragSession != nil {
                    Label(
                        "문서 끝으로 이동",
                        systemImage: horizontal ? "arrow.right.to.line" : "arrow.down.to.line"
                    )
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                    .labelStyle(.iconOnly)
                }
            }
            .modifier(
                PageEndDropTargetModifier(
                    isEnabled: pageDragSession != nil,
                    pageDragSession: $pageDragSession,
                    workspace: workspace
                )
            )
            .accessibilityLabel("문서 끝으로 이동")
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            Button {
                workspace.moveSelectedPage(by: -1)
            } label: {
                Image(systemName: placement.usesHorizontalPageStrip ? "arrow.left" : "arrow.up")
            }
            .help("선택 페이지를 앞으로 이동")
            .disabled(
                !canEditPages
                    || workspace.selectedPages.count != 1
                    || workspace.selectedPages.contains(0)
            )

            Button {
                workspace.moveSelectedPage(by: 1)
            } label: {
                Image(systemName: placement.usesHorizontalPageStrip ? "arrow.right" : "arrow.down")
            }
            .help("선택 페이지를 뒤로 이동")
            .disabled(
                !canEditPages
                    || workspace.selectedPages.count != 1
                    || workspace.selectedPages.contains(max(0, workspace.pageCount - 1))
            )

            Spacer()

            Button(role: .destructive) {
                workspace.deleteSelectedPages()
            } label: {
                Image(systemName: "trash")
            }
            .help("선택 페이지 삭제")
            .disabled(!canEditPages || workspace.selectedPages.isEmpty || workspace.pageCount <= 1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    private var thumbnailMagnificationGesture: some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.01)
            .onChanged { magnification in
                if magnificationBaseline == nil {
                    magnificationBaseline = thumbnailScale
                }
                let baseline = magnificationBaseline ?? thumbnailScale
                thumbnailScaleValue = PageSidebarPreferences.clampedThumbnailScale(
                    baseline * Double(magnification)
                )
            }
            .onEnded { _ in
                magnificationBaseline = nil
            }
    }

    private func adjustThumbnailScale(by steps: Int) {
        thumbnailScaleValue = PageSidebarPreferences.adjustedThumbnailScale(
            thumbnailScale,
            steps: steps
        )
    }

    private func normalizeSavedPreferences() {
        if PageSidebarLayoutMode(rawValue: layoutModeValue) == nil {
            layoutModeValue = PageSidebarLayoutMode.single.rawValue
        }

        let clampedScale = PageSidebarPreferences.clampedThumbnailScale(thumbnailScaleValue)
        if clampedScale != thumbnailScaleValue {
            thumbnailScaleValue = clampedScale
        }
    }

    private func updateSelection(_ index: Int) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if workspace.selectedPages.contains(index) {
                workspace.selectedPages.remove(index)
            } else {
                workspace.selectedPages.insert(index)
            }
        } else if flags.contains(.shift), let anchor = workspace.selectedPages.min() {
            workspace.selectedPages = Set(min(anchor, index)...max(anchor, index))
        } else {
            workspace.selectedPages = [index]
        }
        workspace.setCurrentPage(index)
    }
}

private struct PageSidebarGroupCard: ViewModifier {
    let theme: VibePDFTheme

    func body(content: Content) -> some View {
        content
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.card.opacity(0.55))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.border.opacity(0.7), lineWidth: 0.75)
            }
            .accessibilityElement(children: .contain)
    }
}

/// SwiftUI installs every onDrop as a broad AppKit data/item destination even
/// when the declared type is plain text. Keep those nested destinations out of
/// the hierarchy until an app-owned page drag actually starts so Finder files
/// fall through to the one workspace-level fileURL receiver.
private struct PageReorderDropTargetModifier: ViewModifier {
    let isEnabled: Bool
    let target: Int
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(
                of: [PDFPageDragPayload.typeIdentifier],
                delegate: PageReorderDropDelegate(
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

private struct PageEndDropTargetModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var pageDragSession: PDFPageDragSession?
    let workspace: PDFWorkspaceState

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(
                of: [PDFPageDragPayload.typeIdentifier],
                delegate: PageEndDropDelegate(
                    pageDragSession: $pageDragSession,
                    workspace: workspace
                )
            )
        } else {
            content
        }
    }
}

private struct PageEndDropDelegate: DropDelegate {
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

private struct PageReorderDropDelegate: DropDelegate {
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

// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// 활성 탭의 전체 문서 화면을 조립하는 SwiftUI container다.
///
/// 이 뷰는 툴바, 페이지/검색 사이드바, PDFKit 또는 grid 본문, AI panel과
/// 여러 sheet를 배치한다. 문서 편집 규칙은 `PDFWorkspaceState`에 남기고 여기서는
/// 화면 전환·panel resize처럼 presentation에 가까운 상태만 관리한다.
/// 탭 전환 시 뷰가 재생성되어도 장기 상태는 environment의 workspace가 보존한다.
struct WorkspaceView: View {
    let multiDocumentWorkspace: MultiDocumentWorkspaceState
    let openDocument: () -> Void
    let recentDocuments: [RecentDocument]
    let openRecentDocument: (RecentDocument) -> Void
    let removeRecentDocument: (RecentDocument) -> Void
    let clearRecentDocuments: () -> Void
    let isActive: Bool
    let isFocusMode: Bool
    let setFocusMode: (Bool) -> Void

    /// 부모 탭이 주입한 단일 문서 모델. EnvironmentObject는 깊은 자식에게 같은
    /// 인스턴스를 전달할 때 initializer 인자 폭증을 줄여 준다.
    @EnvironmentObject private var workspace: PDFWorkspaceState
    @EnvironmentObject private var aiSettings: AIProviderSettingsStore
    @EnvironmentObject private var pluginManager: PluginManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("pageOverviewPlacement") private var pageOverviewPlacementValue = PageOverviewPlacement.left.rawValue
    @AppStorage("fourPagePagingDirection") private var gridPagingDirectionValue = PDFGridPagingDirection.vertical.rawValue
    /// Presentation belongs to one window scene. AppStorage broadcast panel
    /// dismissal across every PDF window, which removed another window's
    /// sidebar and triggered its request-cancellation lifecycle.
    @SceneStorage("ai.assistantPanelVisible") private var aiPanelVisible = false
    @AppStorage(WorkspaceChromePreferences.modeToolsVisibleKey)
    private var modeToolsVisible = true
    @AppStorage(PageSidebarPreferences.layoutModeKey)
    private var pageSidebarLayoutModeValue = PageSidebarLayoutMode.single.rawValue
    @AppStorage(PageSidebarPreferences.thumbnailScaleKey)
    private var pageSidebarThumbnailScaleValue = PageSidebarPreferences.defaultThumbnailScale
    // Panel dimensions are viewing preferences like placement and thumbnail
    // scale, so they persist app-wide rather than becoming document edits or
    // per-tab session records. Width and height remain independent.
    @AppStorage(PageSidebarPreferences.verticalPanelWidthKey)
    private var preferredPageSidebarWidth = PageSidebarResizeMetrics.defaultVerticalPanelWidth
    @AppStorage(PageSidebarPreferences.horizontalPanelHeightKey)
    private var preferredPageSidebarHeight = PageSidebarResizeMetrics.defaultHorizontalPanelHeight
    @AppStorage(PageSidebarPreferences.compactHorizontalPanelMigrationKey)
    private var didMigrateCompactHorizontalPanelHeight = false
    // 아래 @State는 모두 현재 화면 수명에만 필요한 presentation state다.
    // PDF 내용/페이지/dirty 여부는 절대 이곳에 중복 저장하지 않는다.
    @State private var showingSignature = false
    @State private var showingOCR = false
    @State private var pendingShareNote: PDFShareNote?
    @State private var gridVisiblePageIndex: Int?
    @State private var isTransitioningGridMode = false
    @State private var gridTransitionTargetPageIndex: Int?
    @State private var gridTransitionToken = UUID()
    // Store only the controller identity here. The parent intentionally does
    // not observe objectWillChange; `PageScrollHUDOverlay` is the sole observer.
    @State private var pageScrollHUDController = PageScrollHUDController()
    @State private var pageSidebarResizeBaseline: Double?
    @State private var livePageSidebarDimension: Double?
    @State private var isPageSidebarDividerHovered = false
    @State private var sidebarMode = DocumentSidebarMode.pages

    init(
        multiDocumentWorkspace: MultiDocumentWorkspaceState,
        openDocument: @escaping () -> Void,
        recentDocuments: [RecentDocument],
        openRecentDocument: @escaping (RecentDocument) -> Void,
        removeRecentDocument: @escaping (RecentDocument) -> Void,
        clearRecentDocuments: @escaping () -> Void,
        isActive: Bool = true,
        isFocusMode: Bool = false,
        setFocusMode: @escaping (Bool) -> Void = { _ in }
    ) {
        self.multiDocumentWorkspace = multiDocumentWorkspace
        self.openDocument = openDocument
        self.recentDocuments = recentDocuments
        self.openRecentDocument = openRecentDocument
        self.removeRecentDocument = removeRecentDocument
        self.clearRecentDocuments = clearRecentDocuments
        self.isActive = isActive
        self.isFocusMode = isFocusMode
        self.setFocusMode = setFocusMode
    }

    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    var body: some View {
        presentedWorkspace
            .sheet(isPresented: $workspace.pluginCommandPaletteVisible) {
                PluginCommandPalette(manager: pluginManager, workspace: workspace)
            }
    }

    private var workspaceSurface: some View {
        Group {
            if !workspace.hasOpenDocument {
                WelcomeView(
                    openDocument: openDocument,
                    recentDocuments: recentDocuments,
                    openRecentDocument: openRecentDocument,
                    removeRecentDocument: removeRecentDocument,
                    clearRecentDocuments: clearRecentDocuments
                )
            } else {
                openedDocumentWorkspace
            }
        }
        .background(theme.canvas)
        .safeAreaInset(edge: .bottom) {
            if let warning = workspace.recoveryWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).padding(8).background(.regularMaterial)
            }
            if let progress = workspace.officeExportProgress {
                HStack {
                    ProgressView(value: progress).frame(maxWidth: 180)
                    Text(L10n.string("conversion.office.menu"))
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                    Spacer()
                    Button(L10n.string("action.cancel")) { workspace.cancelOfficeExport() }
                }
                .padding(10)
                .background(.regularMaterial)
            }
        }
        .tint(theme.accent)
        .contentShape(Rectangle())
    }

    private var layoutObservedWorkspace: some View {
        workspaceSurface
        .onAppear {
            migrateLegacyHorizontalPageSidebarHeightIfNeeded()
            // WorkspaceView is intentionally recreated when tabs switch so
            // PDFKit caches can be released. Restore the lightweight search
            // presentation from the tab-owned search state.
            if
                workspace.isSearching
                    || !workspace.searchNavigatorResults.isEmpty
                    || !workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                sidebarMode = .search
            }
        }
        .onChange(of: workspace.currentPageIndex) { _, newValue in
            if workspace.pageColumns > 2 {
                gridVisiblePageIndex = newValue
            }
        }
        .onChange(of: workspace.pageColumns) { _, newValue in
            resetPageScrollHUD()
            if newValue > 2 {
                beginGridTransition(anchoredAt: workspace.currentPageIndex)
            } else {
                isTransitioningGridMode = false
                gridTransitionTargetPageIndex = nil
                gridVisiblePageIndex = nil
            }
        }
        .onChange(of: workspace.twoPageDisplayMode) { _, _ in
            resetPageScrollHUD()
        }
        .onChange(of: workspace.gridLayoutMode) { _, _ in
            guard workspace.pageColumns > 2 else { return }
            beginGridTransition(anchoredAt: workspace.currentPageIndex)
        }
        .onChange(of: gridPagingDirectionValue) { _, _ in
            guard workspace.pageColumns == PDFGridPageGroup.pageCountPerGroup else { return }
            beginGridTransition(anchoredAt: workspace.currentPageIndex)
        }
        .onChange(of: pageOverviewPlacementValue) { _, _ in
            resetPageSidebarResizeInteraction()
        }
        .onChange(of: workspace.sidebarVisible) { _, _ in
            resetPageSidebarResizeInteraction()
        }
        .onChange(of: isFocusMode) { _, newValue in
            resetPageSidebarResizeInteraction()
            resetPageScrollHUD()
            if newValue {
                if aiPanelVisible {
                    workspace.aiAssistantSession.cancelActiveRequest()
                }
                workspace.pluginPanelRequest = nil
            }
        }
    }

    private var lifecycleWorkspace: some View {
        layoutObservedWorkspace
        .onChange(of: documentIdentity) { _, _ in
            resetPageScrollHUD()
            sidebarMode = .pages
        }
        .onChange(of: workspace.documentURL) { _, _ in
            workspace.aiAssistantSession.documentDidChange()
            workspace.pluginPanelRequest = nil
        }
        .onChange(of: workspace.hasOpenDocument) { _, _ in
            resetPageSidebarResizeInteraction()
        }
        .onChange(of: isActive) { _, newValue in
            if !newValue {
                resetPageScrollHUD()
                workspace.pluginPanelRequest = nil
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue != .active {
                resetPageScrollHUD()
                workspace.pluginPanelRequest = nil
            }
        }
        .onChange(of: workspace.mode) { _, newMode in
            // Global mode shortcuts remain active while a sheet is presented.
            // Dismiss captured signature data as soon as the destination mode
            // no longer permits applying it; addSignature also re-checks this
            // at the model boundary in case dismissal has not completed yet.
            if !newMode.allows(.signature) {
                showingSignature = false
            }
            if workspace.pluginPanelRequest?.kind == .translation,
               !newMode.allows(.translation) {
                workspace.pluginPanelRequest = nil
            }
        }
        .onChange(of: workspace.pluginPanelRequest) { _, newValue in
            if newValue != nil {
                if aiPanelVisible {
                    workspace.aiAssistantSession.cancelActiveRequest()
                }
                aiPanelVisible = false
                // A plug-in launched from the macOS menu remains available
                // while focus mode hides app chrome. Reveal the requested
                // companion instead of leaving a valid panel request invisible.
                if isFocusMode {
                    setFocusMode(false)
                }
            }
        }
        .onChange(of: workspace.revision) { _, newRevision in
            if let request = workspace.pluginPanelRequest,
               request.documentRevision != newRevision {
                workspace.pluginPanelRequest = nil
            }
            if let request = workspace.pendingProtectedExport,
               request.documentRevision != newRevision {
                workspace.cancelProtectedPDFExport()
            }
        }
        .onDisappear {
            resetPageSidebarResizeInteraction()
            resetPageScrollHUD()
            workspace.aiAssistantSession.cancelActiveRequest()
            workspace.pluginPanelRequest = nil
            workspace.cancelProtectedPDFExport()
        }
        .onReceive(pluginManager.$installedPlugins) { plugins in
            guard let request = workspace.pluginPanelRequest else { return }
            let isStillAuthorized = plugins.contains {
                $0.isEnabled
                    && $0.id == request.pluginIdentifier
                    && $0.manifestDigest == request.manifestDigest
            }
            if !isStillAuthorized {
                workspace.pluginPanelRequest = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusDocumentSearch)) { note in
            guard let target = note.object as? PDFWorkspaceState, target === workspace else { return }
            if isFocusMode {
                // WorkspaceToolbar remains mounted at zero height in focus
                // mode so it receives this same notification and can restore
                // its search field focus when the chrome becomes visible.
                setFocusMode(false)
            }
        }
    }

    private var presentedWorkspace: some View {
        lifecycleWorkspace
        .sheet(item: $workspace.pendingTextEdit) { edit in
            TextEditSheet(
                edit: edit,
                onCommit: workspace.commitPendingText,
                onDraftChanged: { text in
                    workspace.updatePendingTextDraft(id: edit.id, text: text)
                },
                onCancel: workspace.cancelPendingText
            )
        }
        .sheet(isPresented: $showingSignature) {
            SignatureSheet(
                settings: $workspace.signatureSettings,
                onStorageError: { workspace.presentedError = $0 },
                onApply: workspace.addSignature
            )
        }
        .sheet(isPresented: $showingOCR) {
            OCRSheet(workspace: workspace, onExport: exportOCRCopy)
        }
        .sheet(item: $workspace.pendingProtectedExport) { presentation in
            PDFSecurityExportSheet(
                onSubmit: { request in
                    exportProtectedPDF(presentation, request: request)
                },
                onCancel: workspace.cancelProtectedPDFExport
            )
        }
        .sheet(item: $pendingShareNote) { note in
            PDFShareNoteSheet(note: note)
        }
        .alert(
            "HwattakPDF",
            isPresented: Binding(
                get: { workspace.presentedError != nil },
                set: { if !$0 { workspace.clearError() } }
            )
        ) {
            Button(L10n.string("action.confirm")) { workspace.clearError() }
        } message: {
            Text(workspace.presentedError ?? L10n.string("알 수 없는 오류"))
        }
    }

    /// The main `body` already owns drop handling, lifecycle observers and
    /// sheets. Keeping the open-document hierarchy in a separate builder makes
    /// Swift's generic type-checker handle this large screen deterministically.
    private var openedDocumentWorkspace: some View {
        VStack(spacing: 0) {
            WorkspaceToolbar(
                workspace: workspace,
                modeToolsVisible: $modeToolsVisible,
                sidebarVisible: sidebarVisibleBinding,
                pageOverviewPlacement: pageOverviewPlacementBinding,
                gridLayoutMode: gridLayoutModeBinding,
                gridPagingDirection: gridPagingDirectionBinding,
                aiPanelVisible: aiPanelVisibleBinding,
                sidebarMode: $sidebarMode,
                openDocument: openDocument,
                saveDocument: {
                    WorkspaceSaveCoordinator.requestSave(workspace: workspace)
                },
                mergeDocument: mergeDocument,
                exportSelectedPagesCombined: exportSelectedPagesCombined,
                exportSelectedPagesIndividually: exportSelectedPagesIndividually,
                insertImage: insertImage,
                showSignature: { showingSignature = true },
                showOCR: { showingOCR = true },
                shareNote: prepareShareNote,
                enterFocusMode: { setFocusMode(true) }
            )
            .frame(height: isFocusMode ? 0 : nil)
            .opacity(isFocusMode ? 0 : 1)
            .clipped()
            .allowsHitTesting(!isFocusMode)
            .accessibilityHidden(isFocusMode)
            // 학습 팔레트는 capability 정책이 허용한 mode에서만 만들어진다.
            // 숨김 처리와 달리 다른 mode의 포커스·접근성 트리에서도 빠진다.
            if !isFocusMode, modeToolsVisible, workspace.allows(.studyTools) {
                StudyModePalette(
                    workspace: workspace,
                    providerSettings: aiSettings,
                    documentCollection: multiDocumentWorkspace,
                    onOpenAssistant: openAIAssistant,
                    showOCR: { showingOCR = true },
                    shareNote: prepareShareNote
                )
            }
            workspaceWithAIAssistant
        }
    }

    @ViewBuilder
    private var workspaceWithAIAssistant: some View {
        // The binding is a remembered presentation preference, not authority.
        // Check the current tab policy again at the render boundary so a mode
        // shortcut cannot leave an AI panel visible for Editing mode.
        if !isFocusMode, let request = activePluginPanelRequest {
            HSplitView {
                workspacePages
                    .frame(
                        minWidth: max(520, workspacePagesMinimumWidth),
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )

                PluginPanelHostView(
                    request: request,
                    onClose: { workspace.pluginPanelRequest = nil }
                )
                .frame(minWidth: 360, idealWidth: 440, maxWidth: 680)
            }
        } else if !isFocusMode, aiPanelVisible, workspace.allows(.aiAssistance) {
            HSplitView {
                workspacePages
                    .frame(
                        minWidth: max(520, workspacePagesMinimumWidth),
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )

                AIAssistantSidebar(
                    viewModel: workspace.aiAssistantSession,
                    workspace: workspace,
                    documentCollection: multiDocumentWorkspace,
                    providerSettings: aiSettings,
                    onOpenRelatedPDF: openRelatedPDF,
                    onRequestDraftApplication: { draft, target in
                        _ = workspace.prepareAITextDraft(draft, target: target)
                    },
                    onClose: closeAIAssistant
                )
                .frame(minWidth: 350, idealWidth: 410, maxWidth: 540)
            }
        } else {
            workspacePages
        }
    }

    @ViewBuilder
    private var workspacePages: some View {
        GeometryReader { geometry in
            workspacePagesContent(availableSize: geometry.size)
        }
        .frame(
            minWidth: workspacePagesMinimumWidth,
            minHeight: workspacePagesMinimumHeight
        )
    }

    @ViewBuilder
    private func workspacePagesContent(availableSize: CGSize) -> some View {
        let dimension = resolvedPageSidebarDimension(availableSize: availableSize)
        switch pageOverviewPlacement {
        case .left:
            HStack(spacing: 0) {
                if effectiveSidebarVisible {
                    pageOverviewPanel
                        .frame(width: dimension)
                    pageOverviewResizeDivider(
                        availableLength: availableSize.width,
                        currentDimension: dimension
                    )
                    .environment(\.layoutDirection, layoutDirection)
                }
                documentCanvas
                    .frame(minWidth: PageSidebarResizeMetrics.minimumDocumentWidth)
            }
            // Placement names are physical left/right. Keep container order
            // stable in RTL while restoring the user's direction inside the
            // page panel and its accessible divider.
            .environment(\.layoutDirection, .leftToRight)
        case .right:
            HStack(spacing: 0) {
                documentCanvas
                    .frame(minWidth: PageSidebarResizeMetrics.minimumDocumentWidth)
                if effectiveSidebarVisible {
                    pageOverviewResizeDivider(
                        availableLength: availableSize.width,
                        currentDimension: dimension
                    )
                    .environment(\.layoutDirection, layoutDirection)
                    pageOverviewPanel
                        .frame(width: dimension)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        case .top:
            VStack(spacing: 0) {
                if effectiveSidebarVisible {
                    pageOverviewPanel
                        .frame(height: dimension)
                    pageOverviewResizeDivider(
                        availableLength: availableSize.height,
                        currentDimension: dimension
                    )
                }
                documentCanvas
                    .frame(minHeight: PageSidebarResizeMetrics.minimumDocumentHeight)
            }
        case .bottom:
            VStack(spacing: 0) {
                documentCanvas
                    .frame(minHeight: PageSidebarResizeMetrics.minimumDocumentHeight)
                if effectiveSidebarVisible {
                    pageOverviewResizeDivider(
                        availableLength: availableSize.height,
                        currentDimension: dimension
                    )
                    pageOverviewPanel
                        .frame(height: dimension)
                }
            }
        }
    }

    private var pageOverviewPanel: some View {
        Group {
            switch sidebarMode {
            case .pages:
                PageSidebarView(
                    workspace: workspace,
                    placement: pageOverviewPlacement,
                    sidebarMode: $sidebarMode
                )
            case .search:
                SearchNavigatorSidebarView(
                    workspace: workspace,
                    placement: pageOverviewPlacement,
                    sidebarMode: $sidebarMode,
                    onRequestOCR: { showingOCR = true }
                )
            }
        }
        .environment(\.layoutDirection, layoutDirection)
    }

    private var documentCanvas: some View {
        let scrollActivityHandler = pageScrollActivityHandler
        return Group {
            if workspace.pageColumns <= 2 {
                PDFKitViewer(
                    workspace: workspace,
                    onScrollActivity: scrollActivityHandler
                )
            } else {
                PDFGridOverview(
                    workspace: workspace,
                    layoutMode: workspace.gridLayoutMode,
                    pagingDirection: gridPagingDirection,
                    onPageGroupChange: handleGridPageGroupChange,
                    onScrollActivity: scrollActivityHandler,
                    onVisiblePageChange: handleGridVisiblePageChange,
                    onPageDoubleClick: openGridPage
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.layoutDirection, .leftToRight)
        .overlay {
            PageScrollHUDOverlay(
                controller: pageScrollHUDController,
                pageRange: pageDisplayRange,
                pageCount: workspace.pageCount,
                trailingPadding: pageHUDTrailingPadding,
                theme: theme
            )
        }
    }

    private var pageOverviewPlacement: PageOverviewPlacement {
        PageOverviewPlacement(rawValue: pageOverviewPlacementValue) ?? .left
    }

    private var pageSidebarLayoutMode: PageSidebarLayoutMode {
        PageSidebarLayoutMode(rawValue: pageSidebarLayoutModeValue) ?? .single
    }

    private var pageSidebarThumbnailScale: Double {
        PageSidebarPreferences.clampedThumbnailScale(pageSidebarThumbnailScaleValue)
    }

    private var pageSidebarMinimumDimension: Double {
        sidebarMode.minimumPanelDimension(for: pageOverviewPlacement)
            ?? PageSidebarResizeMetrics.minimumPanelDimension(
                for: pageOverviewPlacement,
                layoutMode: pageSidebarLayoutMode,
                thumbnailScale: pageSidebarThumbnailScale
            )
    }

    private func enforcingSidebarModeMinimum(_ dimension: Double) -> Double {
        max(pageSidebarMinimumDimension, dimension)
    }

    private var workspacePagesMinimumWidth: CGFloat {
        guard effectiveSidebarVisible, !pageOverviewPlacement.usesHorizontalPageStrip else {
            return CGFloat(PageSidebarResizeMetrics.minimumDocumentWidth)
        }
        return CGFloat(pageSidebarMinimumDimension + PageSidebarResizeMetrics.dividerHitLength
            + PageSidebarResizeMetrics.minimumDocumentWidth)
    }

    private var workspacePagesMinimumHeight: CGFloat {
        guard effectiveSidebarVisible, pageOverviewPlacement.usesHorizontalPageStrip else {
            return CGFloat(PageSidebarResizeMetrics.minimumDocumentHeight)
        }
        return CGFloat(pageSidebarMinimumDimension + PageSidebarResizeMetrics.dividerHitLength
            + PageSidebarResizeMetrics.minimumDocumentHeight)
    }

    private func resolvedPageSidebarDimension(availableSize: CGSize) -> CGFloat {
        guard effectiveSidebarVisible else { return 0 }
        let preferred = livePageSidebarDimension ?? (
            pageOverviewPlacement.usesHorizontalPageStrip
                ? preferredPageSidebarHeight
                : preferredPageSidebarWidth
        )
        let availableLength = pageOverviewPlacement.usesHorizontalPageStrip
            ? availableSize.height
            : availableSize.width
        return CGFloat(enforcingSidebarModeMinimum(PageSidebarResizeMetrics.resolvedDimension(
            preferredDimension: preferred,
            placement: pageOverviewPlacement,
            availableLength: Double(availableLength),
            layoutMode: pageSidebarLayoutMode,
            thumbnailScale: pageSidebarThumbnailScale,
            minimumDimensionOverride: sidebarMode.minimumPanelDimension(
                for: pageOverviewPlacement
            )
        )))
    }

    private func pageOverviewResizeDivider(
        availableLength: CGFloat,
        currentDimension: CGFloat
    ) -> some View {
        let vertical = !pageOverviewPlacement.usesHorizontalPageStrip
        let isActive = pageSidebarResizeBaseline != nil
        return ZStack {
            Color.clear
            Rectangle()
                .fill(isActive || isPageSidebarDividerHovered ? theme.accent : theme.border)
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        }
        .frame(
            width: vertical ? CGFloat(PageSidebarResizeMetrics.dividerHitLength) : nil,
            height: vertical ? nil : CGFloat(PageSidebarResizeMetrics.dividerHitLength)
        )
        .background(
            isActive || isPageSidebarDividerHovered
                ? theme.dropHighlight
                : Color.clear
        )
        .contentShape(Rectangle())
        .gesture(
            pageSidebarResizeGesture(
                availableLength: Double(availableLength),
                currentDimension: Double(currentDimension)
            )
        )
        .onHover(perform: updatePageSidebarDividerHover)
        .focusable()
        .onMoveCommand { direction in
            movePageSidebarDivider(
                direction,
                availableLength: Double(availableLength),
                currentDimension: Double(currentDimension)
            )
        }
        .help(
            L10n.string(
                "page.sidebar.resize_hint",
                defaultValue: "드래그하거나 방향키로 페이지 패널 크기를 조절합니다."
            )
        )
        .accessibilityElement()
        .accessibilityLabel(
            L10n.string(
                "page.sidebar.resize",
                defaultValue: "페이지 패널 크기 조절"
            )
        )
        .accessibilityValue("\(Int(currentDimension.rounded())) pt")
        .accessibilityAdjustableAction { direction in
            let steps: Int
            switch direction {
            case .increment: steps = 1
            case .decrement: steps = -1
            @unknown default: return
            }
            adjustPageSidebarDimension(
                steps: steps,
                availableLength: Double(availableLength),
                currentDimension: Double(currentDimension)
            )
        }
    }

    private func pageSidebarResizeGesture(
        availableLength: Double,
        currentDimension: Double
    ) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if pageSidebarResizeBaseline == nil {
                    pageSidebarResizeBaseline = currentDimension
                }
                let baseline = pageSidebarResizeBaseline ?? currentDimension
                let translation = pageOverviewPlacement.usesHorizontalPageStrip
                    ? Double(value.translation.height)
                    : Double(value.translation.width)
                livePageSidebarDimension = enforcingSidebarModeMinimum(PageSidebarResizeMetrics.resizedDimension(
                    startingDimension: baseline,
                    translation: translation,
                    placement: pageOverviewPlacement,
                    availableLength: availableLength,
                    layoutMode: pageSidebarLayoutMode,
                    thumbnailScale: pageSidebarThumbnailScale,
                    minimumDimensionOverride: sidebarMode.minimumPanelDimension(
                        for: pageOverviewPlacement
                    )
                ))
            }
            .onEnded { value in
                let baseline = pageSidebarResizeBaseline ?? currentDimension
                let translation = pageOverviewPlacement.usesHorizontalPageStrip
                    ? Double(value.translation.height)
                    : Double(value.translation.width)
                let finalDimension = enforcingSidebarModeMinimum(PageSidebarResizeMetrics.resizedDimension(
                    startingDimension: baseline,
                    translation: translation,
                    placement: pageOverviewPlacement,
                    availableLength: availableLength,
                    layoutMode: pageSidebarLayoutMode,
                    thumbnailScale: pageSidebarThumbnailScale,
                    minimumDimensionOverride: sidebarMode.minimumPanelDimension(
                        for: pageOverviewPlacement
                    )
                ))
                persistPageSidebarDimension(finalDimension)
                livePageSidebarDimension = nil
                pageSidebarResizeBaseline = nil
                if !isPageSidebarDividerHovered {
                    NSCursor.arrow.set()
                }
            }
    }

    private func adjustPageSidebarDimension(
        steps: Int,
        availableLength: Double,
        currentDimension: Double
    ) {
        let adjusted = enforcingSidebarModeMinimum(PageSidebarResizeMetrics.adjustedDimension(
            currentDimension,
            steps: steps,
            placement: pageOverviewPlacement,
            availableLength: availableLength,
            layoutMode: pageSidebarLayoutMode,
            thumbnailScale: pageSidebarThumbnailScale,
            minimumDimensionOverride: sidebarMode.minimumPanelDimension(
                for: pageOverviewPlacement
            )
        ))
        persistPageSidebarDimension(adjusted)
    }

    private func movePageSidebarDivider(
        _ direction: MoveCommandDirection,
        availableLength: Double,
        currentDimension: Double
    ) {
        let physicalTranslation: Double?
        if pageOverviewPlacement.usesHorizontalPageStrip {
            switch direction {
            case .up: physicalTranslation = -PageSidebarResizeMetrics.keyboardStep
            case .down: physicalTranslation = PageSidebarResizeMetrics.keyboardStep
            default: physicalTranslation = nil
            }
        } else {
            switch direction {
            case .left: physicalTranslation = -PageSidebarResizeMetrics.keyboardStep
            case .right: physicalTranslation = PageSidebarResizeMetrics.keyboardStep
            default: physicalTranslation = nil
            }
        }
        guard let physicalTranslation else { return }
        let adjusted = enforcingSidebarModeMinimum(PageSidebarResizeMetrics.resizedDimension(
            startingDimension: currentDimension,
            translation: physicalTranslation,
            placement: pageOverviewPlacement,
            availableLength: availableLength,
            layoutMode: pageSidebarLayoutMode,
            thumbnailScale: pageSidebarThumbnailScale,
            minimumDimensionOverride: sidebarMode.minimumPanelDimension(
                for: pageOverviewPlacement
            )
        ))
        persistPageSidebarDimension(adjusted)
    }

    private func persistPageSidebarDimension(_ dimension: Double) {
        if pageOverviewPlacement.usesHorizontalPageStrip {
            preferredPageSidebarHeight = dimension
        } else {
            preferredPageSidebarWidth = dimension
        }
    }

    private func migrateLegacyHorizontalPageSidebarHeightIfNeeded() {
        let migratedHeight = PageSidebarResizeMetrics.migratedHorizontalPanelHeight(
            preferredPageSidebarHeight,
            migrationCompleted: didMigrateCompactHorizontalPanelHeight
        )
        if migratedHeight != preferredPageSidebarHeight {
            preferredPageSidebarHeight = migratedHeight
        }
        if !didMigrateCompactHorizontalPanelHeight {
            didMigrateCompactHorizontalPanelHeight = true
        }
    }

    private func updatePageSidebarDividerHover(_ isHovered: Bool) {
        isPageSidebarDividerHovered = isHovered
        if isHovered {
            (pageOverviewPlacement.usesHorizontalPageStrip
                ? NSCursor.resizeUpDown
                : NSCursor.resizeLeftRight).set()
        } else if pageSidebarResizeBaseline == nil {
            NSCursor.arrow.set()
        }
    }

    private func resetPageSidebarResizeInteraction() {
        if isPageSidebarDividerHovered || pageSidebarResizeBaseline != nil {
            NSCursor.arrow.set()
        }
        pageSidebarResizeBaseline = nil
        livePageSidebarDimension = nil
        isPageSidebarDividerHovered = false
    }

    private var pageOverviewPlacementBinding: Binding<PageOverviewPlacement> {
        Binding(
            get: { pageOverviewPlacement },
            set: { pageOverviewPlacementValue = $0.rawValue }
        )
    }

    private var sidebarVisibleBinding: Binding<Bool> {
        Binding(
            get: { workspace.sidebarVisible },
            set: { workspace.sidebarVisible = $0 }
        )
    }

    private var aiPanelVisibleBinding: Binding<Bool> {
        Binding(
            get: { aiPanelVisible },
            set: { visible in
                if visible {
                    workspace.pluginPanelRequest = nil
                }
                aiPanelVisible = visible
            }
        )
    }

    private var activePluginPanelRequest: PluginPanelRequest? {
        guard let request = workspace.pluginPanelRequest,
              request.documentRevision == workspace.revision,
              pluginManager.installedPlugins.contains(where: {
                  $0.isEnabled
                      && $0.id == request.pluginIdentifier
                      && $0.manifestDigest == request.manifestDigest
              }),
              request.kind != .translation || workspace.allows(.translation) else {
            return nil
        }
        return request
    }

    private var effectiveSidebarVisible: Bool {
        workspace.sidebarVisible && !isFocusMode
    }

    private var gridLayoutModeBinding: Binding<PDFGridLayoutMode> {
        Binding(
            get: { workspace.gridLayoutMode },
            set: { workspace.gridLayoutMode = $0 }
        )
    }

    private var gridPagingDirection: PDFGridPagingDirection {
        PDFGridPagingDirection(rawValue: gridPagingDirectionValue) ?? .vertical
    }

    private var gridPagingDirectionBinding: Binding<PDFGridPagingDirection> {
        Binding(
            get: { gridPagingDirection },
            set: { gridPagingDirectionValue = $0.rawValue }
        )
    }

    private var hudPageIndex: Int {
        let requested = workspace.pageColumns > 2
            ? (gridVisiblePageIndex ?? workspace.currentPageIndex)
            : workspace.currentPageIndex
        return min(max(0, requested), max(0, workspace.pageCount - 1))
    }

    private var pageDisplayRange: PDFPageDisplayRange {
        let groupSize: Int
        if workspace.pageColumns == PDFGridPageGroup.pageCountPerGroup {
            groupSize = PDFGridPageGroup.pageCountPerGroup
        } else if workspace.pageColumns == 2, workspace.twoPageDisplayMode == .paged {
            groupSize = 2
        } else {
            groupSize = 1
        }
        return PDFPageDisplayRange.resolve(
            pageIndex: hudPageIndex,
            pageCount: workspace.pageCount,
            groupSize: groupSize
        )
    }

    private var pageHUDTrailingPadding: CGFloat {
        usesHorizontalFourPagePaging ? 52 : 22
    }

    private var usesHorizontalFourPagePaging: Bool {
        workspace.pageColumns == PDFGridPageGroup.pageCountPerGroup
            && gridPagingDirection == .horizontal
    }

    private var documentIdentity: ObjectIdentifier? {
        workspace.document.map(ObjectIdentifier.init)
    }

    private var pageScrollActivityHandler: (PDFVerticalScrollMetrics) -> Void {
        let controller = pageScrollHUDController
        let acceptsActivity = isActive && scenePhase == .active
        let workspace = workspace
        return { metrics in
            guard acceptsActivity, workspace.pageCount > 0 else { return }
            controller.recordScroll(metrics)
        }
    }

    private func resetPageScrollHUD() {
        pageScrollHUDController.reset()
    }

    private func handleGridVisiblePageChange(_ index: Int) {
        // Ignore initial/teardown geometry reports until the requested page is
        // positioned in the newly-created or reflowed grid. Otherwise page 1
        // can overwrite the page that was current before the layout change.
        guard workspace.pageColumns > 2 else { return }
        if isTransitioningGridMode {
            guard isMatchingGridTransitionTarget(index) else { return }
            isTransitioningGridMode = false
            gridTransitionTargetPageIndex = nil
        }
        if gridVisiblePageIndex != index {
            gridVisiblePageIndex = index
        }
        // In strict four-page paging, this callback describes the visible
        // group rather than an explicit navigation command. Preserve an exact
        // page opened from search or the sidebar (for example page 15 while
        // the HUD shows group 13–16). Swipe/buttons use the separate group
        // callback below and intentionally move currentPageIndex.
        guard workspace.pageColumns != PDFGridPageGroup.pageCountPerGroup else { return }
        if workspace.currentPageIndex != index {
            workspace.setCurrentPage(index)
        }
    }

    private func handleGridPageGroupChange(_ requestedIndex: Int) {
        guard
            workspace.pageColumns == PDFGridPageGroup.pageCountPerGroup,
            workspace.pageCount > 0
        else {
            return
        }
        let groupStart = PDFGridPageGroup(
            containing: requestedIndex,
            documentPageCount: workspace.pageCount
        ).startIndex

        if workspace.currentPageIndex != groupStart {
            // Suppress stale visibility reports while ScrollViewReader moves
            // to the requested group. The requested group start becomes the
            // single source of truth for the HUD and PDF position.
            beginGridTransition(anchoredAt: groupStart)
        }
        gridVisiblePageIndex = groupStart
        // setCurrentPage selects the target when nothing is selected. Paging
        // is a viewing action, so restore the exact edit/page selection.
        let existingSelection = workspace.selectedPages
        workspace.setCurrentPage(groupStart)
        if workspace.selectedPages != existingSelection {
            workspace.selectedPages = existingSelection
        }
    }

    private func isMatchingGridTransitionTarget(_ reportedIndex: Int) -> Bool {
        guard let targetIndex = gridTransitionTargetPageIndex else { return false }
        guard workspace.pageColumns == PDFGridPageGroup.pageCountPerGroup else {
            return reportedIndex == targetIndex
        }
        let reportedGroup = PDFGridPageGroup(
            containing: reportedIndex,
            documentPageCount: workspace.pageCount
        )
        let targetGroup = PDFGridPageGroup(
            containing: targetIndex,
            documentPageCount: workspace.pageCount
        )
        return reportedGroup.startIndex == targetGroup.startIndex
    }

    private func openGridPage(_ index: Int) {
        guard index >= 0, index < workspace.pageCount else { return }
        workspace.selectedPages = [index]
        workspace.setCurrentPage(index)
        isTransitioningGridMode = true
        gridTransitionTargetPageIndex = index
        workspace.gridLayoutMode = .balanced
        gridVisiblePageIndex = nil
        workspace.pageColumns = 1
    }

    private func beginGridTransition(anchoredAt pageIndex: Int) {
        let clampedIndex = min(max(0, pageIndex), max(0, workspace.pageCount - 1))
        let token = UUID()
        gridTransitionToken = token
        isTransitioningGridMode = true
        gridTransitionTargetPageIndex = clampedIndex
        gridVisiblePageIndex = clampedIndex

        // PDFGridOverview normally reports the anchor as soon as its
        // ScrollViewReader finishes positioning. This fallback prevents a
        // permanently suppressed callback if several fully-visible tiles tie.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard gridTransitionToken == token else { return }
            isTransitioningGridMode = false
            gridTransitionTargetPageIndex = nil
        }
    }

    private func mergeDocument() {
        guard workspace.allows(.pageEditing) else { return }
        let urls = WorkspaceFilePanels.choosePDFs(allowsMultipleSelection: true)
        guard !urls.isEmpty else { return }
        workspace.merge(
            urls: urls,
            insertionIndex: workspace.selectedPages.max().map { $0 + 1 }
        )
    }

    private func exportSelectedPagesCombined() {
        guard workspace.canExtractPages, !workspace.selectedPages.isEmpty else { return }
        if let url = WorkspaceFilePanels.chooseSavePDF(
            suggestedName: SelectedPagePDFExporter.combinedFileName(
                for: workspace.documentURL
            ),
            title: L10n.string("panel.title.save_selected_pages_combined")
        ) {
            workspace.exportSelectedPagesAsCombinedPDF(to: url)
        }
    }

    private func exportSelectedPagesIndividually() {
        guard workspace.canExtractPages, !workspace.selectedPages.isEmpty else { return }
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

    private func insertImage() {
        guard workspace.allows(.imageInsertion) else { return }
        if let url = WorkspaceFilePanels.chooseImages().first {
            workspace.insertImage(url: url)
        }
    }

    private func exportOCRCopy() {
        let base = workspace.documentURL?.deletingPathExtension().lastPathComponent ?? "HwattakPDF"
        if let url = WorkspaceFilePanels.chooseSavePDF(suggestedName: "\(base)-searchable.pdf") {
            workspace.exportSearchableOCRCopy(to: url)
        }
    }

    private func exportProtectedPDF(
        _ presentation: PDFProtectedExportPresentation,
        request: PDFProtectedExportRequest
    ) {
        defer { workspace.cancelProtectedPDFExport() }
        guard workspace.exportProtectedCopy(
            presentation: presentation,
            userPassword: request.userPassword
        ) else {
            return
        }
        let url = presentation.destinationURL
        if request.shareAfterSaving,
           PDFFileSharePresenter.present(fileURL: url) {
            workspace.statusMessage = L10n.format(
                "security.export.shared",
                url.lastPathComponent
            )
        }
    }

    /// Snapshot only the text the user selected. Keeping the live PDFSelection
    /// out of sheet state avoids retaining a hibernated PDFKit object graph and
    /// prevents an entire document from being shared by accident.
    private func prepareShareNote() {
        pendingShareNote = PDFShareNote(
            excerpt: PDFShareNote.boundedExcerpt(from: workspace.currentSelection)
        )
    }

    private func closeAIAssistant() {
        workspace.aiAssistantSession.cancelActiveRequest()
        withAnimation(.easeOut(duration: 0.16)) {
            aiPanelVisible = false
        }
    }

    /// 학습 빠른 동작이 준비한 consent preview를 사용자가 확인할 수 있도록
    /// 기존 AI sidebar를 연다. 실제 외부 전송은 sidebar의 확인 sheet에서만 한다.
    private func openAIAssistant() {
        withAnimation(.easeInOut(duration: 0.16)) {
            workspace.pluginPanelRequest = nil
            aiPanelVisible = true
        }
    }

    private func openRelatedPDF(_ result: PDFRelatedDocumentResult) {
        let selectedTabID: UUID?
        switch result.source {
        case let .openTab(tabID):
            guard let descriptor = multiDocumentWorkspace.workspace(containingTab: tabID) else {
                workspace.presentedError = L10n.string(
                    "ai.related.unavailable",
                    defaultValue: "관련 PDF 탭을 더 이상 찾을 수 없습니다."
                )
                return
            }
            _ = multiDocumentWorkspace.selectWorkspace(descriptor.id)
            multiDocumentWorkspace.selectTab(tabID)
            selectedTabID = tabID
        case let .recentDocument(documentID):
            selectedTabID = multiDocumentWorkspace.openRecentDocument(id: documentID)
        }

        guard selectedTabID != nil else { return }
        if let pageIndex = result.matches.first?.pageIndex {
            multiDocumentWorkspace.activeWorkspace?.setCurrentPage(pageIndex)
        }
    }

}

/// Owns the high-frequency HUD state outside `WorkspaceView`. Publishing a new
/// scroll position now invalidates only `PageScrollHUDOverlay`, so the sibling
/// `PDFKitViewer` representable is not updated while native scrolling is live.
@MainActor
final class PageScrollHUDController: ObservableObject {
    @Published private(set) var state = PageScrollHUDState()
    private var dismissalWorkItem: DispatchWorkItem?
    private(set) var generation = UUID()

    func recordScroll(_ metrics: PDFVerticalScrollMetrics) {
        let generation = self.generation
        let now = ProcessInfo.processInfo.systemUptime
        if state.isVisible {
            state.recordScroll(metrics: metrics, at: now)
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                state.recordScroll(metrics: metrics, at: now)
            }
        }
        scheduleDismissal(generation: generation)
    }

    func reset() {
        dismissalWorkItem?.cancel()
        dismissalWorkItem = nil
        generation = UUID()
        state.hide()
    }

    /// Keeps one queued dismissal at a time. New reports only extend the pure
    /// state's deadline; the queued callback reschedules itself once if needed.
    private func scheduleDismissal(generation: UUID) {
        guard dismissalWorkItem == nil else { return }
        guard let scheduledDeadline = state.dismissalDeadline else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, generation == self.generation else { return }
            self.dismissalWorkItem = nil
            let currentTime = ProcessInfo.processInfo.systemUptime
            if
                let currentDeadline = self.state.dismissalDeadline,
                currentTime >= currentDeadline
            {
                withAnimation(.easeOut(duration: 0.16)) {
                    _ = self.state.hideIfExpired(at: currentTime)
                }
            } else {
                self.scheduleDismissal(generation: generation)
            }
        }
        dismissalWorkItem = workItem
        let remainingDelay = max(
            0,
            scheduledDeadline - ProcessInfo.processInfo.systemUptime
        )
        DispatchQueue.main.asyncAfter(
            deadline: .now() + remainingDelay,
            execute: workItem
        )
    }
}

private struct PageScrollHUDOverlay: View {
    @ObservedObject var controller: PageScrollHUDController
    let pageRange: PDFPageDisplayRange
    let pageCount: Int
    let trailingPadding: CGFloat
    let theme: HwattakPDFTheme

    var body: some View {
        GeometryReader { geometry in
            if pageCount > 0, controller.state.isVisible {
                CurrentPageScrollHUD(pageRange: pageRange, theme: theme)
                    .padding(.trailing, trailingPadding)
                    .offset(
                        y: PageScrollHUDLayout.centerY(
                            containerHeight: geometry.size.height,
                            metrics: controller.state.metrics
                        ) - PageScrollHUDLayout.height / 2
                    )
                    .frame(
                        width: geometry.size.width,
                        height: PageScrollHUDLayout.height,
                        alignment: .topTrailing
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.16), value: controller.state.isVisible)
    }
}

private struct CurrentPageScrollHUD: View {
    let pageRange: PDFPageDisplayRange
    let theme: HwattakPDFTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.accent)
            Text(pageRange.pageNumberDescription)
                .foregroundStyle(theme.primaryText)
            Text("/ \(pageRange.totalPageCount)")
                .foregroundStyle(theme.secondaryText)
        }
        .font(.callout.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(theme.card.opacity(0.96), in: Capsule())
        .overlay {
            Capsule()
                .stroke(theme.border, lineWidth: 1)
        }
        .shadow(color: theme.elevatedShadow, radius: 10, y: 4)
        .animation(.easeOut(duration: 0.16), value: pageRange)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pageRange.accessibilityDescription)
    }
}

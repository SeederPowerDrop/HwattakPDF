// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// 활성 PDF 탭의 공통 작업과 현재 모드 도구를 분리한 2단 툴바다.
///
/// 툴바는 PDF를 직접 수정하지 않는다. 문서 관련 명령은 `PDFWorkspaceState`에,
/// 파일 패널이나 sheet가 필요한 명령은 부모 `WorkspaceView`가 준 closure에
/// 전달한다. 이렇게 하면 버튼 배치와 비즈니스 규칙을 분리해 단위 테스트와
/// 메뉴 단축키가 같은 모델 API를 공유할 수 있다.
struct WorkspaceToolbar: View {
    /// `@ObservedObject`는 이 뷰가 workspace를 소유하지 않고 관찰만 함을 뜻한다.
    /// 실제 수명은 탭 session이 관리하므로 툴바 재생성 때 문서가 사라지지 않는다.
    @ObservedObject var workspace: PDFWorkspaceState
    /// Keep toolbar buttons consistent with Edit > Undo/Redo. In particular,
    /// an active on-page text editor owns native character-level undo before
    /// the surrounding PDF document history is allowed to move.
    @ObservedObject private var editCommandRouter = AppEditCommandRouter.shared
    // Binding은 부모가 단일 진실 공급원(source of truth)을 유지하면서 자식이
    // 사용자의 선택을 다시 써 줄 수 있게 하는 SwiftUI의 양방향 연결이다.
    @Binding var modeToolsVisible: Bool
    @Binding var sidebarVisible: Bool
    @Binding var pageOverviewPlacement: PageOverviewPlacement
    @Binding var gridLayoutMode: PDFGridLayoutMode
    @Binding var gridPagingDirection: PDFGridPagingDirection
    @Binding var aiPanelVisible: Bool
    @Binding var sidebarMode: DocumentSidebarMode
    let openDocument: () -> Void
    let saveDocument: () -> Void
    let mergeDocument: () -> Void
    let exportSelectedPagesCombined: () -> Void
    let exportSelectedPagesIndividually: () -> Void
    let insertImage: () -> Void
    let showSignature: () -> Void
    let showOCR: () -> Void
    /// Presentation of the system share sheet belongs to WorkspaceView. The
    /// toolbar only advertises the mode-appropriate command.
    let shareNote: () -> Void
    let enterFocusMode: () -> Void

    @EnvironmentObject private var pluginManager: PluginManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    // 팝오버 열림 여부처럼 문서에 저장할 필요가 없는 짧은 UI 상태만 @State다.
    @State private var showingPenSettings = false
    @State private var showingHighlightSettings = false
    @State private var showingPluginActions = false
    @State private var pendingPluginToolbarAction: (() -> Void)?
    @State private var lastSubmittedSearchText = ""
    @FocusState private var searchFieldFocused: Bool

    private var theme: HwattakPDFTheme {
        HwattakPDFTheme(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            primaryToolbarRow

            // Study owns its purpose-built second row in StudyModePalette.
            // Viewer and Editing use the contextual row below, so every mode
            // has one stable workspace row and one mode-specific tool row.
            if modeToolsVisible, workspace.mode != .study {
                contextualToolbarRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel)
        .onReceive(NotificationCenter.default.publisher(for: .focusDocumentSearch)) { note in
            guard let target = note.object as? PDFWorkspaceState, target === workspace else { return }
            revealSearchNavigator()
            searchFieldFocused = true
        }
        .onReceive(workspace.$searchCompletedQuery) { completedQuery in
            if let completedQuery {
                lastSubmittedSearchText = completedQuery
            }
        }
        .onChange(of: workspace.mode) { _, mode in
            // Menu shortcuts can switch mode without interacting with this
            // view. Close transient UI that the new mode no longer presents.
            if !mode.allows(.aiAssistance) {
                aiPanelVisible = false
            }
            showingPenSettings = false
            if !mode.toolbarSections.contains(.markup) {
                showingHighlightSettings = false
            }
        }
        .onChange(of: modeToolsVisible) { _, isVisible in
            guard !isVisible else { return }
            showingPenSettings = false
            showingHighlightSettings = false
        }
    }

    /// This row never moves when the working mode changes. Navigation, layout,
    /// history and search therefore stay predictable while the prominent
    /// three-way picker communicates HwattakPDF's core hierarchy.
    private var primaryToolbarRow: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 9) {
                    Picker(
                        L10n.string("mode.picker.label", defaultValue: "PDF 사용 모드"),
                        selection: Binding(
                            get: { workspace.mode },
                            set: { workspace.setMode($0) }
                        )
                    ) {
                        ForEach(PDFWorkspaceMode.allCases) { mode in
                            Label(mode.shortTitle, systemImage: mode.systemImage)
                                .tag(mode)
                                .help(mode.summary)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 270)
                    .help(workspace.mode.summary)
                    .accessibilityLabel(
                        L10n.string("mode.picker.label", defaultValue: "PDF 사용 모드")
                    )
                    .accessibilityValue(workspace.mode.title)

                    toolbarGroup {
                        iconButton(
                            modeToolsVisible ? "chevron.up" : "chevron.down",
                            help: L10n.string(
                                modeToolsVisible
                                    ? "toolbar.mode_tools.hide"
                                    : "toolbar.mode_tools.show",
                                defaultValue: modeToolsVisible
                                    ? "모드 도구줄 접기"
                                    : "모드 도구줄 펼치기"
                            )
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                modeToolsVisible.toggle()
                            }
                        }
                        .accessibilityIdentifier("mode-tools-toggle")
                        .accessibilityAddTraits(modeToolsVisible ? .isSelected : [])
                        .accessibilityValue(
                            L10n.string(
                                modeToolsVisible
                                    ? "selection.selected"
                                    : "selection.not_selected"
                            )
                        )
                    }

                    toolbarGroup {
                        iconButton(
                            pageOverviewPlacement.systemImage,
                            help: sidebarVisible
                                ? L10n.string("페이지 패널 가리기")
                                : L10n.string("페이지 패널 보기")
                        ) {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                sidebarVisible.toggle()
                            }
                        }
                        .disabled(workspace.document == nil)

                        Menu {
                            ForEach(PageOverviewPlacement.allCases) { placement in
                                Button {
                                    pageOverviewPlacement = placement
                                    if !sidebarVisible {
                                        withAnimation(.easeInOut(duration: 0.16)) {
                                            sidebarVisible = true
                                        }
                                    }
                                } label: {
                                    Label(placement.title, systemImage: placement.systemImage)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 27, height: 27)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help(L10n.string("페이지 패널 위치"))
                        .accessibilityLabel(L10n.string("페이지 패널 위치"))
                        .accessibilityValue(pageOverviewPlacement.title)

                        PageJumpControl(workspace: workspace)

                        iconButton(
                            "folder.fill",
                            help: L10n.string("menu.open_document") + " (⌘O)",
                            action: openDocument
                        )
                    }

                    viewLayoutControls

                    toolbarGroup {
                        saveButton

                        // These buttons share the Edit menu's router so a live text
                        // editor still receives character-level undo first.
                        iconButton("arrow.uturn.backward", help: undoButtonTitle) {
                            editCommandRouter.performUndo {
                                workspace.undo()
                            }
                        }
                        .disabled(
                            !editCommandRouter.canUndo(documentCanUndo: workspace.canUndo)
                        )

                        iconButton("arrow.uturn.forward", help: redoButtonTitle) {
                            editCommandRouter.performRedo {
                                workspace.redo()
                            }
                        }
                        .disabled(
                            !editCommandRouter.canRedo(documentCanRedo: workspace.canRedo)
                        )
                    }

                    Spacer(minLength: 4)

                    if workspace.mode.toolbarSections.contains(.search) {
                        searchControl
                    }

                    iconButton(
                        "arrow.up.left.and.arrow.down.right",
                        help: L10n.string(
                            "view.focus.enter",
                            defaultValue: "집중 보기"
                        ),
                        action: enterFocusMode
                    )
                    .accessibilityIdentifier("focus-mode-enter")
                    }
                    .controlSize(.regular)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .foregroundStyle(theme.primaryText)
                    .tint(theme.accent)
                    .frame(minWidth: geometry.size.width, alignment: .leading)
                }
            }
            Rectangle()
                .fill(theme.border)
                .frame(width: 1, height: 24)

            // Keep the launcher reachable even when the other tools overflow.
            pluginToolbarMenu
                .padding(.horizontal, 11)
                .foregroundStyle(theme.primaryText)
                .tint(theme.accent)
        }
        .frame(height: 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border.opacity(0.72))
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.string("toolbar.primary.accessibility", defaultValue: "문서 작업 도구")
        )
    }

    /// Only commands for the selected purpose are created on this row.
    /// Conditional creation also keeps commands from other modes out of the
    /// VoiceOver tree instead of merely making them visually transparent.
    private var contextualToolbarRow: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                if workspace.mode.toolbarSections.contains(.inputTools) {
                    toolbarGroup(spacing: 7) {
                        Picker(L10n.string("도구"), selection: $workspace.activeTool) {
                            ForEach(workspace.mode.availableTools) { tool in
                                Label(
                                    workspace.mode.title(for: tool),
                                    systemImage: tool.systemImage
                                )
                                .tag(tool)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: workspace.mode.availableTools.count > 2 ? 218 : 126)
                        .disabled(workspace.pageColumns > 2)

                        if workspace.mode.toolbarSections.contains(.penSettings) {
                            iconButton(
                                "slider.horizontal.3",
                                help: L10n.string("펜 설정")
                            ) {
                                showingPenSettings.toggle()
                            }
                            .popover(isPresented: $showingPenSettings, arrowEdge: .bottom) {
                                PenSettingsPopover(settings: $workspace.inkSettings)
                            }
                        }
                    }
                }

                if workspace.mode.toolbarSections.contains(.markup) {
                    toolbarGroup {
                        iconButton(
                            "highlighter",
                            help: L10n.string("선택한 텍스트 하이라이트")
                        ) {
                            workspace.applyCurrentModeHighlight()
                        }
                        .disabled(workspace.pageColumns > 2)

                        Button {
                            showingHighlightSettings.toggle()
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: workspace.studyMarkupStyle.color))
                                    .frame(width: 22, height: 22)
                                Image(systemName: "paintpalette")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                            }
                            .frame(width: 27, height: 27)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("study.markup.color"))
                        .accessibilityLabel(L10n.string("study.markup.color"))
                        .popover(
                            isPresented: $showingHighlightSettings,
                            arrowEdge: .bottom
                        ) {
                            highlightSettingsPopover
                        }

                        // Viewer keeps signature as a direct annotation action.
                        // Editing consolidates it with images in Insert.
                        if workspace.mode == .viewer,
                           workspace.mode.toolbarSections.contains(.signature) {
                            iconButton(
                                "signature",
                                help: L10n.string("트랙패드 서명"),
                                action: showSignature
                            )
                        }
                    }
                }

                if workspace.mode.toolbarSections.contains(.images) {
                    insertToolsMenu
                }

                if workspace.mode.toolbarSections.contains(.pages) {
                    pageToolsMenu
                }

                if workspace.mode.toolbarSections.contains(.ocr) {
                    ocrButton
                }

                if workspace.mode.toolbarSections.contains(.ai) {
                    aiButton
                }

                if workspace.allows(.noteSharing) {
                    shareNoteButton
                }
                }
                .controlSize(.regular)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(theme.primaryText)
                .tint(theme.accent)
                .frame(minWidth: geometry.size.width, alignment: .center)
            }
        }
        .frame(height: 46)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.border)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.format("toolbar.context.accessibility", workspace.mode.shortTitle)
        )
    }

    /// Common layouts and page fitting remain one-click actions. Less frequent
    /// grid direction and custom-count choices live in the macOS View menu.
    private var viewLayoutControls: some View {
        toolbarGroup(spacing: 3) {
            layoutIconButton(
                help: L10n.format("view.pages_at_once", 1),
                isSelected: workspace.pageColumns == 1,
                identifier: "layout-one-page"
            ) {
                Image(systemName: "rectangle.portrait")
                    .font(.system(size: 13, weight: .medium))
            } action: {
                workspace.pageColumns = 1
            }

            layoutIconButton(
                help: L10n.string("view.two_page.continuous.title"),
                isSelected: workspace.pageColumns == 2
                    && workspace.twoPageDisplayMode == .continuous,
                identifier: "layout-two-page-continuous"
            ) {
                TwoPageLayoutIcon(mode: .continuous)
            } action: {
                workspace.selectTwoPageDisplayMode(.continuous)
            }

            layoutIconButton(
                help: L10n.string("view.two_page.paged.title"),
                isSelected: workspace.pageColumns == 2
                    && workspace.twoPageDisplayMode == .paged,
                identifier: "layout-two-page-paged"
            ) {
                TwoPageLayoutIcon(mode: .paged)
            } action: {
                workspace.selectTwoPageDisplayMode(.paged)
            }

            layoutIconButton(
                help: L10n.format(
                    "view.grid.four_overview",
                    gridLayoutDescription(gridLayoutMode),
                    gridPagingDirection.title
                ),
                isSelected: workspace.pageColumns == 4,
                identifier: "layout-four-page"
            ) {
                FourPageLayoutIcon(mode: gridLayoutMode)
            } action: {
                workspace.pageColumns = 4
            }

            Rectangle()
                .fill(theme.border)
                .frame(width: 1, height: 18)
                .padding(.horizontal, 3)

            layoutIconButton(
                help: L10n.string("view.fit.width"),
                isSelected: workspace.pageFitMode == .width,
                identifier: "fit-page-width"
            ) {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 13, weight: .medium))
            } action: {
                workspace.selectPageFitMode(workspace.pageFitMode == .width ? nil : .width)
            }
            .disabled(workspace.document == nil)

            layoutIconButton(
                help: L10n.string("view.fit.height"),
                isSelected: workspace.pageFitMode == .height,
                identifier: "fit-page-height"
            ) {
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 13, weight: .medium))
            } action: {
                workspace.selectPageFitMode(workspace.pageFitMode == .height ? nil : .height)
            }
            .disabled(workspace.document == nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.string("toolbar.view_layout", defaultValue: "화면 배치")
        )
        .accessibilityIdentifier("view-layout-controls")
    }

    private func layoutIconButton<Icon: View>(
        help: String,
        isSelected: Bool,
        identifier: String,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 27, height: 27)
                .contentShape(Rectangle())
                .background(
                    isSelected ? theme.dropHighlight : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(
            L10n.string(
                isSelected ? "selection.selected" : "selection.not_selected"
            )
        )
    }

    private var insertToolsMenu: some View {
        Menu {
            if workspace.mode.toolbarSections.contains(.signature) {
                Button(action: showSignature) {
                    Label(L10n.string("트랙패드 서명"), systemImage: "signature")
                }
            }
            if workspace.mode.toolbarSections.contains(.images) {
                Button(action: insertImage) {
                    Label(
                        L10n.string(
                            "toolbar.import_image_or_signature",
                            defaultValue: "이미지·서명 이미지 가져오기"
                        ),
                        systemImage: "photo.badge.plus"
                    )
                }
            }
        } label: {
            toolbarMenuLabel(
                L10n.string("toolbar.insert", defaultValue: "삽입"),
                systemImage: "plus.square.on.square"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var pageToolsMenu: some View {
        Menu {
            Button(L10n.string("PDF 병합…"), action: mergeDocument)
            Menu(L10n.string("menu.export_selected_pages")) {
                Button(
                    L10n.string("menu.export_selected_pages.combined"),
                    action: exportSelectedPagesCombined
                )
                Button(
                    L10n.string("menu.export_selected_pages.individual"),
                    action: exportSelectedPagesIndividually
                )
            }
            .disabled(workspace.selectedPages.isEmpty || !workspace.canExtractPages)
            Divider()
            Button(L10n.string("왼쪽으로 회전")) {
                workspace.rotateSelectedPages(clockwise: false)
            }
            Button(L10n.string("오른쪽으로 회전")) {
                workspace.rotateSelectedPages(clockwise: true)
            }
            Button(L10n.string("선택 페이지 삭제"), role: .destructive) {
                workspace.deleteSelectedPages()
            }
        } label: {
            toolbarMenuLabel(
                L10n.string("페이지"),
                systemImage: "rectangle.stack.badge.plus"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var pluginToolbarMenu: some View {
        Button {
            showingPluginActions.toggle()
        } label: {
            Label(
                L10n.string("menu.plugins", defaultValue: "플러그인"),
                systemImage: "puzzlepiece.extension"
            )
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                showingPluginActions || workspace.pluginPanelRequest != nil
                    ? theme.dropHighlight : theme.card,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L10n.string("menu.plugins", defaultValue: "플러그인"))
        .accessibilityLabel(L10n.string("menu.plugins", defaultValue: "플러그인"))
        .accessibilityIdentifier("plugin-toolbar-menu")
        .accessibilityAddTraits(
            showingPluginActions || workspace.pluginPanelRequest != nil ? .isSelected : []
        )
        .popover(isPresented: $showingPluginActions, arrowEdge: .bottom) {
            PluginToolbarPopover(
                manager: pluginManager,
                workspace: workspace,
                runAction: { action, plugin in
                    dismissPluginActions {
                        runPluginAction(action, from: plugin)
                    }
                },
                managePlugins: {
                    dismissPluginActions {
                        openWindow(id: PluginManagerContent.sceneID)
                    }
                }
            )
            .onDisappear(perform: performPendingPluginToolbarAction)
        }
    }

    private func dismissPluginActions(perform action: @escaping () -> Void) {
        pendingPluginToolbarAction = action
        showingPluginActions = false
    }

    private func performPendingPluginToolbarAction() {
        let action = pendingPluginToolbarAction
        pendingPluginToolbarAction = nil
        // Complete the launcher dismissal before a command opens its consent
        // dialog or result panel. Nothing dismisses that newly opened UI.
        DispatchQueue.main.async {
            action?()
        }
    }

    private func runPluginAction(
        _ action: PluginActionManifest,
        from plugin: InstalledPlugin
    ) {
        do {
            try PluginActionLauncher.run(
                manager: pluginManager,
                plugin: plugin,
                action: action,
                workspace: workspace
            )
        } catch PluginSystemError.externalURLCancelled {
            // Closing the per-open disclosure is an expected cancellation.
        } catch {
            workspace.presentedError = error.localizedDescription
        }
    }

    private var ocrButton: some View {
        Button(action: showOCR) {
            HStack(spacing: 7) {
                Label(L10n.string("OCR"), systemImage: "text.viewfinder")
                if workspace.ocrState.isActivelyProcessing {
                    if let fraction = workspace.ocrState.fraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 32)
                .foregroundStyle(theme.primaryText)
                .background(
                    theme.card,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(
            workspace.ocrState.isActivelyProcessing
                ? workspace.ocrState.label
                : L10n.string("완전 로컬 OCR")
        )
        .accessibilityLabel(L10n.string("OCR"))
        .accessibilityValue(
            workspace.ocrState.isActivelyProcessing ? workspace.ocrState.label : ""
        )
        .accessibilityHint(L10n.string("완전 로컬 OCR"))
    }

    private var aiButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                aiPanelVisible.toggle()
            }
        } label: {
            Label(
                L10n.string("ai.toolbar", defaultValue: "PDF AI"),
                systemImage: "sparkles"
            )
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11)
            .frame(height: 32)
            .foregroundStyle(theme.primaryText)
            .background(
                aiPanelVisible ? theme.dropHighlight : theme.card,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(
            aiPanelVisible
                ? L10n.string("ai.close", defaultValue: "AI 패널 닫기")
                : L10n.string("ai.open", defaultValue: "AI 패널 열기")
        )
        .accessibilityAddTraits(aiPanelVisible ? .isSelected : [])
    }

    private var shareNoteButton: some View {
        Button(action: shareNote) {
            Label(
                L10n.string("toolbar.share_note", defaultValue: "메모 공유"),
                systemImage: "square.and.arrow.up"
            )
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 11)
            .frame(height: 32)
            .foregroundStyle(theme.primaryText)
            .background(
                theme.card,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(L10n.string("toolbar.share_note", defaultValue: "메모 공유"))
    }

    private func toolbarMenuLabel(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                theme.card,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    private var searchControl: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.secondaryText)
            TextField("문서 검색", text: $workspace.searchText)
                .textFieldStyle(.plain)
                .frame(minWidth: 112, idealWidth: 145, maxWidth: 180)
                .focused($searchFieldFocused)
                .submitLabel(.search)
                .onKeyPress(.return, phases: .down) { keyPress in
                    // Let the field editor finish Korean/Japanese/Chinese IME
                    // composition before treating Return as navigation.
                    if
                        let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                        editor.hasMarkedText()
                    {
                        return .ignored
                    }
                    performSearchSubmission(
                        backwards: SearchKeyboardNavigation.isBackwards(
                            modifiers: keyPress.modifiers
                        )
                    )
                    return .handled
                }
                .onExitCommand(perform: performSearchEscape)
                .accessibilityHint(
                    L10n.string(
                        "search.navigator.field_hint",
                        defaultValue: "Enter는 다음 결과, Shift+Enter는 이전 결과로 이동합니다."
                    )
                )

            if workspace.isSearching {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 24, height: 24)
                    .help(L10n.string("search.navigator.searching", defaultValue: "문서 검색 중"))
                    .accessibilityLabel(
                        L10n.string("search.navigator.searching", defaultValue: "문서 검색 중")
                    )
            } else if !workspace.searchText.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(L10n.string("search.navigator.clear", defaultValue: "검색 지우기"))
                .accessibilityLabel(
                    L10n.string("search.navigator.clear", defaultValue: "검색 지우기")
                )
            }

            if !workspace.searchNavigatorResults.isEmpty {
                Text(
                    L10n.format(
                        "search.navigator.compact_position",
                        workspace.searchResultIndex + 1,
                        workspace.searchNavigatorResults.count
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .accessibilityHidden(true)
            }

            searchButton("chevron.up", help: L10n.string("이전 검색 결과")) {
                navigateSearch(backwards: true)
            }
            .disabled(workspace.isSearching || normalizedSearchText.isEmpty)
            searchButton("chevron.down", help: L10n.string("다음 검색 결과")) {
                navigateSearch(backwards: false)
            }
            .disabled(workspace.isSearching || normalizedSearchText.isEmpty)

            searchButton(
                sidebarMode == .search ? "sidebar.right" : "list.bullet.rectangle",
                help: L10n.string(
                    "search.navigator.show_results",
                    defaultValue: "검색 결과 탐색기 보기"
                )
            ) {
                revealSearchNavigator()
            }
            .accessibilityAddTraits(sidebarMode == .search ? .isSelected : [])
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }

    private var normalizedSearchText: String {
        workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performSearchSubmission(backwards: Bool) {
        let query = normalizedSearchText
        guard !query.isEmpty else {
            workspace.performSearch()
            revealSearchNavigator()
            return
        }

        if
            !workspace.isSearching,
            query == lastSubmittedSearchText,
            !workspace.searchNavigatorResults.isEmpty
        {
            navigateSearch(backwards: backwards)
        } else {
            lastSubmittedSearchText = query
            workspace.performSearch()
            revealSearchNavigator()
        }
    }

    private func navigateSearch(backwards: Bool) {
        guard !workspace.isSearching else { return }
        if
            workspace.searchNavigatorResults.isEmpty
                || normalizedSearchText != lastSubmittedSearchText
        {
            lastSubmittedSearchText = normalizedSearchText
            workspace.performSearch()
        } else {
            workspace.showNextSearchResult(backwards: backwards)
        }
        revealSearchNavigator()
    }

    private func revealSearchNavigator() {
        sidebarMode = .search
        if !sidebarVisible {
            withAnimation(.easeInOut(duration: 0.16)) {
                sidebarVisible = true
            }
        }
    }

    private func clearSearch() {
        workspace.clearSearch()
        lastSubmittedSearchText = ""
        searchFieldFocused = true
    }

    private func performSearchEscape() {
        if workspace.isSearching {
            workspace.cancelSearch()
        }
        workspace.clearSearch()
        lastSubmittedSearchText = ""
        sidebarMode = .pages
        searchFieldFocused = false
    }

    /// Viewer and Editing intentionally expose only the native Highlight color.
    /// Study's separate palette continues to own thickness and opacity because
    /// those values require its appearance-backed annotation implementation.
    private var highlightSettingsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("study.markup.color"))
                .font(.headline)

            InlineColorPalette(
                selection: highlightColorBinding,
                title: L10n.string("study.markup.color")
            )

            Text(L10n.string("study.markup.undo_hint"))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
        .padding(14)
        .frame(width: 280)
        .foregroundStyle(theme.primaryText)
        .background(theme.panel)
    }

    /// Updating the existing tab-owned style keeps Viewer, Editing and Study
    /// in sync without introducing another preference to maintain.
    private var highlightColorBinding: Binding<NSColor> {
        Binding(
            get: { workspace.studyMarkupStyle.color },
            set: { color in
                var style = workspace.studyMarkupStyle
                style.color = color
                workspace.studyMarkupStyle = style
            }
        )
    }

    /// Use the localized action name when history provides one, matching the
    /// wording in the Edit menu while keeping a useful generic fallback.
    private var undoButtonTitle: String {
        let documentTitle = workspace.undoActionName.map {
            L10n.format("menu.undo_named", $0)
        } ?? L10n.string("menu.undo")
        return editCommandRouter.undoMenuTitle(documentTitle: documentTitle)
    }

    private var redoButtonTitle: String {
        let documentTitle = workspace.redoActionName.map {
            L10n.format("menu.redo_named", $0)
        } ?? L10n.string("menu.redo")
        return editCommandRouter.redoMenuTitle(documentTitle: documentTitle)
    }

    @ViewBuilder
    private func toolbarGroup<Content: View>(
        spacing: CGFloat = 3,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: spacing, content: content)
            .padding(.horizontal, 4)
            .frame(height: 34)
            .background(
                theme.card.opacity(0.58),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }

    private func iconButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 27, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var saveButton: some View {
        Button(action: saveDocument) {
            Label(L10n.string("action.save"), systemImage: "square.and.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 27)
                .foregroundStyle(workspace.isDirty ? theme.ribbon : theme.primaryText)
                .background(
                    workspace.isDirty ? theme.ribbonSoft : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!workspace.canSaveNormally || !workspace.isDirty)
        .help(
            workspace.document?.isEncrypted == true
                ? L10n.string("security.save_protected_copy_required")
                : L10n.string("save.options.help")
        )
        .accessibilityLabel(L10n.string("action.save"))
        .accessibilityHint(
            workspace.document?.isEncrypted == true
                ? L10n.string("security.save_protected_copy_required")
                : L10n.string("save.options.help")
        )
    }

    private func gridLayoutDescription(_ mode: PDFGridLayoutMode) -> String {
        switch mode {
        case .balanced:
            L10n.string("view.grid.2x2")
        case .singleRow:
            L10n.string("view.grid.1x4")
        }
    }

    private func searchButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 24, height: 24)
                .background(theme.panel, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

enum SearchKeyboardNavigation {
    static func isBackwards(modifiers: EventModifiers) -> Bool {
        modifiers.contains(.shift)
    }
}

private struct FourPageLayoutIcon: View {
    let mode: PDFGridLayoutMode

    private var columnCount: Int {
        mode == .balanced ? 2 : 4
    }

    private var rowCount: Int {
        mode == .balanced ? 2 : 1
    }

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<columnCount, id: \.self) { _ in
                VStack(spacing: 1.5) {
                    ForEach(0..<rowCount, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                            .strokeBorder(lineWidth: 1.15)
                    }
                }
            }
        }
        .frame(width: 18, height: 15)
        .accessibilityHidden(true)
    }
}

/// 같은 두 페이지 수 안에서 연속 스크롤과 한 펼침 고정을 구별하는 작은 기호다.
/// 연속 모드는 아래쪽에 다음 펼침의 윗부분을 살짝 보여 주고, 고정 모드는
/// 완전한 두 장만 그려 툴팁을 열지 않아도 차이를 알아볼 수 있게 한다.
private struct TwoPageLayoutIcon: View {
    let mode: PDFTwoPageDisplayMode

    var body: some View {
        Group {
            if mode == .continuous {
                VStack(spacing: 1.5) {
                    pagePair(height: 12)
                    pagePair(height: 8)
                        .frame(height: 3, alignment: .top)
                        .clipped()
                }
            } else {
                pagePair(height: 17)
            }
        }
        .frame(width: 19, height: 19)
    }

    private func pagePair(height: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.4, style: .continuous)
                    .stroke(lineWidth: 1.25)
            }
        }
        .frame(width: 18, height: height)
    }
}

// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// 앱의 composition root: 장면, 장기 수명 모델, 메뉴 명령을 서로 연결한다.
///
/// 비즈니스 로직은 여기 두지 않는다. `@StateObject`로 process/scene 수명에 맞는
/// 객체를 한 번 만들고 하위 view에 주입한다. main Window는 기본 workspace를,
/// UUID 기반 WindowGroup은 tear-out 탭마다 독립 workspace를 사용한다.
@main
struct VibePDFApp: App {
    @NSApplicationDelegateAdaptor(VibePDFAppDelegate.self) private var appDelegate
    @StateObject private var workspace: MultiDocumentWorkspaceState
    @StateObject private var preferences = AppPreferences.shared
    @StateObject private var iconManager = AppIconManager.shared
    @StateObject private var aiSettings = AIProviderSettingsStore.shared
    @StateObject private var pluginManager = PluginManager.shared
    /// Keeps detached-window observers and the app-wide snapshot provider
    /// alive for the full process lifetime.
    private let sessionCoordinator: AppWideWorkspaceSessionCoordinator

    init() {
        let recentDocuments = RecentDocumentsStore()
        let sessionStore = WorkspaceSessionStore()
        let workspace = MultiDocumentWorkspaceState(
            recentDocumentsStore: recentDocuments,
            sessionStore: sessionStore
        )
        _workspace = StateObject(wrappedValue: workspace)
        sessionCoordinator = AppWideWorkspaceSessionCoordinator(
            mainWorkspace: workspace,
            sessionStore: sessionStore
        )
    }

    /// SwiftUI의 `Scene`은 창 종류를 선언한다. 같은 View를 여러 창에서 사용할 때
    /// 각 장면에 locale, layoutDirection, command scope를 다시 주입해야 한다.
    var body: some Scene {
        Window("HwattakPDF", id: "main") {
            TabbedWorkspaceView(
                workspace: workspace,
                windowID: nil,
                sessionCoordinator: sessionCoordinator
            )
                .frame(minWidth: 1_180, minHeight: 690)
                .background(WindowCloseGuard(workspace: workspace))
                .focusedSceneObject(workspace)
                .environmentObject(preferences)
                .environmentObject(iconManager)
                .environmentObject(aiSettings)
                .environmentObject(pluginManager)
                .environment(\.locale, preferences.language.locale)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
                .onAppear {
                    appDelegate.workspace = workspace
                    sessionCoordinator.resumeMainSessionPersistence()
                    iconManager.applySavedSelection()
                }
                .onChange(of: preferences.language) { _, _ in
                    workspace.allTabs.forEach { $0.workspace.refreshLocalization() }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1_420, height: 900)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
        .commands {
            VibePDFCommands(preferences: preferences)
            PluginCommands(manager: pluginManager)
            HelpTutorialCommands()
        }

        WindowGroup("HwattakPDF", for: UUID.self) { $requestID in
            PDFTabTearOutWindowRoot(
                requestID: requestID,
                sessionCoordinator: sessionCoordinator
            )
                .frame(minWidth: 1_180, minHeight: 690)
                .environmentObject(preferences)
                .environmentObject(iconManager)
                .environmentObject(aiSettings)
                .environmentObject(pluginManager)
                .environment(\.locale, preferences.language.locale)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1_420, height: 900)
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

        Window(HelpTutorialContent.windowTitle, id: HelpTutorialContent.sceneID) {
            HelpTutorialView()
                .environment(\.locale, preferences.language.locale)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)

        Window(PluginManagerContent.windowTitle, id: PluginManagerContent.sceneID) {
            PluginManagerView(manager: pluginManager)
                .environmentObject(preferences)
                .environmentObject(pluginManager)
                .environment(\.locale, preferences.language.locale)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
        }
        .defaultSize(width: 820, height: 700)
        .windowResizability(.contentMinSize)

        Window(L10n.string("about.title", defaultValue: "HwattakPDF 정보"), id: AboutContent.sceneID) {
            AboutView()
                .environment(\.locale, preferences.language.locale)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
        }
        .defaultSize(width: 840, height: 690)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(
                preferences: preferences,
                iconManager: iconManager,
                pluginManager: pluginManager
            )
                .environmentObject(preferences)
                .environmentObject(iconManager)
                .environmentObject(aiSettings)
                .environmentObject(pluginManager)
                .environment(\.locale, preferences.language.locale)
                .environment(\.layoutDirection, preferences.language.layoutDirection)
        }
    }
}

@MainActor
private struct VibePDFCommands: Commands {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject private var editCommandRouter = AppEditCommandRouter.shared
    @FocusedObject private var focusedWorkspace: MultiDocumentWorkspaceState?
    @FocusedValue(\.documentSearchAvailable) private var documentSearchAvailable
    @FocusedValue(\.comparisonReadOnlyActive) private var comparisonReadOnlyActive
    @FocusedValue(\.workspacePresentationCommands) private var presentationCommands
    @AppStorage(WorkspaceChromePreferences.modeToolsVisibleKey)
    private var modeToolsVisible = true
    @AppStorage("pageOverviewPlacement")
    private var pageOverviewPlacementValue = PageOverviewPlacement.left.rawValue
    @AppStorage("fourPagePagingDirection")
    private var gridPagingDirectionValue = PDFGridPagingDirection.vertical.rawValue
    @Environment(\.openWindow) private var openWindow

    /// File and tab commands are application-wide menu items, but their model
    /// target must come from the actual key PDF window. Focused values can remain
    /// associated with the parent scene while a sheet is key, and there is no
    /// focused PDF scene at all while Settings, About, or Help is key.
    private var fileCommandWorkspace: MultiDocumentWorkspaceState? {
        AppFileCommandRouter.documentWorkspace(for: NSApp.keyWindow)
    }

    private var documentWorkspace: PDFWorkspaceState? {
        // Never fall back to a hidden main-window PDF while Settings, About,
        // or Help owns the key window. A focused normal PDF scene must own
        // history; comparison publishes a strict read-only boundary below.
        guard comparisonReadOnlyActive != true else { return nil }
        return editCommandRouter.documentWorkspace(
            fallback: fileCommandWorkspace?.activeWorkspace
        )
    }

    /// Byte- or mode-mutating commands target only the normal document surface.
    /// Read-only export/extract commands and saving already-dirty bytes remain
    /// available while comparison is presented.
    private var mutationCommandWorkspace: PDFWorkspaceState? {
        guard comparisonReadOnlyActive != true else { return nil }
        return focusedWorkspace?.activeWorkspace
    }

    /// Exports read the current PDF without mutating it, but they must still
    /// belong to the focused document window. Settings/About/Help must never
    /// export a PDF that happens to be hidden in the fallback main window.
    private var exportCommandWorkspace: PDFWorkspaceState? {
        focusedWorkspace?.activeWorkspace
    }

    /// Search belongs to the toolbar of the active tab. Requiring a focused
    /// document scene prevents Command-F in Settings/About/Help from waking a
    /// hidden main-window search field.
    private var searchCommandWorkspace: PDFWorkspaceState? {
        focusedWorkspace?.activeWorkspace
    }

    /// Mode changes must target only the focused PDF window. Falling back to
    /// the hidden main window while Help or Settings is key would surprise the
    /// user and could silently rewrite that tab's restored mode.
    private var modeCommandWorkspace: PDFWorkspaceState? {
        mutationCommandWorkspace
    }

    /// View commands are presentation-only, but still require a focused PDF
    /// scene. This prevents Settings, Help or comparison mode from changing a
    /// document hidden behind the key window.
    private var viewCommandWorkspace: PDFWorkspaceState? {
        guard comparisonReadOnlyActive != true, presentationCommands != nil else {
            return nil
        }
        return focusedWorkspace?.activeWorkspace
    }

    private var pageOverviewPlacement: PageOverviewPlacement {
        PageOverviewPlacement(rawValue: pageOverviewPlacementValue) ?? .left
    }

    private var gridPagingDirection: PDFGridPagingDirection {
        PDFGridPagingDirection(rawValue: gridPagingDirectionValue) ?? .vertical
    }

    private var undoMenuTitle: String {
        let documentTitle = editHistoryMenuTitle(
            baseKey: "menu.undo",
            namedKey: "menu.undo_named",
            actionName: documentWorkspace?.undoActionName
        )
        return editCommandRouter.undoMenuTitle(documentTitle: documentTitle)
    }

    private var redoMenuTitle: String {
        let documentTitle = editHistoryMenuTitle(
            baseKey: "menu.redo",
            namedKey: "menu.redo_named",
            actionName: documentWorkspace?.redoActionName
        )
        return editCommandRouter.redoMenuTitle(documentTitle: documentTitle)
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.string("about.menu", defaultValue: "HwattakPDF 정보")) {
                openWindow(id: AboutContent.sceneID)
            }
        }

        CommandGroup(replacing: .undoRedo) {
            if editCommandRouter.destination == .blockedBySheet {
                // Do not install Command-Z key equivalents while a sheet owns
                // the interaction. Signature capture has its own local undo.
                Button(L10n.string("menu.undo")) {}
                    .disabled(true)
                Button(L10n.string("menu.redo")) {}
                    .disabled(true)
            } else {
                Button(undoMenuTitle) {
                    editCommandRouter.performUndo {
                        documentWorkspace?.undo()
                    }
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(
                    !editCommandRouter.canUndo(
                        documentCanUndo: documentWorkspace?.canUndo ?? false
                    )
                )

                Button(redoMenuTitle) {
                    editCommandRouter.performRedo {
                        documentWorkspace?.redo()
                    }
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(
                    !editCommandRouter.canRedo(
                        documentCanRedo: documentWorkspace?.canRedo ?? false
                    )
                )
            }

            Divider()

            Button(L10n.string("search.navigator.menu_find", defaultValue: "문서에서 찾기")) {
                guard let searchCommandWorkspace else { return }
                NotificationCenter.default.post(
                    name: .focusDocumentSearch,
                    object: searchCommandWorkspace
                )
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(
                documentSearchAvailable != true
                    || searchCommandWorkspace?.document == nil
            )
        }

        CommandGroup(replacing: .newItem) {
            Button(L10n.string("menu.new_tab")) {
                fileCommandWorkspace?.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(fileCommandWorkspace == nil)

            Button(L10n.string("menu.open_pdf")) {
                guard let fileCommandWorkspace else { return }
                let urls = WorkspaceFilePanels.choosePDFs(
                    allowsMultipleSelection: true,
                    purpose: .openInTabs
                )
                fileCommandWorkspace.beginOpeningPDFsInTabs(urls: urls)
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(fileCommandWorkspace == nil)

            Divider()

            Button(L10n.string("menu.close")) {
                closeActiveTarget()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(!canCloseActiveTarget)
        }

        CommandGroup(replacing: .saveItem) {
            Button(L10n.string("menu.save")) {
                guard
                    let activeWorkspace = exportCommandWorkspace,
                    activeWorkspace.canSaveNormally
                else {
                    return
                }
                WorkspaceSaveCoordinator.requestSave(workspace: activeWorkspace)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(exportCommandWorkspace?.canSaveNormally != true)

            Button(L10n.string("action.save_copy")) {
                guard
                    let activeWorkspace = exportCommandWorkspace,
                    activeWorkspace.canSaveNormally
                else {
                    return
                }
                WorkspaceSaveCoordinator.requestSaveCopy(workspace: activeWorkspace)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(exportCommandWorkspace?.canSaveNormally != true)

            Divider()

            Button(L10n.string("security.export.menu")) {
                guard
                    comparisonReadOnlyActive != true,
                    let activeWorkspace = exportCommandWorkspace,
                    activeWorkspace.canRequestProtectedPDFExport
                else {
                    return
                }
                guard let destinationURL = WorkspaceFilePanels.chooseSavePDF(
                    suggestedName: ProtectedPDFExporter.suggestedFileName(
                        for: activeWorkspace.documentURL
                    ),
                    title: L10n.string("security.export.title")
                ) else {
                    return
                }
                activeWorkspace.requestProtectedPDFExport(to: destinationURL)
            }
            .disabled(
                comparisonReadOnlyActive == true
                    || exportCommandWorkspace?.canRequestProtectedPDFExport != true
            )
        }

        // Extend the native macOS View menu instead of creating a second
        // custom "View" menu. Common layouts remain direct toolbar icons;
        // this menu owns detailed and less frequent presentation choices.
        CommandGroup(after: .sidebar) {
            Button(
                checkedMenuTitle(
                    L10n.string("view.sidebar.show", defaultValue: "페이지 패널 표시"),
                    isSelected: viewCommandWorkspace?.sidebarVisible == true
                )
            ) {
                guard let viewCommandWorkspace else { return }
                viewCommandWorkspace.sidebarVisible.toggle()
            }
            .disabled(viewCommandWorkspace?.document == nil)

            Button(
                checkedMenuTitle(
                    L10n.string(
                        "toolbar.mode_tools.show",
                        defaultValue: "모드 도구줄 표시"
                    ),
                    isSelected: modeToolsVisible
                )
            ) {
                modeToolsVisible.toggle()
            }
            .disabled(viewCommandWorkspace?.document == nil)

            Button(
                L10n.string(
                    presentationCommands?.isFocusMode == true
                        ? "view.focus.exit"
                        : "view.focus.enter",
                    defaultValue: presentationCommands?.isFocusMode == true
                        ? "집중 보기 종료"
                        : "집중 보기"
                )
            ) {
                guard let presentationCommands else { return }
                presentationCommands.setFocusMode(!presentationCommands.isFocusMode)
            }
            .disabled(
                viewCommandWorkspace?.document == nil
                    || editCommandRouter.destination == .blockedBySheet
            )

            Divider()

            Menu(L10n.string("toolbar.view_layout", defaultValue: "화면 배치")) {
                Button(
                    checkedMenuTitle(
                        L10n.format("view.pages_at_once", 1),
                        isSelected: viewCommandWorkspace?.pageColumns == 1
                    )
                ) {
                    viewCommandWorkspace?.pageColumns = 1
                }

                Button(
                    checkedMenuTitle(
                        L10n.string("view.two_page.continuous.title"),
                        isSelected: viewCommandWorkspace?.pageColumns == 2
                            && viewCommandWorkspace?.twoPageDisplayMode == .continuous
                    )
                ) {
                    viewCommandWorkspace?.selectTwoPageDisplayMode(.continuous)
                }

                Button(
                    checkedMenuTitle(
                        L10n.string("view.two_page.paged.title"),
                        isSelected: viewCommandWorkspace?.pageColumns == 2
                            && viewCommandWorkspace?.twoPageDisplayMode == .paged
                    )
                ) {
                    viewCommandWorkspace?.selectTwoPageDisplayMode(.paged)
                }

                Divider()

                ForEach(PDFGridLayoutMode.allCases) { layoutMode in
                    Button(
                        checkedMenuTitle(
                            L10n.format(
                                "view.grid.four_overview",
                                gridLayoutDescription(layoutMode),
                                gridPagingDirection.title
                            ),
                            isSelected: viewCommandWorkspace?.pageColumns == 4
                                && viewCommandWorkspace?.gridLayoutMode == layoutMode
                        )
                    ) {
                        viewCommandWorkspace?.gridLayoutMode = layoutMode
                        viewCommandWorkspace?.pageColumns = 4
                    }
                }

                Divider()

                Menu(L10n.string("사용자 지정 페이지 수")) {
                    ForEach([3] + Array(5...12), id: \.self) { pageCount in
                        Button(
                            checkedMenuTitle(
                                L10n.format("view.pages_at_once", pageCount),
                                isSelected: viewCommandWorkspace?.pageColumns == pageCount
                            )
                        ) {
                            viewCommandWorkspace?.pageColumns = pageCount
                        }
                    }
                }
            }
            .disabled(viewCommandWorkspace?.document == nil)

            Menu(L10n.string("4페이지 그룹 이동 방향")) {
                ForEach(PDFGridPagingDirection.allCases) { direction in
                    Button(
                        checkedMenuTitle(
                            direction.title,
                            isSelected: gridPagingDirection == direction
                        )
                    ) {
                        gridPagingDirectionValue = direction.rawValue
                    }
                }
            }
            .disabled(viewCommandWorkspace?.document == nil)

            Menu(
                L10n.string(
                    "view.sidebar.position",
                    defaultValue: "페이지 패널 위치"
                )
            ) {
                ForEach(PageOverviewPlacement.allCases) { placement in
                    Button(
                        checkedMenuTitle(
                            placement.title,
                            isSelected: pageOverviewPlacement == placement
                        )
                    ) {
                        pageOverviewPlacementValue = placement.rawValue
                        viewCommandWorkspace?.sidebarVisible = true
                    }
                }
            }
            .disabled(viewCommandWorkspace?.document == nil)
        }

        CommandMenu(L10n.string("menu.pdf")) {
            Button(L10n.string("menu.merge")) {
                guard let activeWorkspace = mutationCommandWorkspace else { return }
                guard activeWorkspace.allows(.pageEditing) else { return }
                let urls = WorkspaceFilePanels.choosePDFs(allowsMultipleSelection: true)
                guard !urls.isEmpty else { return }
                activeWorkspace.merge(
                    urls: urls,
                    insertionIndex: activeWorkspace.selectedPages.max().map { $0 + 1 }
                )
            }
            .disabled(
                mutationCommandWorkspace?.document == nil
                    || mutationCommandWorkspace?.allows(.pageEditing) != true
            )

            Menu(L10n.string("menu.export_selected_pages")) {
                Button(L10n.string("menu.export_selected_pages.combined")) {
                    guard
                        let activeWorkspace = exportCommandWorkspace,
                        activeWorkspace.canExtractPages,
                        !activeWorkspace.selectedPages.isEmpty
                    else { return }
                    if let url = WorkspaceFilePanels.chooseSavePDF(
                        suggestedName: SelectedPagePDFExporter.combinedFileName(
                            for: activeWorkspace.documentURL
                        ),
                        title: L10n.string("panel.title.save_selected_pages_combined")
                    ) {
                        activeWorkspace.exportSelectedPagesAsCombinedPDF(to: url)
                    }
                }

                Button(L10n.string("menu.export_selected_pages.individual")) {
                    guard
                        let activeWorkspace = exportCommandWorkspace,
                        activeWorkspace.canExtractPages,
                        !activeWorkspace.selectedPages.isEmpty
                    else { return }
                    if let directory = WorkspaceFilePanels.chooseDirectory(
                        title: L10n.string("panel.title.choose_individual_pages_folder"),
                        message: L10n.format(
                            "panel.message.export_individual_pages",
                            activeWorkspace.selectedPages.count
                        )
                    ) {
                        activeWorkspace.exportSelectedPagesAsIndividualPDFs(to: directory)
                    }
                }
            }
            .disabled(
                exportCommandWorkspace?.canExtractPages != true
                    || exportCommandWorkspace?.selectedPages.isEmpty != false
            )

            Button(L10n.string("menu.export_png")) {
                guard
                    let activeWorkspace = exportCommandWorkspace,
                    activeWorkspace.canRasterizePages,
                    !activeWorkspace.selectedPages.isEmpty
                else { return }
                if let directory = WorkspaceFilePanels.chooseDirectory(
                    message: L10n.string("PNG 파일을 저장할 폴더를 선택하세요.")
                ) {
                    activeWorkspace.exportSelectedPagesAsImages(to: directory)
                }
            }
            .disabled(
                exportCommandWorkspace?.canRasterizePages != true
                    || exportCommandWorkspace?.selectedPages.isEmpty != false
            )

            Divider()

            Button(L10n.string("menu.highlight")) {
                mutationCommandWorkspace?.applyCurrentModeHighlight()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(
                    mutationCommandWorkspace?.document == nil
                        || editCommandRouter.destination != .document
                )
        }

        CommandMenu(L10n.string("mode.menu", defaultValue: "Mode")) {
            // Control-number avoids the Command-number convention commonly
            // reserved for selecting numbered tabs in document applications.
            Button(modeMenuTitle(.viewer)) {
                modeCommandWorkspace?.setMode(.viewer)
            }
            .keyboardShortcut("1", modifiers: .control)
            .disabled(modeCommandWorkspace == nil)

            Button(modeMenuTitle(.editing)) {
                modeCommandWorkspace?.setMode(.editing)
            }
            .keyboardShortcut("2", modifiers: .control)
            .disabled(modeCommandWorkspace == nil)

            Button(modeMenuTitle(.study)) {
                modeCommandWorkspace?.setMode(.study)
            }
            .keyboardShortcut("3", modifiers: .control)
            .disabled(modeCommandWorkspace == nil)
        }

        CommandMenu(L10n.string("menu.tabs")) {
            Button(L10n.string("menu.next_tab")) {
                fileCommandWorkspace?.selectAdjacentTab(forward: true)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled((fileCommandWorkspace?.tabs.count ?? 0) < 2)

            Button(L10n.string("menu.previous_tab")) {
                fileCommandWorkspace?.selectAdjacentTab(forward: false)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled((fileCommandWorkspace?.tabs.count ?? 0) < 2)

            Divider()

            Button(L10n.string("menu.close_others")) {
                closeOtherTabs()
            }
            .disabled((fileCommandWorkspace?.tabs.count ?? 0) < 2)
        }

        CommandMenu(L10n.string("menu.language")) {
            ForEach(AppLanguage.allCases) { language in
                Button(
                    (preferences.language == language ? "✓ " : "") + language.nativeName
                ) {
                    preferences.language = language
                }
            }
        }
    }

    private var canCloseActiveTarget: Bool {
        switch AppFileCommandRouter.closeTarget(for: NSApp.keyWindow) {
        case .activeTab, .window:
            true
        case .none:
            false
        }
    }

    private func closeActiveTarget() {
        switch AppFileCommandRouter.closeTarget(for: NSApp.keyWindow) {
        case let .activeTab(workspace):
            closeActiveTab(in: workspace)
        case let .window(window):
            // Keep AppKit in charge of auxiliary-window and sheet dismissal so
            // SwiftUI presentation bindings and native close validation update.
            window.performClose(nil)
        case .none:
            break
        }
    }

    private func closeActiveTab(in workspace: MultiDocumentWorkspaceState) {
        guard let session = workspace.activeSession else { return }
        guard UnsavedChangesGuard.confirmAndClose(workspace: session.workspace) else { return }
        _ = workspace.closeTab(session.id)
    }

    private func closeOtherTabs() {
        guard let workspace = fileCommandWorkspace else { return }
        guard let activeSession = workspace.activeSession else { return }
        let others = workspace.tabs.filter { $0.id != activeSession.id }
        guard UnsavedChangesGuard.confirmAndClose(workspaces: others.map(\.workspace)) else { return }
        others.forEach { _ = workspace.closeTab($0.id) }
        workspace.selectTab(activeSession.id)
    }

    private func editHistoryMenuTitle(
        baseKey: String,
        namedKey: String,
        actionName: String?
    ) -> String {
        guard
            let actionName,
            !actionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return L10n.string(baseKey)
        }
        return L10n.format(namedKey, actionName)
    }

    private func modeMenuTitle(_ mode: PDFWorkspaceMode) -> String {
        (modeCommandWorkspace?.mode == mode ? "✓ " : "") + mode.title
    }

    private func checkedMenuTitle(_ title: String, isSelected: Bool) -> String {
        (isSelected ? "✓ " : "") + title
    }

    private func gridLayoutDescription(_ mode: PDFGridLayoutMode) -> String {
        switch mode {
        case .balanced:
            L10n.string("view.grid.2x2")
        case .singleRow:
            L10n.string("view.grid.1x4")
        }
    }
}

/// Resolves app-wide File/Tab menu commands against AppKit's key window.
///
/// `@FocusedObject` is useful for live menu state, but it is intentionally not
/// an ownership registry: a document scene can keep its focused values while a
/// sheet is presented. `WindowCloseGuard` is installed only on real PDF windows,
/// so its coordinator provides an exact, testable key-window boundary.
@MainActor
enum AppFileCommandRouter {
    enum CloseTarget {
        case activeTab(MultiDocumentWorkspaceState)
        case window(NSWindow)
        case none
    }

    static func documentWorkspace(for keyWindow: NSWindow?) -> MultiDocumentWorkspaceState? {
        guard
            let keyWindow,
            keyWindow.sheetParent == nil,
            keyWindow.attachedSheet == nil,
            let coordinator = keyWindow.delegate as? WindowCloseGuard.Coordinator
        else {
            return nil
        }
        return coordinator.workspace
    }

    static func closeTarget(for keyWindow: NSWindow?) -> CloseTarget {
        guard let keyWindow else { return .none }
        if let sheet = keyWindow.attachedSheet {
            return .window(sheet)
        }
        if keyWindow.sheetParent != nil {
            return .window(keyWindow)
        }
        if
            let coordinator = keyWindow.delegate as? WindowCloseGuard.Coordinator,
            let workspace = coordinator.workspace
        {
            return .activeTab(workspace)
        }
        return .window(keyWindow)
    }
}

@MainActor
private struct PDFTabTearOutWindowRoot: View {
    let requestID: UUID?
    let sessionCoordinator: AppWideWorkspaceSessionCoordinator

    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var iconManager: AppIconManager

    var body: some View {
        if
            let requestID,
            let workspace = PDFTabTearOutStore.shared.workspace(for: requestID)
        {
            TabbedWorkspaceView(
                workspace: workspace,
                handlesLaunchArguments: false,
                windowID: requestID,
                sessionCoordinator: sessionCoordinator
            )
                .background(WindowCloseGuard(workspace: workspace))
                .focusedSceneObject(workspace)
                .onAppear {
                    iconManager.applySavedSelection()
                }
                .onChange(of: preferences.language) { _, _ in
                    workspace.allTabs.forEach { $0.workspace.refreshLocalization() }
                }
                .onDisappear {
                    PDFTabTearOutStore.shared.releaseWindow(requestID)
                }
        } else {
            ContentUnavailableView(
                L10n.string("tab.new"),
                systemImage: "doc.badge.plus"
            )
        }
    }
}

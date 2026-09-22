// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Use a system-declared in-process payload type. A custom exported UTI that is
// not also declared in Info.plist can be rejected by AppKit before SwiftUI's
// DropDelegate ever receives the mouse drop.
private let hwattakPDFTabType = UTType.utf8PlainText
private let pdfTabWidth: CGFloat = 180
private let pdfTabGroupHeaderWidth: CGFloat = 148
private let tabStackSpring = Animation.spring(
    response: 0.30,
    dampingFraction: 0.88,
    blendDuration: 0.12
)
private let tabDropFeedbackAnimation = Animation.easeOut(duration: 0.12)

private func tabMotionAnimation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .linear(duration: 0.01) : tabStackSpring
}

private func tabFeedbackAnimation(reduceMotion: Bool) -> Animation {
    reduceMotion ? .linear(duration: 0.01) : tabDropFeedbackAnimation
}

private func tabDragSourceID(from info: DropInfo, localTabID: UUID?) -> UUID? {
    PDFTabDragPayload.resolve(
        localTabID: localTabID,
        providerSuggestedNames: info.itemProviders(for: [hwattakPDFTabType.identifier])
            .compactMap(\.suggestedName)
    )
}

/// Loads the authoritative tab ID from the provider contents. Returning `true`
/// means a load was scheduled, not that the payload was valid.
private func loadTabDragSourceID(
    from info: DropInfo,
    completion: @escaping @MainActor (UUID?) -> Void
) -> Bool {
    guard let provider = info.itemProviders(for: [hwattakPDFTabType.identifier]).first else {
        return false
    }
    provider.loadObject(ofClass: NSString.self) { object, _ in
        let sourceID = (object as? NSString)
            .map(String.init)
            .flatMap(PDFTabDragPayload.decode)
        Task { @MainActor in
            completion(sourceID)
        }
    }
    return true
}

/// 탭·탭 스택·명명된 워크스페이스를 표시하고 drag/drop으로 재배치하는 화면이다.
///
/// hover 중에는 빠른 시각 피드백을 위해 local `draggedTabID`를 쓸 수 있지만,
/// 실제 mutation은 반드시 provider 안의 process nonce payload를 비동기로 decode한
/// 뒤 현재 모델 membership을 다시 확인한다. 이 2단계 검증이 취소된 drag나 외부
/// plain text drop이 탭 이동으로 오인되는 것을 막는다.
struct PDFTabBar: View {
    @ObservedObject var workspace: MultiDocumentWorkspaceState

    let canCompare: Bool
    let isComparing: Bool
    let comparisonAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var draggedTabID: UUID?
    // drop target/intent는 포인터가 떠 있는 동안만 필요한 transient UI 상태다.
    @State private var tabDropTargetID: UUID?
    @State private var tabDropIntent: PDFTabDropIntent?
    @State private var groupDropTargetID: UUID?
    @State private var groupDropIntent: PDFTabDropIntent?
    @State private var isFileDropTargeted = false
    @State private var showingResourceMonitor = false
    @State private var showingGroupNameEditor = false
    @State private var groupNameDraft = ""
    @State private var groupBeingRenamedID: UUID?
    @State private var pendingGroupTabIDs: [UUID] = []
    @State private var showingWorkspaceNameEditor = false
    @State private var workspaceBeingRenamedID: UUID?
    @State private var workspaceCreationTabID: UUID?
    @State private var workspaceNameDraft = ""
    @State private var workspacePendingDeletionID: UUID?
    @State private var lastActiveTabByGroup: [UUID: UUID] = [:]

    private var theme: HwattakPDFTheme {
        HwattakPDFTheme(colorScheme: colorScheme)
    }

    private var activeGroup: PDFTabGroup? {
        guard let activeTabID = workspace.activeTabID else { return nil }
        return workspace.group(containing: activeTabID)
    }

    private var visibleActiveGroup: PDFTabGroup? {
        guard let activeGroup, !activeGroup.isCollapsed else { return nil }
        return activeGroup
    }

    private var activePrimaryEntryID: PDFTabBarEntry.ID? {
        guard let activeTabID = workspace.activeTabID else { return nil }
        if let activeGroup {
            return .group(activeGroup.id)
        }
        return .tab(activeTabID)
    }

    private var layoutAnimation: Animation {
        tabMotionAnimation(reduceMotion: reduceMotion)
    }

    private var primaryEntryIDs: [PDFTabBarEntry.ID] {
        workspace.orderedTabBarEntries.map(\.id)
    }

    private var visibleGroupMemberIDs: [UUID] {
        visibleActiveGroup?.tabIDs ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            primaryRow

            if let group = visibleActiveGroup {
                secondaryRow(for: group)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: visibleActiveGroup == nil ? 56 : 100)
        .background(theme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1)
        }
        .overlay {
            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(theme.steel.opacity(0.26))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(theme.chromeText, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    }
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onHover { isInside in
            // SwiftUI does not expose onDrag's session-ended callback. If a
            // drag was released over native titlebar chrome, clear its stale
            // local hint as soon as the pointer returns without a pressed
            // primary button.
            if
                isInside,
                NSEvent.pressedMouseButtons & 1 == 0,
                draggedTabID != nil
            {
                clearTabDragState()
            }
        }
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isFileDropTargeted,
            perform: acceptFinderDrop
        )
        // Child tab/group delegates handle meaningful moves first. This broad
        // fallback consumes a valid tab drag released over non-target chrome
        // (menus, +) so its source never remains visually "dragging".
        .onDrop(
            of: [hwattakPDFTabType.identifier],
            delegate: TabBarDragCleanupDropDelegate(
                draggedTabID: $draggedTabID,
                tabDropTargetID: $tabDropTargetID,
                tabDropIntent: $tabDropIntent,
                groupDropTargetID: $groupDropTargetID,
                groupDropIntent: $groupDropIntent
            )
        )
        .alert(groupEditorTitle, isPresented: $showingGroupNameEditor) {
            TextField("예: 연구 자료", text: $groupNameDraft)
            Button("취소", role: .cancel) {
                resetGroupEditor()
            }
            Button("저장") {
                commitGroupEditor()
            }
        } message: {
            Text("PDF 탭을 주제별로 묶어 접거나 펼칠 수 있습니다.")
        }
        .alert(workspaceEditorTitle, isPresented: $showingWorkspaceNameEditor) {
            TextField("예: 계약 검토", text: $workspaceNameDraft)
            Button("취소", role: .cancel, action: resetWorkspaceEditor)
            Button("저장", action: commitWorkspaceEditor)
        } message: {
            Text("워크스페이스마다 탭과 탭 스택을 따로 정리합니다.")
        }
        .confirmationDialog(
            "워크스페이스를 삭제할까요?",
            isPresented: Binding(
                get: { workspacePendingDeletionID != nil },
                set: { if !$0 { workspacePendingDeletionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("워크스페이스 삭제", role: .destructive, action: deletePendingWorkspace)
            Button("취소", role: .cancel) { workspacePendingDeletionID = nil }
        } message: {
            Text("안에 열린 PDF를 확인한 뒤 워크스페이스를 삭제합니다.")
        }
        .sheet(isPresented: $showingResourceMonitor) {
            ResourceMonitorView(
                sessions: workspace.tabs,
                activeTabID: workspace.activeTabID,
                onSelect: { tabID in
                    workspace.selectTab(tabID)
                    showingResourceMonitor = false
                }
            )
        }
        .onChange(of: workspace.activeTabID, initial: true) { _, newValue in
            guard
                let newValue,
                let group = workspace.group(containing: newValue)
            else { return }
            lastActiveTabByGroup[group.id] = newValue
        }
        .onChange(of: workspace.activeWorkspaceID) { _, _ in
            clearTabDragState()
        }
        .onDisappear(perform: clearTabDragState)
        .animation(layoutAnimation, value: visibleActiveGroup?.id)
        .animation(layoutAnimation, value: primaryEntryIDs)
        .animation(layoutAnimation, value: visibleGroupMemberIDs)
        .animation(tabFeedbackAnimation(reduceMotion: reduceMotion), value: tabDropIntent)
        .animation(tabFeedbackAnimation(reduceMotion: reduceMotion), value: groupDropIntent)
    }

    private var primaryRow: some View {
        HStack(spacing: 9) {
            workspaceMenu
            tabOverviewMenu
            resourceMonitorButton
            comparisonButton
            chromeDivider

            OverflowAwareTabStrip(
                items: workspace.orderedTabBarEntries,
                activeID: activePrimaryEntryID,
                trailingActionWidth: 31,
                theme: theme,
                itemContent: { entry in
                    tabBarEntry(entry)
                },
                endDrop: {
                    primaryEndDropTarget
                },
                trailingAction: {
                    addTabButton
                }
            )
            .frame(maxWidth: .infinity)
        }
        .frame(height: 55)
    }

    private func secondaryRow(for group: PDFTabGroup) -> some View {
        HStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(theme.ribbon)
                Text(group.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(group.tabIDs.count)")
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 6)
                    .frame(minHeight: 18)
                    .background(theme.chromeRaised, in: Capsule())
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.chromeText)
            .frame(width: 190, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.format("tab.group_accessibility", group.title, group.tabIDs.count))

            OverflowAwareTabStrip(
                items: workspace.sessions(in: group),
                activeID: workspace.activeTabID,
                trailingActionWidth: 0,
                theme: theme,
                itemContent: { session in
                    tabItem(session, secondaryGroupID: group.id)
                        .id(PDFTabBarEntry.ID.tab(session.id))
                },
                endDrop: {
                    Color.clear
                        .frame(width: 26, height: 36)
                        .contentShape(Rectangle())
                        .onDrop(
                            of: [hwattakPDFTabType.identifier],
                            delegate: GroupTabEndDropDelegate(
                                groupID: group.id,
                                draggedTabID: $draggedTabID,
                                workspace: workspace
                            )
                        )
                },
                trailingAction: { EmptyView() }
            )
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.format("tab.stack_members", group.title))
        }
        .frame(height: 44)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.chromeText.opacity(0.12)).frame(height: 1)
        }
    }

    private var chromeDivider: some View {
        Rectangle()
            .fill(theme.chromeText.opacity(0.16))
            .frame(width: 1, height: 29)
    }

    private var primaryEndDropTarget: some View {
        Color.clear
            .frame(width: 52, height: 36)
            .contentShape(Rectangle())
            .onDrop(
                of: [hwattakPDFTabType.identifier],
                delegate: UngroupTabAtEndDropDelegate(
                    draggedTabID: $draggedTabID,
                    workspace: workspace
                )
            )
    }

    private var addTabButton: some View {
        Button(action: choosePDFsForNewTabs) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.brandNavy)
                .frame(width: 31, height: 31)
                .background(
                    theme.paperIvory,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help("PDF를 새 탭으로 열기")
        .accessibilityLabel("PDF를 새 탭으로 열기")
    }

    private var resourceMonitorButton: some View {
        Button {
            showingResourceMonitor = true
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.chromeText)
                .frame(width: 31, height: 31)
                .background(
                    theme.chromeRaised,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help("CPU 및 메모리 사용 보기")
        .accessibilityLabel("CPU 및 메모리 사용 보기")
    }

    private var comparisonButton: some View {
        Button(action: comparisonAction) {
            Image(systemName: isComparing ? "xmark" : "rectangle.on.rectangle.angled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.chromeText)
                .frame(width: 31, height: 31)
                .background(
                    theme.chromeRaised,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(alignment: .bottom) {
                    if isComparing {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(theme.ribbon)
                            .frame(height: 2)
                            .padding(.horizontal, 7)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(isComparing ? L10n.string("PDF 비교 닫기") : L10n.string("열린 PDF 비교"))
        .accessibilityLabel(isComparing ? L10n.string("PDF 비교 닫기") : L10n.string("열린 PDF 비교"))
        .disabled(!isComparing && !canCompare)
        .opacity(!isComparing && !canCompare ? 0.45 : 1)
    }

    @ViewBuilder
    private func tabBarEntry(_ entry: PDFTabBarEntry) -> some View {
        switch entry {
        case let .tab(tabID):
            if let session = workspace.tabs.first(where: { $0.id == tabID }) {
                tabItem(session)
                    .id(entry.id)
            }
        case let .group(group):
            tabGroup(group)
                .id(entry.id)
        }
    }

    private func tabItem(
        _ session: PDFTabSession,
        secondaryGroupID: UUID? = nil
    ) -> some View {
        let index = workspace.tabs.firstIndex(where: { $0.id == session.id }) ?? 0
        let currentGroup = workspace.group(containing: session.id)
        return PDFTabItem(
            session: session,
            isActive: workspace.activeTabID == session.id,
            // Do not leave a source tab dimmed merely because SwiftUI missed
            // a drag-ended callback over native window chrome. The source
            // treatment is useful only while a real tab/group target is live.
            isDragging: draggedTabID == session.id
                && (tabDropTargetID != nil || groupDropTargetID != nil),
            theme: theme,
            currentGroup: currentGroup,
            otherTabs: workspace.tabs.filter { candidate in
                guard candidate.id != session.id else { return false }
                guard let currentGroup else { return true }
                return workspace.group(containing: candidate.id)?.id != currentGroup.id
            },
            availableGroups: workspace.tabGroups.filter { $0.id != currentGroup?.id },
            availableWorkspaces: workspace.workspaces.filter { $0.id != workspace.activeWorkspaceID },
            dropIntent: tabDropTargetID == session.id ? tabDropIntent : nil,
            select: {
                workspace.selectTab(session.id)
            },
            close: { closeTab(session.id) },
            closeOthers: { closeOtherTabs(keeping: session.id) },
            closeToRight: { closeTabsToRight(of: session.id) },
            canCloseToRight: index < workspace.tabs.count - 1,
            canMoveLeft: index > 0,
            canMoveRight: index < workspace.tabs.count - 1,
            moveLeft: {
                guard index > 0 else { return }
                moveTabAtStripEdge(session.id, before: workspace.tabs[index - 1].id)
            },
            moveRight: {
                guard index < workspace.tabs.count - 1 else { return }
                moveTabAtStripEdge(session.id, after: workspace.tabs[index + 1].id)
            },
            createGroupWith: { otherTabID in
                beginCreatingGroup(tabIDs: [session.id, otherTabID])
            },
            addToGroup: { groupID in
                _ = workspace.addTab(session.id, toGroup: groupID)
            },
            removeFromGroup: {
                _ = workspace.removeTabFromGroup(session.id)
            },
            renameGroup: {
                guard let currentGroup else { return }
                beginRenamingGroup(currentGroup)
            },
            moveToWorkspace: { workspaceID in
                _ = workspace.moveTab(session.id, toWorkspace: workspaceID)
            },
            showResources: {
                workspace.selectTab(session.id)
                showingResourceMonitor = true
            }
        )
        .onDrag {
            tabDropTargetID = nil
            tabDropIntent = nil
            groupDropTargetID = nil
            groupDropIntent = nil
            draggedTabID = session.id
            let provider = NSItemProvider(
                object: PDFTabDragPayload.encodedValue(for: session.id) as NSString
            )
            provider.suggestedName = PDFTabDragPayload.suggestedName(for: session.id)
            return provider
        }
        .onDrop(
            of: [hwattakPDFTabType.identifier],
            delegate: TabReorderDropDelegate(
                targetID: session.id,
                draggedTabID: $draggedTabID,
                dropTargetID: $tabDropTargetID,
                dropIntent: $tabDropIntent,
                workspace: workspace,
                secondaryGroupID: secondaryGroupID,
                isRightToLeft: layoutDirection == .rightToLeft,
                createGroup: { sourceID, targetID in
                    guard let groupID = workspace.createTabGroup(
                        title: "",
                        tabIDs: [targetID, sourceID]
                    ) else { return }
                    _ = workspace.setTabGroupCollapsed(groupID, isCollapsed: false)
                    workspace.selectTab(sourceID)
                }
            )
        )
    }

    private func tabGroup(_ group: PDFTabGroup) -> some View {
        let sessions = workspace.sessions(in: group)
        let isActive = workspace.activeTabID.map { group.tabIDs.contains($0) } ?? false
        let entries = workspace.orderedTabBarEntries
        let entryIndex = entries.firstIndex(where: { $0.id == .group(group.id) }) ?? 0
        return PDFTabGroupHeader(
            group: group,
            sessions: sessions,
            isActive: isActive,
            theme: theme,
            dropIntent: groupDropTargetID == group.id ? groupDropIntent : nil,
            toggleCollapsed: {
                activateOrToggle(group)
            },
            rename: {
                beginRenamingGroup(group)
            },
            addEmptyTab: {
                workspace.newTab(inGroup: group.id)
            },
            openPDFs: {
                choosePDFsForGroup(group.id)
            },
            dissolve: {
                _ = workspace.deleteTabGroup(group.id, keepingTabs: true)
            },
            closeAll: {
                closeSessions(sessions)
            },
            canMoveLeft: entryIndex > 0,
            canMoveRight: entryIndex < entries.count - 1,
            moveLeft: {
                guard entryIndex > 0 else { return }
                workspace.moveTabGroup(group.id, before: entries[entryIndex - 1].id)
            },
            moveRight: {
                guard entryIndex < entries.count - 1 else { return }
                workspace.moveTabGroup(group.id, after: entries[entryIndex + 1].id)
            }
        )
        .onDrop(
            of: [hwattakPDFTabType.identifier],
            delegate: TabIntoGroupDropDelegate(
                group: group,
                draggedTabID: $draggedTabID,
                dropTargetID: $groupDropTargetID,
                dropIntent: $groupDropIntent,
                workspace: workspace,
                isRightToLeft: layoutDirection == .rightToLeft
            )
        )
    }

    private var groupEditorTitle: String {
        L10n.string(
            groupBeingRenamedID == nil ? "새 탭 스택 만들기" : "탭 스택 이름 변경"
        )
    }

    private func beginCreatingGroup(tabIDs: [UUID]) {
        pendingGroupTabIDs = tabIDs
        groupBeingRenamedID = nil
        groupNameDraft = ""
        showingGroupNameEditor = true
    }

    private func beginRenamingGroup(_ group: PDFTabGroup) {
        pendingGroupTabIDs = []
        groupBeingRenamedID = group.id
        groupNameDraft = group.title
        showingGroupNameEditor = true
    }

    private func activateOrToggle(_ group: PDFTabGroup) {
        let isActive = workspace.activeTabID.map { group.tabIDs.contains($0) } ?? false
        if isActive {
            _ = workspace.toggleTabGroupCollapsed(group.id)
            return
        }

        _ = workspace.setTabGroupCollapsed(group.id, isCollapsed: false)
        let rememberedID = lastActiveTabByGroup[group.id]
        let targetID = rememberedID.flatMap { remembered in
            group.tabIDs.contains(remembered) ? remembered : nil
        } ?? group.tabIDs.first
        if let targetID {
            workspace.selectTab(targetID)
        }
    }

    private func isGroupExpanded(_ group: PDFTabGroup) -> Bool {
        guard !group.isCollapsed, let activeTabID = workspace.activeTabID else { return false }
        return group.tabIDs.contains(activeTabID)
    }

    private func commitGroupEditor() {
        if let groupID = groupBeingRenamedID {
            _ = workspace.renameTabGroup(groupID, to: groupNameDraft)
        } else {
            _ = workspace.createTabGroup(title: groupNameDraft, tabIDs: pendingGroupTabIDs)
        }
        resetGroupEditor()
    }

    private func resetGroupEditor() {
        groupNameDraft = ""
        groupBeingRenamedID = nil
        pendingGroupTabIDs = []
    }

    private var workspaceMenu: some View {
        Menu {
            Section(L10n.string("workspace.menu_title")) {
                ForEach(workspace.workspaces) { item in
                    Button {
                        _ = workspace.selectWorkspace(item.id)
                    } label: {
                        Label {
                            Text(L10n.format("workspace.menu_item", item.title, item.tabCount))
                        } icon: {
                            Image(
                                systemName: item.id == workspace.activeWorkspaceID
                                    ? "checkmark.circle.fill"
                                    : "square.stack.3d.up"
                            )
                        }
                    }
                }
            }

            Divider()
            Button(L10n.string("workspace.new")) {
                beginCreatingWorkspace(fromCurrentTab: false)
            }
            Button(L10n.string("workspace.new_from_current")) {
                beginCreatingWorkspace(fromCurrentTab: true)
            }
            .disabled(workspace.activeTabID == nil)
            Button(L10n.string("workspace.rename")) {
                beginRenamingActiveWorkspace()
            }

            Divider()
            Button(L10n.string("workspace.delete"), role: .destructive) {
                workspacePendingDeletionID = workspace.activeWorkspaceID
            }
            .disabled(workspace.workspaces.count <= 1)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(theme.ribbon)
                Text(workspace.activeWorkspaceDescriptor?.title ?? L10n.string("workspace.menu_title"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(workspace.tabs.count)")
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 5)
                    .frame(minHeight: 17)
                    .background(theme.chrome, in: Capsule())
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.chromeText)
            .padding(.horizontal, 9)
            .frame(width: 174, height: 31, alignment: .leading)
            .background(theme.chromeRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.string("workspace.help"))
        .accessibilityLabel(
            L10n.format(
                "workspace.current_accessibility",
                workspace.activeWorkspaceDescriptor?.title ?? L10n.string("workspace.menu_title"),
                workspace.tabs.count
            )
        )
    }

    private var workspaceEditorTitle: String {
        L10n.string(
            workspaceBeingRenamedID == nil
                ? "workspace.new_title"
                : "workspace.rename_title"
        )
    }

    private func beginCreatingWorkspace(fromCurrentTab: Bool) {
        workspaceBeingRenamedID = nil
        workspaceCreationTabID = fromCurrentTab ? workspace.activeTabID : nil
        workspaceNameDraft = ""
        showingWorkspaceNameEditor = true
    }

    private func beginRenamingActiveWorkspace() {
        workspaceBeingRenamedID = workspace.activeWorkspaceID
        workspaceCreationTabID = nil
        workspaceNameDraft = workspace.activeWorkspaceDescriptor?.title ?? ""
        showingWorkspaceNameEditor = true
    }

    private func commitWorkspaceEditor() {
        if let workspaceID = workspaceBeingRenamedID {
            _ = workspace.renameWorkspace(workspaceID, to: workspaceNameDraft)
        } else if let tabID = workspaceCreationTabID {
            let workspaceID = workspace.createWorkspace(
                title: workspaceNameDraft,
                activate: false
            )
            if workspace.moveTab(tabID, toWorkspace: workspaceID) {
                _ = workspace.selectWorkspace(workspaceID)
            }
        } else {
            _ = workspace.createWorkspace(title: workspaceNameDraft, activate: true)
        }
        resetWorkspaceEditor()
    }

    private func resetWorkspaceEditor() {
        workspaceNameDraft = ""
        workspaceBeingRenamedID = nil
        workspaceCreationTabID = nil
    }

    private func deletePendingWorkspace() {
        guard workspace.workspaces.count > 1 else {
            workspacePendingDeletionID = nil
            return
        }
        let workspaceID = workspacePendingDeletionID ?? workspace.activeWorkspaceID
        workspacePendingDeletionID = nil
        let sessions = workspace.sessions(inWorkspace: workspaceID)
        guard UnsavedChangesGuard.confirmAndClose(workspaces: sessions.map(\.workspace)) else {
            return
        }
        _ = workspace.deleteWorkspace(workspaceID, discardingChanges: true)
    }

    private func clearTabDragState() {
        draggedTabID = nil
        tabDropTargetID = nil
        tabDropIntent = nil
        groupDropTargetID = nil
        groupDropIntent = nil
    }

    private var tabOverviewMenu: some View {
        Menu {
            Section("열린 탭") {
                ForEach(workspace.tabs) { session in
                    Button {
                        workspace.selectTab(session.id)
                    } label: {
                        Label(
                            session.displayName,
                            systemImage: workspace.activeTabID == session.id ? "checkmark" : "doc"
                        )
                    }
                }
            }

            Divider()
            Button("빈 탭 추가") { workspace.newTab() }
            Button("PDF를 새 탭으로 열기…", action: choosePDFsForNewTabs)

            if !workspace.tabGroups.isEmpty {
                Section("탭 스택") {
                    ForEach(workspace.tabGroups) { group in
                        Menu {
                            Button(L10n.string(isGroupExpanded(group) ? "접기" : "펼치기")) {
                                activateOrToggle(group)
                            }
                            Button("이름 변경…") {
                                beginRenamingGroup(group)
                            }
                            Button("PDF 추가…") {
                                choosePDFsForGroup(group.id)
                            }
                            Divider()
                            Button("스택 해제") {
                                _ = workspace.deleteTabGroup(group.id, keepingTabs: true)
                            }
                        } label: {
                            Label(
                                L10n.format("tab.group_count", group.title, group.tabIDs.count),
                                systemImage: "folder.fill"
                            )
                        }
                    }
                }
            }

            if
                let activeID = workspace.activeTabID,
                !stackCandidates(for: activeID).isEmpty
            {
                Menu("현재 탭으로 새 스택 만들기") {
                    ForEach(stackCandidates(for: activeID)) { session in
                        Button(session.displayName) {
                            beginCreatingGroup(tabIDs: [activeID, session.id])
                        }
                    }
                }
            }

            if workspace.tabs.count > 1, let activeID = workspace.activeTabID {
                Divider()
                Button("현재 탭 외 모두 닫기") {
                    closeOtherTabs(keeping: activeID)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up.fill")
                Text("\(workspace.tabs.count)")
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(theme.chromeText)
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(theme.chromeRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("열린 탭 관리")
        .accessibilityLabel(L10n.format("tab.manage_open_count", workspace.tabs.count))
    }

    private func choosePDFsForNewTabs() {
        let urls = WorkspaceFilePanels.choosePDFs(
            allowsMultipleSelection: true,
            purpose: .openInTabs
        )
        workspace.beginOpeningPDFsInTabs(urls: urls)
    }

    private func stackCandidates(for tabID: UUID) -> [PDFTabSession] {
        let currentGroupID = workspace.group(containing: tabID)?.id
        return workspace.tabs.filter { candidate in
            guard candidate.id != tabID else { return false }
            guard let currentGroupID else { return true }
            return workspace.group(containing: candidate.id)?.id != currentGroupID
        }
    }

    private func moveTabAtStripEdge(_ sourceID: UUID, before targetID: UUID) {
        if workspace.group(containing: sourceID)?.id == workspace.group(containing: targetID)?.id {
            workspace.moveTab(sourceID, before: targetID)
        } else {
            workspace.moveTabAsUngrouped(sourceID, before: targetID)
        }
    }

    private func moveTabAtStripEdge(_ sourceID: UUID, after targetID: UUID) {
        if workspace.group(containing: sourceID)?.id == workspace.group(containing: targetID)?.id {
            workspace.moveTab(sourceID, after: targetID)
        } else {
            workspace.moveTabAsUngrouped(sourceID, after: targetID)
        }
    }

    private func choosePDFsForGroup(_ groupID: UUID) {
        let urls = WorkspaceFilePanels.choosePDFs(
            allowsMultipleSelection: true,
            purpose: .openInTabs
        )
        workspace.beginOpeningPDFsInTabs(urls: urls, inGroup: groupID)
    }

    private func closeTab(_ id: UUID) {
        guard let session = workspace.tabs.first(where: { $0.id == id }) else { return }
        guard UnsavedChangesGuard.confirmAndClose(workspace: session.workspace) else { return }
        _ = workspace.closeTab(id)
    }

    private func closeOtherTabs(keeping id: UUID) {
        guard closeSessions(workspace.tabs.filter { $0.id != id }) else { return }
        workspace.selectTab(id)
    }

    private func closeTabsToRight(of id: UUID) {
        guard let index = workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
        guard closeSessions(Array(workspace.tabs.dropFirst(index + 1))) else { return }
        workspace.selectTab(id)
    }

    @discardableResult
    private func closeSessions(_ sessions: [PDFTabSession]) -> Bool {
        guard !sessions.isEmpty else { return true }
        guard UnsavedChangesGuard.confirmAndClose(workspaces: sessions.map(\.workspace)) else {
            return false
        }
        sessions.forEach { _ = workspace.closeTab($0.id) }
        return true
    }

    private func acceptFinderDrop(providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        WorkspaceDroppedFileLoader.load(from: fileProviders) { files in
            let pdfURLs = files.filter { $0.kind == .pdf }.map(\.url)
            if pdfURLs.isEmpty {
                workspace.activeWorkspace?.presentedError = L10n.string("error.tab_drop_pdf_only")
            } else {
                let skipped = files.count - pdfURLs.count
                workspace.beginOpeningPDFsInTabs(urls: pdfURLs) { _ in
                    if skipped > 0 {
                        let message = L10n.format("status.skipped_files", skipped)
                        if
                            let existing = workspace.activeWorkspace?.presentedError,
                            !existing.isEmpty
                        {
                            workspace.activeWorkspace?.presentedError = existing + "\n" + message
                        } else {
                            workspace.activeWorkspace?.presentedError = message
                        }
                    }
                }
            }
        }
        return true
    }
}

private struct TabStripContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct OverflowAwareTabStrip<
    Item: Identifiable,
    ItemContent: View,
    EndDrop: View,
    TrailingAction: View
>: View {
    let items: [Item]
    let activeID: Item.ID?
    let trailingActionWidth: CGFloat
    let theme: HwattakPDFTheme
    let itemContent: (Item) -> ItemContent
    let endDrop: () -> EndDrop
    let trailingAction: () -> TrailingAction

    @State private var contentWidth: CGFloat = 0
    @State private var visibleItemID: Item.ID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        items: [Item],
        activeID: Item.ID?,
        trailingActionWidth: CGFloat,
        theme: HwattakPDFTheme,
        @ViewBuilder itemContent: @escaping (Item) -> ItemContent,
        @ViewBuilder endDrop: @escaping () -> EndDrop,
        @ViewBuilder trailingAction: @escaping () -> TrailingAction
    ) {
        self.items = items
        self.activeID = activeID
        self.trailingActionWidth = trailingActionWidth
        self.theme = theme
        self.itemContent = itemContent
        self.endDrop = endDrop
        self.trailingAction = trailingAction
    }

    var body: some View {
        GeometryReader { geometry in
            let isOverflowing = PDFTabStripLayout.isOverflowing(
                contentWidth: Double(contentWidth),
                trailingActionWidth: Double(trailingActionWidth),
                viewportWidth: Double(geometry.size.width)
            )

            ScrollViewReader { proxy in
                HStack(spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            HStack(spacing: 4) {
                                ForEach(items) { item in
                                    itemContent(item)
                                        .id(item.id)
                                }
                                endDrop()
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .scrollTargetLayout()
                            .background {
                                GeometryReader { contentGeometry in
                                    Color.clear.preference(
                                        key: TabStripContentWidthKey.self,
                                        value: contentGeometry.size.width
                                    )
                                }
                            }

                            if !isOverflowing, trailingActionWidth > 0 {
                                trailingAction()
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.vertical, 4)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: $visibleItemID, anchor: .center)
                    .background {
                        PDFTabStripWheelMonitor(isEnabled: isOverflowing)
                    }

                    if isOverflowing {
                        navigationButton(
                            systemName: "chevron.backward",
                            label: L10n.string("tab.scroll_previous"),
                            isEnabled: currentNavigationIndex > 0
                        ) {
                            scroll(by: -1, using: proxy)
                        }
                        navigationButton(
                            systemName: "chevron.forward",
                            label: L10n.string("tab.scroll_next"),
                            isEnabled: currentNavigationIndex < items.count - 1
                        ) {
                            scroll(by: 1, using: proxy)
                        }
                        if trailingActionWidth > 0 {
                            trailingAction()
                        }
                    }
                }
                .onAppear {
                    revealActive(using: proxy, animated: false)
                }
                .onChange(of: activeID) { _, _ in
                    revealActive(using: proxy, animated: true)
                }
                .onChange(of: items.map(\.id)) { _, _ in
                    revealActive(using: proxy, animated: false)
                }
                .onChange(of: isOverflowing) { _, newValue in
                    if newValue {
                        revealActive(using: proxy, animated: false)
                    }
                }
            }
        }
        .frame(height: 43)
        .onPreferenceChange(TabStripContentWidthKey.self) { newValue in
            contentWidth = newValue
        }
    }

    private var currentNavigationIndex: Int {
        if
            let visibleItemID,
            let index = items.firstIndex(where: { $0.id == visibleItemID })
        {
            return index
        }
        if let activeID, let index = items.firstIndex(where: { $0.id == activeID }) {
            return index
        }
        return 0
    }

    private func navigationButton(
        systemName: String,
        label: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.chromeText)
                .frame(width: 27, height: 31)
                .background(
                    theme.chromeRaised,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
        .help(label)
        .accessibilityLabel(label)
    }

    private func revealActive(using proxy: ScrollViewProxy, animated: Bool) {
        guard
            let activeID,
            items.contains(where: { $0.id == activeID })
        else {
            if
                let visibleItemID,
                !items.contains(where: { $0.id == visibleItemID })
            {
                self.visibleItemID = items.first?.id
            }
            return
        }
        visibleItemID = activeID
        let scroll = { proxy.scrollTo(activeID, anchor: .center) }
        if animated {
            withAnimation(tabMotionAnimation(reduceMotion: reduceMotion), scroll)
        } else {
            scroll()
        }
    }

    private func scroll(by offset: Int, using proxy: ScrollViewProxy) {
        guard let nextIndex = PDFTabStripLayout.steppedIndex(
            from: currentNavigationIndex,
            offset: offset,
            itemCount: items.count
        ) else { return }
        visibleItemID = items[nextIndex].id
        withAnimation(tabMotionAnimation(reduceMotion: reduceMotion)) {
            proxy.scrollTo(items[nextIndex].id, anchor: .center)
        }
    }
}

private struct PDFTabItem: View {
    @ObservedObject var document: PDFWorkspaceState

    let id: UUID
    let isActive: Bool
    let isDragging: Bool
    let theme: HwattakPDFTheme
    let currentGroup: PDFTabGroup?
    let otherTabs: [PDFTabSession]
    let availableGroups: [PDFTabGroup]
    let availableWorkspaces: [PDFDocumentWorkspace]
    let dropIntent: PDFTabDropIntent?
    let select: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    let closeToRight: () -> Void
    let canCloseToRight: Bool
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let moveLeft: () -> Void
    let moveRight: () -> Void
    let createGroupWith: (UUID) -> Void
    let addToGroup: (UUID) -> Void
    let removeFromGroup: () -> Void
    let renameGroup: () -> Void
    let moveToWorkspace: (UUID) -> Void
    let showResources: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: PDFTabSession,
        isActive: Bool,
        isDragging: Bool,
        theme: HwattakPDFTheme,
        currentGroup: PDFTabGroup?,
        otherTabs: [PDFTabSession],
        availableGroups: [PDFTabGroup],
        availableWorkspaces: [PDFDocumentWorkspace],
        dropIntent: PDFTabDropIntent?,
        select: @escaping () -> Void,
        close: @escaping () -> Void,
        closeOthers: @escaping () -> Void,
        closeToRight: @escaping () -> Void,
        canCloseToRight: Bool,
        canMoveLeft: Bool,
        canMoveRight: Bool,
        moveLeft: @escaping () -> Void,
        moveRight: @escaping () -> Void,
        createGroupWith: @escaping (UUID) -> Void,
        addToGroup: @escaping (UUID) -> Void,
        removeFromGroup: @escaping () -> Void,
        renameGroup: @escaping () -> Void,
        moveToWorkspace: @escaping (UUID) -> Void,
        showResources: @escaping () -> Void
    ) {
        document = session.workspace
        id = session.id
        self.isActive = isActive
        self.isDragging = isDragging
        self.theme = theme
        self.currentGroup = currentGroup
        self.otherTabs = otherTabs
        self.availableGroups = availableGroups
        self.availableWorkspaces = availableWorkspaces
        self.dropIntent = dropIntent
        self.select = select
        self.close = close
        self.closeOthers = closeOthers
        self.closeToRight = closeToRight
        self.canCloseToRight = canCloseToRight
        self.canMoveLeft = canMoveLeft
        self.canMoveRight = canMoveRight
        self.moveLeft = moveLeft
        self.moveRight = moveRight
        self.createGroupWith = createGroupWith
        self.addToGroup = addToGroup
        self.removeFromGroup = removeFromGroup
        self.renameGroup = renameGroup
        self.moveToWorkspace = moveToWorkspace
        self.showResources = showResources
    }

    var body: some View {
        tabSurface
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onTapGesture(perform: select)
            .onHover { isHovering = $0 }
            .help(document.hasOpenDocument ? document.displayName : L10n.string("tab.new"))
            .contextMenu { tabContextMenu }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(document.hasOpenDocument ? document.displayName : L10n.string("tab.new"))
            .accessibilityHint("Return 키로 선택합니다. 탭 가장자리에 놓으면 위치를 바꾸고, 가운데에 놓으면 스택을 만듭니다.")
            .accessibilityAction {
                select()
            }
            .modifier(
                HorizontalMoveAccessibilityModifier(
                    canMoveLeft: canMoveLeft,
                    canMoveRight: canMoveRight,
                    leftLabel: "탭 왼쪽으로 이동",
                    rightLabel: "탭 오른쪽으로 이동",
                    moveLeft: moveLeft,
                    moveRight: moveRight
                )
            )
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .focusable()
            .onKeyPress(.return) {
                select()
                return .handled
            }
            .animation(tabFeedbackAnimation(reduceMotion: reduceMotion), value: isHovering)
            .animation(tabMotionAnimation(reduceMotion: reduceMotion), value: isActive)
            .animation(tabMotionAnimation(reduceMotion: reduceMotion), value: isDragging)
            .animation(tabFeedbackAnimation(reduceMotion: reduceMotion), value: dropIntent)
    }

    private var tabSurface: some View {
        HStack(spacing: 7) {
            Image(systemName: document.hasOpenDocument ? "doc.fill" : "doc.badge.plus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isActive ? theme.brandNavy : theme.chromeSecondaryText)

            Text(document.hasOpenDocument ? document.displayName : L10n.string("tab.new"))
                .font(.system(size: 11, weight: isActive ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 164, alignment: .leading)

            if document.isDirty || document.hasPendingReviewTextDraft {
                Circle()
                    .fill(theme.ribbon)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(
                        L10n.string(
                            "document.unsaved_changes",
                            defaultValue: "저장하지 않은 변경 사항"
                        )
                    )
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(
                        isActive ? theme.brandNavy.opacity(0.09) : theme.chromeRaised,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .help("탭 닫기")
            .opacity(isHovering || isActive ? 1 : 0)
            .accessibilityHidden(!(isHovering || isActive))
        }
        .foregroundStyle(isActive ? theme.brandNavy : theme.chromeText)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: pdfTabWidth, height: 35)
        .background(
            isActive ? theme.paperIvory : (isHovering ? theme.chromeRaised : Color.clear),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(isActive ? theme.border : theme.chromeText.opacity(0.08), lineWidth: 1)
        }
        .overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme.ribbon)
                    .frame(height: 2)
                    .padding(.horizontal, 9)
            }
        }
        .shadow(color: isActive ? Color.black.opacity(0.22) : .clear, radius: 5, y: 2)
        .scaleEffect(isDragging ? 0.985 : 1)
        .opacity(isDragging ? 0.78 : 1)
        .overlay {
            dropIndicator
                .allowsHitTesting(false)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var dropIndicator: some View {
        if let dropIntent {
            switch dropIntent {
            case .createOrJoinGroup:
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.steel.opacity(0.88))
                    .overlay {
                        HStack(spacing: 5) {
                            Image(systemName: "square.stack.3d.up.fill")
                            Text("탭 스택")
                                .lineLimit(1)
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.cream)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(theme.cream.opacity(0.92), lineWidth: 2)
                    }
            case .before:
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.ribbon)
                        .frame(width: 4)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            case .after:
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.ribbon)
                        .frame(width: 4)
                }
                .padding(.vertical, 3)
            }
        }
    }

    @ViewBuilder
    private var tabContextMenu: some View {
        Button("탭 선택", action: select)
        Button("탭 닫기", action: close)
        Divider()
        if let currentGroup {
            Button(
                L10n.format("tab.remove_from_group", currentGroup.title),
                action: removeFromGroup
            )
            Button("스택 이름 변경…", action: renameGroup)
        }
        if !availableGroups.isEmpty {
            Menu("기존 스택에 추가") {
                ForEach(availableGroups) { group in
                    Button(L10n.format("tab.group_count", group.title, group.tabIDs.count)) {
                        addToGroup(group.id)
                    }
                }
            }
        }
        if !otherTabs.isEmpty {
            Menu("다른 탭과 새 스택 만들기") {
                ForEach(otherTabs) { session in
                    Button(session.displayName) {
                        createGroupWith(session.id)
                    }
                }
            }
        }
        if !availableWorkspaces.isEmpty {
            Menu(L10n.string("workspace.move_tab")) {
                ForEach(availableWorkspaces) { item in
                    Button(L10n.format("workspace.menu_item", item.title, item.tabCount)) {
                        moveToWorkspace(item.id)
                    }
                }
            }
        }
        Divider()
        Button("자원 사용 보기", action: showResources)
        Divider()
        Button("탭 왼쪽으로 이동", action: moveLeft)
            .disabled(!canMoveLeft)
        Button("탭 오른쪽으로 이동", action: moveRight)
            .disabled(!canMoveRight)
        Divider()
        Button("다른 탭 닫기", action: closeOthers)
        Button("오른쪽 탭 닫기", action: closeToRight)
            .disabled(!canCloseToRight)
    }
}

private struct PDFTabGroupHeader: View {
    let group: PDFTabGroup
    let sessions: [PDFTabSession]
    let isActive: Bool
    let theme: HwattakPDFTheme
    let dropIntent: PDFTabDropIntent?
    let toggleCollapsed: () -> Void
    let rename: () -> Void
    let addEmptyTab: () -> Void
    let openPDFs: () -> Void
    let dissolve: () -> Void
    let closeAll: () -> Void
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let moveLeft: () -> Void
    let moveRight: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var memberNames: String {
        sessions.map(\.displayName).joined(separator: "\n")
    }

    private var isExpanded: Bool {
        isActive && !group.isCollapsed
    }

    var body: some View {
        Button(action: toggleCollapsed) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isActive ? theme.brandNavy : theme.chromeSecondaryText)

                Text(group.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(group.tabIDs.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.horizontal, 5)
                    .frame(minHeight: 18)
                    .background(
                        isActive ? theme.brandNavy.opacity(0.10) : theme.chrome.opacity(0.54),
                        in: Capsule()
                    )

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .foregroundStyle(isActive ? theme.brandNavy : theme.chromeText)
            .padding(.horizontal, 9)
            .frame(width: pdfTabGroupHeaderWidth, height: 35)
            .background(
                isActive ? theme.paperIvory : (isHovering ? theme.steel.opacity(0.42) : theme.chromeRaised),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(alignment: .bottom) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.ribbon)
                        .frame(height: 2)
                        .padding(.horizontal, 8)
                    }
            }
            .overlay {
                dropIndicator
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(tabFeedbackAnimation(reduceMotion: reduceMotion), value: isHovering)
        .animation(tabMotionAnimation(reduceMotion: reduceMotion), value: isActive)
        .animation(tabMotionAnimation(reduceMotion: reduceMotion), value: isExpanded)
        .animation(tabFeedbackAnimation(reduceMotion: reduceMotion), value: dropIntent)
        .help(L10n.format("tab.group_help", group.title, group.tabIDs.count, memberNames))
        .contextMenu {
            Button(
                L10n.string(isExpanded ? "스택 접기" : "스택 펼치기"),
                action: toggleCollapsed
            )
            Button("스택 이름 변경…", action: rename)
            Divider()
            Button("빈 탭 추가", action: addEmptyTab)
            Button("PDF 추가…", action: openPDFs)
            Divider()
            Button("스택 왼쪽으로 이동", action: moveLeft)
                .disabled(!canMoveLeft)
            Button("스택 오른쪽으로 이동", action: moveRight)
                .disabled(!canMoveRight)
            Divider()
            Button("스택 해제", action: dissolve)
            Button("스택의 모든 탭 닫기", role: .destructive, action: closeAll)
        }
        .accessibilityLabel(L10n.format("tab.group_accessibility", group.title, group.tabIDs.count))
        .accessibilityValue(
            isExpanded ? L10n.string("tab.expanded") : L10n.string("tab.collapsed")
        )
        .accessibilityHint(
            isExpanded
                ? L10n.string("tab.collapse_hint")
                : L10n.string("tab.expand_hint")
        )
        .modifier(
            HorizontalMoveAccessibilityModifier(
                canMoveLeft: canMoveLeft,
                canMoveRight: canMoveRight,
                leftLabel: "스택 왼쪽으로 이동",
                rightLabel: "스택 오른쪽으로 이동",
                moveLeft: moveLeft,
                moveRight: moveRight
            )
        )
    }

    @ViewBuilder
    private var dropIndicator: some View {
        if let dropIntent {
            switch dropIntent {
            case .createOrJoinGroup:
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(theme.steel.opacity(0.88))
                    .overlay {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.badge.plus")
                            Text("탭 스택")
                                .lineLimit(1)
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.cream)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(theme.cream.opacity(0.92), lineWidth: 2)
                    }
            case .before:
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.ribbon)
                        .frame(width: 4)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
            case .after:
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.ribbon)
                        .frame(width: 4)
                }
                .padding(.vertical, 3)
            }
        }
    }
}

private struct HorizontalMoveAccessibilityModifier: ViewModifier {
    let canMoveLeft: Bool
    let canMoveRight: Bool
    let leftLabel: String
    let rightLabel: String
    let moveLeft: () -> Void
    let moveRight: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveLeft && canMoveRight {
            content
                .accessibilityAction(named: Text(L10n.string(leftLabel))) { moveLeft() }
                .accessibilityAction(named: Text(L10n.string(rightLabel))) { moveRight() }
        } else if canMoveLeft {
            content.accessibilityAction(named: Text(L10n.string(leftLabel))) { moveLeft() }
        } else if canMoveRight {
            content.accessibilityAction(named: Text(L10n.string(rightLabel))) { moveRight() }
        } else {
            content
        }
    }
}

private struct TabBarDragCleanupDropDelegate: DropDelegate {
    @Binding var draggedTabID: UUID?
    @Binding var tabDropTargetID: UUID?
    @Binding var tabDropIntent: PDFTabDropIntent?
    @Binding var groupDropTargetID: UUID?
    @Binding var groupDropIntent: PDFTabDropIntent?

    func validateDrop(info: DropInfo) -> Bool {
        draggedTabID != nil
            && info.hasItemsConforming(to: [hwattakPDFTabType.identifier])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        draggedTabID = nil
        tabDropTargetID = nil
        tabDropIntent = nil
        groupDropTargetID = nil
        groupDropIntent = nil
        return true
    }
}

private struct TabReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedTabID: UUID?
    @Binding var dropTargetID: UUID?
    @Binding var dropIntent: PDFTabDropIntent?
    let workspace: MultiDocumentWorkspaceState
    let secondaryGroupID: UUID?
    let isRightToLeft: Bool
    let createGroup: (UUID, UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard
            let sourceID = tabDragSourceID(from: info, localTabID: draggedTabID),
            sourceID != targetID,
            workspace.tabs.contains(where: { $0.id == sourceID })
        else { return false }
        return info.hasItemsConforming(to: [hwattakPDFTabType.identifier])
    }

    func dropEntered(info: DropInfo) {
        updateDropState(info)
    }

    func performDrop(info: DropInfo) -> Bool {
        let intent = resolvedIntent(info)
        let didScheduleLoad = loadTabDragSourceID(from: info) { sourceID in
            guard
                let sourceID,
                sourceID != targetID,
                workspace.tabs.contains(where: { $0.id == sourceID }),
                workspace.tabs.contains(where: { $0.id == targetID })
            else { return }

            let sourceGroupID = workspace.group(containing: sourceID)?.id
            let targetGroupID = workspace.group(containing: targetID)?.id
            switch intent {
            case .before:
                if let secondaryGroupID {
                    _ = workspace.addTab(sourceID, toGroup: secondaryGroupID, before: targetID)
                } else if sourceGroupID == targetGroupID {
                    workspace.moveTab(sourceID, before: targetID)
                } else {
                    workspace.moveTabAsUngrouped(sourceID, before: targetID)
                }
            case .after:
                if let secondaryGroupID {
                    _ = workspace.addTab(sourceID, toGroup: secondaryGroupID, after: targetID)
                } else if sourceGroupID == targetGroupID {
                    workspace.moveTab(sourceID, after: targetID)
                } else {
                    workspace.moveTabAsUngrouped(sourceID, after: targetID)
                }
            case .createOrJoinGroup:
                if let targetGroup = workspace.group(containing: targetID) {
                    _ = workspace.addTab(sourceID, toGroup: targetGroup.id, after: targetID)
                } else {
                    createGroup(sourceID, targetID)
                }
            }
        }
        guard didScheduleLoad else {
            clearDropState()
            return false
        }
        clearDropState()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropState(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard dropTargetID == targetID else { return }
        dropTargetID = nil
        dropIntent = nil
    }

    private func resolvedIntent(_ info: DropInfo) -> PDFTabDropIntent {
        PDFTabDropIntent.resolve(
            locationX: Double(info.location.x),
            width: Double(pdfTabWidth),
            isRightToLeft: isRightToLeft,
            previousIntent: dropTargetID == targetID ? dropIntent : nil
        )
    }

    private func updateDropState(_ info: DropInfo) {
        guard
            let sourceID = tabDragSourceID(from: info, localTabID: draggedTabID),
            sourceID != targetID
        else {
            if dropTargetID == targetID {
                dropTargetID = nil
                dropIntent = nil
            }
            return
        }
        let previousIntent = PDFTabDropState.continuingIntent(
            currentTargetID: dropTargetID,
            newTargetID: targetID,
            currentIntent: dropIntent
        )
        dropTargetID = targetID
        dropIntent = PDFTabDropIntent.resolve(
            locationX: Double(info.location.x),
            width: Double(pdfTabWidth),
            isRightToLeft: isRightToLeft,
            previousIntent: previousIntent
        )
    }

    private func clearDropState() {
        draggedTabID = nil
        dropTargetID = nil
        dropIntent = nil
    }
}

private struct TabIntoGroupDropDelegate: DropDelegate {
    let group: PDFTabGroup
    @Binding var draggedTabID: UUID?
    @Binding var dropTargetID: UUID?
    @Binding var dropIntent: PDFTabDropIntent?
    let workspace: MultiDocumentWorkspaceState
    let isRightToLeft: Bool

    func validateDrop(info: DropInfo) -> Bool {
        guard
            let sourceID = tabDragSourceID(from: info, localTabID: draggedTabID),
            workspace.tabs.contains(where: { $0.id == sourceID })
        else { return false }
        return info.hasItemsConforming(to: [hwattakPDFTabType.identifier])
    }

    func dropEntered(info: DropInfo) {
        updateDropState(info)
    }

    func performDrop(info: DropInfo) -> Bool {
        let intent = resolvedIntent(info)
        let didScheduleLoad = loadTabDragSourceID(from: info) { sourceID in
            guard
                let sourceID,
                workspace.tabs.contains(where: { $0.id == sourceID }),
                let currentGroup = workspace.tabGroups.first(where: { $0.id == group.id })
            else { return }

            switch intent {
            case .before:
                if let firstMemberID = currentGroup.tabIDs.first(where: { $0 != sourceID }) {
                    workspace.moveTabAsUngrouped(sourceID, before: firstMemberID)
                } else {
                    _ = workspace.removeTabFromGroup(sourceID)
                }
            case .after:
                if let lastMemberID = currentGroup.tabIDs.reversed().first(where: { $0 != sourceID }) {
                    workspace.moveTabAsUngrouped(sourceID, after: lastMemberID)
                } else {
                    _ = workspace.removeTabFromGroup(sourceID)
                }
            case .createOrJoinGroup:
                _ = workspace.addTab(sourceID, toGroup: group.id)
            }
        }
        guard didScheduleLoad else {
            clearDropState()
            return false
        }
        clearDropState()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropState(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard dropTargetID == group.id else { return }
        dropTargetID = nil
        dropIntent = nil
    }

    private func resolvedIntent(_ info: DropInfo) -> PDFTabDropIntent {
        PDFTabDropIntent.resolve(
            locationX: Double(info.location.x),
            width: Double(pdfTabGroupHeaderWidth),
            isRightToLeft: isRightToLeft,
            previousIntent: dropTargetID == group.id ? dropIntent : nil
        )
    }

    private func updateDropState(_ info: DropInfo) {
        guard tabDragSourceID(from: info, localTabID: draggedTabID) != nil else {
            if dropTargetID == group.id {
                dropTargetID = nil
                dropIntent = nil
            }
            return
        }
        let previousIntent = PDFTabDropState.continuingIntent(
            currentTargetID: dropTargetID,
            newTargetID: group.id,
            currentIntent: dropIntent
        )
        dropTargetID = group.id
        dropIntent = PDFTabDropIntent.resolve(
            locationX: Double(info.location.x),
            width: Double(pdfTabGroupHeaderWidth),
            isRightToLeft: isRightToLeft,
            previousIntent: previousIntent
        )
    }

    private func clearDropState() {
        draggedTabID = nil
        dropTargetID = nil
        dropIntent = nil
    }
}

private struct GroupTabEndDropDelegate: DropDelegate {
    let groupID: UUID
    @Binding var draggedTabID: UUID?
    let workspace: MultiDocumentWorkspaceState

    func validateDrop(info: DropInfo) -> Bool {
        guard let sourceID = tabDragSourceID(from: info, localTabID: draggedTabID) else {
            return false
        }
        return workspace.tabs.contains(where: { $0.id == sourceID })
    }

    func performDrop(info: DropInfo) -> Bool {
        let didScheduleLoad = loadTabDragSourceID(from: info) { sourceID in
            guard
                let sourceID,
                workspace.tabs.contains(where: { $0.id == sourceID }),
                workspace.tabGroups.contains(where: { $0.id == groupID })
            else { return }
            _ = workspace.addTab(sourceID, toGroup: groupID)
        }
        guard didScheduleLoad else {
            draggedTabID = nil
            return false
        }
        draggedTabID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// The trailing space in the top-level strip is a deliberate "take this tab
/// out of its stack" destination. Provider contents are decoded again at
/// commit time; unrelated plain text can never be mistaken for an open tab.
private struct UngroupTabAtEndDropDelegate: DropDelegate {
    @Binding var draggedTabID: UUID?
    let workspace: MultiDocumentWorkspaceState

    func validateDrop(info: DropInfo) -> Bool {
        guard
            let sourceID = tabDragSourceID(from: info, localTabID: draggedTabID),
            workspace.tabs.contains(where: { $0.id == sourceID })
        else { return false }
        return info.hasItemsConforming(to: [hwattakPDFTabType.identifier])
    }

    func performDrop(info: DropInfo) -> Bool {
        let didScheduleLoad = loadTabDragSourceID(from: info) { sourceID in
            guard
                let sourceID,
                workspace.tabs.contains(where: { $0.id == sourceID })
            else { return }
            workspace.moveTabToEnd(sourceID)
            workspace.selectTab(sourceID)
        }
        draggedTabID = nil
        return didScheduleLoad
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

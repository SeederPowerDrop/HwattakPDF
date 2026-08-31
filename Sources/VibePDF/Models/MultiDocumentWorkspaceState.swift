// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

private enum PreparedPDFBatchOpen {
    case existing(URL)
    case inspected(PDFLazyDocumentDescriptor)
    case failed(URL)
}

/// 탭 ID와 그 탭이 소유한 단일 문서 모델을 묶는다.
@MainActor
struct PDFTabSession: Identifiable {
    let id: UUID
    let workspace: PDFWorkspaceState

    init(id: UUID = UUID(), workspace: PDFWorkspaceState) {
        self.id = id
        self.workspace = workspace
    }

    init(id: UUID = UUID()) {
        self.init(id: id, workspace: PDFWorkspaceState())
    }

    var displayName: String {
        workspace.hasOpenDocument ? workspace.displayName : L10n.string("tab.new")
    }

    var isDirty: Bool {
        workspace.isDirty
    }
}

/// 앱 창 하나에서 여러 PDF 탭·탭 스택·명명된 워크스페이스를 조정한다.
///
/// 이 클래스는 PDF 내용을 직접 편집하지 않는다. 활성 탭을 projection으로
/// 노출하고 각 `PDFWorkspaceState`의 변경 알림을 다시 전달한다. 비활성 clean
/// 문서는 메모리 정책에 따라 휴면시키고, 전환 시 필요한 문서만 재개한다.
/// 배열과 active ID는 항상 함께 정규화되어야 하므로 외부 setter를 제공하지 않는다.
@MainActor
final class MultiDocumentWorkspaceState: ObservableObject {
    /// The three properties below remain the active workspace projection for
    /// source compatibility with the original single-workspace model.
    /// 현재 선택된 명명 workspace의 탭 projection이다.
    @Published private(set) var tabs: [PDFTabSession] {
        didSet {
            synchronizeActiveWorkspaceRecord()
            scheduleSessionPersistence()
        }
    }
    /// 탭을 떠나기 전에는 AcroForm field editor를 먼저 commit하고, 새 탭은
    /// 필요하면 PDFDocument를 resume한다. 이 순서가 입력 유실을 막는다.
    @Published private(set) var activeTabID: UUID? {
        willSet {
            guard
                !isLoadingWorkspace,
                newValue != activeTabID,
                let activeTabID,
                let outgoing = tabs.first(where: { $0.id == activeTabID })
            else { return }
            outgoing.workspace.prepareForDeactivation()
        }
        didSet {
            synchronizeActiveWorkspaceRecord()
            if
                activeTabID != oldValue,
                !isLoadingWorkspace,
                !isResolvingLazyTabActivation
            {
                resolveLazyActiveTabIfNeeded(previousTabID: oldValue)
            }
            scheduleSessionPersistence()
        }
    }
    @Published private(set) var tabGroups: [PDFTabGroup] {
        didSet {
            synchronizeActiveWorkspaceRecord()
            scheduleSessionPersistence()
        }
    }
    @Published private(set) var workspaces: [PDFDocumentWorkspace] {
        didSet { scheduleSessionPersistence() }
    }
    @Published private(set) var activeWorkspaceID: UUID {
        didSet { scheduleSessionPersistence() }
    }

    let recentDocumentsStore: RecentDocumentsStore?
    private let sessionStore: WorkspaceSessionStore?
    private let lazyDocumentInspector: any PDFLazyDocumentInspecting
    private var workspaceObservers: [UUID: AnyCancellable] = [:]
    private var recentDocumentsObserver: AnyCancellable?
    private var isLoadingWorkspace = false
    private var sessionPersistenceTask: Task<Void, Never>?
    private var isSessionPersistenceSuspended = false
    private var pendingBatchOpenTask: Task<[UUID], Never>?
    private var pendingBatchOpenRequestID: UUID?
    /// Encrypted batch items are represented by the same lightweight URL/page
    /// descriptor as ordinary lazy tabs. Keeping only this tab-to-URL marker
    /// lets us postpone both the password prompt and the Recent Documents
    /// mutation until the person actually activates and unlocks that tab.
    /// Passwords are never retained here.
    private var deferredEncryptedDocumentURLs: [UUID: URL] = [:]
    private var isInstallingPreparedPDFBatch = false
    private var isResolvingLazyTabActivation = false

    init(
        initialSession: PDFTabSession,
        recentDocumentsStore: RecentDocumentsStore? = nil,
        initialWorkspaceTitle: String? = nil,
        sessionStore: WorkspaceSessionStore? = nil,
        lazyDocumentInspector: any PDFLazyDocumentInspecting = CoreGraphicsPDFLazyDocumentInspector()
    ) {
        let workspaceID = UUID()
        self.recentDocumentsStore = recentDocumentsStore
        self.sessionStore = sessionStore
        self.lazyDocumentInspector = lazyDocumentInspector
        tabs = [initialSession]
        activeTabID = initialSession.id
        tabGroups = []
        activeWorkspaceID = workspaceID
        workspaces = [
            PDFDocumentWorkspace(
                id: workspaceID,
                title: initialWorkspaceTitle ?? PDFDocumentWorkspaceRules.defaultTitle(at: 0),
                tabs: [initialSession],
                activeTabID: initialSession.id
            )
        ]
        observe(initialSession)
        observeRecentDocuments()
    }

    private init(
        restoredSession: RestoredWorkspaceSession,
        recentDocumentsStore: RecentDocumentsStore?,
        sessionStore: WorkspaceSessionStore,
        lazyDocumentInspector: any PDFLazyDocumentInspecting
    ) {
        let activeDescriptor = restoredSession.workspaces.first {
            $0.id == restoredSession.activeWorkspaceID
        } ?? restoredSession.workspaces[0]
        self.recentDocumentsStore = recentDocumentsStore
        self.sessionStore = sessionStore
        self.lazyDocumentInspector = lazyDocumentInspector
        tabs = activeDescriptor.tabs
        activeTabID = activeDescriptor.activeTabID
        tabGroups = activeDescriptor.tabGroups
        activeWorkspaceID = activeDescriptor.id
        workspaces = restoredSession.workspaces

        restoredSession.workspaces.flatMap(\.tabs).forEach(observe)
        observeRecentDocuments()
        normalizeTabOrganization()
        synchronizeActiveWorkspaceRecord()
        _ = activeSession?.workspace.resumeIfNeeded()
    }

    private init(
        restoredWorkspaces: [PDFDocumentWorkspace],
        activeWorkspaceID requestedActiveWorkspaceID: UUID?,
        recentDocumentsStore: RecentDocumentsStore?,
        lazyDocumentInspector: any PDFLazyDocumentInspecting
    ) {
        precondition(!restoredWorkspaces.isEmpty)
        let activeDescriptor = requestedActiveWorkspaceID.flatMap { requested in
            restoredWorkspaces.first { $0.id == requested }
        } ?? restoredWorkspaces[0]
        self.recentDocumentsStore = recentDocumentsStore
        sessionStore = nil
        self.lazyDocumentInspector = lazyDocumentInspector
        tabs = activeDescriptor.tabs
        activeTabID = activeDescriptor.activeTabID
        tabGroups = activeDescriptor.tabGroups
        activeWorkspaceID = activeDescriptor.id
        workspaces = restoredWorkspaces

        restoredWorkspaces.flatMap(\.tabs).forEach(observe)
        observeRecentDocuments()
        normalizeTabOrganization()
        synchronizeActiveWorkspaceRecord()
        _ = activeSession?.workspace.resumeIfNeeded()
    }

    convenience init(
        initialWorkspace: PDFWorkspaceState,
        recentDocumentsStore: RecentDocumentsStore? = nil,
        initialWorkspaceTitle: String? = nil,
        sessionStore: WorkspaceSessionStore? = nil,
        lazyDocumentInspector: any PDFLazyDocumentInspecting = CoreGraphicsPDFLazyDocumentInspector()
    ) {
        self.init(
            initialSession: PDFTabSession(workspace: initialWorkspace),
            recentDocumentsStore: recentDocumentsStore,
            initialWorkspaceTitle: initialWorkspaceTitle,
            sessionStore: sessionStore,
            lazyDocumentInspector: lazyDocumentInspector
        )
    }

    convenience init(
        recentDocumentsStore: RecentDocumentsStore? = nil,
        sessionStore: WorkspaceSessionStore? = nil,
        lazyDocumentInspector: any PDFLazyDocumentInspecting = CoreGraphicsPDFLazyDocumentInspector()
    ) {
        if
            let sessionStore,
            let restoredSession = sessionStore.restore(),
            !restoredSession.workspaces.isEmpty
        {
            self.init(
                restoredSession: restoredSession,
                recentDocumentsStore: recentDocumentsStore,
                sessionStore: sessionStore,
                lazyDocumentInspector: lazyDocumentInspector
            )
            return
        }
        self.init(
            initialWorkspace: PDFWorkspaceState(),
            recentDocumentsStore: recentDocumentsStore,
            sessionStore: sessionStore,
            lazyDocumentInspector: lazyDocumentInspector
        )
    }

    /// Immediately commits lightweight reopen state. PDF bytes are never
    /// serialized here; dirty documents remain governed by save confirmation.
    @discardableResult
    func flushSessionPersistence(
        including additionalWindowWorkspaces: [MultiDocumentWorkspaceState] = []
    ) -> Bool {
        sessionPersistenceTask?.cancel()
        sessionPersistenceTask = nil
        guard let sessionStore else { return true }
        synchronizeActiveWorkspaceRecord()
        additionalWindowWorkspaces.forEach { $0.synchronizeActiveWorkspaceRecord() }
        return sessionStore.save(self, appending: additionalWindowWorkspaces)
    }

    /// Prevent teardown notifications from replacing the final open-document
    /// archive with reset placeholder tabs after a close has been accepted.
    func freezeSessionPersistenceAfterFlushing(
        including additionalWindowWorkspaces: [MultiDocumentWorkspaceState] = []
    ) {
        if isSessionPersistenceSuspended {
            guard let sessionStore else { return }
            additionalWindowWorkspaces.forEach { $0.synchronizeActiveWorkspaceRecord() }
            _ = sessionStore.mergeDetachedWindowWorkspaces(
                additionalWindowWorkspaces
            )
            return
        }
        _ = flushSessionPersistence(including: additionalWindowWorkspaces)
        isSessionPersistenceSuspended = true
        sessionPersistenceTask?.cancel()
        sessionPersistenceTask = nil
    }

    func resumeSessionPersistence(
        restoringWorkspaceIDs requestedWorkspaceIDs: Set<UUID>? = nil
    ) {
        guard isSessionPersistenceSuspended else { return }
        if
            let sessionStore,
            var restoredSession = sessionStore.restore(),
            !restoredSession.workspaces.isEmpty
        {
            if let requestedWorkspaceIDs {
                let requestedWorkspaces = restoredSession.workspaces.filter {
                    requestedWorkspaceIDs.contains($0.id)
                }
                if !requestedWorkspaces.isEmpty {
                    restoredSession.workspaces = requestedWorkspaces
                    if !requestedWorkspaces.contains(where: {
                        $0.id == restoredSession.activeWorkspaceID
                    }) {
                        restoredSession.activeWorkspaceID = requestedWorkspaces[0].id
                    }
                }
            }
            installRestoredSession(restoredSession)
        }
        isSessionPersistenceSuspended = false
        scheduleSessionPersistence()
    }

    /// Rebuilds persisted WindowGroup membership without reopening or copying
    /// any PDF. Session objects move into exactly one window model, preserving
    /// lazy/hibernated state and avoiding duplicate security-scope ownership.
    func partitionRestoredDetachedWindows(
        using topology: WorkspaceSessionArchive.WindowTopologyRecord
    ) -> [WorkspaceSessionDetachedWindowSnapshot] {
        synchronizeActiveWorkspaceRecord()
        let originalWorkspaces = workspaces
        let descriptorsByID = Dictionary(
            uniqueKeysWithValues: originalWorkspaces.map { ($0.id, $0) }
        )
        var assignedWorkspaceIDs: Set<UUID> = []
        var mainDescriptors: [PDFDocumentWorkspace] = topology.mainWorkspaceIDs
            .compactMap { workspaceID in
                guard assignedWorkspaceIDs.insert(workspaceID).inserted else { return nil }
                return descriptorsByID[workspaceID]
            }
        var detachedDescriptors: [(
            record: WorkspaceSessionArchive.WindowTopologyRecord.DetachedWindowRecord,
            workspaces: [PDFDocumentWorkspace]
        )] = []
        for window in topology.detachedWindows {
            let descriptors: [PDFDocumentWorkspace] = window.workspaceIDs.compactMap {
                workspaceID -> PDFDocumentWorkspace? in
                guard assignedWorkspaceIDs.insert(workspaceID).inserted else { return nil }
                return descriptorsByID[workspaceID]
            }
            if !descriptors.isEmpty {
                detachedDescriptors.append((window, descriptors))
            }
        }
        // Incomplete metadata must never strand an otherwise valid restored
        // workspace. Unknown/unassigned records safely remain in main.
        originalWorkspaces.forEach { descriptor in
            if assignedWorkspaceIDs.insert(descriptor.id).inserted {
                mainDescriptors.append(descriptor)
            }
        }

        let priorActiveWorkspaceID = activeWorkspaceID
        activeSession?.workspace.prepareForDeactivation()
        workspaceObservers.removeAll()
        sessionPersistenceTask?.cancel()
        sessionPersistenceTask = nil

        if mainDescriptors.isEmpty {
            let placeholder = PDFTabSession()
            mainDescriptors = [
                PDFDocumentWorkspace(
                    title: PDFDocumentWorkspaceRules.defaultTitle(at: 0),
                    tabs: [placeholder],
                    activeTabID: placeholder.id
                )
            ]
        }
        let mainActiveDescriptor = mainDescriptors.first {
            $0.id == priorActiveWorkspaceID
        } ?? mainDescriptors[0]
        isLoadingWorkspace = true
        workspaces = mainDescriptors
        activeWorkspaceID = mainActiveDescriptor.id
        tabs = mainActiveDescriptor.tabs
        activeTabID = mainActiveDescriptor.activeTabID
        tabGroups = mainActiveDescriptor.tabGroups
        isLoadingWorkspace = false
        mainDescriptors.flatMap(\.tabs).forEach(observe)
        normalizeTabOrganization()
        synchronizeActiveWorkspaceRecord()
        _ = activeSession?.workspace.resumeIfNeeded()

        return detachedDescriptors.map { item in
            WorkspaceSessionDetachedWindowSnapshot(
                windowID: item.record.windowID,
                workspace: MultiDocumentWorkspaceState(
                    restoredWorkspaces: item.workspaces,
                    activeWorkspaceID: item.record.activeWorkspaceID,
                    recentDocumentsStore: recentDocumentsStore,
                    lazyDocumentInspector: lazyDocumentInspector
                )
            )
        }
    }

    private func installRestoredSession(_ restoredSession: RestoredWorkspaceSession) {
        let activeDescriptor = restoredSession.workspaces.first {
            $0.id == restoredSession.activeWorkspaceID
        } ?? restoredSession.workspaces[0]
        sessionForActiveTab()?.workspace.prepareForDeactivation()
        workspaceObservers.removeAll()
        isLoadingWorkspace = true
        workspaces = restoredSession.workspaces
        activeWorkspaceID = activeDescriptor.id
        tabs = activeDescriptor.tabs
        activeTabID = activeDescriptor.activeTabID
        tabGroups = activeDescriptor.tabGroups
        isLoadingWorkspace = false
        restoredSession.workspaces.flatMap(\.tabs).forEach(observe)
        normalizeTabOrganization()
        synchronizeActiveWorkspaceRecord()
        _ = activeSession?.workspace.resumeIfNeeded()
    }

    var activeSession: PDFTabSession? {
        guard let activeTabID else { return tabs.first }
        return tabs.first(where: { $0.id == activeTabID }) ?? tabs.first
    }

    var activeWorkspace: PDFWorkspaceState? {
        activeSession?.workspace
    }

    var activeWorkspaceDescriptor: PDFDocumentWorkspace? {
        workspaces.first { $0.id == activeWorkspaceID }
    }

    /// Includes hidden workspace tabs. Use this for app termination guards,
    /// resource accounting, and operations that must not lose hidden edits.
    var allTabs: [PDFTabSession] {
        workspaces.flatMap(\.tabs)
    }

    var documentSessions: [PDFTabSession] {
        tabs.filter { $0.workspace.hasOpenDocument }
    }

    var recentDocuments: [RecentDocument] {
        recentDocumentsStore?.documents ?? []
    }

    var ungroupedTabs: [PDFTabSession] {
        let groupedIDs = Set(tabGroups.flatMap(\.tabIDs))
        return tabs.filter { !groupedIDs.contains($0.id) }
    }

    var orderedTabBarEntries: [PDFTabBarEntry] {
        let groupByTabID = Dictionary(
            uniqueKeysWithValues: tabGroups.flatMap { group in
                group.tabIDs.map { ($0, group) }
            }
        )
        var emittedGroupIDs: Set<UUID> = []
        return tabs.compactMap { session in
            guard let group = groupByTabID[session.id] else {
                return .tab(session.id)
            }
            guard emittedGroupIDs.insert(group.id).inserted else { return nil }
            return .group(group)
        }
    }

    func sessions(inWorkspace workspaceID: UUID) -> [PDFTabSession] {
        workspaces.first(where: { $0.id == workspaceID })?.tabs ?? []
    }

    func workspace(containingTab tabID: UUID) -> PDFDocumentWorkspace? {
        workspaces.first { workspace in
            workspace.tabs.contains { $0.id == tabID }
        }
    }

    @discardableResult
    func createWorkspace(title: String? = nil, activate: Bool = true) -> UUID {
        synchronizeActiveWorkspaceRecord()

        let session = PDFTabSession()
        let index = workspaces.count
        let fallbackTitle = PDFDocumentWorkspaceRules.defaultTitle(at: index)
        let workspace = PDFDocumentWorkspace(
            title: PDFDocumentWorkspaceRules.normalizedTitle(
                title ?? fallbackTitle,
                fallback: fallbackTitle
            ),
            tabs: [session],
            activeTabID: session.id
        )
        observe(session)
        workspaces.append(workspace)

        if activate {
            loadWorkspace(workspace)
        }
        return workspace.id
    }

    @discardableResult
    func renameWorkspace(_ workspaceID: UUID, to title: String) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return false
        }
        let fallbackTitle = PDFDocumentWorkspaceRules.defaultTitle(at: index)
        workspaces[index].title = PDFDocumentWorkspaceRules.normalizedTitle(
            title,
            fallback: fallbackTitle
        )
        return true
    }

    @discardableResult
    func selectWorkspace(_ workspaceID: UUID) -> Bool {
        guard workspaceID != activeWorkspaceID else { return true }
        synchronizeActiveWorkspaceRecord()
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else {
            return false
        }
        loadWorkspace(workspace)
        return true
    }

    /// Removes a workspace and closes its document sessions. Unsaved sessions
    /// are rejected unless the caller already confirmed a discard/save flow.
    /// The final workspace can never be deleted.
    @discardableResult
    func deleteWorkspace(_ workspaceID: UUID, discardingChanges: Bool = false) -> Bool {
        guard workspaces.count > 1 else { return false }
        synchronizeActiveWorkspaceRecord()
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return false
        }

        let removedWorkspace = workspaces[index]
        if workspaceID == activeWorkspaceID {
            activeSession?.workspace.prepareForDeactivation()
        }
        removedWorkspace.tabs.forEach { $0.workspace.synchronizeWidgetValues() }
        guard discardingChanges || !removedWorkspace.hasUnsavedChanges else { return false }

        removedWorkspace.tabs.forEach { session in
            session.workspace.closeDiscardingChanges()
            workspaceObservers[session.id] = nil
            deferredEncryptedDocumentURLs[session.id] = nil
        }

        let wasActive = workspaceID == activeWorkspaceID
        isLoadingWorkspace = true
        workspaces.remove(at: index)
        isLoadingWorkspace = false

        if wasActive {
            let nextIndex = min(index, workspaces.count - 1)
            loadWorkspace(workspaces[nextIndex])
        }
        return true
    }

    /// Moves an open document session without recreating it. Group membership
    /// is intentionally workspace-local and is removed at the boundary.
    @discardableResult
    func moveTab(_ tabID: UUID, toWorkspace destinationWorkspaceID: UUID) -> Bool {
        synchronizeActiveWorkspaceRecord()
        guard
            let sourceIndex = workspaces.firstIndex(where: {
                $0.tabs.contains { $0.id == tabID }
            }),
            let destinationIndex = workspaces.firstIndex(where: {
                $0.id == destinationWorkspaceID
            }),
            sourceIndex != destinationIndex,
            let sessionIndex = workspaces[sourceIndex].tabs.firstIndex(where: {
                $0.id == tabID
            })
        else {
            return false
        }

        if
            workspaces[sourceIndex].id == activeWorkspaceID,
            activeTabID == tabID
        {
            sessionForActiveTab()?.workspace.prepareForDeactivation()
        }

        isLoadingWorkspace = true
        let removedIndex = sessionIndex
        let session = workspaces[sourceIndex].tabs.remove(at: sessionIndex)
        workspaces[sourceIndex].tabGroups = PDFTabGroupRules.normalizedGroups(
            workspaces[sourceIndex].tabGroups,
            validTabIDs: workspaces[sourceIndex].tabs.map(\.id)
        )

        if workspaces[sourceIndex].tabs.isEmpty {
            let replacement = PDFTabSession()
            observe(replacement)
            workspaces[sourceIndex].tabs = [replacement]
            workspaces[sourceIndex].activeTabID = replacement.id
        } else if workspaces[sourceIndex].activeTabID == tabID {
            let nextIndex = min(removedIndex, workspaces[sourceIndex].tabs.count - 1)
            workspaces[sourceIndex].activeTabID = workspaces[sourceIndex].tabs[nextIndex].id
        }

        // A workspace is born with one pristine placeholder to preserve its
        // active-tab invariant. Moving a real session in consumes that
        // placeholder, just like opening a PDF in the welcome tab does.
        if let placeholderIndex = workspaces[destinationIndex].tabs.firstIndex(
            where: canReuseForOpening
        ) {
            let placeholder = workspaces[destinationIndex].tabs.remove(at: placeholderIndex)
            workspaceObservers[placeholder.id] = nil
            workspaces[destinationIndex].tabGroups = PDFTabGroupRules.normalizedGroups(
                workspaces[destinationIndex].tabGroups,
                validTabIDs: workspaces[destinationIndex].tabs.map(\.id)
            )
        }
        workspaces[destinationIndex].tabs.append(session)
        workspaces[destinationIndex].activeTabID = session.id
        let activeRecord = workspaces.first { $0.id == activeWorkspaceID }
        isLoadingWorkspace = false

        if let activeRecord {
            loadWorkspace(activeRecord)
        }
        return true
    }

    func group(containing tabID: UUID) -> PDFTabGroup? {
        tabGroups.first { $0.tabIDs.contains(tabID) }
    }

    func sessions(in group: PDFTabGroup) -> [PDFTabSession] {
        sessions(inGroup: group.id)
    }

    func sessions(inGroup groupID: UUID) -> [PDFTabSession] {
        guard let group = tabGroups.first(where: { $0.id == groupID }) else { return [] }
        let sessionByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        return group.tabIDs.compactMap { sessionByID[$0] }
    }

    @discardableResult
    func newTab(inGroup groupID: UUID? = nil) -> UUID {
        let session = PDFTabSession()
        tabs.append(session)
        observe(session)
        activeTabID = session.id
        if let groupID {
            _ = addTab(session.id, toGroup: groupID)
        } else {
            normalizeTabOrganization()
        }
        return session.id
    }

    @discardableResult
    func addTab(opening url: URL, inGroup groupID: UUID? = nil) -> UUID? {
        openPDFsInTabs(urls: [url], inGroup: groupID).first
    }

    /// Opens every unique URL in an independent tab. The batch is inspected
    /// with Core Graphics first, then installed as lightweight hibernated tab
    /// descriptors. Only the final successful tab constructs a PDFDocument.
    /// This bounds the PDFKit working-set peak even when Finder supplies dozens
    /// of 50–200 MB files in one synchronous callback.
    @discardableResult
    func openPDFsInTabs(urls: [URL], inGroup groupID: UUID? = nil) -> [UUID] {
        // A password sheet can run a nested AppKit event loop. Refuse a
        // synchronous re-entrant installation rather than letting it intermix
        // two tab snapshots; UI-owned requests use the async path below and
        // wait for the superseded batch to roll back first.
        guard !urls.isEmpty, !isInstallingPreparedPDFBatch else { return [] }
        cancelPendingBatchOpen()
        let prepared = uniquePDFURLs(urls).map { url -> PreparedPDFBatchOpen in
            if session(opening: url) != nil {
                return .existing(url)
            }
            do {
                return .inspected(try lazyDocumentInspector.inspect(url))
            } catch {
                return .failed(url)
            }
        }
        return installPreparedPDFBatch(prepared, inGroup: groupID)
    }

    /// Asynchronously prepares a multi-file selection without blocking AppKit.
    /// Existing tabs are not re-read; new files are inspected with bounded
    /// concurrency and installed together on the main actor in request order.
    @discardableResult
    func openPDFsInTabsAsync(
        urls: [URL],
        inGroup groupID: UUID? = nil,
        maximumInspectionConcurrency: Int = PDFLazyDocumentBatchInspector.defaultMaximumConcurrency
    ) async -> [UUID] {
        let targetWorkspaceID = activeWorkspaceID
        let uniqueURLs = uniquePDFURLs(urls)
        guard !uniqueURLs.isEmpty, !Task.isCancelled else { return [] }

        // Establish access before leaving the item-provider/open-panel callback
        // and retain it until every lazy workspace owns its own scope.
        let batchAccesses = uniqueURLs.map { SecurityScopedAccess(url: $0) }
        var prepared = Array<PreparedPDFBatchOpen?>(repeating: nil, count: uniqueURLs.count)
        var inspectionURLs: [URL] = []
        var inspectionSlots: [Int] = []

        for (index, url) in uniqueURLs.enumerated() {
            if session(opening: url) != nil {
                prepared[index] = .existing(url)
            } else {
                inspectionURLs.append(url)
                inspectionSlots.append(index)
            }
        }

        let outcomes = await PDFLazyDocumentBatchInspector(
            inspector: lazyDocumentInspector,
            maximumConcurrency: maximumInspectionConcurrency
        ).inspect(inspectionURLs)
        guard
            !Task.isCancelled,
            activeWorkspaceID == targetWorkspaceID
        else { return [] }

        // Password prompts are synchronous but AppKit may dispatch another
        // open request from their nested event loop. Serialize only the short
        // main-actor installation phase. A replacement request has already
        // cancelled the older task, whose rollback completes before this task
        // enters `installPreparedPDFBatch`.
        while isInstallingPreparedPDFBatch {
            await Task.yield()
            guard
                !Task.isCancelled,
                activeWorkspaceID == targetWorkspaceID
            else { return [] }
        }

        for (offset, slot) in inspectionSlots.enumerated() {
            let url = uniqueURLs[slot]
            let descriptor = outcomes.indices.contains(offset)
                ? outcomes[offset].descriptor
                : nil
            prepared[slot] = descriptor.map(PreparedPDFBatchOpen.inspected) ?? .failed(url)
        }

        return withExtendedLifetime(batchAccesses) {
            installPreparedPDFBatch(prepared.compactMap { $0 }, inGroup: groupID)
        }
    }

    /// Starts a UI-owned batch. A newer request supersedes the previous one;
    /// `cancelPendingBatchOpen()` is also called when the hosting view leaves
    /// the hierarchy, so a late inspection can never mutate a dead window.
    @discardableResult
    func beginOpeningPDFsInTabs(
        urls: [URL],
        inGroup groupID: UUID? = nil,
        completion: (([UUID]) -> Void)? = nil
    ) -> Task<[UUID], Never> {
        guard !urls.isEmpty else {
            return Task { [] }
        }
        cancelPendingBatchOpen()
        // Start access synchronously while NSOpenPanel/NSItemProvider still
        // owns the original sandbox extension. The async method establishes
        // each workspace's independent long-lived scope before this capture is
        // released.
        let requestAccesses = urls.map { SecurityScopedAccess(url: $0) }
        let requestID = UUID()
        pendingBatchOpenRequestID = requestID
        let task = Task { @MainActor [weak self] () -> [UUID] in
            defer { withExtendedLifetime(requestAccesses) {} }
            guard let self else { return [] }
            let openedIDs = await self.openPDFsInTabsAsync(
                urls: urls,
                inGroup: groupID
            )
            guard
                !Task.isCancelled,
                self.pendingBatchOpenRequestID == requestID
            else { return [] }
            self.pendingBatchOpenTask = nil
            self.pendingBatchOpenRequestID = nil
            completion?(openedIDs)
            return openedIDs
        }
        pendingBatchOpenTask = task
        return task
    }

    func cancelPendingBatchOpen() {
        pendingBatchOpenTask?.cancel()
        pendingBatchOpenTask = nil
        pendingBatchOpenRequestID = nil
    }

    var hasPendingBatchOpen: Bool {
        pendingBatchOpenTask != nil
    }

    private func installPreparedPDFBatch(
        _ prepared: [PreparedPDFBatchOpen],
        inGroup groupID: UUID?
    ) -> [UUID] {
        guard !prepared.isEmpty else { return [] }
        let originalTabs = tabs
        let originalActiveTabID = activeTabID
        let originalTabGroups = tabGroups
        let originalDeferredURLs = deferredEncryptedDocumentURLs
        let originalTabIDs = Set(originalTabs.map(\.id))
        var mutatedReusableOriginalTabIDs: Set<UUID> = []
        var openedIDs: [UUID] = []
        var openedDocuments: [(id: UUID, url: URL, requiresSuccessfulActivation: Bool)] = []
        var failedNames: [String] = []
        isInstallingPreparedPDFBatch = true
        defer { isInstallingPreparedPDFBatch = false }

        for item in prepared {
            guard !Task.isCancelled else {
                rollbackPreparedPDFBatch(
                    to: originalTabs,
                    activeTabID: originalActiveTabID,
                    tabGroups: originalTabGroups,
                    deferredEncryptedURLs: originalDeferredURLs,
                    reusableOriginalTabIDs: mutatedReusableOriginalTabIDs
                )
                return []
            }
            let url: URL
            let targetSession: PDFTabSession
            let requiresSuccessfulActivation: Bool
            switch item {
            case let .failed(failedURL):
                failedNames.append(failedURL.lastPathComponent)
                continue
            case let .existing(existingURL):
                url = existingURL
                guard let existing = session(opening: existingURL) else {
                    failedNames.append(existingURL.lastPathComponent)
                    continue
                }
                targetSession = existing
                // A restored lazy tab has not yet proved that its source can
                // be reopened (and may be password protected).
                requiresSuccessfulActivation = existing.workspace.isHibernated
            case let .inspected(descriptor):
                url = descriptor.url
                if let existing = session(opening: descriptor.url) {
                    // Another request may have installed this file while the
                    // metadata task was suspended. Reuse it instead of racing
                    // a duplicate tab into the workspace.
                    targetSession = existing
                    requiresSuccessfulActivation = descriptor.isEncrypted
                        || existing.workspace.isHibernated
                    break
                }
                if let reusable = reusableEmptySession() {
                    if originalTabIDs.contains(reusable.id) {
                        mutatedReusableOriginalTabIDs.insert(reusable.id)
                    }
                    reusable.workspace.restoreHibernated(
                        url: descriptor.url,
                        pageCount: descriptor.pageCount
                    )
                    targetSession = reusable
                } else {
                    let candidate = PDFWorkspaceState()
                    candidate.restoreHibernated(
                        url: descriptor.url,
                        pageCount: descriptor.pageCount
                    )
                    let created = PDFTabSession(workspace: candidate)
                    tabs.append(created)
                    observe(created)
                    targetSession = created
                }
                if descriptor.isEncrypted {
                    deferredEncryptedDocumentURLs[targetSession.id] = descriptor.url
                }
                requiresSuccessfulActivation = descriptor.isEncrypted
            }

            openedIDs.append(targetSession.id)
            openedDocuments.append(
                (targetSession.id, url, requiresSuccessfulActivation)
            )
            if let groupID {
                _ = addTab(targetSession.id, toGroup: groupID)
            }
        }

        if groupID == nil {
            normalizeTabOrganization()
        }

        if
            let finalID = openedIDs.last,
            tabs.contains(where: { $0.id == finalID })
        {
            if activeTabID != finalID {
                activeTabID = finalID
            } else {
                // Reusing the welcome tab does not change its ID, so the
                // activeTabID observer cannot perform this first lazy resume.
                resolveLazyActiveTabIfNeeded(previousTabID: originalActiveTabID)
            }
        }

        // The password provider is synchronous and may re-enter the app (for
        // example a newer open request can supersede this one while the sheet
        // is up). Respect cancellation after that boundary as well as before
        // installation, and restore the exact pre-batch tab projection.
        guard !Task.isCancelled else {
            rollbackPreparedPDFBatch(
                to: originalTabs,
                activeTabID: originalActiveTabID,
                tabGroups: originalTabGroups,
                deferredEncryptedURLs: originalDeferredURLs,
                reusableOriginalTabIDs: mutatedReusableOriginalTabIDs
            )
            return []
        }

        let installedIDs = Set(tabs.map(\.id))
        openedIDs.removeAll { !installedIDs.contains($0) }
        for openedDocument in openedDocuments where installedIDs.contains(openedDocument.id) {
            let installedSession = tabs.first { $0.id == openedDocument.id }
            guard
                !openedDocument.requiresSuccessfulActivation
                    || installedSession?.workspace.isHibernated == false
            else { continue }
            recordRecentDocument(url: openedDocument.url)
        }

        if !openedIDs.isEmpty {
            enforceLoadedPDFTabBudgetAfterOpening()
        }

        if !failedNames.isEmpty {
            let names = failedNames.map { "‘\($0)’" }.joined(separator: ", ")
            activeWorkspace?.presentedError = L10n.format("status.open_failed", names)
        }
        return openedIDs
    }

    /// Materializes only the tab the person actually selected. A nil result
    /// with no presented error is the password-provider's cancellation signal.
    /// A never-unlocked batch tab is removed as a ghost; an established tab
    /// that merely hibernated is preserved and focus returns to a resident tab.
    private func resolveLazyActiveTabIfNeeded(previousTabID: UUID?) {
        guard
            let session = activeSession,
            session.workspace.isHibernated
        else { return }

        let tabID = session.id
        let documentURL = session.workspace.documentURL
        let isFirstDeferredUnlock = deferredEncryptedDocumentURLs[tabID] != nil
        isResolvingLazyTabActivation = true
        defer { isResolvingLazyTabActivation = false }

        if session.workspace.resumeIfNeeded() {
            let deferredURL = deferredEncryptedDocumentURLs.removeValue(forKey: tabID)
            if
                !isInstallingPreparedPDFBatch,
                (deferredURL != nil || session.workspace.document?.isEncrypted == true),
                let openedURL = deferredURL ?? documentURL
            {
                recordRecentDocument(url: openedURL)
            }
            return
        }

        guard session.workspace.presentedError == nil else { return }
        if isFirstDeferredUnlock {
            deferredEncryptedDocumentURLs.removeValue(forKey: tabID)
            removeCancelledLazyTab(tabID, preferring: previousTabID)
        } else {
            restoreFocusAfterCancelledLazyActivation(
                tabID,
                preferring: previousTabID
            )
        }
    }

    /// An encrypted document that was already opened may later hibernate under
    /// the normal clean-tab memory policy. Cancelling its next password prompt
    /// must not destroy the established tab; only move focus back to a resident
    /// surface so another password sheet is not opened recursively.
    private func restoreFocusAfterCancelledLazyActivation(
        _ cancelledTabID: UUID,
        preferring previousTabID: UUID?
    ) {
        let residentFallback = previousTabID.flatMap { requestedID in
            tabs.first {
                $0.id == requestedID
                    && $0.id != cancelledTabID
                    && !$0.workspace.isHibernated
            }
        } ?? tabs.first {
            $0.id != cancelledTabID && !$0.workspace.isHibernated
        }

        if let residentFallback {
            activeTabID = residentFallback.id
        } else {
            let replacement = PDFTabSession()
            tabs.append(replacement)
            observe(replacement)
            activeTabID = replacement.id
        }
        normalizeTabOrganization()
    }

    /// Removes one cancelled lazy activation without recursively activating a
    /// second lazy/password-protected tab. Prefer the previously resident tab;
    /// if every remaining tab is lazy, leave a fresh welcome tab active and
    /// let the person choose the next document deliberately.
    private func removeCancelledLazyTab(_ tabID: UUID, preferring previousTabID: UUID?) {
        guard let removedIndex = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let sourceGroupID = group(containing: tabID)?.id
        let removed = tabs.remove(at: removedIndex)
        removed.workspace.closeDiscardingChanges()
        workspaceObservers[removed.id] = nil
        for groupIndex in tabGroups.indices {
            tabGroups[groupIndex].tabIDs.removeAll { $0 == removed.id }
        }
        dissolveGroupIfSingleton(sourceGroupID)

        let residentFallback = previousTabID.flatMap { requestedID in
            tabs.first { $0.id == requestedID && !$0.workspace.isHibernated }
        } ?? tabs.dropFirst(min(removedIndex, tabs.count)).first {
            !$0.workspace.isHibernated
        } ?? tabs.prefix(min(removedIndex, tabs.count)).reversed().first {
            !$0.workspace.isHibernated
        }

        if let residentFallback {
            activeTabID = residentFallback.id
        } else {
            let replacement = PDFTabSession()
            tabs.append(replacement)
            observe(replacement)
            activeTabID = replacement.id
        }
        normalizeTabOrganization()
    }

    /// A cancelled/replaced async request must not leak a partially installed
    /// tab set. Restore original session identities and reset only placeholders
    /// that this batch temporarily reused.
    private func rollbackPreparedPDFBatch(
        to originalTabs: [PDFTabSession],
        activeTabID originalActiveTabID: UUID?,
        tabGroups originalTabGroups: [PDFTabGroup],
        deferredEncryptedURLs originalDeferredURLs: [UUID: URL],
        reusableOriginalTabIDs: Set<UUID>
    ) {
        let originalIDs = Set(originalTabs.map(\.id))
        for session in tabs where !originalIDs.contains(session.id) {
            session.workspace.closeDiscardingChanges()
            workspaceObservers[session.id] = nil
        }
        for session in originalTabs where reusableOriginalTabIDs.contains(session.id) {
            session.workspace.closeDiscardingChanges()
        }

        isLoadingWorkspace = true
        tabs = originalTabs
        activeTabID = originalActiveTabID
        tabGroups = originalTabGroups
        deferredEncryptedDocumentURLs = originalDeferredURLs
        isLoadingWorkspace = false
        originalTabs.forEach(observe)
        normalizeTabOrganization()
        synchronizeActiveWorkspaceRecord()
    }

    /// Best-effort hook used by every successful open path.
    func recordRecentDocument(url: URL) {
        guard let recentDocumentsStore else { return }
        do {
            try recentDocumentsStore.record(url: url)
        } catch {
            let message = L10n.string("status.recent_record_failed")
            if let existing = activeWorkspace?.presentedError, !existing.isEmpty {
                activeWorkspace?.presentedError = existing + "\n" + message
            } else {
                activeWorkspace?.presentedError = message
            }
        }
    }

    @discardableResult
    func openRecentDocument(id: UUID) -> UUID? {
        guard let recentDocumentsStore else {
            activeWorkspace?.presentedError = L10n.string("error.recent_store_unavailable")
            return nil
        }
        do {
            let access = try recentDocumentsStore.resolve(id: id)
            // Keep the bookmark scope alive until PDFWorkspaceState has opened
            // the URL and retained its own SecurityScopedAccess.
            return withExtendedLifetime(access) {
                openPDFsInTabs(urls: [access.url]).first
            }
        } catch {
            activeWorkspace?.presentedError = error.localizedDescription
            return nil
        }
    }

    func removeRecentDocument(id: UUID) {
        recentDocumentsStore?.remove(id: id)
    }

    func clearRecentDocuments() {
        recentDocumentsStore?.clear()
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
    }

    func selectAdjacentTab(forward: Bool) {
        guard !tabs.isEmpty else { return }
        let currentIndex = activeTabID.flatMap { id in
            tabs.firstIndex(where: { $0.id == id })
        } ?? 0
        let offset = forward ? 1 : -1
        let nextIndex = (currentIndex + offset + tabs.count) % tabs.count
        activeTabID = tabs[nextIndex].id
    }

    @discardableResult
    func createTabGroup(title: String, tabIDs requestedTabIDs: [UUID]) -> UUID? {
        let validIDs = Set(tabs.map(\.id))
        var seen: Set<UUID> = []
        let requested = requestedTabIDs.filter {
            validIDs.contains($0) && seen.insert($0).inserted
        }
        guard !requested.isEmpty else { return nil }

        let requestedSet = Set(requested)
        for index in tabGroups.indices {
            tabGroups[index].tabIDs.removeAll { requestedSet.contains($0) }
        }
        let group = PDFTabGroup(
            title: PDFTabGroupRules.normalizedTitle(title),
            tabIDs: requested
        )
        tabGroups.append(group)
        normalizeTabOrganization()
        return group.id
    }

    @discardableResult
    func renameTabGroup(_ groupID: UUID, to title: String) -> Bool {
        guard let index = tabGroups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }
        tabGroups[index].title = PDFTabGroupRules.normalizedTitle(title)
        normalizeTabOrganization()
        return true
    }

    @discardableResult
    func setTabGroupCollapsed(_ groupID: UUID, isCollapsed: Bool) -> Bool {
        guard let index = tabGroups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }
        tabGroups[index].isCollapsed = isCollapsed
        return true
    }

    @discardableResult
    func toggleTabGroupCollapsed(_ groupID: UUID) -> Bool {
        guard let index = tabGroups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }
        tabGroups[index].isCollapsed.toggle()
        return true
    }

    /// Adds or moves a tab into a group. Passing no target appends it to the
    /// group; passing a member ID inserts it immediately before that member.
    @discardableResult
    func addTab(
        _ tabID: UUID,
        toGroup groupID: UUID,
        before targetTabID: UUID? = nil
    ) -> Bool {
        placeTab(
            tabID,
            inGroup: groupID,
            placement: targetTabID.map(TabPlacement.before) ?? .end
        )
    }

    @discardableResult
    func addTab(_ tabID: UUID, toGroup groupID: UUID, after targetTabID: UUID) -> Bool {
        placeTab(tabID, inGroup: groupID, placement: .after(targetTabID))
    }

    @discardableResult
    func removeTabFromGroup(_ tabID: UUID) -> Bool {
        guard let groupIndex = tabGroups.firstIndex(where: { $0.tabIDs.contains(tabID) }) else {
            return false
        }
        let sourceGroupID = tabGroups[groupIndex].id
        let currentGroupIDs = tabGroups[groupIndex].tabIDs
        let remainingGroupIDs = currentGroupIDs.filter { $0 != tabID }
        replaceFlatTabBlock(
            removing: Set(currentGroupIDs),
            with: remainingGroupIDs + [tabID],
            anchoredAt: firstFlatIndex(ofAny: currentGroupIDs)
        )
        tabGroups[groupIndex].tabIDs = remainingGroupIDs
        dissolveGroupIfSingleton(sourceGroupID)
        normalizeTabOrganization()
        return true
    }

    @discardableResult
    func moveTab(
        _ tabID: UUID,
        withinGroup groupID: UUID,
        before targetTabID: UUID?
    ) -> Bool {
        guard
            let group = tabGroups.first(where: { $0.id == groupID }),
            group.tabIDs.contains(tabID),
            targetTabID.map({ group.tabIDs.contains($0) }) ?? true
        else {
            return false
        }
        return addTab(tabID, toGroup: groupID, before: targetTabID)
    }

    @discardableResult
    func moveTab(
        _ tabID: UUID,
        withinGroup groupID: UUID,
        after targetTabID: UUID
    ) -> Bool {
        guard
            let group = tabGroups.first(where: { $0.id == groupID }),
            group.tabIDs.contains(tabID),
            group.tabIDs.contains(targetTabID)
        else {
            return false
        }
        return placeTab(tabID, inGroup: groupID, placement: .after(targetTabID))
    }

    @discardableResult
    func moveTabToEnd(_ tabID: UUID, inGroup groupID: UUID) -> Bool {
        moveTab(tabID, withinGroup: groupID, before: nil)
    }

    func moveTabGroup(_ groupID: UUID, before targetGroupID: UUID) {
        moveTabGroup(groupID, before: .group(targetGroupID))
    }

    func moveTabGroup(_ groupID: UUID, before entryID: PDFTabBarEntry.ID) {
        moveTabGroupBlock(groupID, relativeTo: entryID, placeAfter: false)
    }

    func moveTabGroup(_ groupID: UUID, after entryID: PDFTabBarEntry.ID) {
        moveTabGroupBlock(groupID, relativeTo: entryID, placeAfter: true)
    }

    func moveTabGroupToEnd(_ groupID: UUID) {
        guard let group = tabGroups.first(where: { $0.id == groupID }) else { return }
        replaceFlatTabBlock(
            removing: Set(group.tabIDs),
            with: group.tabIDs,
            anchoredAt: tabs.count
        )
        normalizeTabOrganization()
    }

    /// Deletes group metadata. Tabs remain open by default; callers may opt
    /// into closing all clean member tabs as one preflighted operation.
    @discardableResult
    func deleteTabGroup(_ groupID: UUID, keepingTabs: Bool = true) -> Bool {
        guard let group = tabGroups.first(where: { $0.id == groupID }) else { return false }
        guard !keepingTabs else {
            tabGroups.removeAll { $0.id == groupID }
            normalizeTabOrganization()
            return true
        }

        let sessionsToClose = group.tabIDs.compactMap { tabID in
            tabs.first(where: { $0.id == tabID })
        }
        for session in sessionsToClose {
            session.workspace.prepareForDeactivation()
            if session.workspace.isDirty || session.workspace.hasPendingReviewTextDraft {
                activeTabID = session.id
                session.workspace.presentedError = L10n.string("error.unsaved_group_delete")
                return false
            }
        }
        for session in sessionsToClose {
            _ = closeTab(session.id)
        }
        normalizeTabOrganization()
        return true
    }

    /// Closes a clean tab. Dirty tabs are deliberately rejected so callers
    /// must run UnsavedChangesGuard before removing the last reference.
    @discardableResult
    func closeTab(_ id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let session = tabs[index]
        session.workspace.prepareForDeactivation()
        guard
            !session.workspace.isDirty,
            !session.workspace.hasPendingReviewTextDraft
        else {
            activeTabID = id
            session.workspace.presentedError = L10n.string("error.unsaved_tab_close")
            return false
        }

        session.workspace.closeDiscardingChanges()
        removeSession(at: index)
        return true
    }

    func moveTab(_ id: UUID, before targetID: UUID) {
        guard
            id != targetID,
            tabs.contains(where: { $0.id == id }),
            tabs.contains(where: { $0.id == targetID })
        else { return }

        if let targetGroup = group(containing: targetID) {
            _ = addTab(id, toGroup: targetGroup.id, before: targetID)
            return
        }

        for index in tabGroups.indices {
            tabGroups[index].tabIDs.removeAll { $0 == id }
        }
        rawMoveTab(id, before: targetID)
        normalizeTabOrganization()
    }

    func moveTab(_ id: UUID, after targetID: UUID) {
        guard
            id != targetID,
            tabs.contains(where: { $0.id == id }),
            tabs.contains(where: { $0.id == targetID })
        else { return }

        if let targetGroup = group(containing: targetID) {
            _ = addTab(id, toGroup: targetGroup.id, after: targetID)
            return
        }

        for index in tabGroups.indices {
            tabGroups[index].tabIDs.removeAll { $0 == id }
        }
        rawMoveTab(id, after: targetID)
        normalizeTabOrganization()
    }

    /// Moves a tab at the strip level without joining the target's group.
    /// Group members remain a contiguous block, so a grouped target resolves
    /// to the block's leading boundary.
    func moveTabAsUngrouped(_ id: UUID, before targetID: UUID) {
        guard
            id != targetID,
            tabs.contains(where: { $0.id == id }),
            tabs.contains(where: { $0.id == targetID })
        else { return }

        let sourceGroupID = group(containing: id)?.id
        let boundaryID = group(containing: targetID)?.tabIDs.first(where: { $0 != id })
            ?? targetID
        removeTabMembership(id)
        dissolveGroupIfSingleton(sourceGroupID)
        if boundaryID != id {
            rawMoveTab(id, before: boundaryID)
        }
        normalizeTabOrganization()
    }

    /// Moves a tab at the strip level without joining the target's group.
    /// A grouped target resolves to the block's trailing boundary.
    func moveTabAsUngrouped(_ id: UUID, after targetID: UUID) {
        guard
            id != targetID,
            tabs.contains(where: { $0.id == id }),
            tabs.contains(where: { $0.id == targetID })
        else { return }

        let sourceGroupID = group(containing: id)?.id
        let boundaryID = group(containing: targetID)?.tabIDs.reversed().first(where: { $0 != id })
            ?? targetID
        removeTabMembership(id)
        dissolveGroupIfSingleton(sourceGroupID)
        if boundaryID != id {
            rawMoveTab(id, after: boundaryID)
        }
        normalizeTabOrganization()
    }

    func moveTabToEnd(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let sourceGroupID = group(containing: id)?.id
        removeTabMembership(id)
        dissolveGroupIfSingleton(sourceGroupID)
        rawMoveTab(id, before: nil)
        normalizeTabOrganization()
    }

    /// Removes a tab from this window without closing or recreating its PDF
    /// state. The returned session can be installed in another window while
    /// preserving unsaved edits, the document identity, and the tab ID.
    @discardableResult
    func detachTabForNewWindow(_ id: UUID) -> PDFTabSession? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let sourceGroupID = group(containing: id)?.id
        let session = tabs[index]
        session.workspace.prepareForDeactivation()
        removeSession(at: index)
        dissolveGroupIfSingleton(sourceGroupID)
        normalizeTabOrganization()
        return session
    }

    private func canReuseForOpening(_ session: PDFTabSession) -> Bool {
        !session.workspace.hasOpenDocument
            && !session.workspace.isDirty
            && !session.workspace.hasPendingReviewTextDraft
    }

    private func reusableEmptySession() -> PDFTabSession? {
        if let activeSession, canReuseForOpening(activeSession) {
            return activeSession
        }
        return tabs.first(where: canReuseForOpening)
    }

    private func session(opening url: URL) -> PDFTabSession? {
        let requestedKey = canonicalFileKey(for: url)
        return tabs.first { session in
            guard let openURL = session.workspace.documentURL else { return false }
            return canonicalFileKey(for: openURL) == requestedKey
        }
    }

    private func canonicalFileKey(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
    }

    private func uniquePDFURLs(_ urls: [URL]) -> [URL] {
        var seenKeys: Set<String> = []
        return urls.filter { url in
            seenKeys.insert(canonicalFileKey(for: url)).inserted
        }
    }

    /// The batch loader itself creates only one PDFDocument. This final pass
    /// also trims any documents that were resident before the batch began.
    private func enforceLoadedPDFTabBudgetAfterOpening() {
        let storedBudget = UserDefaults.standard.integer(
            forKey: PDFTabMemorySettings.loadedTabBudgetKey
        )
        let configuredBudget = PDFTabMemorySettings.normalizedBudget(
            storedBudget == 0 ? PDFTabMemorySettings.defaultLoadedTabBudget : storedBudget
        )
        let budget = configuredBudget
        let sessions = allTabs
        let inputs = sessions.map { session in
            PDFTabMemoryPolicyInput(
                id: session.id,
                isLoaded: session.workspace.document != nil,
                isActive: session.id == activeTabID,
                isProtected: false,
                canHibernate: session.workspace.canHibernate
            )
        }
        // Tab order is a stable approximation of access age during batch
        // open: earlier entries were opened first and are shed first.
        let recency = Dictionary(
            uniqueKeysWithValues: sessions.enumerated().map {
                ($0.element.id, UInt64($0.offset + 1))
            }
        )
        let candidates = PDFTabMemoryPolicy().hibernationCandidates(
            inputs: inputs,
            lastAccessSequence: recency,
            loadedTabBudget: budget
        )
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for id in candidates {
            _ = sessionByID[id]?.workspace.hibernateIfPossible()
        }
    }

    private func observe(_ session: PDFTabSession) {
        workspaceObservers[session.id] = session.workspace.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                    self?.scheduleSessionPersistence()
                }
            }
    }

    private func scheduleSessionPersistence() {
        guard sessionStore != nil else { return }
        guard !isLoadingWorkspace, !isSessionPersistenceSuspended else { return }
        sessionPersistenceTask?.cancel()
        sessionPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = self.flushSessionPersistence()
        }
    }

    private func observeRecentDocuments() {
        recentDocumentsObserver = recentDocumentsStore?.objectWillChange
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.objectWillChange.send()
                }
            }
    }

    private func removeSession(at index: Int) {
        let sourceGroupID = group(containing: tabs[index].id)?.id
        let removed = tabs.remove(at: index)
        workspaceObservers[removed.id] = nil
        deferredEncryptedDocumentURLs[removed.id] = nil
        for groupIndex in tabGroups.indices {
            tabGroups[groupIndex].tabIDs.removeAll { $0 == removed.id }
        }
        dissolveGroupIfSingleton(sourceGroupID)

        if tabs.isEmpty {
            let replacement = PDFTabSession()
            tabs = [replacement]
            observe(replacement)
            activeTabID = replacement.id
            normalizeTabOrganization()
            return
        }

        if activeTabID == removed.id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        normalizeTabOrganization()
    }

    private func placeTab(
        _ tabID: UUID,
        inGroup groupID: UUID,
        placement: TabPlacement
    ) -> Bool {
        guard tabs.contains(where: { $0.id == tabID }) else { return false }
        let sourceGroupID = group(containing: tabID)?.id
        guard let targetGroupIndex = tabGroups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }
        if placement.targetTabID == tabID, tabGroups[targetGroupIndex].tabIDs.contains(tabID) {
            return true
        }

        let currentTargetIDs = tabGroups[targetGroupIndex].tabIDs
        let targetAnchor = firstFlatIndex(ofAny: currentTargetIDs)
        var desiredTargetIDs = currentTargetIDs.filter { $0 != tabID }
        switch placement {
        case let .before(targetTabID):
            guard let index = desiredTargetIDs.firstIndex(of: targetTabID) else { return false }
            desiredTargetIDs.insert(tabID, at: index)
        case let .after(targetTabID):
            guard let index = desiredTargetIDs.firstIndex(of: targetTabID) else { return false }
            desiredTargetIDs.insert(tabID, at: desiredTargetIDs.index(after: index))
        case .end:
            desiredTargetIDs.append(tabID)
        }

        replaceFlatTabBlock(
            removing: Set(currentTargetIDs).union([tabID]),
            with: desiredTargetIDs,
            anchoredAt: targetAnchor
        )
        for index in tabGroups.indices {
            tabGroups[index].tabIDs.removeAll { $0 == tabID }
        }
        guard let refreshedTargetIndex = tabGroups.firstIndex(where: { $0.id == groupID }) else {
            return false
        }
        tabGroups[refreshedTargetIndex].tabIDs = desiredTargetIDs
        if sourceGroupID != groupID {
            dissolveGroupIfSingleton(sourceGroupID)
        }
        normalizeTabOrganization()
        return true
    }

    private func rawMoveTab(_ id: UUID, before targetID: UUID?) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let session = tabs.remove(at: source)
        guard let targetID else {
            tabs.append(session)
            return
        }
        guard let target = tabs.firstIndex(where: { $0.id == targetID }) else {
            tabs.insert(session, at: min(source, tabs.count))
            return
        }
        tabs.insert(session, at: target)
    }

    private func moveTabGroupBlock(
        _ groupID: UUID,
        relativeTo entryID: PDFTabBarEntry.ID,
        placeAfter: Bool
    ) {
        guard let sourceGroup = tabGroups.first(where: { $0.id == groupID }) else { return }

        let targetIDs: [UUID]
        switch entryID {
        case let .tab(tabID):
            guard tabs.contains(where: { $0.id == tabID }) else { return }
            targetIDs = group(containing: tabID)?.tabIDs ?? [tabID]
        case let .group(targetGroupID):
            guard targetGroupID != groupID else { return }
            guard let targetGroup = tabGroups.first(where: { $0.id == targetGroupID }) else {
                return
            }
            targetIDs = targetGroup.tabIDs
        }

        let targetIndex: Int?
        if placeAfter {
            targetIndex = tabs.lastIndex { targetIDs.contains($0.id) }.map { $0 + 1 }
        } else {
            targetIndex = firstFlatIndex(ofAny: targetIDs)
        }
        guard let targetIndex else { return }

        replaceFlatTabBlock(
            removing: Set(sourceGroup.tabIDs),
            with: sourceGroup.tabIDs,
            anchoredAt: targetIndex
        )
        normalizeTabOrganization()
    }

    private func removeTabMembership(_ id: UUID) {
        for index in tabGroups.indices {
            tabGroups[index].tabIDs.removeAll { $0 == id }
        }
    }

    private func dissolveGroupIfSingleton(_ groupID: UUID?) {
        guard
            let groupID,
            let group = tabGroups.first(where: { $0.id == groupID }),
            group.tabIDs.count < 2
        else { return }
        tabGroups.removeAll { $0.id == groupID }
    }

    private func rawMoveTab(_ id: UUID, after targetID: UUID) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let session = tabs.remove(at: source)
        guard let target = tabs.firstIndex(where: { $0.id == targetID }) else {
            tabs.insert(session, at: min(source, tabs.count))
            return
        }
        tabs.insert(session, at: tabs.index(after: target))
    }

    private func firstFlatIndex(ofAny tabIDs: [UUID]) -> Int? {
        let requested = Set(tabIDs)
        return tabs.firstIndex { requested.contains($0.id) }
    }

    private func replaceFlatTabBlock(
        removing removedIDs: Set<UUID>,
        with replacementIDs: [UUID],
        anchoredAt requestedAnchor: Int?
    ) {
        let currentIDs = tabs.map(\.id)
        let anchor = min(max(0, requestedAnchor ?? currentIDs.count), currentIDs.count)
        let removedBeforeAnchor = currentIDs[..<anchor].count { removedIDs.contains($0) }
        let insertionIndex = anchor - removedBeforeAnchor
        var orderedIDs = currentIDs.filter { !removedIDs.contains($0) }
        let validReplacement = replacementIDs.filter { removedIDs.contains($0) }
        orderedIDs.insert(
            contentsOf: validReplacement,
            at: min(insertionIndex, orderedIDs.count)
        )
        setFlatTabOrder(orderedIDs)
    }

    private func setFlatTabOrder(_ orderedIDs: [UUID]) {
        guard orderedIDs.count == tabs.count, Set(orderedIDs) == Set(tabs.map(\.id)) else {
            return
        }
        let sessionByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        tabs = orderedIDs.compactMap { sessionByID[$0] }
    }

    private func synchronizeActiveWorkspaceRecord() {
        guard !isLoadingWorkspace else { return }
        guard let index = workspaces.firstIndex(where: { $0.id == activeWorkspaceID }) else {
            return
        }
        workspaces[index].tabs = tabs
        workspaces[index].activeTabID = activeTabID
        workspaces[index].tabGroups = tabGroups
    }

    private func loadWorkspace(_ workspace: PDFDocumentWorkspace) {
        // Async metadata preparation operates on the active workspace
        // projection. Never let a request started in one workspace install
        // into a different workspace after the user switches away.
        if workspace.id != activeWorkspaceID {
            cancelPendingBatchOpen()
        }
        sessionForActiveTab()?.workspace.prepareForDeactivation()
        isLoadingWorkspace = true
        activeWorkspaceID = workspace.id
        tabs = workspace.tabs
        activeTabID = workspace.activeTabID
        tabGroups = workspace.tabGroups
        isLoadingWorkspace = false
        normalizeTabOrganization()
        synchronizeActiveWorkspaceRecord()
        resolveLazyActiveTabIfNeeded(previousTabID: nil)
    }

    private func sessionForActiveTab() -> PDFTabSession? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    private func normalizeTabOrganization() {
        let currentIDs = tabs.map(\.id)
        tabGroups = PDFTabGroupRules.normalizedGroups(
            tabGroups,
            validTabIDs: currentIDs
        )

        let groupByTabID = tabGroups.reduce(into: [UUID: PDFTabGroup]()) { result, group in
            for tabID in group.tabIDs {
                result[tabID] = group
            }
        }
        var emittedGroups: Set<UUID> = []
        var compactedIDs: [UUID] = []
        for tabID in currentIDs {
            guard let group = groupByTabID[tabID] else {
                compactedIDs.append(tabID)
                continue
            }
            if emittedGroups.insert(group.id).inserted {
                compactedIDs.append(contentsOf: group.tabIDs)
            }
        }
        if compactedIDs != currentIDs {
            setFlatTabOrder(compactedIDs)
        }

        tabGroups = PDFTabGroupRules.normalizedGroups(
            tabGroups,
            validTabIDs: tabs.map(\.id)
        )
        if let activeTabID, tabs.contains(where: { $0.id == activeTabID }) {
            return
        }
        activeTabID = tabs.first?.id
    }
}

private enum TabPlacement: Equatable {
    case before(UUID)
    case after(UUID)
    case end

    var targetTabID: UUID? {
        switch self {
        case let .before(tabID), let .after(tabID): tabID
        case .end: nil
        }
    }
}

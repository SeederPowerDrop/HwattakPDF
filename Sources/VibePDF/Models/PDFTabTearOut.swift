// SPDX-License-Identifier: MPL-2.0

import Combine
import Foundation

struct WorkspaceComparisonPresentationState: Equatable {
    var isComparing: Bool
    var configuration: PDFComparisonConfiguration
}

enum PDFTabTearOutDropRules {
    static func localCandidate(
        draggedTabID: UUID?,
        openTabIDs: Set<UUID>,
        hasCompatibleProvider: Bool
    ) -> UUID? {
        guard hasCompatibleProvider, let draggedTabID else { return nil }
        return openTabIDs.contains(draggedTabID) ? draggedTabID : nil
    }

    /// Provider contents, including the per-launch nonce, remain authoritative
    /// at commit time. A raw UUID or ordinary external text never moves a tab.
    static func authoritativeTabID(
        encodedValue: String,
        expectedTabID: UUID,
        openTabIDs: Set<UUID>
    ) -> UUID? {
        guard PDFTabDragPayload.decode(encodedValue) == expectedTabID else { return nil }
        return openTabIDs.contains(expectedTabID) ? expectedTabID : nil
    }
}

/// Owns the workspace for every tab that has been torn into a separate app
/// window. A session is moved, rather than reopened from its URL, so dirty
/// annotations and object identity survive the window transition exactly.
@MainActor
protocol PDFTabTearOutStoreObserving: AnyObject {
    func tearOutStore(
        _ store: PDFTabTearOutStore,
        didOpenWindow requestID: UUID,
        workspace: MultiDocumentWorkspaceState
    )
    func tearOutStore(_ store: PDFTabTearOutStore, didCloseWindow requestID: UUID)
}

@MainActor
final class PDFTabTearOutStore {
    static let shared = PDFTabTearOutStore()

    @MainActor
    private final class PendingWindow {
        let source: MultiDocumentWorkspaceState?
        let tabID: UUID?
        let workspaceTitle: String?
        var workspace: MultiDocumentWorkspaceState?

        init(
            source: MultiDocumentWorkspaceState,
            tabID: UUID,
            workspaceTitle: String?
        ) {
            self.source = source
            self.tabID = tabID
            self.workspaceTitle = workspaceTitle
        }

        init(restoredWorkspace: MultiDocumentWorkspaceState) {
            source = nil
            tabID = nil
            workspaceTitle = restoredWorkspace.activeWorkspaceDescriptor?.title
            workspace = restoredWorkspace
        }
    }

    private var pendingWindows: [UUID: PendingWindow] = [:]
    private var windowOrder: [UUID] = []
    private weak var observer: (any PDFTabTearOutStoreObserving)?

    init() {}

    var allWindowWorkspaces: [MultiDocumentWorkspaceState] {
        windowSnapshots.map(\.workspace)
    }

    var windowSnapshots: [WorkspaceSessionDetachedWindowSnapshot] {
        windowOrder.compactMap { requestID in
            guard let workspace = pendingWindows[requestID]?.workspace else { return nil }
            return WorkspaceSessionDetachedWindowSnapshot(
                windowID: requestID,
                workspace: workspace
            )
        }
    }

    func setObserver(_ observer: (any PDFTabTearOutStoreObserving)?) {
        self.observer = observer
    }

    @discardableResult
    func stageNewWindow(
        tabID: UUID,
        from source: MultiDocumentWorkspaceState
    ) -> UUID? {
        guard source.tabs.contains(where: { $0.id == tabID }) else { return nil }

        let requestID = UUID()
        pendingWindows[requestID] = PendingWindow(
            source: source,
            tabID: tabID,
            workspaceTitle: source.activeWorkspaceDescriptor?.title
        )
        windowOrder.append(requestID)
        return requestID
    }

    func workspace(for requestID: UUID) -> MultiDocumentWorkspaceState? {
        guard let pending = pendingWindows[requestID] else { return nil }
        if let workspace = pending.workspace {
            return workspace
        }
        // Claiming happens from the new WindowGroup's body. If SwiftUI cannot
        // create that window, this method is never reached and the source tab
        // remains untouched instead of becoming stranded in a registry.
        guard
            let source = pending.source,
            let tabID = pending.tabID,
            let session = source.detachTabForNewWindow(tabID)
        else {
            pendingWindows[requestID] = nil
            windowOrder.removeAll { $0 == requestID }
            return nil
        }
        let workspace = MultiDocumentWorkspaceState(
            initialSession: session,
            recentDocumentsStore: source.recentDocumentsStore,
            initialWorkspaceTitle: pending.workspaceTitle
        )
        pending.workspace = workspace
        observer?.tearOutStore(
            self,
            didOpenWindow: requestID,
            workspace: workspace
        )
        return workspace
    }

    /// Installs an already reconstructed workspace under its persisted
    /// WindowGroup value. The actual NSWindow is opened later by a SwiftUI
    /// `openWindow(value:)` bridge; no private AppKit geometry APIs are needed.
    @discardableResult
    func registerRestoredWindow(
        requestID: UUID,
        workspace: MultiDocumentWorkspaceState
    ) -> Bool {
        guard pendingWindows[requestID] == nil else { return false }
        pendingWindows[requestID] = PendingWindow(restoredWorkspace: workspace)
        windowOrder.append(requestID)
        observer?.tearOutStore(
            self,
            didOpenWindow: requestID,
            workspace: workspace
        )
        return true
    }

    func releaseWindow(_ requestID: UUID) {
        guard pendingWindows.removeValue(forKey: requestID) != nil else { return }
        windowOrder.removeAll { $0 == requestID }
        observer?.tearOutStore(self, didCloseWindow: requestID)
    }
}

/// Bridges otherwise independent tear-out workspaces into the main session
/// archive. The main workspace already owns its own debounce; this coordinator
/// observes only detached windows and commits their authoritative topology
/// after the same quiet period.
@MainActor
final class AppWideWorkspaceSessionCoordinator:
    WorkspaceSessionAppSnapshotProviding,
    PDFTabTearOutStoreObserving
{
    private weak var mainWorkspace: MultiDocumentWorkspaceState?
    private weak var sessionStore: WorkspaceSessionStore?
    private weak var tearOutStore: PDFTabTearOutStore?
    private var workspaceObservers: [UUID: AnyCancellable] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var comparisonRecords: [WorkspaceSessionArchive.ComparisonRecord]?
    private var pendingRestoredWindowIDs: [UUID] = []
    private let debounceDuration: Duration

    init(
        mainWorkspace: MultiDocumentWorkspaceState,
        sessionStore: WorkspaceSessionStore,
        tearOutStore: PDFTabTearOutStore? = nil,
        debounceDuration: Duration = .milliseconds(650)
    ) {
        let tearOutStore = tearOutStore ?? .shared
        self.mainWorkspace = mainWorkspace
        self.sessionStore = sessionStore
        self.tearOutStore = tearOutStore
        self.debounceDuration = debounceDuration
        comparisonRecords = sessionStore.lastRestoredComparisonRecords

        if let topology = sessionStore.lastRestoredWindowTopology {
            let restoredWindows = mainWorkspace.partitionRestoredDetachedWindows(
                using: topology
            )
            for window in restoredWindows where tearOutStore.registerRestoredWindow(
                requestID: window.windowID,
                workspace: window.workspace
            ) {
                pendingRestoredWindowIDs.append(window.windowID)
            }
        }

        sessionStore.configureAppSnapshotProvider(self)
        tearOutStore.setObserver(self)
        tearOutStore.windowSnapshots.forEach(observe)
        // Establish a durable main base before a future detached-only merge.
        _ = mainWorkspace.flushSessionPersistence(
            including: tearOutStore.allWindowWorkspaces
        )
    }

    /// SwiftUI's public restoration surface can recreate value-addressed
    /// WindowGroup scenes, but it does not expose portable window geometry.
    /// The main scene invokes this once after its OpenWindowAction is ready.
    func openRestoredWindows(using openWindow: (UUID) -> Void) {
        let requestIDs = pendingRestoredWindowIDs
        pendingRestoredWindowIDs.removeAll()
        requestIDs.forEach(openWindow)
    }

    /// A red-closed main window reloads only its persisted workspace members;
    /// live tear-out windows keep their original object graph and dirty state.
    func resumeMainSessionPersistence() {
        guard let mainWorkspace else { return }
        let mainWorkspaceIDs = sessionStore?.lastRestoredWindowTopology?
            .mainWorkspaceIDs
        mainWorkspace.resumeSessionPersistence(
            restoringWorkspaceIDs: mainWorkspaceIDs.map { Set($0) }
        )
    }

    func workspaceSessionAppSnapshot() -> WorkspaceSessionAppSnapshot {
        WorkspaceSessionAppSnapshot(
            detachedWindows: tearOutStore?.windowSnapshots ?? [],
            comparisonRecords: comparisonRecords
        )
    }

    /// nil leaves legacy/unconnected comparison data untouched; [] explicitly
    /// records that no window is comparing.
    func updateComparisonRecords(
        _ records: [WorkspaceSessionArchive.ComparisonRecord]?
    ) {
        comparisonRecords = records
        schedulePersistence()
    }

    func comparisonPresentationState(
        windowID: UUID?,
        workspaceID: UUID
    ) -> WorkspaceComparisonPresentationState? {
        guard let record = comparisonRecords?.first(where: {
            $0.windowID == windowID && $0.workspaceID == workspaceID
        }) else {
            return nil
        }
        var configuration = PDFComparisonConfiguration(
            selectedDocumentIDs: record.selectedDocumentIDs,
            layout: PDFComparisonLayout(rawValue: record.layout) ?? .sideBySide,
            syncEnabled: record.syncEnabled,
            lockedDocumentIDs: Set(record.lockedDocumentIDs)
        )
        configuration.restorePersistedPanelWeights(
            sideBySide: Dictionary(
                record.sideBySideWeights.map { ($0.documentID, $0.weight) },
                uniquingKeysWith: { current, _ in current }
            ),
            stacked: Dictionary(
                record.stackedWeights.map { ($0.documentID, $0.weight) },
                uniquingKeysWith: { current, _ in current }
            )
        )
        return WorkspaceComparisonPresentationState(
            isComparing: record.isComparing && configuration.canBeginComparison,
            configuration: configuration
        )
    }

    func updateComparisonPresentationState(
        windowID: UUID?,
        workspaceID: UUID,
        state: WorkspaceComparisonPresentationState
    ) {
        var records = comparisonRecords ?? []
        records.removeAll {
            $0.windowID == windowID && $0.workspaceID == workspaceID
        }
        if !state.configuration.selectedDocumentIDs.isEmpty {
            func weights(
                for layout: PDFComparisonLayout
            ) -> [WorkspaceSessionArchive.ComparisonRecord.PanelWeight] {
                let stored = state.configuration.persistedPanelWeights(for: layout)
                return state.configuration.selectedDocumentIDs.compactMap { id in
                    stored[id].map {
                        .init(documentID: id, weight: $0)
                    }
                }
            }
            records.append(
                .init(
                    windowID: windowID,
                    workspaceID: workspaceID,
                    isComparing: state.isComparing,
                    selectedDocumentIDs: state.configuration.selectedDocumentIDs,
                    layout: state.configuration.layout.rawValue,
                    syncEnabled: state.configuration.syncEnabled,
                    lockedDocumentIDs: state.configuration.selectedDocumentIDs.filter {
                        state.configuration.lockedDocumentIDs.contains($0)
                    },
                    sideBySideWeights: weights(for: .sideBySide),
                    stackedWeights: weights(for: .stacked)
                )
            )
        }
        comparisonRecords = records
        schedulePersistence()
    }

    @discardableResult
    func flushNow() -> Bool {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard let sessionStore else { return false }
        return sessionStore.mergeDetachedWindowWorkspaces(
            tearOutStore?.allWindowWorkspaces ?? []
        )
    }

    func tearOutStore(
        _ store: PDFTabTearOutStore,
        didOpenWindow requestID: UUID,
        workspace: MultiDocumentWorkspaceState
    ) {
        observe(
            WorkspaceSessionDetachedWindowSnapshot(
                windowID: requestID,
                workspace: workspace
            )
        )
        schedulePersistence()
    }

    func tearOutStore(_ store: PDFTabTearOutStore, didCloseWindow requestID: UUID) {
        workspaceObservers[requestID] = nil
        comparisonRecords?.removeAll { $0.windowID == requestID }
        schedulePersistence()
    }

    private func observe(_ snapshot: WorkspaceSessionDetachedWindowSnapshot) {
        workspaceObservers[snapshot.windowID] = snapshot.workspace.objectWillChange
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.schedulePersistence()
                }
            }
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = flushNow()
        }
    }
}

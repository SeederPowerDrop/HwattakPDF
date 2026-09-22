// SPDX-License-Identifier: MPL-2.0

import Foundation

protocol WorkspaceSessionDataPersisting: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

final class AtomicWorkspaceSessionFilePersistence: WorkspaceSessionDataPersisting {
    let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("HwattakPDF", isDirectory: true)
                .appendingPathComponent("workspace-session-v1.json", isDirectory: false)
        }
    }

    func read() throws -> Data? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    }

    func write(_ data: Data) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // `.atomic` commits a fully encoded replacement from a sibling
        // temporary file, so an interrupted launch/quit cannot leave a
        // partially written JSON archive behind.
        try data.write(to: fileURL, options: [.atomic])
    }
}

protocol WorkspaceSessionBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool)
}

struct SecurityScopedWorkspaceSessionBookmarkCoder: WorkspaceSessionBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: [.nameKey, .isRegularFileKey],
            relativeTo: nil
        )
    }

    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

enum WorkspaceSessionStoreError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case corrupted
    case readFailed(String)
    case writeFailed(String)
    case partiallyRestored(unavailableDocumentCount: Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version):
            "Unsupported workspace session version: \(version)"
        case .corrupted:
            "The saved workspace session is damaged."
        case let .readFailed(message):
            "Could not read the saved workspace session: \(message)"
        case let .writeFailed(message):
            "Could not save the workspace session: \(message)"
        case let .partiallyRestored(count):
            "\(count) document(s) could not be restored."
        }
    }
}

struct WorkspaceSessionArchive: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var activeWorkspaceID: UUID?
    var workspaces: [WorkspaceRecord]
    /// Workspaces captured from tear-out windows at the last snapshot. They
    /// restore as regular workspaces, but provenance lets a later authoritative
    /// window list remove a detached window the user explicitly closed.
    var detachedWorkspaceIDs: [UUID]
    /// Optional schema-v1 additions. Older archives decode these as nil, so
    /// topology/comparison persistence can ship without invalidating existing
    /// session files.
    var windowTopology: WindowTopologyRecord?
    var comparisonRecords: [ComparisonRecord]?

    init(
        schemaVersion: Int = currentSchemaVersion,
        activeWorkspaceID: UUID?,
        workspaces: [WorkspaceRecord],
        detachedWorkspaceIDs: [UUID] = [],
        windowTopology: WindowTopologyRecord? = nil,
        comparisonRecords: [ComparisonRecord]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.activeWorkspaceID = activeWorkspaceID
        self.workspaces = workspaces
        self.detachedWorkspaceIDs = detachedWorkspaceIDs
        self.windowTopology = windowTopology
        self.comparisonRecords = comparisonRecords
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case activeWorkspaceID
        case workspaces
        case detachedWorkspaceIDs
        case windowTopology
        case comparisonRecords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        activeWorkspaceID = try container.decodeIfPresent(UUID.self, forKey: .activeWorkspaceID)
        workspaces = try container.decode([WorkspaceRecord].self, forKey: .workspaces)
        detachedWorkspaceIDs = try container.decodeIfPresent(
            [UUID].self,
            forKey: .detachedWorkspaceIDs
        ) ?? []
        windowTopology = try container.decodeIfPresent(
            WindowTopologyRecord.self,
            forKey: .windowTopology
        )
        comparisonRecords = try container.decodeIfPresent(
            [ComparisonRecord].self,
            forKey: .comparisonRecords
        )
    }

    struct WorkspaceRecord: Codable, Equatable {
        var id: UUID
        var title: String
        var activeTabID: UUID?
        var tabs: [TabRecord]
        var groups: [GroupRecord]
    }

    struct TabRecord: Codable, Equatable {
        var id: UUID
        var document: DocumentRecord?
        var currentPageIndex: Int
        var selectedPages: [Int]
        var pageColumns: Int
        var overviewScale: Double
        /// Optional additions preserve decoding compatibility with existing
        /// schema-v1 archives written before per-tab viewport persistence.
        var sidebarVisible: Bool? = nil
        var gridLayoutMode: String? = nil
        /// Missing in older schema-v1 archives, which intentionally restores
        /// the original continuous two-page behavior.
        var twoPageDisplayMode: String? = nil
        /// Geometry used by the saved clip position. Older archives contain
        /// vertical positions; this does not override the user's global mode.
        var pdfPageNavigationMode: String? = nil
        /// Absent in older archives; their existing automatic/manual zoom
        /// state remains authoritative until a fit direction is selected.
        var pdfPageFitMode: String? = nil
        var pdfAutoScales: Bool? = nil
        var pdfScaleFactor: Double? = nil
        var pdfHorizontalScrollProgress: Double? = nil
        var pdfVerticalScrollProgress: Double? = nil
        var pdfCapturedPageIndex: Int? = nil
        /// Comparison panels retain their own lightweight viewport so opening
        /// comparison mode never overwrites the regular tab viewport.
        var comparisonPDFAutoScales: Bool? = nil
        var comparisonPDFScaleFactor: Double? = nil
        var comparisonPDFHorizontalScrollProgress: Double? = nil
        var comparisonPDFVerticalScrollProgress: Double? = nil
        var comparisonPDFCapturedPageIndex: Int? = nil
        /// Added without increasing schemaVersion: an absent field is a valid
        /// archive written by HwattakPDF 0.6.x and restores to viewer mode.
        /// Keeping it optional is the backward-compatibility mechanism.
        var workspaceMode: String? = nil
    }

    struct DocumentRecord: Codable, Equatable {
        var bookmark: Data
        /// Diagnostic metadata only. Restoration never opens this path when
        /// bookmark resolution fails, because doing so would bypass App
        /// Sandbox authorization.
        var lastKnownPath: String
        var pageCount: Int
        var isImageSource: Bool? = nil
        var isRecoveryCopy: Bool? = nil
    }

    struct GroupRecord: Codable, Equatable {
        var id: UUID
        var title: String
        var tabIDs: [UUID]
        var isCollapsed: Bool
    }

    struct WindowTopologyRecord: Codable, Equatable {
        var mainWorkspaceIDs: [UUID]
        var detachedWindows: [DetachedWindowRecord]

        struct DetachedWindowRecord: Codable, Equatable {
            var windowID: UUID
            var workspaceIDs: [UUID]
            /// Optional for archives written before per-window activation was
            /// captured. Missing values safely fall back to the first member.
            var activeWorkspaceID: UUID? = nil
        }
    }

    /// Scalar/UUID-only representation deliberately avoids coupling archive
    /// decoding to SwiftUI view state or the live comparison model type.
    struct ComparisonRecord: Codable, Equatable {
        var windowID: UUID?
        var workspaceID: UUID
        var isComparing: Bool
        var selectedDocumentIDs: [UUID]
        var layout: String
        var syncEnabled: Bool
        var lockedDocumentIDs: [UUID]
        var sideBySideWeights: [PanelWeight]
        var stackedWeights: [PanelWeight]

        struct PanelWeight: Codable, Equatable {
            var documentID: UUID
            var weight: Double
        }

        func normalized(validDocumentIDs: Set<UUID>) -> ComparisonRecord? {
            var seen: Set<UUID> = []
            let selected = selectedDocumentIDs.filter {
                validDocumentIDs.contains($0) && seen.insert($0).inserted
            }.prefix(4)
            let orderedSelection = Array(selected)
            guard !orderedSelection.isEmpty else { return nil }
            let selectedSet = Set(orderedSelection)
            let normalizedLayout = ["sideBySide", "stacked"].contains(layout)
                ? layout
                : "sideBySide"

            func normalizedWeights(_ weights: [PanelWeight]) -> [PanelWeight] {
                var seenWeights: Set<UUID> = []
                return weights.filter {
                    selectedSet.contains($0.documentID)
                        && $0.weight.isFinite
                        && $0.weight > 0
                        && seenWeights.insert($0.documentID).inserted
                }
            }

            var seenLocks: Set<UUID> = []
            let normalizedLocks = lockedDocumentIDs.filter {
                selectedSet.contains($0) && seenLocks.insert($0).inserted
            }

            return ComparisonRecord(
                windowID: windowID,
                workspaceID: workspaceID,
                isComparing: isComparing
                    && orderedSelection.count >= 2,
                selectedDocumentIDs: orderedSelection,
                layout: normalizedLayout,
                syncEnabled: syncEnabled,
                lockedDocumentIDs: normalizedLocks,
                sideBySideWeights: normalizedWeights(sideBySideWeights),
                stackedWeights: normalizedWeights(stackedWeights)
            )
        }
    }
}

@MainActor
struct RestoredWorkspaceSession {
    var workspaces: [PDFDocumentWorkspace]
    var activeWorkspaceID: UUID
    var windowTopology: WorkspaceSessionArchive.WindowTopologyRecord?
    var comparisonRecords: [WorkspaceSessionArchive.ComparisonRecord]?
}

@MainActor
struct WorkspaceSessionDetachedWindowSnapshot {
    let windowID: UUID
    let workspace: MultiDocumentWorkspaceState
}

@MainActor
struct WorkspaceSessionAppSnapshot {
    var detachedWindows: [WorkspaceSessionDetachedWindowSnapshot]
    /// nil means comparison state is not connected yet and the previous
    /// archive value must be preserved. An empty array is authoritative.
    var comparisonRecords: [WorkspaceSessionArchive.ComparisonRecord]?
}

@MainActor
protocol WorkspaceSessionAppSnapshotProviding: AnyObject {
    func workspaceSessionAppSnapshot() -> WorkspaceSessionAppSnapshot
}

/// Persists only reopenable document references and lightweight UI state.
/// Unsaved PDF bytes and annotations are deliberately not copied into this
/// archive; close/save confirmation remains the sole authority for them.
@MainActor
final class WorkspaceSessionStore {
    private struct ComparisonScope: Hashable {
        let windowID: UUID?
        let workspaceID: UUID
    }

    private let persistence: WorkspaceSessionDataPersisting
    private let bookmarkCoder: WorkspaceSessionBookmarkCoding
    private let fileManager: FileManager
    private var bookmarkCache: [String: Data] = [:]
    private var lastArchive: WorkspaceSessionArchive?
    private weak var appSnapshotProvider: (any WorkspaceSessionAppSnapshotProviding)?

    private(set) var lastError: WorkspaceSessionStoreError?
    private(set) var lastRestoredWindowTopology: WorkspaceSessionArchive.WindowTopologyRecord?
    private(set) var lastRestoredComparisonRecords: [WorkspaceSessionArchive.ComparisonRecord]?

    convenience init() {
        self.init(
            persistence: AtomicWorkspaceSessionFilePersistence(),
            bookmarkCoder: SecurityScopedWorkspaceSessionBookmarkCoder()
        )
    }

    init(
        persistence: WorkspaceSessionDataPersisting,
        bookmarkCoder: WorkspaceSessionBookmarkCoding,
        fileManager: FileManager = .default
    ) {
        self.persistence = persistence
        self.bookmarkCoder = bookmarkCoder
        self.fileManager = fileManager
    }

    func configureAppSnapshotProvider(
        _ provider: (any WorkspaceSessionAppSnapshotProviding)?
    ) {
        appSnapshotProvider = provider
    }

    func restore() -> RestoredWorkspaceSession? {
        let data: Data
        do {
            guard let persisted = try persistence.read() else {
                lastError = nil
                lastRestoredWindowTopology = nil
                lastRestoredComparisonRecords = nil
                return nil
            }
            data = persisted
        } catch {
            lastError = .readFailed(error.localizedDescription)
            return nil
        }

        var archive: WorkspaceSessionArchive
        do {
            archive = try JSONDecoder().decode(WorkspaceSessionArchive.self, from: data)
        } catch {
            lastError = .corrupted
            return nil
        }
        guard archive.schemaVersion == WorkspaceSessionArchive.currentSchemaVersion else {
            lastError = .unsupportedVersion(archive.schemaVersion)
            return nil
        }
        lastArchive = archive

        var seenWorkspaceIDs: Set<UUID> = []
        var seenTabIDs: Set<UUID> = []
        var restoredWorkspaces: [PDFDocumentWorkspace] = []
        var unavailableDocumentCount = 0
        var refreshedAStaleBookmark = false

        for workspaceIndex in archive.workspaces.indices {
            let record = archive.workspaces[workspaceIndex]
            guard seenWorkspaceIDs.insert(record.id).inserted else { continue }

            var sessions: [PDFTabSession] = []
            // The app intentionally permits the same file in separate named
            // workspaces. Only duplicate tabs inside one workspace are ghosts.
            var seenDocumentKeys: Set<String> = []
            for tabIndex in archive.workspaces[workspaceIndex].tabs.indices {
                let tabRecord = archive.workspaces[workspaceIndex].tabs[tabIndex]
                guard seenTabIDs.insert(tabRecord.id).inserted else { continue }

                guard let documentRecord = tabRecord.document else {
                    // Every unique empty tab is intentional UI state (Cmd-T
                    // may create several and stacks can contain them). The
                    // global tab-ID set above removes only malformed repeats.
                    // Its working mode still belongs to the tab, so choosing a
                    // mode before opening a file survives application relaunch.
                    let emptyWorkspace = PDFWorkspaceState()
                    if
                        let rawWorkspaceMode = tabRecord.workspaceMode,
                        let restoredMode = PDFWorkspaceMode(rawValue: rawWorkspaceMode)
                    {
                        emptyWorkspace.restoreModeFromSession(restoredMode)
                    }
                    if
                        let rawTwoPageMode = tabRecord.twoPageDisplayMode,
                        let restoredTwoPageMode = PDFTwoPageDisplayMode(rawValue: rawTwoPageMode)
                    {
                        emptyWorkspace.twoPageDisplayMode = restoredTwoPageMode
                    }
                    emptyWorkspace.restorePageFitMode(
                        tabRecord.pdfPageFitMode.flatMap(PDFPageFitMode.init(rawValue:))
                    )
                    sessions.append(
                        PDFTabSession(id: tabRecord.id, workspace: emptyWorkspace)
                    )
                    continue
                }

                do {
                    let resolution = try bookmarkCoder.resolveBookmark(documentRecord.bookmark)
                    guard resolution.url.isFileURL else {
                        unavailableDocumentCount += 1
                        continue
                    }
                    let scopedAccess = SecurityScopedAccess(url: resolution.url)
                    var isDirectory: ObjCBool = false
                    guard
                        fileManager.fileExists(
                            atPath: resolution.url.path,
                            isDirectory: &isDirectory
                        ),
                        !isDirectory.boolValue
                    else {
                        unavailableDocumentCount += 1
                        continue
                    }

                    let documentKey = canonicalFileKey(for: resolution.url)
                    guard seenDocumentKeys.insert(documentKey).inserted else { continue }

                    let validSelection = Set(tabRecord.selectedPages.filter {
                        $0 >= 0 && $0 < documentRecord.pageCount
                    })
                    let workspace = PDFWorkspaceState()
                    let isLaunchActiveTab = record.id == archive.activeWorkspaceID
                        && tabRecord.id == record.activeTabID
                    if documentRecord.isImageSource == true {
                        workspace.restoreHibernated(
                            url: resolution.url, pageCount: 1,
                            currentPageIndex: 0, selectedPages: [0]
                        )
                        workspace.associateImageSource(resolution.url)
                        if isLaunchActiveTab && !workspace.resumeIfNeeded() {
                            unavailableDocumentCount += 1
                            continue
                        }
                    } else if isLaunchActiveTab {
                        let didOpen = withExtendedLifetime(scopedAccess) {
                            workspace.open(url: resolution.url)
                        }
                        guard didOpen else {
                            unavailableDocumentCount += 1
                            continue
                        }
                        let lastPage = max(0, workspace.pageCount - 1)
                        workspace.currentPageIndex = min(
                            max(0, tabRecord.currentPageIndex),
                            lastPage
                        )
                        let actualSelection = Set(validSelection.filter {
                            $0 < workspace.pageCount
                        })
                        workspace.selectedPages = actualSelection.isEmpty && workspace.pageCount > 0
                            ? [workspace.currentPageIndex]
                            : actualSelection
                    } else {
                        withExtendedLifetime(scopedAccess) {
                            workspace.restoreHibernated(
                                url: resolution.url,
                                pageCount: documentRecord.pageCount,
                                currentPageIndex: tabRecord.currentPageIndex,
                                selectedPages: validSelection
                            )
                        }
                    }
                    if documentRecord.isRecoveryCopy == true { workspace.markAsRecoveredCopy() }
                    workspace.pageColumns = min(12, max(1, tabRecord.pageColumns))
                    workspace.overviewScale = min(1.6, max(0.7, tabRecord.overviewScale))
                    workspace.sidebarVisible = tabRecord.sidebarVisible ?? true
                    if
                        let rawTwoPageMode = tabRecord.twoPageDisplayMode,
                        let restoredTwoPageMode = PDFTwoPageDisplayMode(rawValue: rawTwoPageMode)
                    {
                        workspace.twoPageDisplayMode = restoredTwoPageMode
                    }
                    if
                        let rawLayoutMode = tabRecord.gridLayoutMode,
                        let layoutMode = PDFGridLayoutMode(rawValue: rawLayoutMode)
                    {
                        workspace.gridLayoutMode = layoutMode
                    }
                    if
                        let rawWorkspaceMode = tabRecord.workspaceMode,
                        let restoredMode = PDFWorkspaceMode(rawValue: rawWorkspaceMode)
                    {
                        workspace.restoreModeFromSession(restoredMode)
                    }
                    workspace.restorePDFViewport(
                        autoScales: tabRecord.pdfAutoScales,
                        scaleFactor: tabRecord.pdfScaleFactor.map { CGFloat($0) },
                        horizontalScrollProgress: tabRecord.pdfHorizontalScrollProgress.map {
                            CGFloat($0)
                        },
                        verticalScrollProgress: tabRecord.pdfVerticalScrollProgress.map {
                            CGFloat($0)
                        },
                        capturedPageIndex: tabRecord.pdfCapturedPageIndex,
                        navigationMode: tabRecord.pdfPageNavigationMode
                            .flatMap(PDFPageNavigationMode.init(rawValue:)) ?? .verticalScroll
                    )
                    workspace.restorePDFViewport(
                        autoScales: tabRecord.comparisonPDFAutoScales,
                        scaleFactor: tabRecord.comparisonPDFScaleFactor.map { CGFloat($0) },
                        horizontalScrollProgress: tabRecord
                            .comparisonPDFHorizontalScrollProgress.map { CGFloat($0) },
                        verticalScrollProgress: tabRecord
                            .comparisonPDFVerticalScrollProgress.map { CGFloat($0) },
                        capturedPageIndex: tabRecord.comparisonPDFCapturedPageIndex,
                        context: .comparison
                    )
                    workspace.restorePageFitMode(
                        tabRecord.pdfPageFitMode.flatMap(PDFPageFitMode.init(rawValue:))
                    )
                    sessions.append(PDFTabSession(id: tabRecord.id, workspace: workspace))

                    if resolution.isStale {
                        do {
                            let refreshed = try withExtendedLifetime(scopedAccess) {
                                try bookmarkCoder.makeBookmark(for: resolution.url)
                            }
                            archive.workspaces[workspaceIndex].tabs[tabIndex].document?.bookmark = refreshed
                            bookmarkCache[documentKey] = refreshed
                            refreshedAStaleBookmark = true
                        } catch {
                            // The resolved scoped URL is already live in the
                            // PDF workspace. Bookmark maintenance must not turn
                            // a successful restore into a failure.
                            bookmarkCache[documentKey] = documentRecord.bookmark
                        }
                    } else {
                        bookmarkCache[documentKey] = documentRecord.bookmark
                    }
                } catch {
                    // Never fall back to lastKnownPath: a damaged or denied
                    // security-scoped bookmark means this one tab is skipped.
                    unavailableDocumentCount += 1
                }
            }

            if sessions.isEmpty {
                let replacementID = UUID()
                seenTabIDs.insert(replacementID)
                sessions = [PDFTabSession(id: replacementID)]
            }

            let validTabIDs = sessions.map(\.id)
            let groups = PDFTabGroupRules.normalizedGroups(
                record.groups.map {
                    PDFTabGroup(
                        id: $0.id,
                        title: $0.title,
                        tabIDs: $0.tabIDs,
                        isCollapsed: $0.isCollapsed
                    )
                },
                validTabIDs: validTabIDs
            )
            let fallbackTitle = PDFDocumentWorkspaceRules.defaultTitle(
                at: restoredWorkspaces.count
            )
            restoredWorkspaces.append(
                PDFDocumentWorkspace(
                    id: record.id,
                    title: PDFDocumentWorkspaceRules.normalizedTitle(
                        record.title,
                        fallback: fallbackTitle
                    ),
                    tabs: sessions,
                    activeTabID: record.activeTabID.flatMap { requested in
                        validTabIDs.contains(requested) ? requested : nil
                    } ?? validTabIDs.first,
                    tabGroups: groups
                )
            )
        }

        guard !restoredWorkspaces.isEmpty else {
            lastError = unavailableDocumentCount > 0
                ? .partiallyRestored(unavailableDocumentCount: unavailableDocumentCount)
                : .corrupted
            return nil
        }

        if refreshedAStaleBookmark {
            do {
                try write(archive)
            } catch {
                lastError = .writeFailed(error.localizedDescription)
            }
        }
        lastArchive = archive
        if unavailableDocumentCount > 0 {
            lastError = .partiallyRestored(
                unavailableDocumentCount: unavailableDocumentCount
            )
        } else if !refreshedAStaleBookmark || lastError == nil {
            lastError = nil
        }

        let activeWorkspaceID = archive.activeWorkspaceID.flatMap { requested in
            restoredWorkspaces.contains(where: { $0.id == requested }) ? requested : nil
        } ?? restoredWorkspaces[0].id
        let topology = normalizedTopology(
            archive.windowTopology,
            legacyDetachedWorkspaceIDs: archive.detachedWorkspaceIDs,
            restoredWorkspaces: restoredWorkspaces
        )
        let workspaceByID = Dictionary(
            uniqueKeysWithValues: restoredWorkspaces.map { ($0.id, $0) }
        )
        let comparisons: [WorkspaceSessionArchive.ComparisonRecord]? =
            archive.comparisonRecords?.compactMap { record -> WorkspaceSessionArchive.ComparisonRecord? in
            guard let descriptor = workspaceByID[record.workspaceID] else { return nil }
            return record.normalized(
                validDocumentIDs: Set(descriptor.tabs.map(\.id))
            )
        }
        lastRestoredWindowTopology = topology
        lastRestoredComparisonRecords = comparisons
        return RestoredWorkspaceSession(
            workspaces: restoredWorkspaces,
            activeWorkspaceID: activeWorkspaceID,
            windowTopology: topology,
            comparisonRecords: comparisons
        )
    }

    @discardableResult
    func save(
        _ workspace: MultiDocumentWorkspaceState,
        appending additionalWindowWorkspaces: [MultiDocumentWorkspaceState] = []
    ) -> Bool {
        do {
            let appSnapshot = resolvedAppSnapshot(
                explicitlyAppending: additionalWindowWorkspaces
            )
            let archive = try makeArchive(
                for: workspace,
                detachedWindows: appSnapshot.detachedWindows,
                comparisonRecords: appSnapshot.comparisonRecords
            )
            try write(archive)
            lastArchive = archive
            lastRestoredWindowTopology = archive.windowTopology
            lastRestoredComparisonRecords = archive.comparisonRecords
            lastError = nil
            return true
        } catch {
            lastError = .writeFailed(error.localizedDescription)
            return false
        }
    }

    /// Adds or refreshes detached-window workspaces on top of the last valid
    /// main-window archive. This is used when the main window was already red-
    /// closed and its live PDF models have since been torn down; rebuilding
    /// from that reset model would otherwise erase the preserved base session.
    @discardableResult
    func mergeDetachedWindowWorkspaces(
        _ windowWorkspaces: [MultiDocumentWorkspaceState]
    ) -> Bool {
        do {
            var archive: WorkspaceSessionArchive
            if let lastArchive {
                archive = lastArchive
            } else if
                let data = try persistence.read(),
                let decoded = try? JSONDecoder().decode(WorkspaceSessionArchive.self, from: data),
                decoded.schemaVersion == WorkspaceSessionArchive.currentSchemaVersion
            {
                archive = decoded
            } else {
                let firstWorkspaceID = windowWorkspaces.first?.activeWorkspaceID
                archive = WorkspaceSessionArchive(
                    activeWorkspaceID: firstWorkspaceID,
                    workspaces: []
                )
            }

            let appSnapshot = resolvedAppSnapshot(
                explicitlyAppending: windowWorkspaces
            )
            let records = try makeRecords(
                from: appSnapshot.detachedWindows.flatMap { $0.workspace.workspaces }
            )
            let currentDetachedIDs = Set(records.map(\.id))
            let previousDetachedIDs = Set(archive.detachedWorkspaceIDs)
            archive.workspaces.removeAll { record in
                previousDetachedIDs.contains(record.id)
                    && !currentDetachedIDs.contains(record.id)
            }
            for record in records {
                if let existingIndex = archive.workspaces.firstIndex(where: { $0.id == record.id }) {
                    archive.workspaces[existingIndex] = record
                } else {
                    archive.workspaces.append(record)
                }
            }
            archive.detachedWorkspaceIDs = records.map(\.id)
            archive.windowTopology = WorkspaceSessionArchive.WindowTopologyRecord(
                mainWorkspaceIDs: archive.windowTopology?.mainWorkspaceIDs
                    ?? archive.workspaces.map(\.id).filter { !currentDetachedIDs.contains($0) },
                detachedWindows: appSnapshot.detachedWindows.map {
                    WorkspaceSessionArchive.WindowTopologyRecord.DetachedWindowRecord(
                        windowID: $0.windowID,
                        workspaceIDs: $0.workspace.workspaces.map(\.id),
                        activeWorkspaceID: $0.workspace.activeWorkspaceID
                    )
                }
            )
            if let comparisonRecords = appSnapshot.comparisonRecords {
                archive.comparisonRecords = normalizedComparisonRecords(
                    comparisonRecords,
                    workspaceRecords: archive.workspaces
                )
            }
            try write(archive)
            lastArchive = archive
            lastRestoredWindowTopology = archive.windowTopology
            lastRestoredComparisonRecords = archive.comparisonRecords
            lastError = nil
            return true
        } catch {
            lastError = .writeFailed(error.localizedDescription)
            return false
        }
    }

    private func makeArchive(
        for workspace: MultiDocumentWorkspaceState,
        detachedWindows: [WorkspaceSessionDetachedWindowSnapshot],
        comparisonRecords: [WorkspaceSessionArchive.ComparisonRecord]?
    ) throws -> WorkspaceSessionArchive {
        let allDescriptors = workspace.workspaces
            + detachedWindows.flatMap { $0.workspace.workspaces }
        let records = try makeRecords(from: allDescriptors)
        let detachedIDs = detachedWindows.flatMap { $0.workspace.workspaces.map(\.id) }
        let currentMainIDs = workspace.workspaces.map(\.id)

        // Until the WindowGroup restore bridge consumes a persisted topology,
        // restored detached descriptors temporarily live in the main model.
        // Preserve their provenance instead of flattening it on the first
        // routine main-workspace debounce.
        let preservedTopology: WorkspaceSessionArchive.WindowTopologyRecord?
        if
            detachedWindows.isEmpty,
            let previousTopology = lastArchive?.windowTopology,
            !previousTopology.detachedWindows.isEmpty,
            Set(currentMainIDs).isSuperset(of: Set(lastArchive?.detachedWorkspaceIDs ?? []))
        {
            preservedTopology = previousTopology
        } else {
            preservedTopology = nil
        }

        return WorkspaceSessionArchive(
            activeWorkspaceID: workspace.activeWorkspaceID,
            workspaces: records,
            detachedWorkspaceIDs: preservedTopology == nil
                ? detachedIDs
                : lastArchive?.detachedWorkspaceIDs ?? detachedIDs,
            windowTopology: preservedTopology ?? WorkspaceSessionArchive.WindowTopologyRecord(
                mainWorkspaceIDs: currentMainIDs,
                detachedWindows: detachedWindows.map {
                    WorkspaceSessionArchive.WindowTopologyRecord.DetachedWindowRecord(
                        windowID: $0.windowID,
                        workspaceIDs: $0.workspace.workspaces.map(\.id),
                        activeWorkspaceID: $0.workspace.activeWorkspaceID
                    )
                }
            ),
            comparisonRecords: comparisonRecords.map {
                normalizedComparisonRecords($0, workspaceRecords: records)
            } ?? lastArchive?.comparisonRecords
        )
    }

    private func resolvedAppSnapshot(
        explicitlyAppending workspaces: [MultiDocumentWorkspaceState]
    ) -> WorkspaceSessionAppSnapshot {
        if let appSnapshotProvider {
            return appSnapshotProvider.workspaceSessionAppSnapshot()
        }
        return WorkspaceSessionAppSnapshot(
            detachedWindows: workspaces.map {
                WorkspaceSessionDetachedWindowSnapshot(
                    windowID: $0.activeWorkspaceID,
                    workspace: $0
                )
            },
            comparisonRecords: nil
        )
    }

    private func makeRecords(
        from allDescriptors: [PDFDocumentWorkspace]
    ) throws -> [WorkspaceSessionArchive.WorkspaceRecord] {
        var seenWorkspaceIDs: Set<UUID> = []
        let records: [WorkspaceSessionArchive.WorkspaceRecord] = try allDescriptors.compactMap {
            descriptor -> WorkspaceSessionArchive.WorkspaceRecord? in
            guard seenWorkspaceIDs.insert(descriptor.id).inserted else { return nil }
            return WorkspaceSessionArchive.WorkspaceRecord(
                id: descriptor.id,
                title: descriptor.title,
                activeTabID: descriptor.activeTabID,
                tabs: try descriptor.tabs.map { session in
                    let comparisonViewport = session.workspace.pdfViewportState(
                        for: .comparison
                    )
                    let documentRecord: WorkspaceSessionArchive.DocumentRecord?
                    if session.workspace.hasOpenDocument,
                       let url = session.workspace.sessionDocumentURL {
                        let key = canonicalFileKey(for: url)
                        let bookmark: Data
                        if let cached = bookmarkCache[key] {
                            bookmark = cached
                        } else {
                            bookmark = try bookmarkCoder.makeBookmark(for: url)
                            bookmarkCache[key] = bookmark
                        }
                        documentRecord = .init(
                            bookmark: bookmark,
                            lastKnownPath: url.path,
                            pageCount: session.workspace.pageCount,
                            isImageSource: session.workspace.imageSourceURL != nil ? true : nil,
                            isRecoveryCopy: session.workspace.isRecoveryCopy ? true : nil
                        )
                    } else {
                        documentRecord = nil
                    }
                    return WorkspaceSessionArchive.TabRecord(
                        id: session.id,
                        document: documentRecord,
                        currentPageIndex: session.workspace.currentPageIndex,
                        selectedPages: session.workspace.selectedPages.sorted(),
                        pageColumns: session.workspace.pageColumns,
                        overviewScale: session.workspace.overviewScale,
                        sidebarVisible: session.workspace.sidebarVisible,
                        gridLayoutMode: session.workspace.gridLayoutMode.rawValue,
                        twoPageDisplayMode: session.workspace.twoPageDisplayMode.rawValue,
                        pdfPageNavigationMode: session.workspace.pdfViewportState.navigationMode.rawValue,
                        pdfPageFitMode: session.workspace.pageFitMode?.rawValue,
                        pdfAutoScales: session.workspace.pdfViewportState.autoScales,
                        pdfScaleFactor: session.workspace.pdfViewportState.scaleFactor.map(Double.init),
                        pdfHorizontalScrollProgress: session.workspace.pdfViewportState
                            .horizontalScrollProgress.map(Double.init),
                        pdfVerticalScrollProgress: session.workspace.pdfViewportState
                            .verticalScrollProgress.map(Double.init),
                        pdfCapturedPageIndex: session.workspace.pdfViewportState.capturedPageIndex,
                        comparisonPDFAutoScales: comparisonViewport.autoScales,
                        comparisonPDFScaleFactor: comparisonViewport.scaleFactor.map(Double.init),
                        comparisonPDFHorizontalScrollProgress: comparisonViewport
                            .horizontalScrollProgress.map(Double.init),
                        comparisonPDFVerticalScrollProgress: comparisonViewport
                            .verticalScrollProgress.map(Double.init),
                        comparisonPDFCapturedPageIndex: comparisonViewport.capturedPageIndex,
                        workspaceMode: session.workspace.mode.rawValue
                    )
                },
                groups: descriptor.tabGroups.map {
                    WorkspaceSessionArchive.GroupRecord(
                        id: $0.id,
                        title: $0.title,
                        tabIDs: $0.tabIDs,
                        isCollapsed: $0.isCollapsed
                    )
                }
            )
        }
        return records
    }

    private func write(_ archive: WorkspaceSessionArchive) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try persistence.write(encoder.encode(archive))
    }

    private func normalizedComparisonRecords(
        _ records: [WorkspaceSessionArchive.ComparisonRecord],
        workspaceRecords: [WorkspaceSessionArchive.WorkspaceRecord]
    ) -> [WorkspaceSessionArchive.ComparisonRecord] {
        let validTabIDsByWorkspace = Dictionary(
            uniqueKeysWithValues: workspaceRecords.map { record in
                (record.id, Set(record.tabs.map(\.id)))
            }
        )
        var seenScopes: Set<ComparisonScope> = []
        return records.compactMap { record in
            let scope = ComparisonScope(
                windowID: record.windowID,
                workspaceID: record.workspaceID
            )
            guard
                seenScopes.insert(scope).inserted,
                let validTabIDs = validTabIDsByWorkspace[record.workspaceID]
            else {
                return nil
            }
            return record.normalized(validDocumentIDs: validTabIDs)
        }
    }

    private func normalizedTopology(
        _ topology: WorkspaceSessionArchive.WindowTopologyRecord?,
        legacyDetachedWorkspaceIDs: [UUID],
        restoredWorkspaces: [PDFDocumentWorkspace]
    ) -> WorkspaceSessionArchive.WindowTopologyRecord? {
        let validIDs = Set(restoredWorkspaces.map(\.id))
        guard !validIDs.isEmpty else { return nil }

        let sourceTopology: WorkspaceSessionArchive.WindowTopologyRecord
        if let topology {
            sourceTopology = topology
        } else if !legacyDetachedWorkspaceIDs.isEmpty {
            let detachedSet = Set(legacyDetachedWorkspaceIDs)
            sourceTopology = WorkspaceSessionArchive.WindowTopologyRecord(
                mainWorkspaceIDs: restoredWorkspaces.map(\.id).filter {
                    !detachedSet.contains($0)
                },
                detachedWindows: legacyDetachedWorkspaceIDs.map {
                    WorkspaceSessionArchive.WindowTopologyRecord.DetachedWindowRecord(
                        windowID: $0,
                        workspaceIDs: [$0],
                        activeWorkspaceID: $0
                    )
                }
            )
        } else {
            return nil
        }

        var assignedWorkspaceIDs: Set<UUID> = []
        var mainWorkspaceIDs: [UUID] = []
        for workspaceID in sourceTopology.mainWorkspaceIDs
        where validIDs.contains(workspaceID) && assignedWorkspaceIDs.insert(workspaceID).inserted {
            mainWorkspaceIDs.append(workspaceID)
        }

        var seenWindowIDs: Set<UUID> = []
        var detachedWindows: [WorkspaceSessionArchive.WindowTopologyRecord.DetachedWindowRecord] = []
        for window in sourceTopology.detachedWindows
        where seenWindowIDs.insert(window.windowID).inserted {
            let workspaceIDs = window.workspaceIDs.filter {
                validIDs.contains($0) && assignedWorkspaceIDs.insert($0).inserted
            }
            guard !workspaceIDs.isEmpty else { continue }
            detachedWindows.append(
                .init(
                    windowID: window.windowID,
                    workspaceIDs: workspaceIDs,
                    activeWorkspaceID: window.activeWorkspaceID.flatMap { requested in
                        workspaceIDs.contains(requested) ? requested : nil
                    } ?? workspaceIDs.first
                )
            )
        }

        // Never strand a valid workspace because of incomplete/corrupt
        // topology metadata. Unassigned records safely fall back to main.
        restoredWorkspaces.map(\.id).forEach { workspaceID in
            if assignedWorkspaceIDs.insert(workspaceID).inserted {
                mainWorkspaceIDs.append(workspaceID)
            }
        }
        return WorkspaceSessionArchive.WindowTopologyRecord(
            mainWorkspaceIDs: mainWorkspaceIDs,
            detachedWindows: detachedWindows
        )
    }

    private func canonicalFileKey(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
    }
}

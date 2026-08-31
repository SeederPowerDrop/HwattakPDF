// SPDX-License-Identifier: MPL-2.0

import Foundation

@MainActor
struct PDFDocumentWorkspace: Identifiable {
    let id: UUID
    var title: String
    var tabs: [PDFTabSession]
    var activeTabID: UUID?
    var tabGroups: [PDFTabGroup]

    init(
        id: UUID = UUID(),
        title: String,
        tabs: [PDFTabSession],
        activeTabID: UUID?,
        tabGroups: [PDFTabGroup] = []
    ) {
        self.id = id
        self.title = title
        self.tabs = tabs
        self.activeTabID = activeTabID
        self.tabGroups = tabGroups
    }

    var tabCount: Int { tabs.count }

    var documentCount: Int {
        tabs.count { $0.workspace.hasOpenDocument }
    }

    var hasUnsavedChanges: Bool {
        // A review-sheet draft is intentionally outside the PDF until Apply,
        // but deleting a workspace would still destroy user input. Treat it as
        // unsaved lifecycle state even though it must not make the PDF dirty.
        tabs.contains {
            $0.workspace.isDirty || $0.workspace.hasPendingReviewTextDraft
        }
    }
}

enum PDFDocumentWorkspaceRules {
    static func defaultTitle(at index: Int) -> String {
        let format = L10n.string(
            "workspace.default_name",
            defaultValue: "Workspace %d"
        )
        return String(
            format: format,
            locale: L10n.currentLanguage.locale,
            max(1, index + 1)
        )
    }

    static func normalizedTitle(_ title: String, fallback: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

struct PDFTabGroup: Identifiable, Equatable {
    let id: UUID
    var title: String
    var tabIDs: [UUID]
    var isCollapsed: Bool

    init(
        id: UUID = UUID(),
        title: String,
        tabIDs: [UUID],
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.tabIDs = tabIDs
        self.isCollapsed = isCollapsed
    }
}

enum PDFTabBarEntry: Identifiable, Equatable {
    case tab(UUID)
    case group(PDFTabGroup)

    enum ID: Hashable {
        case tab(UUID)
        case group(UUID)
    }

    var id: ID {
        switch self {
        case let .tab(tabID): .tab(tabID)
        case let .group(group): .group(group.id)
        }
    }

    var tabIDs: [UUID] {
        switch self {
        case let .tab(tabID): [tabID]
        case let .group(group): group.tabIDs
        }
    }
}

enum PDFTabDropIntent: Equatable {
    case before
    case createOrJoinGroup
    case after

    static func resolve(
        locationX: Double,
        width: Double,
        isRightToLeft: Bool = false,
        previousIntent: PDFTabDropIntent? = nil
    ) -> PDFTabDropIntent {
        guard width.isFinite, width > 0, locationX.isFinite else {
            return .createOrJoinGroup
        }
        let physicalPosition = min(1, max(0, locationX / width))
        let previousPhysicalIntent = previousIntent.map { intent in
            logicalToPhysical(for: intent, isRightToLeft: isRightToLeft)
        }
        let physicalIntent: PDFTabDropIntent
        switch previousPhysicalIntent {
        case .before:
            if physicalPosition > 0.84 {
                physicalIntent = .after
            } else if physicalPosition >= 0.26 {
                physicalIntent = .createOrJoinGroup
            } else {
                physicalIntent = .before
            }
        case .after:
            if physicalPosition < 0.16 {
                physicalIntent = .before
            } else if physicalPosition <= 0.74 {
                physicalIntent = .createOrJoinGroup
            } else {
                physicalIntent = .after
            }
        case .createOrJoinGroup:
            if physicalPosition < 0.16 {
                physicalIntent = .before
            } else if physicalPosition > 0.84 {
                physicalIntent = .after
            } else {
                physicalIntent = .createOrJoinGroup
            }
        case nil:
            if physicalPosition < 0.20 {
                physicalIntent = .before
            } else if physicalPosition > 0.80 {
                physicalIntent = .after
            } else {
                physicalIntent = .createOrJoinGroup
            }
        }
        guard isRightToLeft else { return physicalIntent }
        switch physicalIntent {
        case .before: return .after
        case .after: return .before
        case .createOrJoinGroup: return .createOrJoinGroup
        }
    }

    private static func logicalToPhysical(
        for logicalIntent: PDFTabDropIntent,
        isRightToLeft: Bool
    ) -> PDFTabDropIntent {
        guard isRightToLeft else { return logicalIntent }
        switch logicalIntent {
        case .before: return .after
        case .after: return .before
        case .createOrJoinGroup: return .createOrJoinGroup
        }
    }
}

/// Keeps hysteresis local to one visual drop target. Carrying an edge intent
/// from the previous tab into a newly hovered tab makes the new target feel
/// sticky around its center/edge boundary.
enum PDFTabDropState {
    static func continuingIntent(
        currentTargetID: UUID?,
        newTargetID: UUID,
        currentIntent: PDFTabDropIntent?
    ) -> PDFTabDropIntent? {
        currentTargetID == newTargetID ? currentIntent : nil
    }
}

/// Identifies an in-process tab drag. Local state is used only for synchronous
/// hover feedback; the opaque provider contents are authoritative at drop time.
enum PDFTabDragPayload {
    private static let kind = "tab"
    private static let suggestedNamePrefix = "hwattak-tab-"

    static func suggestedName(for tabID: UUID) -> String {
        suggestedNamePrefix + tabID.uuidString
    }

    static func encodedValue(for tabID: UUID) -> String {
        InternalDragPayload.encodedValue(for: tabID, kind: kind)
    }

    static func decode(_ value: String) -> UUID? {
        InternalDragPayload.decode(value, expectedKind: kind)
    }

    static func resolve(
        localTabID: UUID?,
        providerSuggestedNames: [String]
    ) -> UUID? {
        // Local state is intentionally authoritative only for hover feedback.
        // `performDrop` separately decodes the opaque provider contents before
        // it is allowed to mutate the workspace.
        if let localTabID { return localTabID }
        for name in providerSuggestedNames where name.hasPrefix(suggestedNamePrefix) {
            let idValue = String(name.dropFirst(suggestedNamePrefix.count))
            if let tabID = UUID(uuidString: idValue) { return tabID }
        }
        return nil
    }
}

enum PDFTabStripLayout {
    static let mouseWheelLineMultiplier = 12.0

    static func isOverflowing(
        contentWidth: Double,
        trailingActionWidth: Double,
        viewportWidth: Double,
        spacing: Double = 4
    ) -> Bool {
        guard
            contentWidth.isFinite,
            trailingActionWidth.isFinite,
            viewportWidth.isFinite,
            spacing.isFinite,
            viewportWidth > 0
        else {
            return false
        }
        let trailingWidth = trailingActionWidth > 0
            ? max(0, trailingActionWidth) + max(0, spacing)
            : 0
        return max(0, contentWidth) + trailingWidth > viewportWidth
    }

    static func steppedIndex(
        from index: Int,
        offset: Int,
        itemCount: Int
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        return min(max(0, index + offset), itemCount - 1)
    }

    /// Converts an ordinary vertical wheel gesture into the content-space
    /// horizontal delta used by the tab strip. Native horizontal gestures and
    /// modified wheel shortcuts remain owned by AppKit.
    static func mappedHorizontalWheelDelta(
        deltaX: Double,
        deltaY: Double,
        hasPreciseDeltas: Bool,
        hasBlockingModifier: Bool
    ) -> Double? {
        guard
            !hasBlockingModifier,
            deltaX.isFinite,
            deltaY.isFinite,
            abs(deltaY) > 0.0001,
            abs(deltaY) >= abs(deltaX)
        else {
            return nil
        }

        let combinedDelta: Double
        if deltaX == 0 || deltaX.sign != deltaY.sign {
            // Opposing diagonal jitter must not reverse or cancel the user's
            // dominant vertical direction.
            combinedDelta = deltaY
        } else {
            combinedDelta = deltaX + deltaY
        }
        let multiplier = hasPreciseDeltas ? 1 : mouseWheelLineMultiplier
        return combinedDelta * multiplier
    }
}

enum PDFTabGroupRules {
    static var fallbackTitle: String { L10n.string("tab.default_group") }

    static func normalizedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackTitle : trimmed
    }

    static func normalizedGroups(
        _ groups: [PDFTabGroup],
        validTabIDs: [UUID]
    ) -> [PDFTabGroup] {
        let validIDs = Set(validTabIDs)
        let tabOrder = Dictionary(
            uniqueKeysWithValues: validTabIDs.enumerated().map { ($0.element, $0.offset) }
        )
        var seenGroupIDs: Set<UUID> = []
        var assignedTabIDs: Set<UUID> = []
        var result: [PDFTabGroup] = []

        for var group in groups {
            guard seenGroupIDs.insert(group.id).inserted else { continue }

            var seenInGroup: Set<UUID> = []
            group.tabIDs = group.tabIDs.filter { tabID in
                guard validIDs.contains(tabID) else { return false }
                guard seenInGroup.insert(tabID).inserted else { return false }
                return assignedTabIDs.insert(tabID).inserted
            }
            group.tabIDs.sort {
                tabOrder[$0, default: .max] < tabOrder[$1, default: .max]
            }
            guard !group.tabIDs.isEmpty else { continue }

            group.title = normalizedTitle(group.title)
            result.append(group)
        }
        result.sort {
            let lhsIndex = $0.tabIDs.compactMap { tabOrder[$0] }.min() ?? .max
            let rhsIndex = $1.tabIDs.compactMap { tabOrder[$0] }.min() ?? .max
            return lhsIndex < rhsIndex
        }
        return result
    }
}

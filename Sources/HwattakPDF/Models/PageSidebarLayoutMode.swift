// SPDX-License-Identifier: MPL-2.0

import Foundation

enum PageSidebarLayoutMode: String, CaseIterable, Identifiable {
    case single
    case facingPages
    case fourPages

    var id: String { rawValue }

    var pagesPerGroup: Int {
        switch self {
        case .single: 1
        case .facingPages: 2
        case .fourPages: 4
        }
    }

    var title: String {
        switch self {
        case .single:
            L10n.string("page.sidebar.layout.single", defaultValue: "1페이지")
        case .facingPages:
            L10n.string("page.sidebar.layout.facing", defaultValue: "좌우 2페이지")
        case .fourPages:
            L10n.string("page.sidebar.layout.four", defaultValue: "4페이지")
        }
    }

    var symbolName: String {
        switch self {
        case .single: "rectangle.portrait"
        case .facingPages: "rectangle.split.2x1"
        case .fourPages: "square.grid.2x2"
        }
    }

    /// Facing pages intentionally start with pages 1 and 2. The sidebar is a
    /// page-management overview, so it does not reserve a blank verso for a
    /// cover the way some reading views do.
    func groups(pageCount: Int) -> [PageSidebarPageGroup] {
        let safePageCount = max(0, pageCount)
        guard safePageCount > 0 else { return [] }

        return stride(from: 0, to: safePageCount, by: pagesPerGroup).map { startIndex in
            let slots = (0..<pagesPerGroup).map { offset -> Int? in
                let pageIndex = startIndex + offset
                return pageIndex < safePageCount ? pageIndex : nil
            }
            return PageSidebarPageGroup(startIndex: startIndex, slots: slots)
        }
    }

    /// Follow visible neighbors first. If that direction has no thumbnail,
    /// continue to the previous/next page so all four arrows remain useful in
    /// a single row/column and across group edges. Only document ends stop
    /// navigation; empty trailing slots are never selectable.
    func navigationTarget(
        from pageIndex: Int,
        direction: PageSidebarNavigationDirection,
        placement: PageOverviewPlacement,
        pageCount: Int,
        isRightToLeft: Bool
    ) -> Int? {
        guard pageIndex >= 0, pageIndex < pageCount else { return nil }
        let columns = placement.usesHorizontalPageStrip
            ? pageCount
            : (self == .single ? 1 : 2)
        let offset: Int
        switch direction {
        case .up:
            offset = pageIndex >= columns ? -columns : -1
        case .down:
            offset = columns < pageCount - pageIndex ? columns : 1
        case .left, .right:
            let movesForward = (direction == .right) != isRightToLeft
            offset = movesForward ? 1 : -1
        }
        guard offset < 0 ? pageIndex >= -offset : offset < pageCount - pageIndex else {
            return nil
        }
        return pageIndex + offset
    }
}

enum PageSidebarNavigationDirection: CaseIterable {
    case up, down, left, right
}

struct PageSidebarPageGroup: Identifiable, Equatable {
    let startIndex: Int
    let slots: [Int?]

    var id: Int { startIndex }
    var pageIndices: [Int] { slots.compactMap { $0 } }
}

enum PageSidebarPreferences {
    static let layoutModeKey = "pageSidebar.layoutMode"
    static let thumbnailScaleKey = "pageSidebar.thumbnailScale"
    static let verticalPanelWidthKey = "pageSidebar.verticalPanelWidth"
    static let horizontalPanelHeightKey = "pageSidebar.horizontalPanelHeight"
    static let compactHorizontalPanelMigrationKey =
        "pageSidebar.compactHorizontalPanelHeightMigrationV1"

    static let defaultThumbnailScale = 1.0
    static let minimumThumbnailScale = 0.65
    static let maximumThumbnailScale = 1.35
    static let thumbnailScaleStep = 0.1

    static func clampedThumbnailScale(_ value: Double) -> Double {
        guard value.isFinite else { return defaultThumbnailScale }
        return min(maximumThumbnailScale, max(minimumThumbnailScale, value))
    }

    static func adjustedThumbnailScale(_ value: Double, steps: Int) -> Double {
        clampedThumbnailScale(value + Double(steps) * thumbnailScaleStep)
    }

    static func minimumVerticalPanelWidth(
        layoutMode: PageSidebarLayoutMode,
        thumbnailScale: Double
    ) -> Double {
        let scale = clampedThumbnailScale(thumbnailScale)
        let slotCount = layoutMode == .single ? 1.0 : 2.0
        let baseThumbnailWidth = layoutMode == .single ? 148.0 : 72.0
        let slotWidth = baseThumbnailWidth * scale + 16
        let groupSpacing = layoutMode == .single ? 0 : 6
        let groupPadding = layoutMode == .single ? 0 : 10
        let scrollerPadding = 26.0
        let contentWidth = slotWidth * slotCount
            + Double(groupSpacing + groupPadding)
            + scrollerPadding
        let universalMinimum = layoutMode == .single ? 196.0 : 220.0
        return max(universalMinimum, contentWidth)
    }

    static func minimumHorizontalPanelHeight(
        layoutMode: PageSidebarLayoutMode,
        thumbnailScale: Double
    ) -> Double {
        let baseThumbnailWidth = layoutMode == .single ? 108.0 : 72.0
        let metrics = PageSidebarLayoutMetrics.horizontalPanel(
            thumbnailWidth: baseThumbnailWidth * clampedThumbnailScale(thumbnailScale),
            isGrouped: layoutMode != .single
        )
        return max(
            PageSidebarLayoutMetrics.minimumHorizontalPanelHeight,
            metrics.estimatedThumbnailCardHeight
        )
    }
}

/// Pure sizing policy shared by the resize gesture, window-resize clamping,
/// and keyboard/accessibility adjustments.
struct PageSidebarResizeMetrics {
    static let defaultVerticalPanelWidth = 224.0
    static let legacyDefaultHorizontalPanelHeight = 224.0
    static let defaultHorizontalPanelHeight = 188.0
    static let maximumVerticalPanelWidth = 520.0
    static let maximumHorizontalPanelHeight = 440.0
    static let minimumDocumentWidth = 420.0
    static let minimumDocumentHeight = 260.0
    static let dividerHitLength = 10.0
    static let keyboardStep = 20.0

    static func migratedHorizontalPanelHeight(
        _ storedHeight: Double,
        migrationCompleted: Bool
    ) -> Double {
        guard storedHeight.isFinite else { return defaultHorizontalPanelHeight }
        guard
            !migrationCompleted,
            abs(storedHeight - legacyDefaultHorizontalPanelHeight) < 0.001
        else {
            return storedHeight
        }
        return defaultHorizontalPanelHeight
    }

    static func defaultDimension(for placement: PageOverviewPlacement) -> Double {
        placement.usesHorizontalPageStrip
            ? defaultHorizontalPanelHeight
            : defaultVerticalPanelWidth
    }

    static func maximumDimension(for placement: PageOverviewPlacement) -> Double {
        placement.usesHorizontalPageStrip
            ? maximumHorizontalPanelHeight
            : maximumVerticalPanelWidth
    }

    static func minimumDocumentDimension(for placement: PageOverviewPlacement) -> Double {
        placement.usesHorizontalPageStrip ? minimumDocumentHeight : minimumDocumentWidth
    }

    static func minimumPanelDimension(
        for placement: PageOverviewPlacement,
        layoutMode: PageSidebarLayoutMode,
        thumbnailScale: Double
    ) -> Double {
        if placement.usesHorizontalPageStrip {
            return PageSidebarPreferences.minimumHorizontalPanelHeight(
                layoutMode: layoutMode,
                thumbnailScale: thumbnailScale
            )
        }
        return PageSidebarPreferences.minimumVerticalPanelWidth(
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale
        )
    }

    /// Keeps the canvas usable as the window shrinks. The WorkspaceView also
    /// advertises a matching minimum size, so the minimum panel and canvas
    /// dimensions can normally both be honored.
    static func resolvedDimension(
        preferredDimension: Double,
        placement: PageOverviewPlacement,
        availableLength: Double,
        layoutMode: PageSidebarLayoutMode,
        thumbnailScale: Double,
        minimumDimensionOverride: Double? = nil
    ) -> Double {
        let fallback = defaultDimension(for: placement)
        let preferred = preferredDimension.isFinite ? preferredDimension : fallback
        let minimum = minimumDimensionOverride.flatMap { override in
            override.isFinite ? max(0, override) : nil
        } ?? minimumPanelDimension(
            for: placement,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale
        )
        let staticMaximum = maximumDimension(for: placement)
        let minimumDocument = minimumDocumentDimension(for: placement)
        let viewportMaximum: Double
        if availableLength.isFinite {
            viewportMaximum = max(
                minimum,
                availableLength - minimumDocument - dividerHitLength
            )
        } else {
            viewportMaximum = staticMaximum
        }
        let maximum = max(minimum, min(staticMaximum, viewportMaximum))
        return min(maximum, max(minimum, preferred))
    }

    static func resizedDimension(
        startingDimension: Double,
        translation: Double,
        placement: PageOverviewPlacement,
        availableLength: Double,
        layoutMode: PageSidebarLayoutMode,
        thumbnailScale: Double,
        minimumDimensionOverride: Double? = nil
    ) -> Double {
        let safeTranslation = translation.isFinite ? translation : 0
        let signedTranslation: Double
        switch placement {
        case .left, .top:
            signedTranslation = safeTranslation
        case .right, .bottom:
            signedTranslation = -safeTranslation
        }
        return resolvedDimension(
            preferredDimension: startingDimension + signedTranslation,
            placement: placement,
            availableLength: availableLength,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale,
            minimumDimensionOverride: minimumDimensionOverride
        )
    }

    static func adjustedDimension(
        _ currentDimension: Double,
        steps: Int,
        placement: PageOverviewPlacement,
        availableLength: Double,
        layoutMode: PageSidebarLayoutMode,
        thumbnailScale: Double,
        minimumDimensionOverride: Double? = nil
    ) -> Double {
        resolvedDimension(
            preferredDimension: currentDimension + Double(steps) * keyboardStep,
            placement: placement,
            availableLength: availableLength,
            layoutMode: layoutMode,
            thumbnailScale: thumbnailScale,
            minimumDimensionOverride: minimumDimensionOverride
        )
    }
}

struct PageSidebarLayoutMetrics: Equatable {
    static let defaultHorizontalPanelHeight = 188.0
    static let minimumHorizontalPanelHeight = 188.0
    static let defaultMaximumHorizontalPanelHeight = 276.0
    static let horizontalScrollerTopPadding = 8.0
    static let horizontalScrollerBottomPadding = 8.0

    let idealHorizontalPanelHeight: Double
    let maximumHorizontalPanelHeight: Double
    let estimatedThumbnailCardHeight: Double

    static func horizontalPanel(
        thumbnailWidth: Double,
        maximumPageAspect: Double = 1.414,
        isGrouped: Bool
    ) -> PageSidebarLayoutMetrics {
        let safeWidth = thumbnailWidth.isFinite ? max(1, thumbnailWidth) : 108
        let safeAspect = maximumPageAspect.isFinite ? max(0.1, maximumPageAspect) : 1.414
        // Image + PageThumbnailView's label spacing/line + page button padding
        // + ScrollView padding. Grouped cards add their own 5pt top/bottom.
        let estimatedCardHeight = safeWidth * safeAspect
            + 9 + 14
            + 16
            + horizontalScrollerTopPadding + horizontalScrollerBottomPadding
            + (isGrouped ? 10 : 0)
        let idealHeight = min(380, max(defaultHorizontalPanelHeight, estimatedCardHeight))
        let maximumHeight = max(
            defaultMaximumHorizontalPanelHeight,
            min(420, idealHeight + 24)
        )
        return PageSidebarLayoutMetrics(
            idealHorizontalPanelHeight: idealHeight,
            maximumHorizontalPanelHeight: maximumHeight,
            estimatedThumbnailCardHeight: estimatedCardHeight
        )
    }
}

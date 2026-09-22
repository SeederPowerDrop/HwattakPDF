// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

final class PageSidebarLayoutModeTests: XCTestCase {
    func testFacingPagesPairFirstAndSecondPagesWithoutAReservedCoverSlot() {
        let groups = PageSidebarLayoutMode.facingPages.groups(pageCount: 5)

        XCTAssertEqual(groups.map(\.slots), [
            [0, 1],
            [2, 3],
            [4, nil]
        ])
        XCTAssertEqual(groups.map(\.pageIndices), [[0, 1], [2, 3], [4]])
    }

    func testFourPageGroupsKeepFixedNonPageSlotsInLastCard() {
        let groups = PageSidebarLayoutMode.fourPages.groups(pageCount: 6)

        XCTAssertEqual(groups.map(\.slots), [
            [0, 1, 2, 3],
            [4, 5, nil, nil]
        ])
        XCTAssertEqual(groups.map(\.id), [0, 4])
        XCTAssertEqual(groups.last?.pageIndices, [4, 5])
    }

    func testSinglePageGroupsPreserveEveryPageIndex() {
        let groups = PageSidebarLayoutMode.single.groups(pageCount: 4)

        XCTAssertEqual(groups.map(\.slots), [[0], [1], [2], [3]])
        XCTAssertEqual(groups.flatMap(\.pageIndices), [0, 1, 2, 3])
    }

    func testGroupingAnEmptyOrNegativePageCountIsSafe() {
        for mode in PageSidebarLayoutMode.allCases {
            XCTAssertTrue(mode.groups(pageCount: 0).isEmpty)
            XCTAssertTrue(mode.groups(pageCount: -3).isEmpty)
        }
    }

    func testThumbnailScaleClampsInvalidAndOutOfRangeValues() {
        XCTAssertEqual(PageSidebarPreferences.clampedThumbnailScale(.nan), 1)
        XCTAssertEqual(PageSidebarPreferences.clampedThumbnailScale(.infinity), 1)
        XCTAssertEqual(PageSidebarPreferences.clampedThumbnailScale(0.1), 0.65)
        XCTAssertEqual(PageSidebarPreferences.clampedThumbnailScale(2), 1.35)
        XCTAssertEqual(PageSidebarPreferences.clampedThumbnailScale(1.15), 1.15)
    }

    func testThumbnailScaleButtonsStepAndClampAtBothLimits() {
        XCTAssertEqual(
            PageSidebarPreferences.adjustedThumbnailScale(1, steps: 1),
            1.1,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PageSidebarPreferences.adjustedThumbnailScale(0.67, steps: -1),
            0.65,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PageSidebarPreferences.adjustedThumbnailScale(1.32, steps: 1),
            1.35,
            accuracy: 0.0001
        )
    }

    func testHorizontalPanelExpandsEnoughForMaximumScaleA4ThumbnailAndPageNumber() {
        let thumbnailWidth = 108 * PageSidebarPreferences.maximumThumbnailScale
        let metrics = PageSidebarLayoutMetrics.horizontalPanel(
            thumbnailWidth: thumbnailWidth,
            maximumPageAspect: 1.414,
            isGrouped: false
        )

        XCTAssertGreaterThan(metrics.idealHorizontalPanelHeight, 224)
        XCTAssertGreaterThanOrEqual(
            metrics.idealHorizontalPanelHeight,
            metrics.estimatedThumbnailCardHeight
        )
        XCTAssertGreaterThanOrEqual(
            metrics.maximumHorizontalPanelHeight,
            metrics.idealHorizontalPanelHeight
        )
    }

    func testHorizontalPanelUsesCompactContentFittedDefaults() {
        let scale = 0.9
        let metrics = PageSidebarLayoutMetrics.horizontalPanel(
            thumbnailWidth: 108 * scale,
            maximumPageAspect: 1.414,
            isGrouped: false
        )
        let minimum = PageSidebarPreferences.minimumHorizontalPanelHeight(
            layoutMode: .single,
            thumbnailScale: scale
        )

        XCTAssertEqual(PageSidebarResizeMetrics.defaultHorizontalPanelHeight, 188)
        XCTAssertEqual(PageSidebarLayoutMetrics.defaultHorizontalPanelHeight, 188)
        XCTAssertEqual(PageSidebarLayoutMetrics.horizontalScrollerTopPadding, 8)
        XCTAssertEqual(PageSidebarLayoutMetrics.horizontalScrollerBottomPadding, 8)
        XCTAssertEqual(metrics.estimatedThumbnailCardHeight, 192.4408, accuracy: 0.001)
        XCTAssertEqual(minimum, metrics.estimatedThumbnailCardHeight, accuracy: 0.001)
        XCTAssertLessThan(minimum, PageSidebarResizeMetrics.legacyDefaultHorizontalPanelHeight)
    }

    func testLegacyHorizontalPanelHeightMigratesOnceWithoutOverwritingCustomSizing() {
        XCTAssertEqual(
            PageSidebarResizeMetrics.migratedHorizontalPanelHeight(
                PageSidebarResizeMetrics.legacyDefaultHorizontalPanelHeight,
                migrationCompleted: false
            ),
            PageSidebarResizeMetrics.defaultHorizontalPanelHeight
        )
        XCTAssertEqual(
            PageSidebarResizeMetrics.migratedHorizontalPanelHeight(
                260,
                migrationCompleted: false
            ),
            260
        )
        XCTAssertEqual(
            PageSidebarResizeMetrics.migratedHorizontalPanelHeight(
                PageSidebarResizeMetrics.legacyDefaultHorizontalPanelHeight,
                migrationCompleted: true
            ),
            PageSidebarResizeMetrics.legacyDefaultHorizontalPanelHeight
        )
        XCTAssertEqual(
            PageSidebarResizeMetrics.migratedHorizontalPanelHeight(
                .nan,
                migrationCompleted: true
            ),
            PageSidebarResizeMetrics.defaultHorizontalPanelHeight
        )
    }

    func testResizePreferenceKeysKeepWidthAndHeightIndependent() {
        XCTAssertNotEqual(
            PageSidebarPreferences.verticalPanelWidthKey,
            PageSidebarPreferences.horizontalPanelHeightKey
        )
        XCTAssertEqual(
            PageSidebarResizeMetrics.defaultDimension(for: .left),
            PageSidebarResizeMetrics.defaultVerticalPanelWidth
        )
        XCTAssertEqual(
            PageSidebarResizeMetrics.defaultDimension(for: .top),
            PageSidebarResizeMetrics.defaultHorizontalPanelHeight
        )
    }

    func testVerticalMinimumGrowsWithGroupedLargeThumbnails() {
        let singleMinimum = PageSidebarPreferences.minimumVerticalPanelWidth(
            layoutMode: .single,
            thumbnailScale: 1
        )
        let groupedMinimum = PageSidebarPreferences.minimumVerticalPanelWidth(
            layoutMode: .fourPages,
            thumbnailScale: PageSidebarPreferences.maximumThumbnailScale
        )

        XCTAssertGreaterThanOrEqual(singleMinimum, 196)
        XCTAssertGreaterThanOrEqual(groupedMinimum, 220)
        XCTAssertGreaterThan(groupedMinimum, singleMinimum)
    }

    func testResizeDragSignsFollowPhysicalPlacement() {
        let commonArguments = (
            availableLength: 1_200.0,
            layoutMode: PageSidebarLayoutMode.single,
            thumbnailScale: 1.0
        )
        let left = PageSidebarResizeMetrics.resizedDimension(
            startingDimension: 260,
            translation: 40,
            placement: .left,
            availableLength: commonArguments.availableLength,
            layoutMode: commonArguments.layoutMode,
            thumbnailScale: commonArguments.thumbnailScale
        )
        let right = PageSidebarResizeMetrics.resizedDimension(
            startingDimension: 260,
            translation: 40,
            placement: .right,
            availableLength: commonArguments.availableLength,
            layoutMode: commonArguments.layoutMode,
            thumbnailScale: commonArguments.thumbnailScale
        )
        let top = PageSidebarResizeMetrics.resizedDimension(
            startingDimension: 260,
            translation: 40,
            placement: .top,
            availableLength: 900,
            layoutMode: commonArguments.layoutMode,
            thumbnailScale: commonArguments.thumbnailScale
        )
        let bottom = PageSidebarResizeMetrics.resizedDimension(
            startingDimension: 260,
            translation: 40,
            placement: .bottom,
            availableLength: 900,
            layoutMode: commonArguments.layoutMode,
            thumbnailScale: commonArguments.thumbnailScale
        )

        XCTAssertEqual(left, 300)
        XCTAssertEqual(right, 220)
        XCTAssertEqual(top, 300)
        XCTAssertEqual(bottom, 220)
    }

    func testResizeUsesGestureBaselineInsteadOfAccumulatingTranslations() {
        let firstUpdate = PageSidebarResizeMetrics.resizedDimension(
            startingDimension: 240,
            translation: 20,
            placement: .left,
            availableLength: 1_200,
            layoutMode: .single,
            thumbnailScale: 1
        )
        let laterUpdate = PageSidebarResizeMetrics.resizedDimension(
            startingDimension: 240,
            translation: 40,
            placement: .left,
            availableLength: 1_200,
            layoutMode: .single,
            thumbnailScale: 1
        )

        XCTAssertEqual(firstUpdate, 260)
        XCTAssertEqual(laterUpdate, 280)
    }

    func testWindowResizeClampsVisibleWidthWhileAllowingPreferredWidthWhenRoomReturns() {
        let constrained = PageSidebarResizeMetrics.resolvedDimension(
            preferredDimension: 500,
            placement: .left,
            availableLength: 800,
            layoutMode: .single,
            thumbnailScale: 1
        )
        let roomy = PageSidebarResizeMetrics.resolvedDimension(
            preferredDimension: 500,
            placement: .left,
            availableLength: 1_200,
            layoutMode: .single,
            thumbnailScale: 1
        )

        XCTAssertEqual(
            constrained,
            800 - PageSidebarResizeMetrics.minimumDocumentWidth
                - PageSidebarResizeMetrics.dividerHitLength
        )
        XCTAssertEqual(roomy, 500)
    }

    func testResizeClampsInvalidValuesAndKeyboardAdjustments() {
        let invalid = PageSidebarResizeMetrics.resolvedDimension(
            preferredDimension: .nan,
            placement: .left,
            availableLength: .infinity,
            layoutMode: .single,
            thumbnailScale: 1
        )
        let minimum = PageSidebarResizeMetrics.adjustedDimension(
            196,
            steps: -100,
            placement: .left,
            availableLength: 1_200,
            layoutMode: .single,
            thumbnailScale: 1
        )
        let maximum = PageSidebarResizeMetrics.adjustedDimension(
            500,
            steps: 100,
            placement: .left,
            availableLength: 2_000,
            layoutMode: .single,
            thumbnailScale: 1
        )

        XCTAssertEqual(invalid, PageSidebarResizeMetrics.defaultVerticalPanelWidth)
        XCTAssertEqual(minimum, 196)
        XCTAssertEqual(maximum, PageSidebarResizeMetrics.maximumVerticalPanelWidth)
    }
}

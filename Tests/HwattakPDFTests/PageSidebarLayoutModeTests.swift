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

    func testThumbnailsGrowWhenEachPanelPlacementExpands() {
        for placement in PageOverviewPlacement.allCases {
            let initialDimension = placement.usesHorizontalPageStrip ? 188.0 : 224.0
            let expandedDimension = placement.usesHorizontalPageStrip ? 400.0 : 440.0
            for mode in PageSidebarLayoutMode.allCases {
                for scale in [0.65, 1.0, 1.35] {
                    let initial = PageSidebarLayoutMetrics.thumbnailWidth(
                        panelDimension: initialDimension,
                        placement: placement,
                        layoutMode: mode,
                        thumbnailScale: scale
                    )
                    let expanded = PageSidebarLayoutMetrics.thumbnailWidth(
                        panelDimension: expandedDimension,
                        placement: placement,
                        layoutMode: mode,
                        thumbnailScale: scale
                    )

                    XCTAssertGreaterThan(
                        expanded, initial,
                        "\(placement), \(mode), zoom \(scale)"
                    )
                }
            }
        }
    }

    func testVerticalThumbnailsKeepSlotsAndGroupPaddingInsidePanel() {
        for placement in [PageOverviewPlacement.left, .right] {
            for mode in PageSidebarLayoutMode.allCases {
                for dimension in [224.0, 320.0, 440.0, 520.0] {
                    for scale in [0.65, 1.0, 1.35] {
                        let width = PageSidebarLayoutMetrics.thumbnailWidth(
                            panelDimension: dimension,
                            placement: placement,
                            layoutMode: mode,
                            thumbnailScale: scale
                        )
                        // Each page button adds 8pt per side. A two-column
                        // group adds a 6pt gap and 5pt border padding per side.
                        let contentWidth = mode == .single
                            ? width + 16 + 26
                            : 2 * (width + 16) + 6 + 10 + 26

                        XCTAssertLessThanOrEqual(
                            contentWidth, dimension + 0.001,
                            "\(placement), \(mode), width \(dimension), zoom \(scale)"
                        )
                    }
                }
            }
        }
    }

    func testHorizontalThumbnailsReservePageNumbersForDifferentPageShapes() {
        for placement in [PageOverviewPlacement.top, .bottom] {
            for mode in PageSidebarLayoutMode.allCases {
                for dimension in [188.0, 276.0, 400.0, 440.0] {
                    for scale in [0.65, 1.0, 1.35] {
                        // Landscape, portrait, and unusually tall crop boxes.
                        for aspect in [0.707, 1.414, 4.0, 8.0] {
                            let width = PageSidebarLayoutMetrics.thumbnailWidth(
                                panelDimension: dimension,
                                placement: placement,
                                layoutMode: mode,
                                thumbnailScale: scale,
                                maximumPageAspect: aspect
                            )
                            let imageAndLabelHeight = width * aspect + 9 + 14
                            let buttonAndScrollerPadding = 16.0 + 8 + 8
                            let groupPadding = mode == .single ? 0.0 : 10.0
                            let contentHeight = imageAndLabelHeight
                                + buttonAndScrollerPadding + groupPadding

                            XCTAssertLessThanOrEqual(
                                contentHeight, dimension + 0.001,
                                "\(placement), \(mode), height \(dimension), zoom \(scale), aspect \(aspect)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testSavedThumbnailZoomRemainsEffectiveAfterPanelResize() {
        for placement in PageOverviewPlacement.allCases {
            let dimension = placement.usesHorizontalPageStrip ? 400.0 : 320.0
            for mode in PageSidebarLayoutMode.allCases {
                let widths = [0.65, 1.0, 1.35].map { scale in
                    PageSidebarLayoutMetrics.thumbnailWidth(
                        panelDimension: dimension,
                        placement: placement,
                        layoutMode: mode,
                        thumbnailScale: scale
                    )
                }

                XCTAssertLessThan(widths[0], widths[1], "\(placement), \(mode)")
                XCTAssertLessThan(widths[1], widths[2], "\(placement), \(mode)")
            }
        }
    }

    func testAdaptiveThumbnailWidthHandlesInvalidDimensionsAndPreferences() {
        for placement in PageOverviewPlacement.allCases {
            for mode in PageSidebarLayoutMode.allCases {
                for dimension in [Double.nan, .infinity, -.infinity, -100, 0, 1] {
                    let width = PageSidebarLayoutMetrics.thumbnailWidth(
                        panelDimension: dimension,
                        placement: placement,
                        layoutMode: mode,
                        thumbnailScale: .nan,
                        maximumPageAspect: .nan
                    )

                    XCTAssertTrue(width.isFinite, "\(placement), \(mode), \(dimension)")
                    XCTAssertGreaterThanOrEqual(width, 1)
                }

                let referenceDimension = PageSidebarResizeMetrics.defaultDimension(for: placement)
                let expectedFallback = PageSidebarLayoutMetrics.thumbnailWidth(
                    panelDimension: referenceDimension,
                    placement: placement,
                    layoutMode: mode,
                    thumbnailScale: 1
                )
                for invalidAspect in [Double.nan, .infinity, -.infinity, -1, 0] {
                    let fallback = PageSidebarLayoutMetrics.thumbnailWidth(
                        panelDimension: .infinity,
                        placement: placement,
                        layoutMode: mode,
                        thumbnailScale: .infinity,
                        maximumPageAspect: invalidAspect
                    )

                    XCTAssertEqual(fallback, expectedFallback, accuracy: 0.001)
                }
            }
        }
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

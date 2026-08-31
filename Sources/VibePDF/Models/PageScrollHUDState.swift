// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// A document-independent description of the vertical scrollbar thumb.
/// All positions use top-to-bottom normalized coordinates.
struct PDFVerticalScrollMetrics: Equatable {
    let progress: CGFloat
    let visibleFraction: CGFloat
    let thumbCenterProgress: CGFloat

    init(
        progress: CGFloat,
        visibleFraction: CGFloat,
        thumbCenterProgress: CGFloat? = nil
    ) {
        let safeProgress = Self.clamped(progress)
        let safeVisibleFraction = Self.clamped(visibleFraction)
        self.progress = safeProgress
        self.visibleFraction = safeVisibleFraction
        self.thumbCenterProgress = Self.clamped(
            thumbCenterProgress
                ?? safeVisibleFraction / 2
                + safeProgress * (1 - safeVisibleFraction)
        )
    }

    /// Resolves metrics from an AppKit document view and its visible rectangle.
    /// Unflipped document views place their top edge at the maximum Y value.
    static func physical(
        documentFrame: CGRect,
        visibleRect: CGRect,
        isDocumentFlipped: Bool,
        thumbCenterProgress: CGFloat? = nil
    ) -> PDFVerticalScrollMetrics {
        let documentHeight = max(0, documentFrame.height)
        let viewportHeight = min(max(0, visibleRect.height), documentHeight)
        let scrollableHeight = max(0, documentHeight - viewportHeight)

        let distanceFromTop: CGFloat
        if isDocumentFlipped {
            distanceFromTop = visibleRect.minY - documentFrame.minY
        } else {
            distanceFromTop = documentFrame.maxY - visibleRect.maxY
        }

        let progress = scrollableHeight > 0
            ? distanceFromTop / scrollableHeight
            : 0
        let visibleFraction = documentHeight > 0
            ? viewportHeight / documentHeight
            : 1

        return PDFVerticalScrollMetrics(
            progress: progress,
            visibleFraction: visibleFraction,
            thumbCenterProgress: thumbCenterProgress
        )
    }

    /// Resolves a useful scrollbar position for SwiftUI page grids, where no
    /// public scroll-view geometry is available. `pageStride` is four for the
    /// strict four-page pager and one for a continuous overview.
    static func semantic(
        pageIndex: Int,
        pageCount: Int,
        visiblePageCount: Int,
        pageStride: Int = 1
    ) -> PDFVerticalScrollMetrics {
        guard pageCount > 0 else {
            return PDFVerticalScrollMetrics(progress: 0, visibleFraction: 1)
        }

        let safeVisiblePageCount = min(max(1, visiblePageCount), pageCount)
        let safeStride = max(1, pageStride)
        let clampedIndex = min(max(0, pageIndex), pageCount - 1)

        let maximumStart: Int
        let currentStart: Int
        if safeStride > 1 {
            maximumStart = ((pageCount - 1) / safeStride) * safeStride
            currentStart = (clampedIndex / safeStride) * safeStride
        } else {
            maximumStart = max(0, pageCount - safeVisiblePageCount)
            currentStart = min(clampedIndex, maximumStart)
        }

        return PDFVerticalScrollMetrics(
            progress: maximumStart > 0
                ? CGFloat(currentStart) / CGFloat(maximumStart)
                : 0,
            visibleFraction: CGFloat(safeVisiblePageCount) / CGFloat(pageCount)
        )
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// Pure state for the transient current-page HUD. The view layer owns the one
/// cancellable timer and calls `hideIfExpired` when its deadline fires.
struct PageScrollHUDState: Equatable {
    static let dismissalDelay: TimeInterval = 1.75

    private(set) var isVisible = false
    private(set) var metrics = PDFVerticalScrollMetrics(
        progress: 0,
        visibleFraction: 1
    )
    private(set) var lastActivityTime: TimeInterval?

    var dismissalDeadline: TimeInterval? {
        lastActivityTime.map { $0 + Self.dismissalDelay }
    }

    mutating func recordScroll(
        metrics: PDFVerticalScrollMetrics,
        at time: TimeInterval
    ) {
        self.metrics = metrics
        lastActivityTime = time.isFinite ? time : 0
        isVisible = true
    }

    @discardableResult
    mutating func hideIfExpired(at time: TimeInterval) -> Bool {
        guard
            isVisible,
            let dismissalDeadline,
            time.isFinite,
            time >= dismissalDeadline
        else {
            return false
        }
        hide()
        return true
    }

    mutating func hide() {
        isVisible = false
        lastActivityTime = nil
    }
}

enum PageScrollHUDLayout {
    static let height: CGFloat = 32
    static let edgeInset: CGFloat = 12

    static func centerY(
        containerHeight: CGFloat,
        metrics: PDFVerticalScrollMetrics,
        hudHeight: CGFloat = height,
        edgeInset: CGFloat = edgeInset
    ) -> CGFloat {
        let safeContainerHeight = max(0, containerHeight)
        let safeHUDHeight = min(max(0, hudHeight), safeContainerHeight)
        let safeInset = min(
            max(0, edgeInset),
            max(0, (safeContainerHeight - safeHUDHeight) / 2)
        )
        let minimumCenter = safeInset + safeHUDHeight / 2
        let maximumCenter = max(
            minimumCenter,
            safeContainerHeight - safeInset - safeHUDHeight / 2
        )
        let physicalThumbCenter = metrics.thumbCenterProgress * safeContainerHeight
        return min(maximumCenter, max(minimumCenter, physicalThumbCenter))
    }
}

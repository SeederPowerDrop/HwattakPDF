// SPDX-License-Identifier: MPL-2.0

import AppKit

/// Converts an AppKit scroll view's live position into the metrics used by the
/// page HUD. The native knob rectangle is preferred because overlay scrollers
/// can impose a minimum thumb size that differs from the content ratio.
enum PDFScrollViewMetricsResolver {
    static func resolve(_ scrollView: NSScrollView) -> PDFVerticalScrollMetrics? {
        guard let documentView = scrollView.contentView.documentView else {
            return nil
        }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let fallbackMetrics = PDFVerticalScrollMetrics.physical(
            documentFrame: documentView.frame,
            visibleRect: visibleRect,
            isDocumentFlipped: documentView.isFlipped
        )
        return PDFVerticalScrollMetrics.physical(
            documentFrame: documentView.frame,
            visibleRect: visibleRect,
            isDocumentFlipped: documentView.isFlipped,
            thumbCenterProgress: actualThumbCenterProgress(
                in: scrollView,
                fallback: fallbackMetrics.thumbCenterProgress
            )
        )
    }

    private static func actualThumbCenterProgress(
        in scrollView: NSScrollView,
        fallback: CGFloat
    ) -> CGFloat? {
        guard
            let scroller = scrollView.verticalScroller,
            !scroller.isHidden,
            scroller.alphaValue > 0.01
        else {
            return nil
        }

        let knobRect = scroller.rect(for: .knob)
        let slotRect = scroller.rect(for: .knobSlot)
        guard
            !knobRect.isEmpty,
            !slotRect.isEmpty,
            slotRect.height > 0,
            knobRect.height > 0
        else {
            return nil
        }

        let rawCenter = min(
            1,
            max(0, (knobRect.midY - slotRect.minY) / slotRect.height)
        )
        let direct = scroller.isFlipped ? rawCenter : 1 - rawCenter
        let reversed = 1 - direct
        return abs(direct - fallback) <= abs(reversed - fallback)
            ? direct
            : reversed
    }
}

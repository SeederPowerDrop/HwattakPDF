// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

@MainActor
extension InteractivePDFView {
    func updatePageFitMode(revealCurrentPage: Bool = false) {
        let requested = viewportContext == .normal ? workspaceState?.pageFitMode : nil
        if requested != nil, revealCurrentPage { revealPageAfterFitting = true }
        if activePageFitMode != requested {
            activePageFitMode = requested
            revealPageAfterFitting = requested != nil
            if requested == nil, workspaceState?.pdfViewportState.autoScales == true {
                autoScales = true
            }
        }
        schedulePageFitUpdate()
    }

    func schedulePageFitUpdate() {
        guard activePageFitMode != nil, !isApplyingPageFitScale, !pageFitUpdateScheduled else { return }
        pageFitUpdateScheduled = true
        // PDFKit replaces its clip view during layout and spread changes.
        // Read its final size after that layout, never from SwiftUI's old frame.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyPageFitScale()
            self.pageFitUpdateScheduled = false
        }
    }

    func applyPageFitScale() {
        guard viewportContext == .normal,
              let mode = activePageFitMode,
              mode == workspaceState?.pageFitMode,
              let state = workspaceState,
              let document,
              let selectedPage = document.page(at: state.currentPageIndex),
              bounds.width > 1, bounds.height > 1
        else { return }

        let pageCount = (displayMode == .twoUp || displayMode == .twoUpContinuous) ? 2 : 1
        let start = state.currentPageIndex / pageCount * pageCount
        let pageSizes = (start..<min(start + pageCount, document.pageCount)).compactMap { index -> CGSize? in
            guard let page = document.page(at: index) else { return nil }
            let size = page.bounds(for: displayBox).size
            return abs(page.rotation % 180) == 90
                ? CGSize(width: size.height, height: size.width) : size
        }
        // The clip view's bounds are magnified document units. Convert back to
        // PDFView coordinates to measure the actual on-screen reading area.
        let scrollView = firstDocumentScrollView()
        let viewport = scrollView.map {
            convert($0.contentView.bounds, from: $0.contentView).size
        } ?? bounds.size
        let margins = displaysPageBreaks ? pageBreakMargins : NSEdgeInsetsZero
        let isContinuous = displayMode == .singlePageContinuous || displayMode == .twoUpContinuous
        guard var target = mode.scaleFactor(
            viewportSize: viewport,
            pageSizes: pageSizes,
            horizontalInsets: (margins.left + margins.right) * CGFloat(pageCount + (isContinuous ? 0 : 1)),
            verticalInsets: (margins.top + margins.bottom) * (displayMode == .singlePageContinuous ? 1 : 2)
        ) else { return }
        // PDFKit scales page-break margins with the document. Its intrinsic
        // width also includes rotation, unequal pages and paged-mode gutters;
        // using that width prevents a small unwanted horizontal overflow.
        if mode == .width, let width = scrollView?.documentView?.frame.width,
           width.isFinite, width > 0 {
            target = min(20, max(0.05, viewport.width / width))
        }

        isApplyingPageFitScale = true
        defer { isApplyingPageFitScale = false }
        autoScales = false
        // PDFKit's automatic fit can leave a narrower allowed zoom range.
        // Expand that range before asking it to fill just one axis.
        minScaleFactor = min(minScaleFactor, target)
        maxScaleFactor = max(maxScaleFactor, target)
        if abs(scaleFactor - target) > 0.0001 {
            scaleFactor = target
            layoutDocumentView()
            if mode == .height { revealPageAfterFitting = true }
        }
        if revealPageAfterFitting {
            revealPageAfterFitting = false
            go(to: selectedPage)
        }
        state.recordPDFViewport(
            autoScales: false,
            scaleFactor: scaleFactor,
            scrollProgress: nil
        )
    }

    func endPageFitForManualZoom() {
        guard viewportContext == .normal, activePageFitMode != nil else { return }
        activePageFitMode = nil
        revealPageAfterFitting = false
        workspaceState?.endPageFitForManualZoom()
    }
}

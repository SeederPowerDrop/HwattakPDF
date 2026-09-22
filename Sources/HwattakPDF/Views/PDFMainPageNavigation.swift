// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

extension InteractivePDFView {
    /// Canvas keys only: field editors and annotation handles own their arrows.
    @discardableResult
    func handlePageNavigationKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              pageNavigationMode == .horizontalPaging,
              viewportContext == .normal,
              Self.viewportModifiers(from: event.modifierFlags).isEmpty,
              !hasPageEditingFocus,
              event.keyCode == 123 || event.keyCode == 124 else { return false }
        resetPageTurnGesture()
        return turnPage(by: event.keyCode == 124 ? 1 : -1)
    }

    @discardableResult
    func turnPage(by step: Int) -> Bool {
        guard pageNavigationMode == .horizontalPaging, viewportContext == .normal,
              !isDrawingInkStroke, let workspace = workspaceState,
              let document, document === workspace.document, document.pageCount > 0 else { return false }
        guard let target = PDFPageNavigationMode.targetPage(
            from: workspace.currentPageIndex,
            pageCount: document.pageCount,
            pagesPerTurn: workspace.pageColumns > 1 ? 2 : 1,
            step: step
        ), let page = document.page(at: target) else { return true }
        clearSelection()
        workspace.currentSelection = nil
        workspace.selectedPages = [target]
        workspace.setCurrentPage(target)
        go(to: page)
        return true
    }

    private var hasPageEditingFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return ownsPageEditingKeys(responder)
    }

    private func ownsPageEditingKeys(_ view: NSView) -> Bool {
        var ancestor: NSView? = view
        while let current = ancestor, current !== self {
            if current is NSTextView || current is NSControl
                || current is PDFAnnotationEditingOverlayView
                || current is PDFInlineTextEditingOverlayView
                || current is PDFInlineTextEditorPanel { return true }
            ancestor = current.superview
        }
        return false
    }

    func canHandlePageTurnScroll(_ event: NSEvent) -> Bool {
        guard event.type == .scrollWheel, document != nil,
              pageNavigationMode == .horizontalPaging, viewportContext == .normal,
              !isDrawingInkStroke, !hasPageEditingFocus,
              Self.viewportModifiers(from: event.modifierFlags).isEmpty else { return false }
        // At larger zoom, horizontal gestures pan the page. Arrow keys still
        // turn pages. Modified zoom and Shift-pan have their own event path.
        guard autoScales || scaleFactor <= scaleFactorForSizeToFit * 1.01 else { return false }
        if let hit = window?.contentView?.hitTest(event.locationInWindow), ownsPageEditingKeys(hit) {
            return false
        }
        return true
    }

    @discardableResult
    func handlePageTurnScroll(_ event: NSEvent) -> Bool {
        guard canHandlePageTurnScroll(event) else {
            resetPageTurnGesture()
            return false
        }
        let phase = event.phase
        let momentum = event.momentumPhase
        let discrete = phase.isEmpty && momentum.isEmpty
        let gestureActive = pageTurnGesture.isTouchActive || pageTurnGesture.isAwaitingMomentum
            || pageTurnGesture.isMomentumActive
        // Preserve native vertical scrolling within a page. A mouse wheel has
        // no horizontal axis on many devices, so its vertical ticks can turn.
        if !gestureActive, event.hasPreciseScrollingDeltas,
           abs(event.scrollingDeltaX) <= abs(event.scrollingDeltaY) { return false }

        pageTurnResetWorkItem?.cancel()
        if phase.contains(.began) || phase.contains(.mayBegin) || !gestureActive {
            pageTurnGesture.beginTouchGesture()
        }
        if momentum.contains(.began) { pageTurnGesture.beginMomentum() }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let primary = discrete && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY : event.scrollingDeltaX
        let cross: CGFloat = discrete ? 0 : event.scrollingDeltaY
        if let step = pageTurnGesture.consume(primaryDelta: primary * multiplier, crossAxisDelta: cross * multiplier) {
            _ = turnPage(by: step)
        }

        if phase.contains(.cancelled) || momentum.contains(.ended) || momentum.contains(.cancelled) {
            resetPageTurnGesture()
        } else {
            if phase.contains(.ended) { pageTurnGesture.endTouchGesture() }
            // Keep the latch through the momentum tail; also recover from a
            // device that never emits an ended phase.
            let delay = phase.contains(.ended) ? 0.28 : (discrete ? 0.24 : 0.6)
            let reset = DispatchWorkItem { [weak self] in self?.resetPageTurnGesture() }
            pageTurnResetWorkItem = reset
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: reset)
        }
        return true
    }

    func resetPageTurnGesture() {
        pageTurnResetWorkItem?.cancel()
        pageTurnResetWorkItem = nil
        pageTurnGesture.reset()
    }
}

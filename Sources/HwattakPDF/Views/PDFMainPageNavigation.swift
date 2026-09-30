// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

extension InteractivePDFView {
    /// Canvas keys only: field editors and annotation handles own their arrows.
    @discardableResult
    func handlePageNavigationKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              viewportContext == .normal,
              PDFArrowKeyRepeater.accepts(modifiers: event.modifierFlags),
              !hasPageEditingFocus,
              !isDrawingInkStroke,
              (123...126).contains(event.keyCode),
              let workspace = workspaceState,
              let document, document === workspace.document else { return false }
        // Option arrows always reach PDFKit unchanged. Shift arrows still
        // belong to native text selection when a selection is active.
        if currentSelection != nil,
           event.modifierFlags.contains(.shift) { return false }
        resetPageTurnGesture()
        let revision = workspace.revision
        let mode = workspace.mode
        let columns = workspace.pageColumns
        let navigation = pageNavigationMode
        return arrowKeyRepeater.handleKeyDown(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            isRepeat: event.isARepeat,
            window: window
        ) { [weak self, weak workspace, weak document] in
            guard let self, let workspace, let document,
                  self.document === document, workspace.document === document,
                  workspace.revision == revision, workspace.mode == mode,
                  workspace.pageColumns == columns, self.pageNavigationMode == navigation,
                  self.viewportContext == .normal, !self.isDrawingInkStroke,
                  !self.hasPageEditingFocus, self.ownsArrowKeyFocus else { return false }
            if self.currentSelection != nil,
               self.arrowKeyRepeater.currentModifiers.contains(.shift) {
                return false
            }
            if navigation == .horizontalPaging, event.keyCode == 123 || event.keyCode == 124 {
                return self.turnPage(by: event.keyCode == 124 ? 1 : -1)
            }
            return self.scrollDocumentForArrow(keyCode: event.keyCode)
        }
    }

    private var ownsArrowKeyFocus: Bool {
        // Offscreen views can perform a single action but never start a timer.
        guard let window else { return true }
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    /// Scroll by a stable screen distance; PDFKit's clip coordinates change
    /// with magnification. The shared repeater controls tempo in every layout.
    @discardableResult
    func scrollDocumentForArrow(keyCode: UInt16) -> Bool {
        guard (123...126).contains(keyCode), let scrollView = firstDocumentScrollView(),
              let documentView = scrollView.contentView.documentView else { return false }
        let clip = scrollView.contentView
        let step = clip.convert(CGSize(width: 40, height: 40), from: self)
        var proposed = clip.bounds
        switch keyCode {
        case 123: proposed.origin.x -= abs(step.width)
        case 124: proposed.origin.x += abs(step.width)
        case 125: proposed.origin.y += abs(step.height) * (documentView.isFlipped ? 1 : -1)
        case 126: proposed.origin.y -= abs(step.height) * (documentView.isFlipped ? 1 : -1)
        default: return false
        }
        let constrained = clip.constrainBoundsRect(proposed)
        if abs(constrained.origin.y - clip.bounds.origin.y) < 0.001,
           keyCode == 125 || keyCode == 126,
           pageNavigationMode == .verticalScroll,
           displayMode == .singlePage || displayMode == .twoUp {
            return turnPage(by: keyCode == 125 ? 1 : -1)
        }
        clip.setBoundsOrigin(constrained.origin)
        scrollView.reflectScrolledClipView(clip)
        return true
    }

    @discardableResult
    func turnPage(by step: Int) -> Bool {
        guard viewportContext == .normal,
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

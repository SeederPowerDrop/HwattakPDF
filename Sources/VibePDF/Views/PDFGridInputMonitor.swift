// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// A passive AppKit bridge used only while the grid is on screen. It does not
/// participate in hit testing, so page selection, drag-and-drop and controls
/// keep their normal SwiftUI behavior.
@MainActor
struct PDFGridInputMonitor: NSViewRepresentable {
    let pagingEnabled: Bool
    let pagingDirection: PDFGridPagingDirection
    let wheelZoomModifier: PDFWheelZoomModifier
    let onMagnificationChanged: (CGFloat) -> Void
    let onMagnificationEnded: (CGFloat) -> Void
    let onScrollActivity: () -> Void
    let onPageStep: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pagingEnabled: pagingEnabled,
            pagingDirection: pagingDirection,
            wheelZoomModifier: wheelZoomModifier,
            onMagnificationChanged: onMagnificationChanged,
            onMagnificationEnded: onMagnificationEnded,
            onScrollActivity: onScrollActivity,
            onPageStep: onPageStep
        )
    }

    func makeNSView(context: Context) -> MonitoringView {
        let view = MonitoringView(frame: .zero)
        view.monitorCoordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: MonitoringView, context: Context) {
        context.coordinator.update(
            pagingEnabled: pagingEnabled,
            pagingDirection: pagingDirection,
            wheelZoomModifier: wheelZoomModifier,
            onMagnificationChanged: onMagnificationChanged,
            onMagnificationEnded: onMagnificationEnded,
            onScrollActivity: onScrollActivity,
            onPageStep: onPageStep
        )
        view.monitorCoordinator = context.coordinator
        if view.window != nil {
            context.coordinator.attach(to: view)
        }
    }

    static func dismantleNSView(_ view: MonitoringView, coordinator: Coordinator) {
        coordinator.detach()
        view.monitorCoordinator = nil
    }

    final class MonitoringView: NSView {
        weak var monitorCoordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                monitorCoordinator?.attach(to: self)
            } else {
                monitorCoordinator?.detach(keeping: self)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override var acceptsFirstResponder: Bool {
            false
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var monitoredView: MonitoringView?
        private var eventMonitor: Any?
        private var pagingEnabled: Bool
        private var pagingDirection: PDFGridPagingDirection
        private var wheelZoomModifier: PDFWheelZoomModifier
        private var onMagnificationChanged: (CGFloat) -> Void
        private var onMagnificationEnded: (CGFloat) -> Void
        private var onScrollActivity: () -> Void
        private var onPageStep: (Int) -> Void
        private var pagingSession = PDFGridPagingGestureSession()
        private var pagingResetWorkItem: DispatchWorkItem?
        private var magnificationEndWorkItem: DispatchWorkItem?
        private var magnification = PDFGridMagnificationAccumulator()
        private var isMagnifying = false
        private var wheelMagnification = PDFWheelZoomAccumulator()
        private var isWheelMagnifying = false
        private var modifiedScrollGesture = PDFViewportModifiedScrollGestureLatch()
        private var modifiedScrollEndWorkItem: DispatchWorkItem?

        init(
            pagingEnabled: Bool,
            pagingDirection: PDFGridPagingDirection,
            wheelZoomModifier: PDFWheelZoomModifier,
            onMagnificationChanged: @escaping (CGFloat) -> Void,
            onMagnificationEnded: @escaping (CGFloat) -> Void,
            onScrollActivity: @escaping () -> Void,
            onPageStep: @escaping (Int) -> Void
        ) {
            self.pagingEnabled = pagingEnabled
            self.pagingDirection = pagingDirection
            self.wheelZoomModifier = wheelZoomModifier
            self.onMagnificationChanged = onMagnificationChanged
            self.onMagnificationEnded = onMagnificationEnded
            self.onScrollActivity = onScrollActivity
            self.onPageStep = onPageStep
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            pagingResetWorkItem?.cancel()
            magnificationEndWorkItem?.cancel()
            modifiedScrollEndWorkItem?.cancel()
        }

        func update(
            pagingEnabled: Bool,
            pagingDirection: PDFGridPagingDirection,
            wheelZoomModifier: PDFWheelZoomModifier,
            onMagnificationChanged: @escaping (CGFloat) -> Void,
            onMagnificationEnded: @escaping (CGFloat) -> Void,
            onScrollActivity: @escaping () -> Void,
            onPageStep: @escaping (Int) -> Void
        ) {
            if self.pagingEnabled != pagingEnabled || self.pagingDirection != pagingDirection {
                resetPagingGesture()
            }
            self.pagingEnabled = pagingEnabled
            self.pagingDirection = pagingDirection
            if self.wheelZoomModifier != wheelZoomModifier {
                finishModifiedScrollGesture()
            }
            self.wheelZoomModifier = wheelZoomModifier
            self.onMagnificationChanged = onMagnificationChanged
            self.onMagnificationEnded = onMagnificationEnded
            self.onScrollActivity = onScrollActivity
            self.onPageStep = onPageStep
        }

        func attach(to view: MonitoringView) {
            monitoredView = view
            guard eventMonitor == nil, view.window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.magnify, .scrollWheel]
            ) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func detach(keeping view: MonitoringView? = nil) {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            resetPagingGesture()
            finishMagnificationIfNeeded()
            finishModifiedScrollGesture()
            if monitoredView !== view {
                monitoredView = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard eventIsInsideMonitoredView(event) else {
                resetPagingGesture()
                finishMagnificationIfNeeded()
                finishModifiedScrollGesture()
                return event
            }

            switch event.type {
            case .magnify:
                handleMagnification(event)
                return nil
            case .scrollWheel:
                return handleScroll(event)
            default:
                return event
            }
        }

        private func eventIsInsideMonitoredView(_ event: NSEvent) -> Bool {
            guard
                let view = monitoredView,
                let window = view.window,
                event.window === window,
                window.isVisible,
                !view.visibleRect.isEmpty
            else {
                return false
            }

            let location = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(location), view.visibleRect.contains(location) else {
                return false
            }

            var ancestor: NSView? = view
            while let current = ancestor {
                if current.isHidden || current.alphaValue <= 0.01 {
                    return false
                }
                if let layer = current.layer, layer.opacity <= 0.01 {
                    return false
                }
                ancestor = current.superview
            }
            return true
        }

        private func handleMagnification(_ event: NSEvent) {
            resetPagingGesture()
            finishModifiedScrollGesture()
            magnificationEndWorkItem?.cancel()

            if event.phase.contains(.began) || !isMagnifying {
                magnification.reset()
                isMagnifying = true
            }

            // NSEvent reports an additive change for each magnify event. Keep
            // one factor relative to the gesture baseline and commit once.
            onMagnificationChanged(
                magnification.consume(change: event.magnification)
            )

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                finishMagnificationIfNeeded()
            } else if event.phase.isEmpty {
                scheduleMagnificationEnd()
            }
        }

        private func handleScroll(_ event: NSEvent) -> NSEvent? {
            let input = PDFViewportScrollInput(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                modifiers: InteractivePDFView.viewportModifiers(
                    from: event.modifierFlags
                )
            )
            let intent = PDFViewportScrollIntentResolver.resolve(
                input,
                zoomModifier: wheelZoomModifier
            )
            let modifiedOwner = modifiedScrollGesture.ownerForEvent(
                intent: intent,
                touchPhasePresent: !event.phase.isEmpty,
                touchPhaseBegan: event.phase.contains(.mayBegin)
                    || event.phase.contains(.began),
                momentumPhasePresent: !event.momentumPhase.isEmpty
            )

            if let modifiedOwner {
                resetPagingGesture()
                finishMagnificationIfNeeded()

                switch modifiedOwner {
                case .zoom:
                    if let stepFactor = PDFViewportScrollIntentResolver.zoomStepFactor(
                        deltaY: input.deltaY,
                        hasPreciseDeltas: input.hasPreciseDeltas
                    ) {
                        handleWheelMagnification(stepFactor: stepFactor)
                    }
                case .horizontalPan:
                    finishWheelMagnificationIfNeeded()
                    if let delta = PDFViewportScrollIntentResolver.horizontalPanDelta(
                        deltaX: input.deltaX,
                        deltaY: input.deltaY,
                        hasPreciseDeltas: input.hasPreciseDeltas
                    ) {
                        _ = panHorizontally(wheelDelta: delta, event: event)
                    }
                }

                updateModifiedScrollLifecycle(after: event)
                return nil
            }

            if isWheelMagnifying {
                finishWheelMagnificationIfNeeded()
            }

            // Modifier combinations are deliberately ambiguous and must not
            // leak into the strict four-page wheel pager.
            let modifiers = InteractivePDFView.viewportModifiers(
                from: event.modifierFlags
            )
            if !modifiers.isEmpty {
                resetPagingGesture()
                return event
            }

            // Emit native/pager wheel activity only. Modified zoom and pan do
            // not represent document-page scrolling and should not show HUDs.
            onScrollActivity()

            guard pagingEnabled, !isMagnifying else {
                resetPagingGesture()
                return event
            }

            pagingResetWorkItem?.cancel()
            let phase = event.phase
            let momentumPhase = event.momentumPhase
            let isDiscreteEvent = phase.isEmpty && momentumPhase.isEmpty

            if phase.contains(.mayBegin) || phase.contains(.began) {
                pagingSession.beginTouchGesture()
            } else if isDiscreteEvent && !pagingSession.isTouchActive {
                pagingSession.beginTouchGesture()
            } else if
                !pagingSession.isTouchActive,
                !pagingSession.isAwaitingMomentum,
                !pagingSession.isMomentumActive
            {
                pagingSession.beginTouchGesture()
            }

            if momentumPhase.contains(.began) {
                pagingSession.beginMomentum()
            }

            let precisionMultiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            let primaryDelta: CGFloat
            let crossAxisDelta: CGFloat
            switch pagingDirection {
            case .vertical:
                primaryDelta = event.scrollingDeltaY * precisionMultiplier
                crossAxisDelta = event.scrollingDeltaX * precisionMultiplier
            case .horizontal:
                primaryDelta = event.scrollingDeltaX * precisionMultiplier
                crossAxisDelta = event.scrollingDeltaY * precisionMultiplier
            }

            if let step = pagingSession.consume(
                primaryDelta: primaryDelta,
                crossAxisDelta: crossAxisDelta
            ) {
                onPageStep(step)
            }

            if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
                pagingSession.endMomentum()
            } else if phase.contains(.cancelled) {
                pagingSession.reset()
            } else if phase.contains(.ended) {
                pagingSession.endTouchGesture()
                schedulePagingResetAfterPossibleMomentum()
            } else if isDiscreteEvent {
                scheduleDiscretePagingReset()
            }

            // At fit scale the wheel is page navigation, not pixel scrolling.
            return nil
        }

        private func handleWheelMagnification(stepFactor: CGFloat) {
            if !isWheelMagnifying {
                wheelMagnification.reset()
                isWheelMagnifying = true
            }
            onMagnificationChanged(
                wheelMagnification.consume(stepFactor: stepFactor)
            )
        }

        private func panHorizontally(wheelDelta: CGFloat, event: NSEvent) -> Bool {
            guard
                wheelDelta.isFinite,
                abs(wheelDelta) > 0.0001,
                let scrollView = scrollView(at: event),
                let documentView = scrollView.contentView.documentView
            else { return false }

            let clipView = scrollView.contentView
            guard documentView.frame.width - clipView.bounds.width > 0.5 else {
                return true
            }
            var proposedBounds = clipView.bounds
            proposedBounds.origin.x -= wheelDelta
            let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
            if abs(constrainedBounds.origin.x - clipView.bounds.origin.x) > 0.0001 {
                clipView.setBoundsOrigin(constrainedBounds.origin)
                scrollView.reflectScrolledClipView(clipView)
            }
            // Consume at the horizontal edge too, preventing one continuous
            // Shift gesture from suddenly becoming vertical scrolling.
            return true
        }

        private func scrollView(at event: NSEvent) -> NSScrollView? {
            var view = event.window?.contentView?.hitTest(event.locationInWindow)
            while let current = view {
                if let scrollView = current as? NSScrollView { return scrollView }
                view = current.superview
            }
            return nil
        }

        private func schedulePagingResetAfterPossibleMomentum() {
            let workItem = DispatchWorkItem { [weak self] in
                self?.pagingSession.finishWaitingForMomentum()
            }
            pagingResetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
        }

        private func scheduleDiscretePagingReset() {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pagingSession.reset()
            }
            pagingResetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: workItem)
        }

        private func scheduleMagnificationEnd() {
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishMagnificationIfNeeded()
            }
            magnificationEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
        }

        private func updateModifiedScrollLifecycle(after event: NSEvent) {
            modifiedScrollEndWorkItem?.cancel()
            modifiedScrollEndWorkItem = nil

            if
                event.phase.contains(.cancelled)
                    || event.momentumPhase.contains(.ended)
                    || event.momentumPhase.contains(.cancelled)
            {
                finishModifiedScrollGesture()
                return
            }

            let delay: TimeInterval?
            if event.phase.contains(.ended) {
                modifiedScrollGesture.touchEnded()
                delay = 0.28
        } else if event.phase.isEmpty, event.momentumPhase.isEmpty {
            delay = 0.16
        } else {
            // Defensive fallback for devices/drivers that omit an explicit
            // ended phase. Continuous events refresh this deadline.
            delay = 0.6
        }

            guard let delay else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.finishModifiedScrollGesture()
            }
            modifiedScrollEndWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func finishModifiedScrollGesture() {
            modifiedScrollEndWorkItem?.cancel()
            modifiedScrollEndWorkItem = nil
            modifiedScrollGesture.reset()
            finishWheelMagnificationIfNeeded()
        }

        private func resetPagingGesture() {
            pagingResetWorkItem?.cancel()
            pagingResetWorkItem = nil
            pagingSession.reset()
        }

        private func finishMagnificationIfNeeded() {
            magnificationEndWorkItem?.cancel()
            magnificationEndWorkItem = nil
            guard isMagnifying else { return }
            let finalFactor = magnification.relativeFactor
            isMagnifying = false
            magnification.reset()
            onMagnificationEnded(finalFactor)
        }

        private func finishWheelMagnificationIfNeeded() {
            guard isWheelMagnifying else { return }
            let finalFactor = wheelMagnification.relativeFactor
            isWheelMagnifying = false
            wheelMagnification.reset()
            onMagnificationEnded(finalFactor)
        }
    }
}

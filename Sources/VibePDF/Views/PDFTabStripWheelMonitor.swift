// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// A passive bridge that redirects an unmodified vertical wheel gesture into
/// the horizontal SwiftUI scroll view beneath it. It never participates in hit
/// testing, so tabs, close buttons, context menus, and drag/drop stay native.
@MainActor
struct PDFTabStripWheelMonitor: NSViewRepresentable {
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled)
    }

    func makeNSView(context: Context) -> MonitoringView {
        let view = MonitoringView(frame: .zero)
        view.monitorCoordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: MonitoringView, context: Context) {
        context.coordinator.update(isEnabled: isEnabled)
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
        private enum GestureOwner {
            case undecided
            case native
            case redirected
        }

        private weak var monitoredView: MonitoringView?
        private var eventMonitor: Any?
        private var isEnabled: Bool
        private var gestureOwner = GestureOwner.undecided
        private var gestureResetWorkItem: DispatchWorkItem?

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            gestureResetWorkItem?.cancel()
        }

        func update(isEnabled: Bool) {
            self.isEnabled = isEnabled
            if !isEnabled {
                resetGesture()
            }
        }

        func attach(to view: MonitoringView) {
            monitoredView = view
            guard eventMonitor == nil, view.window != nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func detach(keeping view: MonitoringView? = nil) {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            resetGesture()
            if monitoredView !== view {
                monitoredView = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard
                isEnabled,
                eventIsInsideMonitoredView(event),
                let scrollView = scrollView(at: event)
            else {
                resetGesture()
                return event
            }

            if event.phase.contains(.mayBegin) || event.phase.contains(.began) {
                gestureResetWorkItem?.cancel()
                gestureResetWorkItem = nil
                gestureOwner = .undecided
            } else if event.phase.isEmpty, event.momentumPhase.isEmpty {
                // A mouse-wheel notch is a complete gesture. It must not
                // inherit ownership while a trackpad is awaiting momentum.
                resetGesture()
            }

            let blockedModifiers: NSEvent.ModifierFlags = [
                .shift, .control, .option, .command
            ]
            let hasBlockingModifier = !event.modifierFlags
                .intersection(blockedModifiers)
                .isEmpty
            let mappedDelta = PDFTabStripLayout.mappedHorizontalWheelDelta(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                hasBlockingModifier: hasBlockingModifier
            )
            let hasMovement = abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 0.0001
            let hasGesturePhase = !event.phase.isEmpty || !event.momentumPhase.isEmpty

            if gestureOwner == .undecided, hasMovement, hasGesturePhase {
                gestureOwner = mappedDelta == nil ? .native : .redirected
            }

            let shouldRedirect: Bool
            if hasGesturePhase {
                shouldRedirect = gestureOwner == .redirected
            } else {
                shouldRedirect = mappedDelta != nil
            }

            var consumed = false
            if shouldRedirect {
                if let mappedDelta {
                    consumed = PDFTabStripWheelMonitor.scrollHorizontally(
                        wheelDelta: CGFloat(mappedDelta),
                        in: scrollView
                    )
                } else {
                    // Keep zero-delta end/cancel and momentum tail events with
                    // the owner that handled the beginning of the gesture.
                    consumed = true
                }
            }

            updateGestureLifecycle(after: event)
            return consumed ? nil : event
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

        private func scrollView(at event: NSEvent) -> NSScrollView? {
            var view = event.window?.contentView?.hitTest(event.locationInWindow)
            while let current = view {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }

        private func updateGestureLifecycle(after event: NSEvent) {
            gestureResetWorkItem?.cancel()
            gestureResetWorkItem = nil

            if
                event.phase.contains(.cancelled)
                    || event.momentumPhase.contains(.ended)
                    || event.momentumPhase.contains(.cancelled)
            {
                gestureOwner = .undecided
                return
            }

            guard event.phase.contains(.ended) else { return }
            let workItem = DispatchWorkItem { [weak self] in
                self?.gestureOwner = .undecided
                self?.gestureResetWorkItem = nil
            }
            gestureResetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: workItem)
        }

        private func resetGesture() {
            gestureResetWorkItem?.cancel()
            gestureResetWorkItem = nil
            gestureOwner = .undecided
        }
    }

    /// Applies AppKit's natural wheel direction once (`origin.x -= delta`) and
    /// constrains both ends. Returning true means the horizontal strip owns the
    /// gesture, including when it has already reached an edge.
    @discardableResult
    static func scrollHorizontally(
        wheelDelta: CGFloat,
        in scrollView: NSScrollView
    ) -> Bool {
        guard
            wheelDelta.isFinite,
            abs(wheelDelta) > 0.0001,
            let documentView = scrollView.contentView.documentView
        else {
            return false
        }

        let clipView = scrollView.contentView
        guard documentView.frame.width - clipView.bounds.width > 0.5 else {
            return false
        }
        var proposedBounds = clipView.bounds
        proposedBounds.origin.x -= wheelDelta
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        if abs(constrainedBounds.origin.x - clipView.bounds.origin.x) > 0.0001 {
            clipView.setBoundsOrigin(constrainedBounds.origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        return true
    }
}

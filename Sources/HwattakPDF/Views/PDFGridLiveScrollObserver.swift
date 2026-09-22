// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Observes the native scroll view backing a SwiftUI grid. Placing this view
/// inside the ScrollView content makes `enclosingScrollView` resolve the exact
/// canvas scroll view instead of an unrelated sidebar or host scroll view.
@MainActor
struct PDFGridLiveScrollObserver: NSViewRepresentable {
    let onScrollActivity: (PDFVerticalScrollMetrics) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScrollActivity: onScrollActivity)
    }

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        context.coordinator.update(onScrollActivity: onScrollActivity)
        view.coordinator = context.coordinator
        context.coordinator.attach(to: view)
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: Coordinator) {
        coordinator.detach()
        view.coordinator = nil
    }

    final class ObserverView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                coordinator?.detach(keeping: self)
            } else {
                coordinator?.attach(to: self)
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.scheduleRefresh()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var hostView: ObserverView?
        private weak var observedScrollView: NSScrollView?
        private var liveScrollObserver: NSObjectProtocol?
        private var onScrollActivity: (PDFVerticalScrollMetrics) -> Void
        private var refreshScheduled = false
        private var lifecycleGeneration = 0

        init(onScrollActivity: @escaping (PDFVerticalScrollMetrics) -> Void) {
            self.onScrollActivity = onScrollActivity
        }

        deinit {
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
            }
        }

        func update(onScrollActivity: @escaping (PDFVerticalScrollMetrics) -> Void) {
            self.onScrollActivity = onScrollActivity
            refreshObservation()
            scheduleRefresh()
        }

        func attach(to view: ObserverView) {
            if hostView !== view {
                detach()
                hostView = view
            }
            refreshObservation()
            scheduleRefresh()
        }

        func detach(keeping view: ObserverView? = nil) {
            lifecycleGeneration += 1
            refreshScheduled = false
            removeObservation()
            if hostView !== view {
                hostView = nil
            }
        }

        func scheduleRefresh() {
            guard hostView != nil, !refreshScheduled else { return }
            refreshScheduled = true
            let generation = lifecycleGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.lifecycleGeneration else { return }
                self.refreshScheduled = false
                self.refreshObservation()
            }
        }

        private func refreshObservation() {
            guard
                let hostView,
                hostView.window != nil,
                let scrollView = hostView.enclosingScrollView
            else {
                removeObservation()
                return
            }

            guard observedScrollView !== scrollView else { return }
            removeObservation()
            observedScrollView = scrollView
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                MainActor.assumeIsolated {
                    guard self.observedScrollView === scrollView else { return }
                    guard let metrics = PDFScrollViewMetricsResolver.resolve(scrollView) else {
                        return
                    }
                    self.onScrollActivity(metrics)
                }
            }
        }

        private func removeObservation() {
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
                self.liveScrollObserver = nil
            }
            observedScrollView = nil
        }
    }
}

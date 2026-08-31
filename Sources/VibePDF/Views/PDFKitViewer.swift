// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit
import SwiftUI

/// SwiftUI 상태 모델과 AppKit `PDFView`를 연결하는 adapter다.
///
/// `NSViewRepresentable` 수명주기:
/// 1. `makeNSView`에서 PDFView를 한 번 만들고 delegate/observer를 붙인다.
/// 2. `updateNSView`에서 최신 모델 상태와 기존 PDFView의 차이만 적용한다.
/// 3. `dismantleNSView`에서 form 입력·viewport를 commit하고 observer를 해제한다.
///
/// Coordinator가 notification과 delegate를 받아 `PDFWorkspaceState`로 되돌려 보내며,
/// `isApplyingState` 같은 guard가 모델 -> 뷰 -> 모델의 무한 피드백을 막는다.
@MainActor
struct PDFKitViewer: NSViewRepresentable {
    @ObservedObject var state: PDFWorkspaceState
    @AppStorage(PDFWheelZoomModifier.defaultsKey)
    private var wheelZoomModifierValue = PDFWheelZoomModifier.defaultValue.rawValue
    @AppStorage(AppPerformanceSettings.efficientRenderingEnabledKey)
    private var efficientRenderingEnabled = AppPerformanceSettings.defaultEfficientRenderingEnabled
    private let scrollSyncCoordinator: PDFScrollSyncCoordinator?
    private let scrollSyncID: UUID?
    private let scrollSyncLocked: Bool
    private let onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)?
    private let viewportContext: PDFViewerViewportContext

    init(
        workspace: PDFWorkspaceState,
        scrollSyncCoordinator: PDFScrollSyncCoordinator? = nil,
        scrollSyncID: UUID? = nil,
        scrollSyncLocked: Bool = false,
        viewportContext: PDFViewerViewportContext = .normal,
        onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)? = nil
    ) {
        _state = ObservedObject(wrappedValue: workspace)
        self.scrollSyncCoordinator = scrollSyncCoordinator
        self.scrollSyncID = scrollSyncID
        self.scrollSyncLocked = scrollSyncLocked
        self.viewportContext = viewportContext
        self.onScrollActivity = onScrollActivity
    }

    init(
        state: PDFWorkspaceState,
        scrollSyncCoordinator: PDFScrollSyncCoordinator? = nil,
        scrollSyncID: UUID? = nil,
        scrollSyncLocked: Bool = false,
        viewportContext: PDFViewerViewportContext = .normal,
        onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)? = nil
    ) {
        _state = ObservedObject(wrappedValue: state)
        self.scrollSyncCoordinator = scrollSyncCoordinator
        self.scrollSyncID = scrollSyncID
        self.scrollSyncLocked = scrollSyncLocked
        self.viewportContext = viewportContext
        self.onScrollActivity = onScrollActivity
    }

    /// SwiftUI struct가 재생성되어도 AppKit delegate 상태를 유지할 참조 객체다.
    func makeCoordinator() -> Coordinator {
        Coordinator(
            state: state,
            viewportContext: viewportContext,
            onScrollActivity: onScrollActivity
        )
    }

    /// AppKit view의 변하지 않는 기본 설정은 생성 시 한 번만 적용한다.
    func makeNSView(context: Context) -> InteractivePDFView {
        let pdfView = InteractivePDFView(frame: .zero)
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.displaysAsBook = false
        pdfView.displayBox = .cropBox
        pdfView.backgroundColor = adaptiveCanvasColor()
        pdfView.pageShadowsEnabled = viewportContext == .normal || !efficientRenderingEnabled
        pdfView.autoScales = true
        pdfView.viewportContext = viewportContext
        pdfView.wheelZoomModifier = wheelZoomModifier
        pdfView.configure(with: state)
        context.coordinator.attach(to: pdfView)
        context.coordinator.updateScrollSyncRegistration(
            coordinator: scrollSyncCoordinator,
            id: scrollSyncID,
            locked: scrollSyncLocked
        )
        context.coordinator.refreshScrollActivityObservation()
        return pdfView
    }

    /// 매 SwiftUI 갱신마다 호출되므로 비싼 작업은 identity/revision 비교 뒤 실행한다.
    func updateNSView(_ pdfView: InteractivePDFView, context: Context) {
        let coordinator = context.coordinator
        coordinator.updateState(state)
        coordinator.updateScrollActivityHandler(onScrollActivity)
        coordinator.isApplyingState = true
        defer { coordinator.isApplyingState = false }
        var pdfKitHierarchyMayHaveChanged = false

        if pdfView.viewportContext != viewportContext {
            pdfView.viewportContext = viewportContext
        }
        pdfView.configure(with: state)
        if pdfView.wheelZoomModifier != wheelZoomModifier {
            pdfView.wheelZoomModifier = wheelZoomModifier
        }
        let pageShadowsEnabled = viewportContext == .normal || !efficientRenderingEnabled
        if pdfView.pageShadowsEnabled != pageShadowsEnabled {
            pdfView.pageShadowsEnabled = pageShadowsEnabled
        }

        let documentChanged = pdfView.document !== state.document
        if documentChanged {
            pdfKitHierarchyMayHaveChanged = true
            pdfView.document = state.document
            coordinator.lastAppliedPageIndex = nil
            coordinator.lastAppliedPage = nil
            coordinator.lastSearchSelection = nil
            if state.document != nil {
                let viewport = state.pdfViewportState(for: viewportContext)
                if
                    let scaleFactor = viewport.scaleFactor,
                    !viewport.autoScales
                {
                    pdfView.autoScales = false
                    pdfView.scaleFactor = min(20, max(0.05, scaleFactor))
                } else {
                    pdfView.autoScales = true
                }
            }
        }

        let requestedMode = Self.requestedDisplayMode(
            pageColumns: state.pageColumns,
            twoPageDisplayMode: state.twoPageDisplayMode,
            viewportContext: viewportContext
        )
        if pdfView.displayMode != requestedMode {
            pdfKitHierarchyMayHaveChanged = true
            let wasAutoScaling = pdfView.autoScales
            let previousScale = pdfView.scaleFactor
            coordinator.lastAppliedPageIndex = nil
            coordinator.lastAppliedPage = nil
            coordinator.lastSearchSelection = nil
            pdfView.displayMode = requestedMode
            if wasAutoScaling {
                pdfView.autoScales = true
            } else {
                pdfView.scaleFactor = previousScale
            }
        }

        if coordinator.lastRevision != state.revision {
            pdfKitHierarchyMayHaveChanged = true
            coordinator.lastRevision = state.revision
            pdfView.layoutDocumentView()
            pdfView.needsDisplay = true
        }

        if
            let document = state.document,
            state.currentPageIndex >= 0,
            state.currentPageIndex < document.pageCount,
            let page = document.page(at: state.currentPageIndex),
            coordinator.requiresNavigation(
                to: page,
                at: state.currentPageIndex,
                in: pdfView
            )
        {
            state.primeWidgetValues(on: page)
            coordinator.lastAppliedPageIndex = state.currentPageIndex
            coordinator.lastAppliedPage = page
            pdfView.go(to: page)
            if requestedMode == .twoUp {
                pdfView.visiblePages.forEach { state.primeWidgetValues(on: $0) }
            }
        }

        // PDFKit can replace its private document/scroll views when a document,
        // display mode, or layout changes. Refresh after those mutations and
        // once more on the next run loop after PDFKit has finished layout.
        coordinator.updateScrollSyncRegistration(
            coordinator: scrollSyncCoordinator,
            id: scrollSyncID,
            locked: scrollSyncLocked,
            forceRefresh: pdfKitHierarchyMayHaveChanged
        )
        if pdfKitHierarchyMayHaveChanged {
            pdfView.relinquishNativeFileDropDestination()
            pdfView.invalidateDocumentScrollViewCache()
            // A PDFDisplayMode change can replace PDFKit's private document
            // hierarchy. Reconnect the normal editor overlays to that hierarchy.
            pdfView.configure(with: state)
            pdfView.restoreRenderingOverlayOrderIfNeeded()
            coordinator.refreshScrollActivityObservation()
            coordinator.scheduleScrollActivityObservationRefresh()
        }
        applySearchSelection(to: pdfView, coordinator: coordinator)
        if documentChanged {
            coordinator.scheduleViewportRestoration(
                state.pdfViewportState(for: viewportContext)
            )
        }
    }

    private func adaptiveCanvasColor() -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0.051, green: 0.090, blue: 0.137, alpha: 1)
                : NSColor(red: 0.933, green: 0.914, blue: 0.871, alpha: 1)
        }
    }

    /// PDFKit이 지원하는 1·2페이지 표시 모드로 워크스페이스 선택을 변환한다.
    /// 3페이지 이상은 `WorkspaceView`에서 개요 화면으로 분기되므로 이 함수에
    /// 들어오지 않지만, 방어적으로 두 페이지 연속 보기로 정규화한다.
    static func requestedDisplayMode(
        pageColumns: Int,
        twoPageDisplayMode: PDFTwoPageDisplayMode,
        viewportContext: PDFViewerViewportContext = .normal
    ) -> PDFDisplayMode {
        guard pageColumns > 1 else { return .singlePageContinuous }
        // The comparison synchronizer coordinates normalized clip positions,
        // not discrete spread identity. Keep comparison and defensive 3+ page
        // calls on the established continuous path.
        guard viewportContext == .normal, pageColumns == 2 else {
            return .twoUpContinuous
        }
        return twoPageDisplayMode == .paged ? .twoUp : .twoUpContinuous
    }

    private var wheelZoomModifier: PDFWheelZoomModifier {
        PDFWheelZoomModifier(rawValue: wheelZoomModifierValue) ?? .defaultValue
    }

    static func dismantleNSView(_ pdfView: InteractivePDFView, coordinator: Coordinator) {
        // A replacement coordinator may already have installed its token on
        // the shared workspace. Commit through this outgoing view directly so
        // normal↔comparison/layout rebuilds cannot route the old field editor
        // to the new PDFView's handler.
        // Synchronize/commit the custom inline draft before the PDFView and its
        // native field editors leave the responder chain.
        pdfView.prepareInlineTextEditingOverlayForRemoval()
        coordinator.prepareForDismantling()
        coordinator.detach()
        pdfView.cancelInkStroke()
        pdfView.resetViewportScrollGesture()
        pdfView.prepareAnnotationEditingOverlayForRemoval()
        pdfView.workspaceState = nil
    }

    private func applySearchSelection(to pdfView: PDFView, coordinator: Coordinator) {
        coordinator.applySearchSelection(state.activeSearchSelection, to: pdfView)
    }

    @MainActor
    final class Coordinator: NSObject {
        private(set) weak var state: PDFWorkspaceState?
        weak var pdfView: InteractivePDFView?
        var isApplyingState = false
        var lastAppliedPageIndex: Int?
        weak var lastAppliedPage: PDFPage?
        var lastRevision: UUID?
        var lastSearchSelection: PDFSelection?
        private var lastSynchronizedSearchSelection: PDFSelection?
        private var activeSearchSelectionCancellable: AnyCancellable?
        private var formEventMonitor: Any?
        private var viewportScrollEventMonitor: Any?
        private weak var scrollSyncCoordinator: PDFScrollSyncCoordinator?
        private var scrollSyncID: UUID?
        private var scrollSyncLocked = false
        private var scrollSyncRefreshScheduled = false
        private weak var observedScrollView: NSScrollView?
        private var liveScrollObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var pendingLiveScrollReportWorkItem: DispatchWorkItem?
        private var liveScrollReportGeneration = UUID()
        private var lastLiveScrollDeliveryTime: TimeInterval?
        private var lastObservedVerticalScrollOrigin: CGFloat?
        private var scrollActivityRefreshScheduled = false
        private var viewportRestoreGeneration = UUID()
        private var onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)?
        private let currentTime: () -> TimeInterval
        private let viewportContext: PDFViewerViewportContext
        private let deactivationCommitToken = UUID()
        private weak var registeredDeactivationState: PDFWorkspaceState?
        var hasRegisteredDeactivationCommitHandler: Bool {
            registeredDeactivationState != nil
        }

        init(
            state: PDFWorkspaceState,
            viewportContext: PDFViewerViewportContext = .normal,
            onScrollActivity: ((PDFVerticalScrollMetrics) -> Void)? = nil,
            currentTime: @escaping () -> TimeInterval = {
                ProcessInfo.processInfo.systemUptime
            }
        ) {
            self.state = state
            self.viewportContext = viewportContext
            self.onScrollActivity = onScrollActivity
            self.currentTime = currentTime
        }

        func attach(to pdfView: InteractivePDFView) {
            detach()
            self.pdfView = pdfView
            observeActiveSearchSelection()
            registerDeactivationCommitHandlerIfNeeded()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionChanged(_:)),
                name: .PDFViewSelectionChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scaleChanged(_:)),
                name: .PDFViewScaleChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textFieldEditingBegan(_:)),
                name: NSText.didBeginEditingNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textFieldEditingEnded(_:)),
                name: NSText.didEndEditingNotification,
                object: nil
            )
            formEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseUp, .rightMouseUp, .keyUp]
            ) { [weak self, weak pdfView] event in
                guard
                    let self,
                    let pdfView,
                    event.window === pdfView.window,
                    self.eventTargetsPDFView(event, pdfView: pdfView)
                else {
                    return event
                }
                // While PDFKit's shared text field editor is active, AppKit's
                // native UndoManager owns Command-Z. Defer the document-level
                // semantic snapshot until the editor resigns, so native undo
                // is not recorded as a new inverse PDF command.
                if
                    event.type == .keyUp,
                    let textView = event.window?.firstResponder as? NSTextView,
                    textView.isFieldEditor
                {
                    return event
                }
                // PDFKit commits some controls at event end and others when
                // the field editor resigns, so check both moments.
                let interactedPage = pdfView.currentPage
                self.scheduleWidgetSynchronization(on: interactedPage, after: 0)
                self.scheduleWidgetSynchronization(on: interactedPage, after: 0.12)
                return event
            }
            viewportScrollEventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .scrollWheel
            ) { [weak self, weak pdfView] event in
                guard
                    let self,
                    let pdfView
                else { return event }
                guard event.window === pdfView.window else {
                    pdfView.finishViewportScrollGesture()
                    return event
                }
                // Ordinary trackpad/mouse scrolling stays entirely on PDFKit's
                // native event path. Only the explicit Option/Command zoom and
                // Shift-pan gestures pay for a topmost-view hit test.
                guard pdfView.viewportScrollRequiresInterception(event) else {
                    return event
                }
                guard self.eventTargetsPDFView(event, pdfView: pdfView) else {
                    pdfView.finishViewportScrollGesture()
                    return event
                }
                let handled = pdfView.handleViewportScroll(event)
                return handled ? nil : event
            }
            pdfView.onModifiedScrollGestureEnded = { [weak self] in
                self?.captureViewportState()
            }
            refreshScrollActivityObservation()
            scheduleScrollActivityObservationRefresh()
        }

        func updateState(_ state: PDFWorkspaceState) {
            guard self.state !== state else { return }
            unregisterDeactivationCommitHandler()
            activeSearchSelectionCancellable?.cancel()
            activeSearchSelectionCancellable = nil
            lastSynchronizedSearchSelection = nil
            self.state = state
            if pdfView != nil {
                observeActiveSearchSelection()
            }
            registerDeactivationCommitHandlerIfNeeded()
        }

        /// Keeps the model selection authoritative for every consumer that does
        /// not read PDFView directly (markup, Share Note, AI context). PDFKit's
        /// selection-changed notification is intentionally ignored while
        /// `updateNSView` applies state, so search navigation needs this explicit
        /// model-side bridge.
        private func observeActiveSearchSelection() {
            activeSearchSelectionCancellable?.cancel()
            activeSearchSelectionCancellable = state?.$activeSearchSelection.sink {
                [weak self, weak state] selection in
                MainActor.assumeIsolated {
                    guard let self, self.state === state else { return }
                    self.synchronizeActiveSearchSelection(selection)
                }
            }
        }

        private func synchronizeActiveSearchSelection(_ selection: PDFSelection?) {
            guard let state else { return }
            if let selection {
                lastSynchronizedSearchSelection = selection
                if state.currentSelection !== selection {
                    state.currentSelection = selection
                }
                return
            }

            if
                let previous = lastSynchronizedSearchSelection,
                state.currentSelection === previous
            {
                state.currentSelection = nil
            }
            lastSynchronizedSearchSelection = nil
        }

        /// Applies the same search selection to PDFKit and the workspace. This is
        /// internal so the representable boundary can be exercised without a
        /// SwiftUI hosting window in regression tests.
        func applySearchSelection(_ selection: PDFSelection?, to pdfView: PDFView) {
            synchronizeActiveSearchSelection(selection)

            guard let selection else {
                if let previous = lastSearchSelection {
                    pdfView.highlightedSelections = nil
                    if let current = pdfView.currentSelection, current === previous {
                        pdfView.clearSelection()
                    }
                    lastSearchSelection = nil
                }
                return
            }

            guard lastSearchSelection !== selection else { return }
            selection.color = NSColor.systemYellow.withAlphaComponent(0.62)
            pdfView.highlightedSelections = [selection]
            lastSearchSelection = selection
            pdfView.setCurrentSelection(selection, animate: true)
            pdfView.go(to: selection)
        }

        /// Ends editing only when this PDFView (or its private field editor)
        /// owns the window's first responder. Other controls and other windows
        /// are intentionally left untouched.
        func commitFocusedFormEditing() {
            guard
                let pdfView,
                let window = pdfView.window,
                let responder = window.firstResponder,
                Self.responder(responder, belongsTo: pdfView)
            else { return }
            _ = window.makeFirstResponder(pdfView)
        }

        /// The outgoing coordinator commits through its own PDFView. Other
        /// normal/comparison coordinators have separate registry tokens and are
        /// neither invoked nor removed by this local dismantling step.
        func prepareForDismantling() {
            pdfView?.commitAnnotationEditingBeforeDeactivation()
            commitFocusedFormEditing()
            state?.synchronizeWidgetValues()
            captureViewportState()
        }

        static func responder(_ responder: NSResponder, belongsTo pdfView: PDFView) -> Bool {
            guard let responderView = responder as? NSView else { return false }
            if responderView === pdfView || responderView.isDescendant(of: pdfView) {
                return true
            }

            // AppKit's shared NSTextView field editor is hosted by the window,
            // not beneath the edited control. Its delegate identifies the
            // PDFKit control that owns the current editing session.
            if
                let textView = responderView as? NSTextView,
                textView.isFieldEditor,
                let ownerView = textView.delegate as? NSView
            {
                return ownerView === pdfView || ownerView.isDescendant(of: pdfView)
            }
            return false
        }

        private func registerDeactivationCommitHandlerIfNeeded() {
            guard
                pdfView != nil,
                let state
            else { return }
            registeredDeactivationState = state
            state.installDeactivationCommitHandler(id: deactivationCommitToken) { [weak self, weak pdfView] in
                guard let self else { return }
                // Save, tab switch, close, and hibernation all enter through
                // this hook. Settle image/crop geometry first, then commit the
                // custom on-page text editor and native PDFKit form fields, so
                // no visible mutation remains only in a view hierarchy while
                // the model still appears clean.
                pdfView?.commitAnnotationEditingBeforeDeactivation()
                pdfView?.commitInlineTextEditorBeforePointerAction()
                self.commitFocusedFormEditing()
                // Quit/close persistence flushes before SwiftUI dismantles
                // the view, so capture the final zoom/scroll here as well.
                self.captureViewportState()
            }
        }

        private func unregisterDeactivationCommitHandler() {
            registeredDeactivationState?.removeDeactivationCommitHandler(
                id: deactivationCommitToken
            )
            registeredDeactivationState = nil
        }

        private func eventTargetsPDFView(_ event: NSEvent, pdfView: PDFView) -> Bool {
            if event.type == .keyUp {
                guard let responder = event.window?.firstResponder else { return false }
                return Self.responder(responder, belongsTo: pdfView)
            }

            guard let hitView = event.window?.contentView?.hitTest(event.locationInWindow) else {
                return false
            }
            return hitView === pdfView || hitView.isDescendant(of: pdfView)
        }

        func updateScrollSyncRegistration(
            coordinator: PDFScrollSyncCoordinator?,
            id: UUID?,
            locked: Bool,
            forceRefresh: Bool = false
        ) {
            let registrationChanged = scrollSyncCoordinator !== coordinator
                || scrollSyncID != id
                || scrollSyncLocked != locked
            if registrationChanged {
                if let scrollSyncCoordinator, let scrollSyncID, let pdfView {
                    scrollSyncCoordinator.unregister(id: scrollSyncID, pdfView: pdfView)
                }
                scrollSyncCoordinator = coordinator
                scrollSyncID = id
            }
            scrollSyncLocked = locked

            guard registrationChanged || forceRefresh else { return }
            guard let coordinator, let id, let pdfView else { return }
            coordinator.updateRegistration(
                pdfView: pdfView,
                id: id,
                locked: locked
            )
            scheduleScrollSyncRegistrationRefresh()
        }

        func updateScrollActivityHandler(
            _ handler: ((PDFVerticalScrollMetrics) -> Void)?
        ) {
            onScrollActivity = handler
        }

        func refreshScrollActivityObservation() {
            guard
                let pdfView,
                let scrollView = firstScrollView(in: pdfView) ?? pdfView.enclosingScrollView
            else {
                removeScrollActivityObservation()
                return
            }

            guard observedScrollView !== scrollView else { return }
            removeScrollActivityObservation()
            observedScrollView = scrollView
            lastObservedVerticalScrollOrigin = scrollView.contentView.bounds.origin.y
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                MainActor.assumeIsolated {
                    self.reportLiveScroll(from: scrollView)
                }
            }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                guard let self, let scrollView else { return }
                MainActor.assumeIsolated {
                    self.finishLiveScroll(from: scrollView)
                }
            }
        }

        func scheduleScrollActivityObservationRefresh() {
            guard !scrollActivityRefreshScheduled else { return }
            scrollActivityRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollActivityRefreshScheduled = false
                self.refreshScrollActivityObservation()
            }
        }

        func detach() {
            viewportRestoreGeneration = UUID()
            unregisterDeactivationCommitHandler()
            activeSearchSelectionCancellable?.cancel()
            activeSearchSelectionCancellable = nil
            lastSynchronizedSearchSelection = nil
            if let scrollSyncCoordinator, let scrollSyncID, let pdfView {
                scrollSyncCoordinator.unregister(id: scrollSyncID, pdfView: pdfView)
            }
            scrollSyncCoordinator = nil
            scrollSyncID = nil
            scrollSyncLocked = false
            scrollSyncRefreshScheduled = false
            scrollActivityRefreshScheduled = false
            removeScrollActivityObservation()
            NotificationCenter.default.removeObserver(self)
            if let formEventMonitor {
                NSEvent.removeMonitor(formEventMonitor)
                self.formEventMonitor = nil
            }
            if let viewportScrollEventMonitor {
                NSEvent.removeMonitor(viewportScrollEventMonitor)
                self.viewportScrollEventMonitor = nil
            }
            pdfView?.onModifiedScrollGestureEnded = nil
            pdfView = nil
        }

        private func reportLiveScroll(from scrollView: NSScrollView) {
            guard
                !isApplyingState,
                observedScrollView === scrollView
            else {
                return
            }

            let currentOriginY = scrollView.contentView.bounds.origin.y
            guard PDFLiveScrollReportingPolicy.hasMeaningfulVerticalMovement(
                from: lastObservedVerticalScrollOrigin,
                to: currentOriginY
            ) else {
                return
            }
            lastObservedVerticalScrollOrigin = currentOriginY

            let now = currentTime()
            let delay = PDFLiveScrollReportingPolicy.deliveryDelay(
                lastDeliveryTime: lastLiveScrollDeliveryTime,
                currentTime: now
            )
            if delay <= 0 {
                cancelPendingLiveScrollReport()
                deliverLiveScrollActivity(from: scrollView, at: now)
            } else if pendingLiveScrollReportWorkItem == nil {
                let generation = UUID()
                liveScrollReportGeneration = generation
                let workItem = DispatchWorkItem { [weak self, weak scrollView] in
                    guard let self, let scrollView else { return }
                    guard self.liveScrollReportGeneration == generation else { return }
                    self.pendingLiveScrollReportWorkItem = nil
                    self.deliverLiveScrollActivity(
                        from: scrollView,
                        at: self.currentTime()
                    )
                }
                pendingLiveScrollReportWorkItem = workItem
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + delay,
                    execute: workItem
                )
            }
        }

        private func deliverLiveScrollActivity(
            from scrollView: NSScrollView,
            at time: TimeInterval
        ) {
            guard !isApplyingState, observedScrollView === scrollView else { return }
            let metrics: PDFVerticalScrollMetrics?
            if usesPagedTwoPageMode {
                metrics = semanticPagedScrollMetrics()
            } else {
                metrics = PDFScrollViewMetricsResolver.resolve(scrollView)
            }
            guard let metrics else { return }
            lastLiveScrollDeliveryTime = time
            onScrollActivity?(metrics)
        }

        private func finishLiveScroll(from scrollView: NSScrollView) {
            guard observedScrollView === scrollView else { return }
            if pendingLiveScrollReportWorkItem != nil {
                cancelPendingLiveScrollReport()
                deliverLiveScrollActivity(
                    from: scrollView,
                    at: currentTime()
                )
            }
            // Session restoration only needs the settled position. Keeping this
            // write off the native delta path leaves PDFKit's tile compositor
            // free to follow the pointer while still preserving the final view.
            captureViewportState(scrollView: scrollView)
            lastObservedVerticalScrollOrigin = scrollView.contentView.bounds.origin.y
            lastLiveScrollDeliveryTime = nil
        }

        private func cancelPendingLiveScrollReport() {
            liveScrollReportGeneration = UUID()
            pendingLiveScrollReportWorkItem?.cancel()
            pendingLiveScrollReportWorkItem = nil
        }

        func captureViewportState() {
            let scrollView = pdfView.flatMap {
                firstScrollView(in: $0) ?? $0.enclosingScrollView
            }
            captureViewportState(scrollView: scrollView)
        }

        private func captureViewportState(scrollView: NSScrollView?) {
            guard let pdfView else { return }
            let progress: PDFScrollProgress?
            if
                let scrollView,
                let documentView = scrollView.contentView.documentView
            {
                progress = PDFScrollProgress.progress(
                    boundsOrigin: scrollView.contentView.bounds.origin,
                    documentFrame: documentView.frame,
                    viewportSize: scrollView.contentView.bounds.size
                )
            } else {
                progress = nil
            }
            state?.recordPDFViewport(
                autoScales: pdfView.autoScales,
                scaleFactor: pdfView.scaleFactor,
                scrollProgress: progress,
                context: viewportContext
            )
        }

        func scheduleViewportRestoration(_ viewport: PDFViewerViewportState) {
            guard
                let currentPageIndex = state?.currentPageIndex,
                viewport.scrollProgress(forPageIndex: currentPageIndex) != nil
            else { return }
            let generation = UUID()
            viewportRestoreGeneration = generation
            DispatchQueue.main.async { [weak self] in
                self?.restoreViewport(viewport, generation: generation)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.restoreViewport(viewport, generation: generation)
                }
            }
        }

        private func restoreViewport(
            _ viewport: PDFViewerViewportState,
            generation: UUID
        ) {
            guard
                viewportRestoreGeneration == generation,
                let currentPageIndex = state?.currentPageIndex,
                let progress = viewport.scrollProgress(forPageIndex: currentPageIndex),
                let pdfView,
                let scrollView = firstScrollView(in: pdfView) ?? pdfView.enclosingScrollView,
                let documentView = scrollView.contentView.documentView
            else { return }

            pdfView.layoutSubtreeIfNeeded()
            let origin = progress.boundsOrigin(
                documentFrame: documentView.frame,
                viewportSize: scrollView.contentView.bounds.size
            )
            isApplyingState = true
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isApplyingState = false
        }

        private func removeScrollActivityObservation() {
            cancelPendingLiveScrollReport()
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
                self.liveScrollObserver = nil
            }
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
                self.liveScrollEndObserver = nil
            }
            lastLiveScrollDeliveryTime = nil
            lastObservedVerticalScrollOrigin = nil
            observedScrollView = nil
        }

        private func firstScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            for subview in view.subviews {
                if let scrollView = firstScrollView(in: subview) {
                    return scrollView
                }
            }
            return nil
        }

        private func scheduleScrollSyncRegistrationRefresh() {
            guard !scrollSyncRefreshScheduled else { return }
            scrollSyncRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollSyncRefreshScheduled = false
                guard
                    let scrollSyncCoordinator = self.scrollSyncCoordinator,
                    let scrollSyncID = self.scrollSyncID,
                    let pdfView = self.pdfView
                else {
                    return
                }
                scrollSyncCoordinator.updateRegistration(
                    pdfView: pdfView,
                    id: scrollSyncID,
                    locked: self.scrollSyncLocked
                )
            }
        }

        private func scheduleWidgetSynchronization(
            on page: PDFPage?,
            after delay: TimeInterval
        ) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.state?.synchronizeWidgetValues(on: page)
            }
        }

        /// Mouse and Tab interception are the normal boundary, but accessibility
        /// or a future PDFKit implementation can still create a field editor
        /// directly. Refuse that editor before it accepts text when the workspace
        /// has no durable form-write path.
        @objc func textFieldEditingBegan(_ notification: Notification) {
            guard
                let pdfView,
                pdfView.viewportContext == .comparison
                    || state?.allowsNativeFormEditing != true,
                let textView = notification.object as? NSTextView,
                textView.isFieldEditor,
                Self.responder(textView, belongsTo: pdfView),
                let window = pdfView.window
            else { return }
            _ = window.makeFirstResponder(pdfView)
            if pdfView.viewportContext == .normal {
                state?.presentedError = L10n.string(
                    "security.user_session_read_only",
                    defaultValue: "사용자 암호로 연 PDF는 보안을 유지해 저장할 수 없어 읽기 전용으로 열립니다. 편집하려면 소유자 암호로 다시 여세요."
                )
            }
        }

        /// A field editor may resign because the user clicked a toolbar,
        /// sidebar or another window. Those clicks do not target PDFView and
        /// therefore bypass the local mouse monitor above. Observe the actual
        /// AppKit editing boundary so the complete text session becomes one
        /// semantic PDF undo command after PDFKit commits its widget value.
        @objc func textFieldEditingEnded(_ notification: Notification) {
            guard
                let pdfView,
                let textView = notification.object as? NSTextView,
                textView.isFieldEditor,
                Self.responder(textView, belongsTo: pdfView)
            else { return }
            let editedPage = pdfView.currentPage
            // didEndEditing is the semantic boundary and PDFKit has normally
            // committed the field by this point. Capture synchronously so a
            // toolbar action triggered by the same click is registered after
            // the form command, preserving chronological undo order.
            state?.synchronizeWidgetValues(on: editedPage)
            // A few PDFKit controls publish their value one run-loop later.
            // The semantic snapshot makes this a no-op in the common case.
            scheduleWidgetSynchronization(on: editedPage, after: 0.12)
        }

        func requiresNavigation(
            to requestedPage: PDFPage,
            at requestedIndex: Int,
            in pdfView: PDFView
        ) -> Bool {
            if
                usesPagedTwoPageMode,
                lastAppliedPageIndex == requestedIndex,
                lastAppliedPage === requestedPage,
                pdfView.visiblePages.contains(where: { $0 === requestedPage })
            {
                return false
            }
            return lastAppliedPageIndex != requestedIndex
                || lastAppliedPage !== requestedPage
                || pdfView.currentPage !== requestedPage
        }

        /// Identity-only compatibility seam used by document-replacement
        /// regression tests that do not construct a live PDFView hierarchy.
        func requiresNavigation(
            to requestedPage: PDFPage,
            at requestedIndex: Int,
            visiblePage: PDFPage?
        ) -> Bool {
            lastAppliedPageIndex != requestedIndex
                || lastAppliedPage !== requestedPage
                || visiblePage !== requestedPage
        }

        @objc private func pageChanged(_ notification: Notification) {
            guard
                !isApplyingState,
                let pdfView = notification.object as? PDFView,
                let document = pdfView.document,
                let page = pdfView.currentPage
            else { return }

            let index = document.index(for: page)
            guard index != NSNotFound else { return }

            if usesPagedTwoPageMode {
                pdfView.visiblePages.forEach { state?.primeWidgetValues(on: $0) }
                // `currentPage` may be the left page even after an explicit
                // jump to the right page. Preserve that exact requested index
                // while it remains inside the visible spread.
                if
                    let requestedIndex = state?.currentPageIndex,
                    let requestedPage = document.page(at: requestedIndex),
                    pdfView.visiblePages.contains(where: { $0 === requestedPage })
                {
                    lastAppliedPageIndex = requestedIndex
                    lastAppliedPage = requestedPage
                    if let metrics = semanticPagedScrollMetrics(pageIndex: requestedIndex) {
                        onScrollActivity?(metrics)
                    }
                    return
                }
            }

            lastAppliedPageIndex = index
            lastAppliedPage = page
            if state?.currentPageIndex != index {
                state?.setCurrentPage(index)
            }
            if usesPagedTwoPageMode {
                if let metrics = semanticPagedScrollMetrics(pageIndex: index) {
                    onScrollActivity?(metrics)
                }
            }
        }

        private var usesPagedTwoPageMode: Bool {
            viewportContext == .normal
                && state?.pageColumns == 2
                && state?.twoPageDisplayMode == .paged
        }

        private func semanticPagedScrollMetrics(
            pageIndex: Int? = nil
        ) -> PDFVerticalScrollMetrics? {
            guard let state, state.pageCount > 0 else { return nil }
            return PDFVerticalScrollMetrics.semantic(
                pageIndex: pageIndex ?? state.currentPageIndex,
                pageCount: state.pageCount,
                visiblePageCount: 2,
                pageStride: 2
            )
        }

        @objc private func selectionChanged(_ notification: Notification) {
            guard
                !isApplyingState,
                let pdfView = notification.object as? PDFView
            else { return }
            state?.currentSelection = pdfView.currentSelection
        }

        @objc private func scaleChanged(_ notification: Notification) {
            guard !isApplyingState, notification.object as? PDFView === pdfView else { return }
            guard pdfView?.isHandlingModifiedZoom != true else { return }
            captureViewportState()
        }
    }
}

@MainActor
final class InteractivePDFView: PDFView {
    weak var workspaceState: PDFWorkspaceState?
    var wheelZoomModifier: PDFWheelZoomModifier = .defaultValue
    /// Comparison views are intentionally read-only even when their source tab
    /// is currently in Editing mode.
    var viewportContext: PDFViewerViewportContext = .normal

    private(set) var activeTool: WorkspaceTool = .select
    fileprivate var currentInkSettings = InkSettings()
    fileprivate var inkPage: PDFPage?
    fileprivate var inkPoints: [CGPoint] = []

    private let inkOverlay = PDFInkPreviewView(frame: .zero)
    private var modifiedScrollGesture = PDFViewportModifiedScrollGestureLatch()
    private var modifiedScrollEndWorkItem: DispatchWorkItem?
    private weak var cachedDocumentScrollView: NSScrollView?
    var onModifiedScrollGestureEnded: (() -> Void)?
    /// A Widget consumes a complete mouse sequence in a normal PDFView. In a
    /// comparison viewport we swallow that sequence so PDFKit cannot create a
    /// field editor after the protected mouse-down.
    private var suppressingProtectedWidgetMouseSequence = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        relinquishNativeFileDropDestination()
        installInkOverlay()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        relinquishNativeFileDropDestination()
        installInkOverlay()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relinquishNativeFileDropDestination()
    }

    /// PDFView registers the legacy filename pasteboard type and otherwise
    /// becomes the deepest Finder destination, preventing the outer workspace
    /// receiver from seeing a drop over the rendered page. The app owns file
    /// opening at the tab/workspace boundary; PDFKit selection and annotation
    /// movement use their native pointer paths and do not need this destination.
    func relinquishNativeFileDropDestination() {
        unregisterDraggedTypes()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            AppEditCommandRouter.shared.invalidate()
        }
        return accepted
    }

    func configure(with state: PDFWorkspaceState) {
        workspaceState = state
        currentInkSettings = state.inkSettings

        // Comparison panels share the source workspace object with the regular
        // window. The user may choose Pen/Eraser in that other window after the
        // comparison panel has appeared, so an onAppear reset is insufficient.
        // Derive an effective read-only tool on every state update instead.
        let effectiveTool: WorkspaceTool = viewportContext == .comparison
            ? .select
            : state.activeTool
        if activeTool != effectiveTool {
            activeTool = effectiveTool
            if activeTool != .pen {
                cancelInkStroke()
            }
            window?.invalidateCursorRects(for: self)
        }
        // Comparison panes are strictly read-only and may show four PDFViews
        // at once. Do not allocate editor panels or annotation scanners there;
        // selection, links and scrolling remain native PDFKit behavior.
        if viewportContext == .normal {
            configureAnnotationEditingOverlay()
            configureInlineTextEditingOverlay()
            restoreRenderingOverlayOrderIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        inkOverlay.frame = bounds
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch activeTool {
        case .select:
            break
        case .text:
            addCursorRect(bounds, cursor: .iBeam)
        case .pen, .eraser:
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Events inside the floating panel never reach PDFView. Therefore an
        // event that does arrive here is an outside click and closes the prior
        // transaction before a new tool interprets the same pointer action.
        commitInlineTextEditorBeforePointerAction()
        let point = convert(event.locationInWindow, from: nil)

        suppressingProtectedWidgetMouseSequence = blockedNativeFormWidget(at: point) != nil
        if suppressingProtectedWidgetMouseSequence {
            clearAnnotationEditingSelection()
            cancelInkStroke()
            window?.makeFirstResponder(self)
            if viewportContext == .normal {
                workspaceState?.presentedError = L10n.string(
                    "security.user_session_read_only",
                    defaultValue: "사용자 암호로 연 PDF는 보안을 유지해 저장할 수 없어 읽기 전용으로 열립니다. 편집하려면 소유자 암호로 다시 여세요."
                )
            }
            return
        }

        if viewportContext == .comparison {
            // Selection, links, wheel/trackpad scrolling and ordinary PDFView
            // behavior stay native. Form Widgets are the one Select-tool case
            // that mutates a document, so intercept only that hit.
            clearAnnotationEditingSelection()
            cancelInkStroke()
            super.mouseDown(with: event)
            return
        }

        if let page = page(for: point, nearest: true) {
            workspaceState?.primeWidgetValues(on: page)
        }
        switch activeTool {
        case .select:
            clearAnnotationEditingSelection()
            super.mouseDown(with: event)
        case .text:
            handleTextClick(event)
        case .pen:
            beginInkStroke(event)
        case .eraser:
            handleEraserClick(event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if suppressingProtectedWidgetMouseSequence {
            return
        }
        guard viewportContext == .normal else {
            cancelInkStroke()
            super.mouseDragged(with: event)
            return
        }
        guard activeTool == .pen, inkPage != nil else {
            super.mouseDragged(with: event)
            return
        }
        appendInkPoint(from: event)
    }

    override func mouseUp(with event: NSEvent) {
        if suppressingProtectedWidgetMouseSequence {
            suppressingProtectedWidgetMouseSequence = false
            return
        }
        guard viewportContext == .normal else {
            cancelInkStroke()
            super.mouseUp(with: event)
            return
        }
        guard activeTool == .pen, inkPage != nil else {
            super.mouseUp(with: event)
            return
        }
        appendInkPoint(from: event)
        commitInkStroke()
    }

    override func keyDown(with event: NSEvent) {
        if suppressesNativeFormWidgetTraversal(keyCode: event.keyCode) {
            // PDFKit uses Tab/Shift-Tab to enter and cycle AcroForm controls.
            // A comparison panel has no editable field destination, so consume
            // only that traversal key. Copy, selection, arrows, Page Up/Down,
            // links and every other native PDFView shortcut still reach super.
            return
        }
        super.keyDown(with: event)
    }

    /// Small deterministic seam for the keyboard half of comparison read-only
    /// enforcement. Hardware-layout modifiers do not change the Tab key code,
    /// so this covers both forward and Shift-Tab widget traversal.
    func suppressesComparisonWidgetTraversal(keyCode: UInt16) -> Bool {
        viewportContext == .comparison && keyCode == 48
    }

    /// Normal encrypted user sessions are subject to the same protection as a
    /// comparison viewport. Missing workspace authority is deliberately blocked.
    func suppressesNativeFormWidgetTraversal(keyCode: UInt16) -> Bool {
        keyCode == 48
            && (viewportContext == .comparison
                || workspaceState?.allowsNativeFormEditing != true)
    }

    func cancelInkStroke() {
        let hadPreview = inkPage != nil || !inkPoints.isEmpty
        inkPage = nil
        inkPoints.removeAll(keepingCapacity: true)
        inkOverlay.isHidden = true
        if hadPreview {
            inkOverlay.needsDisplay = true
        }
    }

    /// Handles only an unambiguous convenience gesture. Returning `false`
    /// leaves the original NSEvent untouched so PDFKit keeps ownership of
    /// ordinary scrolling, form widgets, annotations, selection and pinch.
    @discardableResult
    func handleViewportScroll(_ event: NSEvent) -> Bool {
        let input = PDFViewportScrollInput(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            modifiers: Self.viewportModifiers(from: event.modifierFlags)
        )
        let intent = PDFViewportScrollIntentResolver.resolve(
            input,
            zoomModifier: wheelZoomModifier
        )
        let owner = modifiedScrollGesture.ownerForEvent(
            intent: intent,
            touchPhasePresent: !event.phase.isEmpty,
            touchPhaseBegan: event.phase.contains(.mayBegin)
                || event.phase.contains(.began),
            momentumPhasePresent: !event.momentumPhase.isEmpty
        )

        guard let owner else {
            modifiedScrollEndWorkItem?.cancel()
            modifiedScrollEndWorkItem = nil
            return false
        }

        switch owner {
        case .zoom:
            if let stepFactor = PDFViewportScrollIntentResolver.zoomStepFactor(
                deltaY: input.deltaY,
                hasPreciseDeltas: input.hasPreciseDeltas
            ) {
                _ = zoomAroundPointer(
                    stepFactor: stepFactor,
                    pointerInView: convert(event.locationInWindow, from: nil)
                )
            }
        case .horizontalPan:
            if let delta = PDFViewportScrollIntentResolver.horizontalPanDelta(
                deltaX: input.deltaX,
                deltaY: input.deltaY,
                hasPreciseDeltas: input.hasPreciseDeltas
            ) {
                _ = panHorizontally(wheelDelta: delta)
            }
        }

        updateModifiedScrollLifecycle(after: event)
        // An owned phase is consumed even when it reaches a scale/pan edge.
        return true
    }

    /// Cheap preflight for the local event monitor. A latched gesture keeps
    /// ownership through momentum even after the keyboard modifier is released.
    func viewportScrollRequiresInterception(_ event: NSEvent) -> Bool {
        if modifiedScrollGesture.owner != nil { return true }
        let input = PDFViewportScrollInput(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            modifiers: Self.viewportModifiers(from: event.modifierFlags)
        )
        return PDFViewportScrollIntentResolver.resolve(
            input,
            zoomModifier: wheelZoomModifier
        ) != .native
    }

    var isHandlingModifiedZoom: Bool {
        modifiedScrollGesture.owner == .zoom
    }

    func resetViewportScrollGesture() {
        modifiedScrollEndWorkItem?.cancel()
        modifiedScrollEndWorkItem = nil
        modifiedScrollGesture.reset()
    }

    func finishViewportScrollGesture() {
        let hadOwner = modifiedScrollGesture.owner != nil
        resetViewportScrollGesture()
        if hadOwner {
            onModifiedScrollGestureEnded?()
        }
    }

    func invalidateDocumentScrollViewCache() {
        cachedDocumentScrollView = nil
    }

    func restoreRenderingOverlayOrderIfNeeded() {
        restoreEditingOverlayOrderIfNeeded(above: inkOverlay)
    }

    var inkPreviewSubviewIndexForTesting: Int? {
        subviews.firstIndex { $0 === inkOverlay }
    }

    private func updateModifiedScrollLifecycle(after event: NSEvent) {
        modifiedScrollEndWorkItem?.cancel()
        modifiedScrollEndWorkItem = nil

        if
            event.phase.contains(.cancelled)
                || event.momentumPhase.contains(.ended)
                || event.momentumPhase.contains(.cancelled)
        {
            finishViewportScrollGesture()
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
            self?.finishViewportScrollGesture()
        }
        modifiedScrollEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    static func viewportModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> PDFViewportScrollModifiers {
        var result: PDFViewportScrollModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    @discardableResult
    func zoomAroundPointer(stepFactor: CGFloat, pointerInView: CGPoint) -> Bool {
        guard document != nil else { return false }
        guard let anchorPage = page(for: pointerInView, nearest: true) else { return false }
        let anchorOnPage = convert(pointerInView, to: anchorPage)
        let oldScale = scaleFactor
        let targetScale = PDFViewportScrollIntentResolver.clampedScale(
            currentScale: oldScale,
            stepFactor: stepFactor,
            minimumScale: minScaleFactor,
            maximumScale: maxScaleFactor
        )
        guard abs(targetScale - oldScale) > 0.000_001 else { return true }

        autoScales = false
        scaleFactor = targetScale
        layoutDocumentView()
        layoutSubtreeIfNeeded()

        if let scrollView = firstDocumentScrollView() {
            let clipView = scrollView.contentView
            let anchorAfterZoom = convert(anchorOnPage, from: anchorPage)
            let anchorInClip = clipView.convert(anchorAfterZoom, from: self)
            // PDFKit implements scaleFactor using NSScrollView magnification,
            // which changes clipView.bounds.size. Recompute the cursor's local
            // offset *after* scaling instead of reusing pre-scale pixels.
            let pointerInClip = clipView.convert(pointerInView, from: self)
            let pointerOffsetAfterScale = CGPoint(
                x: pointerInClip.x - clipView.bounds.origin.x,
                y: pointerInClip.y - clipView.bounds.origin.y
            )
            var proposedBounds = clipView.bounds
            proposedBounds.origin.x = anchorInClip.x - pointerOffsetAfterScale.x
            proposedBounds.origin.y = anchorInClip.y - pointerOffsetAfterScale.y
            let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
            clipView.setBoundsOrigin(constrainedBounds.origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        return true
    }

    private func panHorizontally(wheelDelta: CGFloat) -> Bool {
        guard
            wheelDelta.isFinite,
            abs(wheelDelta) > 0.0001,
            let scrollView = firstDocumentScrollView(),
            let documentView = scrollView.contentView.documentView
        else { return false }

        let clipView = scrollView.contentView
        let availableWidth = documentView.frame.width - clipView.bounds.width
        guard availableWidth > 0.5 else {
            // Shift is horizontal-only even when the fitted page has nowhere
            // to pan; passing it through could unexpectedly scroll vertically.
            return true
        }

        var proposedBounds = clipView.bounds
        proposedBounds.origin.x -= wheelDelta
        let constrainedBounds = clipView.constrainBoundsRect(proposedBounds)
        guard abs(constrainedBounds.origin.x - clipView.bounds.origin.x) > 0.0001 else {
            // This PDF canvas owns the horizontal gesture even at its edge;
            // handing it back would unexpectedly turn the same gesture into
            // vertical document scrolling.
            return true
        }
        clipView.setBoundsOrigin(constrainedBounds.origin)
        scrollView.reflectScrolledClipView(clipView)
        return true
    }

    private func firstDocumentScrollView() -> NSScrollView? {
        if
            let cachedDocumentScrollView,
            cachedDocumentScrollView === enclosingScrollView
                || cachedDocumentScrollView.isDescendant(of: self)
        {
            return cachedDocumentScrollView
        }
        let resolved = Self.firstScrollView(in: self) ?? enclosingScrollView
        cachedDocumentScrollView = resolved
        return resolved
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let result = firstScrollView(in: subview) { return result }
        }
        return nil
    }

    private func installInkOverlay() {
        inkOverlay.owner = self
        inkOverlay.isHidden = true
        inkOverlay.autoresizingMask = [.width, .height]
        inkOverlay.frame = bounds
        addSubview(inkOverlay, positioned: .above, relativeTo: nil)
    }

    /// Testable event-boundary seam for comparison-form protection.
    /// Coordinates are in this PDFView's view space.
    func comparisonWidget(at viewPoint: CGPoint) -> PDFAnnotation? {
        guard viewportContext == .comparison else { return nil }
        return widget(at: viewPoint)
    }

    /// Returns a widget only when native editing is forbidden for this viewport.
    /// Coordinates are in this PDFView's view space.
    func blockedNativeFormWidget(at viewPoint: CGPoint) -> PDFAnnotation? {
        guard
            viewportContext == .comparison
                || workspaceState?.allowsNativeFormEditing != true
        else { return nil }
        return widget(at: viewPoint)
    }

    private func widget(at viewPoint: CGPoint) -> PDFAnnotation? {
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let pagePoint = convert(viewPoint, to: page)
        return page.annotations.reversed().first { annotation in
            let type = annotation.type?.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            return type == "Widget" && annotation.bounds.contains(pagePoint)
        }
    }

    private func handleTextClick(_ event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let pagePoint = convert(viewPoint, to: page)
        let hitAnnotation = page.annotation(at: pagePoint)
        let editableAnnotation: PDFAnnotation?
        if hitAnnotation?.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText" {
            editableAnnotation = hitAnnotation
        } else {
            editableAnnotation = nil
        }

        guard let document, let state = workspaceState else { return }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return }

        if viewportContext == .normal, state.allowsInlineTextEditing {
            // Double-click editing of existing objects is handled by the
            // selection overlay. The Text tool also supports a single-click
            // path, but only for HwattakPDF-owned FreeText annotations.
            let appOwnedFreeText = editableAnnotation.flatMap { annotation in
                EditableAnnotationIdentity.kind(of: annotation) == .freeText
                    ? annotation
                    : nil
            }

            // A third-party FreeText may carry authoring semantics or custom
            // appearance data that HwattakPDF does not understand. Do not
            // reinterpret a click on that object as a request to create a new
            // blank inline annotation on top of it. Falling through preserves
            // the established review sheet, where adoption remains explicit.
            let canUseInlinePath = editableAnnotation == nil || appOwnedFreeText != nil

            // When the click falls inside one single-page PDFSelection, offer
            // an honest visual overlay replacement. The source content stream
            // is not deleted and remains searchable/copyable.
            var replacementText: String?
            var replacementBounds: CGRect?
            var replacementWasTruncated = false
            if
                appOwnedFreeText == nil,
                let selection = state.currentSelection,
                selection.pages.count == 1,
                selection.pages.first === page
            {
                let selectionBounds = selection.bounds(for: page)
                if selectionBounds.contains(pagePoint) {
                    let fragments = selection.selectionsByLine().lazy.compactMap { line -> String? in
                        guard line.pages.contains(where: { $0 === page }) else { return nil }
                        return line.string
                    }
                    let limited = InlineTextDraftLimiter.limit(fragments: fragments)
                    replacementText = limited.text
                    replacementWasTruncated = limited.wasTruncated
                    replacementBounds = selectionBounds
                }
            }

            if canUseInlinePath, state.requestInlineTextEdit(
                pageIndex: pageIndex,
                point: pagePoint,
                annotation: appOwnedFreeText,
                visualReplacementText: replacementText,
                visualReplacementBounds: replacementBounds
            ) {
                if replacementWasTruncated {
                    state.statusMessage = [
                        L10n.string("inline_text.visual_replacement_warning"),
                        L10n.format(
                            "inline_text.length_limit",
                            InlineTextDraftLimiter.maximumCharacterCount
                        ),
                    ].joined(separator: " ")
                }
                configureInlineTextEditingOverlay()
                return
            }
            if
                canUseInlinePath,
                state.inlineTextEditRejectionReason == .existingTextExceedsSafetyLimit
            {
                // The object was deliberately left byte-for-byte unchanged.
                // Do not route it into the legacy unbounded TextEditor or
                // reinterpret the click as a new annotation.
                return
            }
        }

        // Viewer/Study notes and unowned third-party FreeText retain the
        // existing transactional sheet instead of being silently adopted by
        // the direct editing overlay.
        state.requestTextEdit(
            pageIndex: pageIndex,
            point: pagePoint,
            annotation: editableAnnotation
        )
    }

    private func beginInkStroke(_ event: NSEvent) {
        // `activeTool` is a view snapshot and can be one SwiftUI update behind
        // a global mode/tool shortcut. Refuse to start from that stale snapshot
        // unless the current model still authorizes handwriting with Pen.
        guard
            viewportContext == .normal,
            let state = workspaceState,
            state.allows(.handwriting),
            state.activeTool == .pen
        else {
            cancelInkStroke()
            super.mouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        inkPage = page
        inkPoints = []
        appendInkPoint(from: event, acceptingDuplicate: true)
    }

    private func appendInkPoint(from event: NSEvent, acceptingDuplicate: Bool = false) {
        guard let page = inkPage else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let pagePoint = convert(viewPoint, to: page)
        let pageBounds = page.bounds(for: displayBox)
        let tolerance = max(2, currentInkSettings.width)
        guard pageBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(pagePoint) else { return }

        if !acceptingDuplicate, let previous = inkPoints.last {
            let distance = hypot(pagePoint.x - previous.x, pagePoint.y - previous.y)
            guard distance >= 0.35 else { return }
        }

        inkPoints.append(pagePoint)
        inkOverlay.isHidden = false
        inkOverlay.needsDisplay = true
    }

    private func commitInkStroke() {
        guard let page = inkPage else {
            cancelInkStroke()
            return
        }
        let points = inkPoints
        let committed = commitInkStroke(points, on: page)
        cancelInkStroke()
        if committed {
            needsDisplay = true
        }
    }

    /// Final mutation boundary for a native PDFKit Ink annotation.
    ///
    /// Mouse-down and mouse-up can straddle a mode or tool change. Re-checking
    /// the live model here prevents a stale drag from committing after Pen has
    /// become unavailable. The page identity check also prevents a pending
    /// stroke from being attached to a PDF that has since been replaced.
    @discardableResult
    func commitInkStroke(_ capturedPoints: [CGPoint], on page: PDFPage) -> Bool {
        guard
            viewportContext == .normal,
            let state = workspaceState,
            state.allows(.handwriting),
            state.activeTool == .pen,
            let document = state.document,
            document.index(for: page) != NSNotFound,
            let first = capturedPoints.first
        else { return false }

        var points = capturedPoints
        if points.count == 1 {
            points.append(CGPoint(x: first.x + max(0.2, currentInkSettings.width * 0.08), y: first.y))
        }

        let lineWidth = max(0.2, currentInkSettings.width)
        let padding = max(2, lineWidth * 1.25)
        let minX = points.map(\.x).min() ?? first.x
        let maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y
        let maxY = points.map(\.y).max() ?? first.y
        let bounds = CGRect(
            x: minX - padding,
            y: minY - padding,
            width: max(maxX - minX + padding * 2, padding * 2),
            height: max(maxY - minY + padding * 2, padding * 2)
        )

        let path = NSBezierPath()
        path.move(to: CGPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        let annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        PDFAnnotationPrivacy.clearImplicitAuthor(on: annotation)
        annotation.color = currentInkSettings.pdfInkColor
        annotation.modificationDate = Date()
        annotation.setValue("HwattakPDF-Ink-\(UUID().uuidString)", forAnnotationKey: .name)
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        annotation.add(path)
        page.addAnnotation(annotation)

        state.registerAddedAnnotation(
            annotation,
            on: page,
            message: L10n.string("펜 주석을 추가했습니다.")
        )
        return true
    }

    private func handleEraserClick(_ event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: false) else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let pagePoint = convert(viewPoint, to: page)
        guard let state = workspaceState else { return }
        let annotation = page.annotations.reversed().first { annotation in
            annotation.bounds.contains(pagePoint)
                && state.allowsEraserRemoval(of: annotation)
        }
        guard let annotation else { return }
        if state.removeAnnotationWithEraser(annotation, from: page) {
            needsDisplay = true
        }
    }
}

@MainActor
private final class PDFInkPreviewView: NSView {
    weak var owner: InteractivePDFView?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard
            let owner,
            let page = owner.inkPage,
            let first = owner.inkPoints.first
        else { return }

        let path = NSBezierPath()
        let firstInView = owner.convert(first, from: page)
        path.move(to: convert(firstInView, from: owner))
        for point in owner.inkPoints.dropFirst() {
            let pointInView = owner.convert(point, from: page)
            path.line(to: convert(pointInView, from: owner))
        }

        let previewWidth = max(1, owner.currentInkSettings.width * owner.scaleFactor)
        let color = owner.currentInkSettings.pdfInkColor
        NSGraphicsContext.saveGraphicsState()
        color.setStroke()
        color.setFill()
        path.lineWidth = previewWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        if owner.inkPoints.count == 1 {
            let center = convert(firstInView, from: owner)
            NSBezierPath(
                ovalIn: CGRect(
                    x: center.x - previewWidth / 2,
                    y: center.y - previewWidth / 2,
                    width: previewWidth,
                    height: previewWidth
                )
            ).fill()
        } else {
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

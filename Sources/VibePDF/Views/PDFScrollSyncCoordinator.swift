// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import PDFKit

/// A document-independent scroll position that can be mapped between PDF views
/// with different page sizes, zoom factors, and viewport dimensions.
struct PDFScrollProgress: Equatable {
    var horizontal: CGFloat
    var vertical: CGFloat

    init(horizontal: CGFloat, vertical: CGFloat) {
        self.horizontal = Self.clamped(horizontal)
        self.vertical = Self.clamped(vertical)
    }

    static func progress(
        boundsOrigin: CGPoint,
        documentFrame: CGRect,
        viewportSize: CGSize
    ) -> PDFScrollProgress {
        let minimumX = documentFrame.minX
        let minimumY = documentFrame.minY
        let horizontalRange = max(0, documentFrame.width - viewportSize.width)
        let verticalRange = max(0, documentFrame.height - viewportSize.height)

        return PDFScrollProgress(
            horizontal: normalized(
                value: boundsOrigin.x,
                minimum: minimumX,
                range: horizontalRange
            ),
            vertical: normalized(
                value: boundsOrigin.y,
                minimum: minimumY,
                range: verticalRange
            )
        )
    }

    func boundsOrigin(
        documentFrame: CGRect,
        viewportSize: CGSize
    ) -> CGPoint {
        let horizontalRange = max(0, documentFrame.width - viewportSize.width)
        let verticalRange = max(0, documentFrame.height - viewportSize.height)
        return CGPoint(
            x: documentFrame.minX + horizontal * horizontalRange,
            y: documentFrame.minY + vertical * verticalRange
        )
    }

    private static func normalized(
        value: CGFloat,
        minimum: CGFloat,
        range: CGFloat
    ) -> CGFloat {
        guard range > 0 else { return 0 }
        return clamped((value - minimum) / range)
    }

    private static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// Synchronizes normalized scrolling across any number of PDFKit participants.
///
/// The coordinator observes each PDF view's enclosing clip view. Locked panels
/// are completely isolated: they neither drive nor follow synchronization.
@MainActor
final class PDFScrollSyncCoordinator: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            if !enabled {
                applyingParticipantIDs.removeAll()
            }
        }
    }

    private struct Participant {
        weak var pdfView: PDFView?
        weak var clipView: NSClipView?
        var isLocked: Bool
        var boundsObserver: NSObjectProtocol?
    }

    private var participants: [UUID: Participant] = [:]
    private var applyingParticipantIDs: Set<UUID> = []

    init(enabled: Bool = true) {
        self.enabled = enabled
    }

    deinit {
        for participant in participants.values {
            if let observer = participant.boundsObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func register(
        pdfView: PDFView,
        id: UUID,
        locked: Bool = false
    ) {
        let clipView = scrollView(for: pdfView)?.contentView
        if
            let current = participants[id],
            current.pdfView === pdfView,
            current.clipView === clipView
        {
            var updated = current
            updated.isLocked = locked
            participants[id] = updated
            return
        }

        unregister(id: id)
        guard let clipView else { return }

        clipView.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self, weak clipView] _ in
            guard let self, let clipView else { return }
            MainActor.assumeIsolated {
                self.clipViewBoundsChanged(id: id, clipView: clipView)
            }
        }
        participants[id] = Participant(
            pdfView: pdfView,
            clipView: clipView,
            isLocked: locked,
            boundsObserver: observer
        )
        removeReleasedParticipants()
    }

    func updateRegistration(
        pdfView: PDFView,
        id: UUID,
        locked: Bool
    ) {
        register(pdfView: pdfView, id: id, locked: locked)
    }

    func unregister(id: UUID, pdfView expectedPDFView: PDFView? = nil) {
        guard let participant = participants[id] else {
            applyingParticipantIDs.remove(id)
            return
        }
        // SwiftUI can create a replacement view with the same logical ID
        // before dismantling its predecessor. The old teardown must not remove
        // the replacement's registration.
        if let expectedPDFView, participant.pdfView !== expectedPDFView {
            return
        }
        participants.removeValue(forKey: id)
        if let observer = participant.boundsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        applyingParticipantIDs.remove(id)
    }

    private func clipViewBoundsChanged(id: UUID, clipView: NSClipView) {
        guard
            enabled,
            !applyingParticipantIDs.contains(id),
            let source = participants[id],
            !source.isLocked,
            source.clipView === clipView,
            let sourceDocumentView = clipView.documentView
        else {
            return
        }

        let progress = PDFScrollProgress.progress(
            boundsOrigin: clipView.bounds.origin,
            documentFrame: sourceDocumentView.frame,
            viewportSize: clipView.bounds.size
        )

        removeReleasedParticipants()
        for (targetID, participant) in participants where targetID != id && !participant.isLocked {
            guard
                let targetClipView = participant.clipView,
                let targetDocumentView = targetClipView.documentView
            else {
                continue
            }

            let targetOrigin = progress.boundsOrigin(
                documentFrame: targetDocumentView.frame,
                viewportSize: targetClipView.bounds.size
            )
            guard !approximatelyEqual(targetClipView.bounds.origin, targetOrigin) else {
                continue
            }

            applyingParticipantIDs.insert(targetID)
            targetClipView.setBoundsOrigin(targetOrigin)
            targetClipView.enclosingScrollView?.reflectScrolledClipView(targetClipView)
            applyingParticipantIDs.remove(targetID)
        }
    }

    private func scrollView(for pdfView: PDFView) -> NSScrollView? {
        // Prefer PDFKit's document scroll view. An enclosing scroll view, when
        // present, belongs to the host UI and does not describe PDF progress.
        if let scrollView = firstScrollView(in: pdfView) {
            return scrollView
        }
        return pdfView.enclosingScrollView
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

    private func removeReleasedParticipants() {
        let releasedIDs = participants.compactMap { id, participant in
            participant.pdfView == nil || participant.clipView == nil ? id : nil
        }
        for id in releasedIDs {
            unregister(id: id)
        }
    }

    private func approximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.25 && abs(lhs.y - rhs.y) < 0.25
    }
}

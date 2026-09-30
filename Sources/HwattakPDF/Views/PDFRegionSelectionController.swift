// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

enum PDFTextSelectionGeometry {
    /// Sample only the clicked page. A corrupt font ascent can make a single
    /// character selection hundreds of pages tall, even when glyphs look fine.
    static func needsRegionSelection(on page: PDFPage) -> Bool {
        let count = page.numberOfCharacters
        guard count > 0 else { return false }
        let box = page.bounds(for: .cropBox)
        let limit = max(box.width, box.height) * 4
        guard limit.isFinite, limit > 0 else { return false }
        for sample in 0..<min(count, 24) {
            let index = sample * max(0, count - 1) / max(1, min(count, 24) - 1)
            guard let selection = page.selection(for: NSRange(location: index, length: 1)) else { continue }
            let rect = selection.bounds(for: page)
            if !rect.isNull && (!rect.width.isFinite || !rect.height.isFinite
                || rect.width > limit || rect.height > limit) { return true }
        }
        return false
    }
}

/// An ephemeral selection only: original PDF bytes, annotations and OCR
/// checkpoints are never rewritten. Damaged font metrics are repaired in a
/// selection-only page; explicit region selection is recognized on-device.
@MainActor
final class PDFRegionSelectionController {
    weak var owner: InteractivePDFView?
    private let overlay = PDFRegionSelectionOverlay(frame: .zero)
    private weak var document: PDFDocument?
    private var revision: UUID?
    private var geometryCache: [(page: PDFPage, damaged: Bool, proxy: PDFNativeSelectionProxy?)] = []
    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var page: PDFPage?
    private var start: CGPoint?
    private var region: CGRect?
    private var nativeProxy: PDFNativeSelectionProxy?
    private var nativeAnchor: PDFSelection?
    private var nativeClickCount = 1
    private var nativeHasDragged = false
    private var nativeFragments: [PDFRegionTextFragment] = []
    private weak var observedClipView: NSClipView?
    private var boundsObserver: NSObjectProtocol?
    private(set) var selection: PDFRegionTextSelection?
    var isDragging: Bool { start != nil }
    var isActive: Bool { page != nil }

    init(owner: InteractivePDFView) {
        self.owner = owner
        overlay.controller = self
    }

    deinit {
        task?.cancel()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    func synchronize() {
        guard let owner else { return }
        let newRevision = owner.workspaceState?.revision
        if document !== owner.document || revision != newRevision {
            cancel()
            document = owner.document
            revision = newRevision
            geometryCache.removeAll()
        }
        if owner.activeTool != .select
            || (selection != nil && owner.workspaceState?.currentSelection !== selection)
            || (isActive && owner.workspaceState?.currentSelection != nil
                && owner.workspaceState?.currentSelection !== selection)
            || (page != nil && !owner.visiblePages.contains(where: { $0 === page })) {
            cancel()
        }
        refreshOverlay()
    }

    func refreshOverlay() {
        guard let owner else { return }
        owner.positionRegionSelectionOverlay(overlay)
        overlay.frame = owner.bounds
        overlay.isHidden = !isActive
        overlay.needsDisplay = true
        let clipView = owner.documentView?.enclosingScrollView?.contentView
        if observedClipView !== clipView {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            observedClipView = clipView
            boundsObserver = nil
            if let clipView {
                clipView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.overlay.needsDisplay = true }
                }
            }
        }
    }

    @discardableResult
    func begin(with event: NSEvent) -> Bool {
        cancel()
        guard let owner, owner.activeTool == .select,
              let state = owner.workspaceState, state.allows(.copyAndPaste),
              owner.document === state.document else { return false }
        let point = owner.convert(event.locationInWindow, from: nil)
        guard let page = owner.page(for: point, nearest: false) else { return false }
        let pagePoint = owner.convert(point, to: page)
        // Native links and form widgets retain their own pointer behavior.
        guard !page.annotations.contains(where: {
            ($0.type == "Link" || $0.type == "Widget") && $0.bounds.contains(pagePoint)
        }) else { return false }
        let explicit = event.modifierFlags.contains(.option)
        let damaged: Bool
        let proxy: PDFNativeSelectionProxy?
        if let cached = geometryCache.first(where: { $0.page === page }) {
            damaged = cached.damaged
            proxy = cached.proxy
        } else {
            damaged = PDFTextSelectionGeometry.needsRegionSelection(on: page)
            proxy = damaged ? PDFNativeSelectionProxy.makePage(for: page) : nil
            geometryCache.append((page, damaged, proxy))
            if geometryCache.count > 4 { geometryCache.removeFirst() }
        }
        guard explicit || damaged else { return false }
        owner.clearSelection()
        state.currentSelection = nil
        self.page = page
        start = pagePoint
        nativeProxy = explicit ? nil : proxy
        nativeClickCount = event.clickCount
        if let proxy = nativeProxy {
            if nativeClickCount >= 3 {
                nativeAnchor = proxy.page.selectionForLine(at: pagePoint)
            } else if nativeClickCount == 2 {
                nativeAnchor = proxy.page.selectionForWord(at: pagePoint)
            }
            if let nativeAnchor { applyNativeSelection(nativeAnchor) }
        } else {
            region = CGRect(origin: pagePoint, size: .zero)
            state.statusMessage = L10n.string("selection.region_drag")
        }
        owner.window?.makeFirstResponder(owner)
        refreshOverlay()
        return true
    }

    func drag(with event: NSEvent) {
        guard let owner, let page, let start else { return }
        owner.autoscroll(with: event)
        let end = owner.convert(owner.convert(event.locationInWindow, from: nil), to: page)
        if let proxy = nativeProxy {
            if nativeClickCount < 2, !nativeHasDragged,
               hypot(end.x - start.x, end.y - start.y) * owner.scaleFactor < 2 { return }
            nativeHasDragged = true
            var result = proxy.page.selection(from: start, to: end)
            if let anchor = nativeAnchor {
                let extent = nativeClickCount >= 3
                    ? proxy.page.selectionForLine(at: end)
                    : proxy.page.selectionForWord(at: end)
                // Combining selections with add() can retain overlapping text
                // ranges. Build one character range for word/line dragging.
                var combined: NSRange?
                for part in [result, anchor, extent].compactMap({ $0 }) {
                    for index in 0..<part.numberOfTextRanges(on: proxy.page) {
                        let range = part.range(at: index, on: proxy.page)
                        guard range.location != NSNotFound else { continue }
                        combined = combined.map { NSUnionRange($0, range) } ?? range
                    }
                }
                if let combined { result = proxy.page.selection(for: combined) }
            }
            applyNativeSelection(result)
            return
        }
        region = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(start.x - end.x), height: abs(start.y - end.y))
            .intersection(page.bounds(for: .cropBox))
        refreshOverlay()
    }

    func end(with event: NSEvent) {
        drag(with: event)
        start = nil
        if nativeProxy != nil {
            if selection == nil { cancel() }
            return
        }
        guard let owner, let state = owner.workspaceState, let page,
              let document = owner.document, document === state.document,
              state.allows(.copyAndPaste), let region, !region.isNull,
              region.width * owner.scaleFactor >= 4,
              region.height * owner.scaleFactor >= 4 else {
            cancel()
            return
        }
        let id = UUID()
        requestID = id
        let capturedRevision = state.revision
        state.statusMessage = L10n.string("selection.region_recognizing")
        task = Task { [weak self, weak state, weak document, weak page] in
            do {
                // Yield once so the completed rectangle/progress can be drawn.
                await Task.yield()
                try Task.checkCancellation()
                guard let page else { return }
                let snapshot = try PDFRegionTextRecognizer.snapshot(page: page, region: region)
                let fragments = try await PDFRegionTextRecognizer.recognize(snapshot)
                try Task.checkCancellation()
                guard let self, self.requestID == id, let state, let document,
                      self.owner?.document === document, state.document === document,
                      state.revision == capturedRevision, state.allows(.copyAndPaste),
                      state.currentSelection == nil,
                      self.owner?.activeTool == .select,
                      document.index(for: page) != NSNotFound,
                      self.owner?.visiblePages.contains(where: { $0 === page }) == true else { return }
                self.task = nil
                self.requestID = nil
                guard !fragments.isEmpty else {
                    self.cancel()
                    state.statusMessage = L10n.string("selection.region_empty")
                    return
                }
                let result = PDFRegionTextSelection(document: document, page: page, fragments: fragments)
                self.selection = result
                self.region = nil
                state.currentSelection = result
                state.statusMessage = L10n.string("selection.region_ready")
                self.refreshOverlay()
            } catch is CancellationError {
                // A newer gesture/navigation owns the current status/selection.
            } catch {
                guard let self, self.requestID == id else { return }
                self.cancel()
                state?.statusMessage = L10n.string("selection.region_failed")
            }
        }
    }

    private func applyNativeSelection(_ result: PDFSelection?) {
        guard let owner, let page, let proxy = nativeProxy,
              let document = owner.document, let state = owner.workspaceState,
              document === state.document, state.allows(.copyAndPaste) else { return }
        let fragments = result?.selectionsByLine().compactMap { line -> PDFRegionTextFragment? in
            guard let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PDFRegionTextFragment(text: text, bounds: line.bounds(for: proxy.page))
        } ?? []
        // Publish only when the character boundary changes, not on every pixel.
        guard fragments != nativeFragments else { return }
        nativeFragments = fragments
        let adapted = PDFRegionTextSelection(document: document, page: page, fragments: fragments)
        selection = adapted.fragments.isEmpty ? nil : adapted
        state.currentSelection = selection
        state.statusMessage = L10n.string(selection == nil ? "status.ready" : "selection.selected")
        refreshOverlay()
    }

    func cancel() {
        if isActive, let state = owner?.workspaceState,
           state.statusMessage == L10n.string("selection.region_recognizing")
                || state.statusMessage == L10n.string("selection.region_drag") {
            state.statusMessage = L10n.string("status.ready")
        }
        requestID = nil
        task?.cancel()
        task = nil
        if let selection, owner?.workspaceState?.currentSelection === selection {
            owner?.workspaceState?.currentSelection = nil
        }
        selection = nil
        page = nil
        start = nil
        region = nil
        nativeProxy = nil
        nativeAnchor = nil
        nativeClickCount = 1
        nativeHasDragged = false
        nativeFragments = []
        overlay.isHidden = true
        overlay.needsDisplay = true
    }

    func draw(in view: NSView) {
        guard let owner, let page else { return }
        let rectangles: [CGRect]
        if let region { rectangles = [region] }
        else { rectangles = selection?.fragments.map(\.bounds) ?? [] }
        // A single path is filled once, so overlapping boxes cannot accumulate
        // into the opaque blue bands seen in malformed native selections.
        let path = NSBezierPath()
        path.windingRule = .nonZero
        for rectangle in rectangles {
            path.appendRect(view.convert(owner.convert(rectangle, from: page), from: owner))
        }
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.25).setFill()
        path.fill()
        if region != nil {
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

@MainActor
private final class PDFRegionSelectionOverlay: NSView {
    weak var controller: PDFRegionSelectionController?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { controller?.draw(in: self) }
}

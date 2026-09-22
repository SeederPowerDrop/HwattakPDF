// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Transparent AppKit layer that draws selection handles over `PDFView`.
///
/// PDF annotations live in *page coordinates*, while mouse events and the
/// blue/orange handles live in *window/view coordinates*. Keeping this as a
/// sibling overlay avoids storing editor decorations in the PDF itself (which
/// is why the resize handles and delete affordance never appear in saved files).
/// All PDFKit object access stays on the main actor.
@MainActor
final class PDFAnnotationEditingOverlayView: NSView {
    /// A live drag mutates PDFKit objects before mouse-up so the user gets an
    /// immediate preview. Consequently we must retain enough immutable state
    /// to undo that preview if the mode/tool/document changes mid-gesture.
    /// The annotation and page order snapshots also prevent a stale mouse-up
    /// from committing into a page graph that another operation replaced.
    private struct GeometryMutationSnapshot {
        let annotation: PDFAnnotation
        let page: PDFPage
        let document: PDFDocument
        let pageIndex: Int
        let annotationOrder: [PDFAnnotation]
        let kind: EditableAnnotationKind
        let bounds: CGRect
        let cropRect: CGRect?
        let modificationDate: Date?
    }

    /// A drag remembers its starting state instead of incrementally modifying
    /// an already-modified rectangle. This prevents accumulated rounding error
    /// and gives the undo command an exact "before" value.
    private enum DragOperation {
        case moving(start: CGPoint, snapshot: GeometryMutationSnapshot)
        case resizing(
            handle: ImageAnnotationHandle,
            snapshot: GeometryMutationSnapshot
        )
        case cropping(
            handle: ImageAnnotationHandle,
            snapshot: GeometryMutationSnapshot
        )

        var snapshot: GeometryMutationSnapshot {
            switch self {
            case let .moving(_, snapshot),
                 let .resizing(_, snapshot),
                 let .cropping(_, snapshot):
                return snapshot
            }
        }
    }

    weak var owner: InteractivePDFView?

    private weak var selectedAnnotation: PDFAnnotation?
    private weak var selectedPage: PDFPage?
    private var dragOperation: DragOperation?
    private var isCropping = false
    private var cropSessionSnapshot: GeometryMutationSnapshot?
    private var boundsObserver: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?
    private weak var observedClipView: NSClipView?
    private(set) var superviewAttachmentCount = 0

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            superviewAttachmentCount += 1
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            AppEditCommandRouter.shared.invalidate()
        }
        return accepted
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Scroll-wheel routing never selects or drags an annotation. Bypass the
        // reverse annotation scan so native 120 Hz panning reaches PDFKit with
        // no editor-overlay work.
        if NSApp.currentEvent?.type == .scrollWheel { return nil }
        guard owner?.activeTool == .select else { return nil }
        validateSelection()
        if handle(at: point) != nil || editableAnnotation(at: point) != nil {
            return self
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner, owner.activeTool == .select else { return }
        let point = convert(event.locationInWindow, from: nil)

        // Handles take precedence over the annotation body. Otherwise a click
        // on a corner would start moving the object instead of resizing it.
        if
            let annotation = selectedAnnotation,
            let page = selectedPage,
            let selectedHandle = handle(at: point),
            let snapshot = geometrySnapshot(for: annotation, on: page)
        {
            if isCropping, annotation is ImageStampAnnotation {
                dragOperation = .cropping(
                    handle: selectedHandle,
                    snapshot: snapshot
                )
            } else {
                dragOperation = .resizing(
                    handle: selectedHandle,
                    snapshot: snapshot
                )
            }
            window?.makeFirstResponder(self)
            return
        }

        guard
            let hit = editableAnnotation(at: point),
            let pagePoint = pagePoint(for: event, on: hit.page)
        else {
            clearSelection()
            return
        }

        // In Editing mode, a double-click on an app-owned FreeText object
        // enters the exact same inline transaction as the Text tool. Viewer,
        // Study, and comparison canvases never take this branch, preserving
        // their normal select/copy and read-only behavior.
        if
            event.clickCount >= 2,
            hit.kind == .freeText,
            owner.viewportContext == .normal,
            owner.workspaceState?.allowsInlineTextEditing == true,
            let document = owner.document
        {
            let pageIndex = document.index(for: hit.page)
            if
                pageIndex != NSNotFound,
                owner.workspaceState?.requestInlineTextEdit(
                    pageIndex: pageIndex,
                    point: pagePoint,
                    annotation: hit.annotation
                ) == true
            {
                selectedAnnotation = nil
                selectedPage = nil
                dragOperation = nil
                owner.configureInlineTextEditingOverlay()
                needsDisplay = true
                return
            }
            if
                owner.workspaceState?.inlineTextEditRejectionReason
                    == .existingTextExceedsSafetyLimit
            {
                // Keep the selected PDF object untouched. In particular, do
                // not start a move gesture after a double-click that the text
                // safety policy has already handled with a visible message.
                return
            }
        }

        if selectedAnnotation !== hit.annotation {
            finishCropping()
            selectedAnnotation = hit.annotation
            selectedPage = hit.page
            isCropping = false
            owner.workspaceState?.statusMessage = selectionMessage(for: hit.kind)
        }
        window?.makeFirstResponder(self)
        if !isCropping {
            guard let snapshot = geometrySnapshot(for: hit.annotation, on: hit.page) else {
                clearSelection()
                return
            }
            dragOperation = .moving(
                start: pagePoint,
                snapshot: snapshot
            )
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let owner,
            let annotation = selectedAnnotation,
            let page = selectedPage,
            let point = pagePoint(for: event, on: page),
            let dragOperation
        else { return }
        guard isAuthorizedForCommit(dragOperation.snapshot) else {
            rollbackActiveDrag()
            discardSelectionState()
            owner.needsDisplay = true
            needsDisplay = true
            return
        }

        // Geometry helpers operate only in page coordinates. The overlay does
        // the AppKit/PDFKit conversion once and delegates clamping/aspect-ratio
        // rules to the pure helpers, which are easier to unit-test.
        let pageBounds = page.bounds(for: owner.displayBox)
        switch dragOperation {
        case let .moving(start, snapshot):
            annotation.bounds = ImageAnnotationGeometry.movedBounds(
                snapshot.bounds,
                translation: CGSize(width: point.x - start.x, height: point.y - start.y),
                within: pageBounds
            )

        case let .resizing(handle, snapshot):
            annotation.bounds = ImageAnnotationGeometry.resizedBounds(
                snapshot.bounds,
                handle: handle,
                draggedTo: point,
                within: pageBounds,
                preservingAspectRatio: !event.modifierFlags.contains(.shift)
            )

        case let .cropping(handle, snapshot):
            guard
                let imageAnnotation = annotation as? ImageStampAnnotation,
                let originalCrop = snapshot.cropRect
            else {
                rollbackActiveDrag()
                discardSelectionState()
                return
            }
            let croppedBounds = ImageAnnotationGeometry.resizedBounds(
                snapshot.bounds,
                handle: handle,
                draggedTo: point,
                within: snapshot.bounds,
                minimumSize: ImageAnnotationGeometry.minimumDisplaySize,
                preservingAspectRatio: false
            )
            imageAnnotation.bounds = croppedBounds
            imageAnnotation.updateCropRect(
                ImageAnnotationGeometry.cropRect(
                    originalCrop,
                    displayedIn: snapshot.bounds,
                    croppedTo: croppedBounds
                )
            )
        }

        annotation.modificationDate = Date()
        owner.needsDisplay = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard
            let annotation = selectedAnnotation,
            let page = selectedPage,
            let operation = dragOperation
        else { return }
        defer { dragOperation = nil }
        let snapshot = operation.snapshot
        guard
            annotation === snapshot.annotation,
            page === snapshot.page,
            isAuthorizedForCommit(snapshot)
        else {
            rollbackActiveDrag()
            discardSelectionState()
            owner?.needsDisplay = true
            needsDisplay = true
            return
        }

        let changed: Bool
        let message: String
        switch operation {
        case .moving:
            changed = !approximatelyEqual(annotation.bounds, snapshot.bounds)
            message = movementMessage(for: annotation)
        case .resizing:
            changed = !approximatelyEqual(annotation.bounds, snapshot.bounds)
            message = EditableAnnotationIdentity.kind(of: annotation) == .image
                ? L10n.string("이미지 크기를 변경했습니다.")
                : L10n.string("status.annotation_changed")
        case .cropping:
            let cropChanged = if
                let image = annotation as? ImageStampAnnotation,
                let originalCrop = snapshot.cropRect
            {
                !approximatelyEqual(image.normalizedCropRect, originalCrop)
            } else {
                false
            }
            changed = !approximatelyEqual(annotation.bounds, snapshot.bounds) || cropChanged
            message = L10n.string("이미지를 잘랐습니다.")
        }

        // Live dragging already changed the PDFAnnotation. Mouse-up therefore
        // registers an *already applied* history command rather than applying
        // the edit a second time. Crop mode is committed once for the whole
        // session so several handle adjustments still consume one undo step.
        if changed {
            switch operation {
            case .moving, .resizing:
                owner?.workspaceState?.registerAnnotationGeometryChange(
                    annotation,
                    on: page,
                    from: snapshot.bounds,
                    originalModificationDate: snapshot.modificationDate,
                    message: message
                )
            case .cropping:
                // Crop mode is one logical session. It is recorded once by
                // finishCropping(), not once for every handle drag.
                break
            }
        } else if !isCropping {
            restoreGeometry(from: snapshot)
        }
        owner?.needsDisplay = true
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        // A context-menu command is a second semantic transaction. Never let
        // it observe geometry that exists only as an unrecorded mouse-drag
        // preview, or Undo could later report a clean checkpoint while leaving
        // those preview bounds in the PDF graph.
        rollbackActiveDrag()
        let point = convert(event.locationInWindow, from: nil)
        if let hit = editableAnnotation(at: point), selectedAnnotation !== hit.annotation {
            finishCropping()
            selectedAnnotation = hit.annotation
            selectedPage = hit.page
            isCropping = false
            owner?.workspaceState?.statusMessage = selectionMessage(for: hit.kind)
            needsDisplay = true
        }
        guard selectedAnnotation != nil, let menu = editingMenu() else {
            super.rightMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func keyDown(with event: NSEvent) {
        guard let selectedAnnotation else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == 53 { // Escape
            if isCropping {
                cancelCropping()
            } else {
                clearSelection()
            }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Enter
            if isCropping {
                finishCropping()
                needsDisplay = true
                return
            }
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / forward delete
            rollbackActiveDrag()
            deleteSelectedAnnotation(nil)
            return
        }

        if
            EditableAnnotationIdentity.kind(of: selectedAnnotation) == .image,
            event.modifierFlags.contains(.command)
        {
            let characters = event.charactersIgnoringModifiers ?? ""
            if characters == "]" {
                rollbackActiveDrag()
                reorderSelectedImage(
                    event.modifierFlags.contains(.option) ? .bringToFront : .bringForward
                )
                return
            }
            if characters == "[" {
                rollbackActiveDrag()
                reorderSelectedImage(
                    event.modifierFlags.contains(.option) ? .sendToBack : .sendBackward
                )
                return
            }
        }

        let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let translation: CGSize?
        switch event.keyCode {
        case 123: translation = CGSize(width: -distance, height: 0)
        case 124: translation = CGSize(width: distance, height: 0)
        case 125: translation = CGSize(width: 0, height: -distance)
        case 126: translation = CGSize(width: 0, height: distance)
        default: translation = nil
        }
        guard let translation else {
            super.keyDown(with: event)
            return
        }
        rollbackActiveDrag()
        moveSelectedAnnotation(by: translation)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard
            let annotation = selectedAnnotation,
            let page = selectedPage,
            let kind = EditableAnnotationIdentity.kind(of: annotation)
        else { return }
        let centers = handleCenters(for: annotation, on: page)
        guard centers.count == ImageAnnotationHandle.allCases.count else { return }

        // Everything below is editor chrome only. `draw(_:)` paints into this
        // transparent NSView, not into `PDFPage`, so it is never serialized.
        let color = isCropping ? NSColor.systemOrange : NSColor.controlAccentColor
        let outline = NSBezierPath()
        guard
            let bottomLeft = centers[.bottomLeft],
            let bottomRight = centers[.bottomRight],
            let topRight = centers[.topRight],
            let topLeft = centers[.topLeft]
        else { return }
        outline.move(to: bottomLeft)
        outline.line(to: bottomRight)
        outline.line(to: topRight)
        outline.line(to: topLeft)
        outline.close()

        NSGraphicsContext.saveGraphicsState()
        color.setStroke()
        outline.lineWidth = 2
        if isCropping {
            outline.setLineDash([5, 3], count: 2, phase: 0)
        }
        outline.stroke()

        if kind.canResize {
            for center in centers.values {
                let handleBounds = CGRect(
                    x: center.x - 5,
                    y: center.y - 5,
                    width: 10,
                    height: 10
                )
                NSColor.windowBackgroundColor.setFill()
                NSBezierPath(roundedRect: handleBounds, xRadius: 2, yRadius: 2).fill()
                color.setStroke()
                let border = NSBezierPath(roundedRect: handleBounds, xRadius: 2, yRadius: 2)
                border.lineWidth = 2
                border.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        if isCropping {
            drawCropHint(near: topLeft, color: color)
        }
    }

    func refreshForConfiguration() {
        refreshScrollObservation()
        let hadSelection = selectedAnnotation != nil
        // SwiftUI can update for harmless reasons (search/status text) while
        // AppKit is still delivering a drag. Preserve an authorized preview,
        // but roll it back immediately when its original authority/identity
        // assumptions no longer hold (for example Editing -> Study).
        if let operation = dragOperation, !isAuthorizedForCommit(operation.snapshot) {
            rollbackActiveDrag()
        }
        if owner?.activeTool != .select {
            finishCropping()
            discardSelectionState()
        } else {
            validateSelection()
        }
        if hadSelection || selectedAnnotation != nil {
            needsDisplay = true
        }
    }

    func clearSelection() {
        let hadSelection = selectedAnnotation != nil
        rollbackActiveDrag()
        finishCropping()
        discardSelectionState()
        if hadSelection {
            needsDisplay = true
        }
    }

    /// Settles the overlay's live transaction before Save/close/tab switch.
    ///
    /// A completed crop stays visible before the user presses Return, but it
    /// is not in history (and therefore not dirty) until `finishCropping()`.
    /// Lifecycle code must call this synchronously before it decides whether a
    /// document needs saving. A mouse drag still in flight is only a preview
    /// and is rolled back; an already completed crop session is committed as
    /// one undoable edit.
    func prepareForDeactivation() {
        rollbackActiveDrag()
        finishCropping()
        owner?.needsDisplay = true
        needsDisplay = true
    }

    func prepareForRemoval() {
        rollbackActiveDrag()
        finishCropping()
        discardSelectionState()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        if let scaleObserver {
            NotificationCenter.default.removeObserver(scaleObserver)
            self.scaleObserver = nil
        }
        observedClipView = nil
        owner = nil
    }

    private func editableAnnotation(
        at overlayPoint: CGPoint
    ) -> (annotation: PDFAnnotation, page: PDFPage, kind: EditableAnnotationKind)? {
        guard let owner, owner.viewportContext == .normal else { return nil }
        // Walk overlay -> PDFView -> PDFPage. PDFKit's `convert` APIs also
        // account for zoom, rotation and the active display box.
        let ownerPoint = owner.convert(overlayPoint, from: self)
        guard let page = owner.page(for: ownerPoint, nearest: false) else { return nil }
        let point = owner.convert(ownerPoint, to: page)
        guard let annotation = page.annotations.reversed().first(where: { annotation in
            guard let kind = EditableAnnotationIdentity.kind(of: annotation) else {
                return false
            }
            return owner.workspaceState?.allowsAnnotationEditing(
                kind,
                annotation: annotation
            ) == true
                && annotation.bounds.contains(point)
        }), let kind = EditableAnnotationIdentity.kind(of: annotation) else { return nil }
        return (annotation, page, kind)
    }

    private func pagePoint(for event: NSEvent, on page: PDFPage) -> CGPoint? {
        guard let owner else { return nil }
        let ownerPoint = owner.convert(event.locationInWindow, from: nil)
        return owner.convert(ownerPoint, to: page)
    }

    private func handle(at point: CGPoint) -> ImageAnnotationHandle? {
        guard
            let annotation = selectedAnnotation,
            let page = selectedPage,
            EditableAnnotationIdentity.kind(of: annotation)?.canResize == true
        else { return nil }
        let centers = handleCenters(for: annotation, on: page)
        return ImageAnnotationHandle.allCases.first { handle in
            guard let center = centers[handle] else { return false }
            return CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16).contains(point)
        }
    }

    private func handleCenters(
        for annotation: PDFAnnotation,
        on page: PDFPage
    ) -> [ImageAnnotationHandle: CGPoint] {
        guard let owner else { return [:] }
        let bounds = annotation.bounds
        let pagePoints: [ImageAnnotationHandle: CGPoint] = [
            .bottomLeft: CGPoint(x: bounds.minX, y: bounds.minY),
            .bottomRight: CGPoint(x: bounds.maxX, y: bounds.minY),
            .topLeft: CGPoint(x: bounds.minX, y: bounds.maxY),
            .topRight: CGPoint(x: bounds.maxX, y: bounds.maxY),
        ]
        return pagePoints.mapValues { pagePoint in
            let ownerPoint = owner.convert(pagePoint, from: page)
            return convert(ownerPoint, from: owner)
        }
    }

    private func moveSelectedAnnotation(by translation: CGSize) {
        guard
            let owner,
            let annotation = selectedAnnotation,
            let page = selectedPage,
            let snapshot = geometrySnapshot(for: annotation, on: page),
            isAuthorizedForCommit(snapshot)
        else { return }
        let updatedBounds = ImageAnnotationGeometry.movedBounds(
            snapshot.bounds,
            translation: translation,
            within: page.bounds(for: owner.displayBox)
        )
        guard !approximatelyEqual(snapshot.bounds, updatedBounds) else { return }
        annotation.bounds = updatedBounds
        annotation.modificationDate = Date()
        owner.workspaceState?.registerAnnotationGeometryChange(
            annotation,
            on: page,
            from: snapshot.bounds,
            originalModificationDate: snapshot.modificationDate,
            message: movementMessage(for: annotation)
        )
        owner.needsDisplay = true
        needsDisplay = true
    }

    private func editingMenu() -> NSMenu? {
        guard
            let annotation = selectedAnnotation,
            let page = selectedPage,
            EditableAnnotationIdentity.kind(of: annotation)?.hasImageEditingMenu == true,
            let snapshot = geometrySnapshot(for: annotation, on: page),
            isAuthorizedForCommit(snapshot)
        else { return nil }
        let menu = NSMenu(title: L10n.string("이미지 편집"))

        if isCropping {
            menu.addItem(menuItem(L10n.string("자르기 완료"), action: #selector(finishCroppingFromMenu(_:))))
            menu.addItem(menuItem(L10n.string("자르기 취소"), action: #selector(cancelCroppingFromMenu(_:))))
        } else {
            let cropItem = menuItem(L10n.string("자르기…"), action: #selector(beginCroppingFromMenu(_:)))
            cropItem.isEnabled = annotation is ImageStampAnnotation
            menu.addItem(cropItem)
        }

        menu.addItem(.separator())
        let images = page.annotations.filter(ImageAnnotationIdentity.isEditableImage)
        let index = images.firstIndex(where: { $0 === annotation }) ?? 0
        let front = menuItem(L10n.string("맨 앞으로"), action: #selector(bringToFront(_:)))
        front.isEnabled = index < images.count - 1
        menu.addItem(front)
        let forward = menuItem(L10n.string("한 단계 앞으로"), action: #selector(bringForward(_:)))
        forward.isEnabled = index < images.count - 1
        menu.addItem(forward)
        let backward = menuItem(L10n.string("한 단계 뒤로"), action: #selector(sendBackward(_:)))
        backward.isEnabled = index > 0
        menu.addItem(backward)
        let back = menuItem(L10n.string("맨 뒤로"), action: #selector(sendToBack(_:)))
        back.isEnabled = index > 0
        menu.addItem(back)

        menu.addItem(.separator())
        menu.addItem(menuItem(L10n.string("이미지 삭제"), action: #selector(deleteSelectedAnnotation(_:))))
        return menu
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func beginCroppingFromMenu(_ sender: Any?) {
        beginCropping()
    }

    @objc private func finishCroppingFromMenu(_ sender: Any?) {
        finishCropping()
        needsDisplay = true
    }

    @objc private func cancelCroppingFromMenu(_ sender: Any?) {
        cancelCropping()
    }

    @objc private func bringToFront(_ sender: Any?) {
        reorderSelectedImage(.bringToFront)
    }

    @objc private func bringForward(_ sender: Any?) {
        reorderSelectedImage(.bringForward)
    }

    @objc private func sendBackward(_ sender: Any?) {
        reorderSelectedImage(.sendBackward)
    }

    @objc private func sendToBack(_ sender: Any?) {
        reorderSelectedImage(.sendToBack)
    }

    @objc private func deleteSelectedAnnotation(_ sender: Any?) {
        guard
            let annotation = selectedAnnotation,
            let page = selectedPage,
            let kind = EditableAnnotationIdentity.kind(of: annotation),
            let snapshot = geometrySnapshot(for: annotation, on: page),
            snapshot.kind == kind,
            isAuthorizedForCommit(snapshot)
        else { return }

        if kind == .image {
            guard owner?.workspaceState?.deleteImageAnnotation(annotation, on: page) == true else {
                return
            }
        } else {
            let originalIndex = page.annotations.firstIndex(where: { $0 === annotation })
                ?? page.annotations.count
            owner?.workspaceState?.prepareForDeactivation()
            page.removeAnnotation(annotation)
            owner?.workspaceState?.registerRemovedAnnotation(
                annotation,
                from: page,
                originalIndex: originalIndex,
                message: L10n.string("주석을 삭제했습니다.")
            )
        }
        discardSelectionState()
        owner?.needsDisplay = true
        needsDisplay = true
    }

    private func reorderSelectedImage(_ command: ImageLayerOrderCommand) {
        guard
            let annotation = selectedAnnotation,
            let page = selectedPage,
            let snapshot = geometrySnapshot(for: annotation, on: page),
            snapshot.kind == .image,
            isAuthorizedForCommit(snapshot),
            owner?.workspaceState?.reorderImageAnnotation(annotation, on: page, command: command) == true
        else { return }
        owner?.needsDisplay = true
        needsDisplay = true
    }

    private func beginCropping() {
        guard
            !isCropping,
            let imageAnnotation = selectedAnnotation as? ImageStampAnnotation,
            let page = selectedPage,
            EditableAnnotationIdentity.kind(of: imageAnnotation) == .image,
            let snapshot = geometrySnapshot(for: imageAnnotation, on: page),
            isAuthorizedForCommit(snapshot)
        else { return }
        // Preserve the complete pre-crop state. Cancel and sub-tolerance edits
        // must restore it byte-for-byte (including modificationDate), or the
        // UI could claim the document is clean while its graph still differs.
        cropSessionSnapshot = snapshot
        isCropping = true
        dragOperation = nil
        needsDisplay = true
    }

    private func finishCropping() {
        // A menu/key action should not be able to commit a half-delivered drag.
        // Revert that preview first; the completed crop session can then be
        // validated and committed as one undoable operation.
        rollbackActiveDrag()
        let snapshot = cropSessionSnapshot
        isCropping = false
        cropSessionSnapshot = nil
        dragOperation = nil
        guard
            let snapshot,
            let imageAnnotation = selectedAnnotation as? ImageStampAnnotation,
            let page = selectedPage,
            imageAnnotation === snapshot.annotation,
            page === snapshot.page,
            let originalCrop = snapshot.cropRect
        else { return }

        guard isAuthorizedForCommit(snapshot) else {
            restoreGeometry(from: snapshot)
            return
        }

        if
            !approximatelyEqual(imageAnnotation.bounds, snapshot.bounds)
                || !approximatelyEqual(imageAnnotation.normalizedCropRect, originalCrop)
        {
            owner?.workspaceState?.registerAnnotationGeometryChange(
                imageAnnotation,
                on: page,
                from: snapshot.bounds,
                originalCropRect: originalCrop,
                originalModificationDate: snapshot.modificationDate,
                message: L10n.string("이미지를 잘랐습니다.")
            )
        } else {
            restoreGeometry(from: snapshot)
        }
    }

    private func cancelCropping() {
        rollbackActiveDrag()
        rollbackCropSession()
        owner?.needsDisplay = true
        needsDisplay = true
    }

    private func geometrySnapshot(
        for annotation: PDFAnnotation,
        on page: PDFPage
    ) -> GeometryMutationSnapshot? {
        guard
            let owner,
            let workspace = owner.workspaceState,
            let document = owner.document,
            let workspaceDocument = workspace.document,
            document === workspaceDocument,
            owner.viewportContext == .normal,
            owner.activeTool == .select,
            let kind = EditableAnnotationIdentity.kind(of: annotation),
            workspace.allowsAnnotationEditing(kind, annotation: annotation),
            page.annotations.contains(where: { $0 === annotation })
        else {
            return nil
        }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        return GeometryMutationSnapshot(
            annotation: annotation,
            page: page,
            document: document,
            pageIndex: pageIndex,
            annotationOrder: page.annotations,
            kind: kind,
            bounds: annotation.bounds,
            cropRect: (annotation as? ImageStampAnnotation)?.normalizedCropRect,
            modificationDate: annotation.modificationDate
        )
    }

    /// Rechecks every authority and identity assumption made at mouse-down.
    /// A mode switch, tool change, document replacement, page move, annotation
    /// reorder, or kind-marker change makes the transaction stale.
    private func isAuthorizedForCommit(_ snapshot: GeometryMutationSnapshot) -> Bool {
        guard
            let owner,
            let workspace = owner.workspaceState,
            let visibleDocument = owner.document,
            let workspaceDocument = workspace.document,
            visibleDocument === snapshot.document,
            workspaceDocument === snapshot.document,
            owner.viewportContext == .normal,
            owner.activeTool == .select,
            selectedAnnotation === snapshot.annotation,
            selectedPage === snapshot.page,
            snapshot.document.page(at: snapshot.pageIndex) === snapshot.page,
            EditableAnnotationIdentity.kind(of: snapshot.annotation) == snapshot.kind,
            workspace.allowsAnnotationEditing(
                snapshot.kind,
                annotation: snapshot.annotation
            )
        else {
            return false
        }
        let currentOrder = snapshot.page.annotations
        return currentOrder.count == snapshot.annotationOrder.count
            && zip(currentOrder, snapshot.annotationOrder).allSatisfy { $0 === $1 }
    }

    private func restoreGeometry(from snapshot: GeometryMutationSnapshot) {
        // Never resurrect an annotation that another operation removed. If it
        // still belongs to the original page, however, restoring its preview
        // geometry is safe even after the mode capability was revoked.
        guard snapshot.page.annotations.contains(where: { $0 === snapshot.annotation }) else {
            return
        }
        snapshot.annotation.bounds = snapshot.bounds
        if
            let cropRect = snapshot.cropRect,
            let image = snapshot.annotation as? ImageStampAnnotation
        {
            image.updateCropRect(cropRect)
        }
        snapshot.annotation.modificationDate = snapshot.modificationDate
    }

    private func rollbackActiveDrag() {
        guard let operation = dragOperation else { return }
        // A crop session is one transaction spanning several handle drags.
        // Invalidating any live crop drag therefore restores the state from
        // before the session, not merely the state before its latest handle.
        let snapshot = isCropping
            ? (cropSessionSnapshot ?? operation.snapshot)
            : operation.snapshot
        restoreGeometry(from: snapshot)
        dragOperation = nil
    }

    private func rollbackCropSession() {
        if let cropSessionSnapshot {
            restoreGeometry(from: cropSessionSnapshot)
        }
        isCropping = false
        cropSessionSnapshot = nil
        dragOperation = nil
    }

    private func discardSelectionState() {
        selectedAnnotation = nil
        selectedPage = nil
        dragOperation = nil
        isCropping = false
        cropSessionSnapshot = nil
    }

    private func validateSelection() {
        guard let owner, let annotation = selectedAnnotation, let page = selectedPage else { return }
        let basicSelectionIsValid: Bool
        if let document = owner.document,
           let kind = EditableAnnotationIdentity.kind(of: annotation)
        {
            basicSelectionIsValid = document.index(for: page) != NSNotFound
                && page.annotations.contains(where: { $0 === annotation })
                && owner.viewportContext == .normal
                && owner.activeTool == .select
                && owner.workspaceState?.allowsAnnotationEditing(
                    kind,
                    annotation: annotation
                ) == true
        } else {
            basicSelectionIsValid = false
        }

        let transactionIsValid: Bool
        if let snapshot = cropSessionSnapshot ?? dragOperation?.snapshot {
            transactionIsValid = isAuthorizedForCommit(snapshot)
        } else {
            transactionIsValid = true
        }

        guard basicSelectionIsValid, transactionIsValid else {
            rollbackActiveDrag()
            rollbackCropSession()
            discardSelectionState()
            return
        }
    }

    private func refreshScrollObservation() {
        guard let owner else { return }
        // PDFView owns a private NSScrollView. Its clip view moves without this
        // overlay moving, so scrolling and scaling must explicitly invalidate
        // the handles' display positions.
        let clipView = firstScrollView(in: owner)?.contentView ?? owner.enclosingScrollView?.contentView
        if observedClipView !== clipView {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            observedClipView = clipView
            if let clipView {
                clipView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard self?.selectedAnnotation != nil else { return }
                        self?.needsDisplay = true
                    }
                }
            } else {
                boundsObserver = nil
            }
        }

        if scaleObserver == nil {
            scaleObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged,
                object: owner,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.selectedAnnotation != nil else { return }
                    self?.needsDisplay = true
                }
            }
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) { return scrollView }
        }
        return nil
    }

    private func drawCropHint(near point: CGPoint, color: NSColor) {
        let text = L10n.string("자르기 중 · Return 완료 · Esc 취소") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let pill = CGRect(
            x: point.x,
            y: point.y + 12,
            width: textSize.width + 14,
            height: textSize.height + 8
        )
        color.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        text.draw(
            at: CGPoint(x: pill.minX + 7, y: pill.minY + 4),
            withAttributes: attributes
        )
    }

    private func selectionMessage(for kind: EditableAnnotationKind) -> String {
        if kind == .image {
            return L10n.string("이미지 선택 · 드래그해 이동 · 모서리로 크기 조절 · 우클릭해 자르기/레이어 편집")
        }
        return L10n.string("선택한 개체를 드래그해 이동하고 화살표 키로 미세 조정할 수 있습니다.")
    }

    private func movementMessage(for annotation: PDFAnnotation) -> String {
        EditableAnnotationIdentity.kind(of: annotation) == .image
            ? L10n.string("이미지 위치를 변경했습니다.")
            : L10n.string("status.annotation_changed")
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.01
            && abs(lhs.minY - rhs.minY) < 0.01
            && abs(lhs.width - rhs.width) < 0.01
            && abs(lhs.height - rhs.height) < 0.01
    }
}

@MainActor
extension InteractivePDFView {
    /// Installs exactly one overlay above PDFKit's private rendering subviews.
    /// SwiftUI can update/rebuild its NSViewRepresentable many times, so an
    /// existing overlay keeps both its identity and z-order. Reattaching it on
    /// every scroll-driven update forces AppKit to relayout the PDF tile stack.
    func configureAnnotationEditingOverlay() {
        let overlay: PDFAnnotationEditingOverlayView
        if let installed = subviews.compactMap({ $0 as? PDFAnnotationEditingOverlayView }).last {
            overlay = installed
        } else {
            overlay = PDFAnnotationEditingOverlayView(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.owner = self
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.owner = self
        overlay.refreshForConfiguration()
    }

    /// PDFKit can append replacement private rendering views after document or
    /// layout mutations. Restore the ink preview and two editor overlays as one
    /// stable suffix; the common scroll-driven update is a no-op.
    func restoreEditingOverlayOrderIfNeeded(above inkOverlay: NSView) {
        guard
            let annotationOverlay = subviews.compactMap({
                $0 as? PDFAnnotationEditingOverlayView
            }).last,
            let inlineOverlay = subviews.compactMap({
                $0 as? PDFInlineTextEditingOverlayView
            }).last
        else { return }

        let suffix = Array(subviews.suffix(3))
        guard
            suffix.count != 3
                || suffix[0] !== inkOverlay
                || suffix[1] !== annotationOverlay
                || suffix[2] !== inlineOverlay
        else { return }

        addSubview(inkOverlay, positioned: .above, relativeTo: nil)
        addSubview(annotationOverlay, positioned: .above, relativeTo: nil)
        addSubview(inlineOverlay, positioned: .above, relativeTo: nil)
    }

    func clearAnnotationEditingSelection() {
        subviews.compactMap { $0 as? PDFAnnotationEditingOverlayView }.forEach { $0.clearSelection() }
    }

    func commitAnnotationEditingBeforeDeactivation() {
        subviews.compactMap { $0 as? PDFAnnotationEditingOverlayView }
            .forEach { $0.prepareForDeactivation() }
    }

    func prepareAnnotationEditingOverlayForRemoval() {
        subviews.compactMap { $0 as? PDFAnnotationEditingOverlayView }.forEach { $0.prepareForRemoval() }
    }
}

// SPDX-License-Identifier: MPL-2.0

import PDFKit

/// Image-specific editing commands live in a separate extension so the already
/// large `PDFWorkspaceState` file can focus on document lifetime and saving.
///
/// These methods still run on the main actor: PDFKit annotation collections are
/// UI-owned mutable objects and are not safe to change from a background task.
@MainActor
extension PDFWorkspaceState {
    /// Changes only the relative order of editable image stamps.
    ///
    /// A PDF page can interleave images with highlights, text fields, signatures,
    /// and other annotations. Rebuilding an "images only" array and appending it
    /// would accidentally move those other kinds. Instead, the code below keeps
    /// every non-image slot fixed and substitutes reordered images into the old
    /// image slots. The complete before/after arrays are also recorded so Undo
    /// restores the exact visual stacking order rather than merely approximating it.
    @discardableResult
    func reorderImageAnnotation(
        _ annotation: PDFAnnotation,
        on page: PDFPage,
        command: ImageLayerOrderCommand
    ) -> Bool {
        // Views hide this command outside Editing mode, but model methods are
        // also called by tests, undo integrations and future plug-ins. Enforce
        // authority again at the mutation boundary so a stale menu/gesture
        // cannot reorder an imported image after the mode changed.
        guard allows(.imageInsertion) else { return false }
        prepareForDeactivation()
        // Keep object identity (`===`) rather than comparing annotation values.
        // Two stamps may have equal bounds and contents but still be distinct layers.
        let originalOrder = page.annotations
        let images = originalOrder.filter(ImageAnnotationIdentity.isEditableImage)
        guard
            allows(.imageInsertion),
            EditableAnnotationIdentity.kind(of: annotation) == .image,
            let selectedIndex = images.firstIndex(where: { $0 === annotation })
        else { return false }

        let reordered = ImageLayerOrder.reordered(
            images,
            selectedIndex: selectedIndex,
            command: command
        )
        guard !zip(images, reordered).allSatisfy({ $0 === $1 }) else { return false }

        // Walk the page's original mixed annotation order. Only image positions
        // consume an item from `reordered`; every other annotation remains where it was.
        var reorderedIterator = reordered.makeIterator()
        let finalOrder = originalOrder.map { annotation in
            ImageAnnotationIdentity.isEditableImage(annotation)
                ? (reorderedIterator.next() ?? annotation)
                : annotation
        }
        originalOrder.forEach(page.removeAnnotation)
        finalOrder.forEach(page.addAnnotation)
        registerAnnotationOrderChange(
            on: page,
            from: originalOrder,
            to: finalOrder,
            message: layerOrderMessage(for: command)
        )
        return true
    }

    @discardableResult
    func deleteImageAnnotation(_ annotation: PDFAnnotation, on page: PDFPage) -> Bool {
        guard allows(.imageInsertion) else { return false }
        prepareForDeactivation()
        guard
            allows(.imageInsertion),
            EditableAnnotationIdentity.kind(of: annotation) == .image,
            ImageAnnotationIdentity.isEditableImage(annotation),
            page.annotations.contains(where: { $0 === annotation })
        else { return false }

        // Capture the complete layer order before removal. Undo needs both the
        // deleted object and its precise position among every annotation kind.
        let originalOrder = page.annotations
        page.removeAnnotation(annotation)
        registerAnnotationOrderChange(
            on: page,
            from: originalOrder,
            to: page.annotations,
            message: L10n.string("status.image_deleted")
        )
        return true
    }

    private func layerOrderMessage(for command: ImageLayerOrderCommand) -> String {
        switch command {
        case .bringToFront:
            L10n.string("status.image_front")
        case .bringForward:
            L10n.string("status.image_forward")
        case .sendBackward:
            L10n.string("status.image_backward")
        case .sendToBack:
            L10n.string("status.image_back")
        }
    }
}

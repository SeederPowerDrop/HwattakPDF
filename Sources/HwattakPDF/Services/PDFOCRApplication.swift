// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Builds the same searchable representation as Save New PDF without touching
/// the live PDF graph. Only the final validated page replacement runs on main.
enum PDFOCRApplication {
    /// Only these pages receive a new flattened image/text layer. Empty and
    /// skipped results retain the original editable PDF page and its objects.
    static func replacementPageIndexes(checkpoint: OCRCheckpoint) -> Set<Int> {
        Set(checkpoint.pages.compactMap { index, result in
            guard !result.skippedBecauseTextExists,
                  result.observations.contains(where: {
                      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else { return nil }
            return index
        })
    }

    struct LinkDestinationChange {
        let annotation: PDFAnnotation
        let original: PDFDestination
        let replacement: PDFDestination

        func apply() { annotation.destination = replacement }
        func restore() { annotation.destination = original }
    }

    /// Retained pages can link into a replaced page. Capture both mappings so
    /// applying OCR and undoing it keep local links pointing at live objects.
    static func linkDestinationChanges(from original: [PDFPage], to replacement: [PDFPage]) -> [LinkDestinationChange] {
        guard original.count == replacement.count else { return [] }
        let indexes = Dictionary(uniqueKeysWithValues: original.enumerated().map {
            (ObjectIdentifier($0.element), $0.offset)
        })
        return original.indices.flatMap { index -> [LinkDestinationChange] in
            guard original[index] === replacement[index] else { return [] }
            return original[index].annotations.compactMap { annotation in
                guard let destination = annotation.destination,
                      let target = destination.page,
                      let targetIndex = indexes[ObjectIdentifier(target)],
                      target !== replacement[targetIndex] else { return nil }
                let mapped = PDFDestination(
                    page: replacement[targetIndex],
                    at: normalizedDestinationPoint(destination.point, from: target)
                )
                mapped.zoom = destination.zoom
                return LinkDestinationChange(annotation: annotation, original: destination, replacement: mapped)
            }
        }
    }

    /// Commits an already rendered snapshot without holding the UI thread.
    /// The caller captures this precondition before snapshot/rendering begins.
    static func saveRenderedCopy(
        _ data: Data, to destination: URL,
        protectedSourceURLs: [URL],
        destinationPrecondition: PDFDestinationPrecondition
    ) async throws {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let rendered = PDFDocument(data: data) else {
                throw WorkspaceError.operationFailed(L10n.string("error.validate_ocr_copy"))
            }
            let validate = {
                try Task.checkCancellation()
                guard !protectedSourceURLs.contains(where: {
                    PDFSourceFileVersion.refersToSameLocation($0, destination)
                }) else {
                    throw WorkspaceError.operationFailed(L10n.string("error.save_copy_same_as_original"))
                }
                try destinationPrecondition.validate()
            }
            try validate()
            try AtomicPDFWriter.write(rendered, to: destination, validateDestinationBeforeCommit: validate)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    static func render(snapshotURL: URL, checkpoint: OCRCheckpoint, renderDPI: CGFloat = 220) async throws -> Data {
        let worker = Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HwattakPDF-OCR-Result-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("result.pdf")
            try Task.checkCancellation()
            guard let snapshot = PDFDocument(url: snapshotURL) else {
                throw WorkspaceError.cannotOpen(snapshotURL)
            }
            try SearchablePDFExporter.export(
                document: snapshot,
                checkpoint: checkpoint,
                to: output,
                renderDPI: renderDPI,
                beforeDestinationCommit: { try Task.checkCancellation() }
            )
            try Task.checkCancellation()
            // The resulting PDFDocument owns these bytes, so undo/redo and
            // later saves do not depend on a deleted temporary backing file.
            return try Data(contentsOf: output)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    @MainActor
    static func replacePages(in document: PDFDocument, expected: [PDFPage], with replacement: [PDFPage]) throws {
        guard document.pageCount == expected.count,
              expected.enumerated().allSatisfy({ document.page(at: $0.offset) === $0.element }) else {
            throw WorkspaceError.operationFailed(
                L10n.string("error.undo_page_state", defaultValue: "The pages are no longer in the expected state.")
            )
        }
        for index in (0..<document.pageCount).reversed() { document.removePage(at: index) }
        for (index, page) in replacement.enumerated() { document.insert(page, at: index) }
    }

    /// Outline destinations hold page objects. Rebuild their page mapping so
    /// the contents sidebar keeps navigating after the original pages detach.
    static func copyOutline(_ outline: PDFOutline?, from document: PDFDocument, to pages: [PDFPage]) -> PDFOutline? {
        guard let outline else { return nil }
        let copy = PDFOutline()
        copy.label = outline.label
        copy.isOpen = outline.isOpen
        if outline.destination == nil { copy.action = outline.action }
        if let destination = outline.destination, let oldPage = destination.page {
            let index = document.index(for: oldPage)
            if pages.indices.contains(index) {
                let page = pages[index]
                let point = page === oldPage
                    ? destination.point
                    : normalizedDestinationPoint(destination.point, from: oldPage)
                let mapped = PDFDestination(page: page, at: point)
                mapped.zoom = destination.zoom
                copy.destination = mapped
            }
        }
        for index in 0..<outline.numberOfChildren {
            if let child = copyOutline(outline.child(at: index), from: document, to: pages) {
                copy.insertChild(child, at: copy.numberOfChildren)
            }
        }
        return copy
    }

    /// Re-rendered pages use a zero-origin crop box with rotation baked into
    /// the page content. Translate outline coordinates into that same space.
    private static func normalizedDestinationPoint(_ point: CGPoint, from page: PDFPage) -> CGPoint {
        let bounds = page.bounds(for: .cropBox)
        let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        switch ((page.rotation % 360) + 360) % 360 {
        case 90: return CGPoint(x: local.y, y: bounds.width - local.x)
        case 180: return CGPoint(x: bounds.width - local.x, y: bounds.height - local.y)
        case 270: return CGPoint(x: bounds.height - local.y, y: local.x)
        default: return local
        }
    }
}

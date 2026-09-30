// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// OCR 결과를 보이지 않는 텍스트 층으로 합성한 새 PDF를 만든다.
///
/// 새로 인식한 글자가 있는 페이지만 다시 그리고 투명한 텍스트를 얹는다.
/// 다른 페이지와 인식을 건너뛴 페이지는 원래 PDF 구조 그대로 복사한다.
/// 다시 그린 페이지의 링크와 양식은 편집 기능이 사라질 수 있다.
enum SearchablePDFExporter {
    /// 전체 결과를 임시 파일에 완성하고 다시 열어 검증한 뒤 destination으로 옮긴다.
    static func export(
        document: PDFDocument,
        checkpoint: OCRCheckpoint,
        to destination: URL,
        sourceURL: URL? = nil,
        renderDPI: CGFloat = 220,
        beforeDestinationCommit: (() throws -> Void)? = nil
    ) throws {
        try PDFDocumentSecurityPolicy.validateCanExportSearchableOCR(document)
        guard
            checkpoint.pageCount == document.pageCount,
            checkpoint.pages.allSatisfy({ index, result in
                index >= 0 && index < document.pageCount && result.pageIndex == index
            })
        else {
            throw WorkspaceError.operationFailed(L10n.string("error.validate_ocr_copy"))
        }
        let access = SecurityScopedAccess(url: destination)
        // Protect both identities independently. A direct caller must not be
        // able to hide PDFKit's actual disk source by supplying a different
        // explicit URL, while an in-memory document may still provide its
        // source explicitly.
        let protectedSourceURLs = [sourceURL, document.documentURL].compactMap { $0 }
        // The save-panel extension must remain active through staging,
        // validation, the final alias recheck, and the move/replace commit.
        defer { withExtendedLifetime(access) {} }
        try validateDoesNotAliasSource(protectedSourceURLs, destination: destination)
        let destinationPrecondition = try PDFDestinationPrecondition(
            destination: destination
        )

        // NSSavePanel can authorize only the chosen file, not a temporary
        // sibling in its folder. Render in our private temporary directory,
        // then let the shared writer handle the file-scoped save permission.
        let fileManager = FileManager.default
        let stagingDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-OCRExport-\(UUID().uuidString)", isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        let replacementIndexes = PDFOCRApplication.replacementPageIndexes(checkpoint: checkpoint).sorted()
        let snapshotData: Data?
        if document.isEncrypted {
            // Only owner-unlocked sources reach this point. Like the OCR
            // snapshot writer, produce a passwordless, process-local copy.
            snapshotData = document.dataRepresentation(options: [
                .ownerPasswordOption: "",
                .userPasswordOption: "",
                PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): NSNumber(value: 128)
            ])
        } else {
            snapshotData = document.dataRepresentation()
        }
        guard let snapshotData,
              let stagedDocument = PDFDocument(data: snapshotData),
              !stagedDocument.isLocked,
              stagedDocument.pageCount == document.pageCount else {
            throw WorkspaceError.operationFailed(L10n.string("error.validate_ocr_copy"))
        }
        // Keep the page objects from this full-document copy. Rebuilding all
        // pages through Core Graphics would flatten unselected annotations,
        // forms, and links and discard their original crop/rotation geometry.
        var outputPages = try (0..<stagedDocument.pageCount).map { index in
            guard let page = stagedDocument.page(at: index) else {
                throw WorkspaceError.operationFailed(L10n.format("error.ocr_page_load", index + 1))
            }
            return page
        }
        if !replacementIndexes.isEmpty {
            let temporary = stagingDirectory.appendingPathComponent("recognized-pages.pdf")
            try renderRecognizedPages(
                in: document, checkpoint: checkpoint, pageIndexes: replacementIndexes,
                to: temporary, renderDPI: renderDPI
            )
            guard let recognizedDocument = PDFDocument(url: temporary),
                  recognizedDocument.pageCount == replacementIndexes.count else {
                throw WorkspaceError.operationFailed(L10n.string("error.validate_ocr_copy"))
            }
            for (renderedIndex, originalIndex) in replacementIndexes.enumerated() {
                guard let page = recognizedDocument.page(at: renderedIndex) else {
                    throw WorkspaceError.operationFailed(L10n.string("error.validate_ocr_copy"))
                }
                outputPages[originalIndex] = page
            }
            let originalPages = (0..<stagedDocument.pageCount).compactMap { stagedDocument.page(at: $0) }
            let linkChanges = PDFOCRApplication.linkDestinationChanges(from: originalPages, to: outputPages)
            let outline = PDFOCRApplication.copyOutline(
                stagedDocument.outlineRoot, from: stagedDocument, to: outputPages
            )
            for index in replacementIndexes {
                stagedDocument.removePage(at: index)
                stagedDocument.insert(outputPages[index], at: index)
            }
            for change in linkChanges { change.apply() }
            stagedDocument.outlineRoot = outline
        }
        try Task.checkCancellation()

        try AtomicPDFWriter.write(
            stagedDocument,
            to: destination,
            validateDestinationBeforeCommit: {
                // Keep the precondition captured BEFORE OCR rendering, not
                // just the one the writer captures before serialization.
                try beforeDestinationCommit?()
                try validateDoesNotAliasSource(protectedSourceURLs, destination: destination)
                try destinationPrecondition.validate()
            }
        )

        guard PDFDocument(url: destination)?.pageCount == document.pageCount else {
            throw WorkspaceError.operationFailed(L10n.string("error.reopen_ocr_copy"))
        }
    }

    /// Render only pages with usable new recognition. A skipped or empty
    /// result must not flatten a page merely because it was in the OCR range.
    private static func renderRecognizedPages(
        in document: PDFDocument,
        checkpoint: OCRCheckpoint,
        pageIndexes: [Int],
        to temporary: URL,
        renderDPI: CGFloat
    ) throws {
        guard let consumer = CGDataConsumer(url: temporary as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw WorkspaceError.cannotSave(temporary)
        }
        defer { context.closePDF() }
        for index in pageIndexes {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index),
                      let result = checkpoint.pages[index] else {
                    throw WorkspaceError.operationFailed(L10n.format("error.ocr_page_load", index + 1))
                }
                let sourceBounds = page.bounds(for: .cropBox)
                let rotated = abs(page.rotation % 180) == 90
                let outputSize = rotated
                    ? CGSize(width: sourceBounds.height, height: sourceBounds.width)
                    : sourceBounds.size
                var mediaBox = CGRect(origin: .zero, size: outputSize)
                let pageInfo = [kCGPDFContextMediaBox as String: Data(
                    bytes: &mediaBox, count: MemoryLayout<CGRect>.size
                )] as CFDictionary
                context.beginPDFPage(pageInfo)
                defer { context.endPDFPage() }
                context.saveGState()
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(mediaBox)
                let hasExistingText = !(page.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasExistingText {
                    // Drawing into a PDF copies its old hidden text. Replace
                    // inaccurate OCR instead of stacking two text layers.
                    let image = try VisionOCRService.render(page: page, dpi: renderDPI)
                    context.draw(image, in: mediaBox)
                } else {
                    page.draw(with: .cropBox, to: context)
                }
                context.restoreGState()
                drawInvisibleText(
                    result.observations,
                    sourceBounds: sourceBounds,
                    pageRotation: page.rotation,
                    in: mediaBox,
                    context: context
                )
            }
        }
    }

    private static func validateDoesNotAliasSource(
        _ sourceURLs: [URL],
        destination: URL
    ) throws {
        guard sourceURLs.contains(where: {
            PDFSourceFileVersion.refersToSameLocation($0, destination)
        }) else { return }
        throw WorkspaceError.operationFailed(
            L10n.string("error.save_copy_same_as_original")
        )
    }

    /// 글자는 PDF에 존재하지만 화면에는 보이지 않도록 `.invisible` 모드로 그린다.
    /// 각 OCR box 폭에 맞게 가로 비율을 조정해 선택 영역이 원문 위치에 가깝게 된다.
    private static func drawInvisibleText(
        _ observations: [OCRWordBox],
        sourceBounds: CGRect,
        pageRotation: Int,
        in mediaBox: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity

        for observation in observations where !observation.text.isEmpty {
            let target = outputTextRect(
                normalized: CGRect(
                    x: observation.x,
                    y: observation.y,
                    width: observation.width,
                    height: observation.height
                ),
                sourceBounds: sourceBounds,
                pageRotation: pageRotation,
                mediaBox: mediaBox
            )
            let fontSize = max(4, target.height * 0.82)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            guard
                let attributed = CFAttributedStringCreate(nil, observation.text as CFString, attributes),
                !observation.text.isEmpty
            else { continue }
            let line = CTLineCreateWithAttributedString(attributed)
            let naturalWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let horizontalScale = naturalWidth > 0 ? min(8, max(0.08, target.width / naturalWidth)) : 1

            context.saveGState()
            context.translateBy(x: target.minX, y: target.minY)
            context.scaleBy(x: horizontalScale, y: 1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// Vision의 0...1 정규화 좌표를 출력 PDF의 point 좌표로 변환한다.
    private static func outputTextRect(
        normalized: CGRect,
        sourceBounds: CGRect,
        pageRotation: Int,
        mediaBox: CGRect
    ) -> CGRect {
        // Vision normalized boxes describe the already rotated crop-box image.
        // PDFPage.draw emits that same visible orientation into mediaBox. Keep
        // the OCR layer in that visual coordinate system; sourceBounds is kept
        // explicit so non-zero crop origins do not leak into the result.
        _ = sourceBounds
        _ = pageRotation
        return CGRect(
            x: mediaBox.minX + normalized.minX * mediaBox.width,
            y: mediaBox.minY + normalized.minY * mediaBox.height,
            width: max(1, normalized.width * mediaBox.width),
            height: max(1, normalized.height * mediaBox.height)
        )
    }
}

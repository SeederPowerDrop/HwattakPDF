// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// OCR 결과를 보이지 않는 텍스트 층으로 합성한 새 PDF를 만든다.
///
/// 원본 PDF를 직접 수정하지 않고 각 페이지의 **보이는 모습**을 새 PDF에 그린 뒤
/// Vision 좌표에 투명 텍스트를 얹는다. 따라서 검색/선택은 가능해지지만 링크,
/// 양식, 기존 전자서명 같은 상호작용 객체는 평탄화된다. 이 차이는 UI와 README에
/// 명시되어 있으며, 사용자는 항상 원본을 별도로 보관해야 한다.
enum SearchablePDFExporter {
    /// 전체 결과를 임시 파일에 완성하고 다시 열어 검증한 뒤 destination으로 옮긴다.
    static func export(
        document: PDFDocument,
        checkpoint: OCRCheckpoint,
        to destination: URL,
        sourceURL: URL? = nil,
        beforeDestinationCommit: (() throws -> Void)? = nil
    ) throws {
        try PDFDocumentSecurityPolicy.validateCanExportSearchableOCR(document)
        guard
            checkpoint.pageCount == document.pageCount,
            checkpoint.pages.keys.allSatisfy({ $0 >= 0 && $0 < document.pageCount })
        else {
            throw WorkspaceError.operationFailed(L10n.string("error.validate_ocr_copy"))
        }
        let parent = destination.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).ocr.tmp"
        )
        let access = SecurityScopedAccess(url: destination)
        // Protect both identities independently. A direct caller must not be
        // able to hide PDFKit's actual disk source by supplying a different
        // explicit URL, while an in-memory document may still provide its
        // source explicitly.
        let protectedSourceURLs = [sourceURL, document.documentURL].compactMap { $0 }
        // The save-panel extension must remain active through staging,
        // validation, the final alias recheck, and the move/replace commit.
        defer { withExtendedLifetime(access) {} }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try validateDoesNotAliasSource(protectedSourceURLs, destination: destination)
        let destinationPrecondition = try PDFDestinationPrecondition(
            destination: destination
        )

        guard
            let consumer = CGDataConsumer(url: temporary as CFURL),
            let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw WorkspaceError.cannotSave(destination)
        }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let sourceBounds = page.bounds(for: .cropBox)
            let rotated = abs(page.rotation % 180) == 90
            let outputSize = rotated
                ? CGSize(width: sourceBounds.height, height: sourceBounds.width)
                : sourceBounds.size
            var mediaBox = CGRect(origin: .zero, size: outputSize)
            let pageInfo = [kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)

            context.saveGState()
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            // PDFPage draws the crop box with its rotation and printable
            // annotation appearances. This keeps handwritten notes and image
            // stamps visible in the derived OCR copy while the original stays
            // untouched. Interactive links/forms are intentionally flattened.
            page.draw(with: .cropBox, to: context)
            context.restoreGState()

            if let result = checkpoint.pages[index], !result.skippedBecauseTextExists {
                drawInvisibleText(
                    result.observations,
                    sourceBounds: sourceBounds,
                    pageRotation: page.rotation,
                    in: mediaBox,
                    context: context
                )
            }

            context.endPDFPage()
        }
        context.closePDF()

        // Never replace the user's chosen destination with an unopenable
        // partial result. Validate the staging file first.
        guard
            let stagedDocument = PDFDocument(url: temporary),
            stagedDocument.pageCount == document.pageCount
        else {
            try? FileManager.default.removeItem(at: temporary)
            throw WorkspaceError.operationFailed(L10n.string("error.validate_ocr_copy"))
        }

        let fileManager = FileManager.default
        do {
            // OCR export may take minutes. Respect a file created or edited at
            // the chosen path while pages were rendered instead of replacing it.
            try beforeDestinationCommit?()
            try validateDoesNotAliasSource(protectedSourceURLs, destination: destination)
            try destinationPrecondition.validate()
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch let workspaceError as WorkspaceError {
            try? fileManager.removeItem(at: temporary)
            throw workspaceError
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw WorkspaceError.cannotSave(destination)
        }

        guard PDFDocument(url: destination)?.pageCount == document.pageCount else {
            throw WorkspaceError.operationFailed(L10n.string("error.reopen_ocr_copy"))
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

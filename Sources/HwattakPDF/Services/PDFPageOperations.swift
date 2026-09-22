// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// A detached one-page document paired with its zero-based source index.
///
/// Keeping the index beside the document prevents batch exporters from losing
/// the original page number after noncontiguous selections are sorted.
struct ExtractedPDFPage {
    let sourcePageIndex: Int
    let document: PDFDocument
}

/// PDF 페이지 복사·추출·병합에 공통으로 쓰는 작은 연산 모음이다.
///
/// PDFKit의 `PDFPage`는 자신을 소유한 문서와 내부 객체 그래프를 공유할 수 있다.
/// 그래서 다른 문서에 페이지를 넣을 때는 반드시 `detachedCopy`를 만들어 원본과
/// 결과 문서가 같은 mutable 객체를 우연히 함께 수정하지 않게 한다.
enum PDFPageOperations {
    /// 빠른 `NSCopying` 경로를 먼저 시도하고, 실패하면 한 페이지 PDF로
    /// 직렬화/재개방해 소유 관계가 끊긴 복사본을 만든다.
    static func detachedCopy(of page: PDFPage) -> PDFPage? {
        if let copied = page.copy() as? PDFPage {
            return copied
        }

        guard
            let data = page.dataRepresentation,
            let onePageDocument = PDFDocument(data: data),
            let copied = onePageDocument.page(at: 0)?.copy() as? PDFPage
        else {
            return nil
        }
        return copied
    }

    /// 선택 인덱스를 문서 순서로 정렬해 새 PDF에 복사한다.
    static func extract(from document: PDFDocument, indexes: [Int]) throws -> PDFDocument {
        // Keep the service boundary authoritative. Model/UI callers perform the
        // same check for prompt feedback, but direct integrations must not turn
        // a restricted user-password session into an unrestricted page copy.
        try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
        let indexes = try normalizedSelection(indexes, pageCount: document.pageCount)
        let output = PDFDocument()
        for index in indexes {
            let page = try detachedPage(from: document, at: index)
            output.insert(page, at: output.pageCount)
        }
        return output
    }

    /// 선택한 각 페이지를 독립적인 한 페이지 PDF로 만든다.
    ///
    /// Every index is validated before the first page is copied. A mixed valid
    /// and invalid request therefore cannot produce a partial export batch.
    static func extractIndividually(
        from document: PDFDocument,
        indexes: [Int]
    ) throws -> [ExtractedPDFPage] {
        try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
        let indexes = try normalizedSelection(indexes, pageCount: document.pageCount)
        return try indexes.map { index in
            let output = PDFDocument()
            output.insert(try detachedPage(from: document, at: index), at: 0)
            return ExtractedPDFPage(sourcePageIndex: index, document: output)
        }
    }

    @discardableResult
    /// source 전체를 destination 뒤에 복사하고 실제 삽입된 페이지 수를 반환한다.
    /// 원본 `source`는 변경하지 않는다.
    static func append(contentsOf source: PDFDocument, to destination: PDFDocument) throws -> Int {
        try PDFDocumentSecurityPolicy.validateCanExtractPages(source)
        var inserted = 0
        for index in 0..<source.pageCount {
            guard
                let sourcePage = source.page(at: index),
                let page = detachedCopy(of: sourcePage)
            else {
                throw WorkspaceError.operationFailed(L10n.format("error.copy_merged_page", index + 1))
            }
            destination.insert(page, at: destination.pageCount)
            inserted += 1
        }
        return inserted
    }

    /// Selected-page exports are set-based even when an integration passes an
    /// array. Duplicates are removed and the resulting pages follow document
    /// order, matching the visible sidebar selection contract.
    static func normalizedSelection(_ indexes: [Int], pageCount: Int) throws -> [Int] {
        guard !indexes.isEmpty else { throw WorkspaceError.noPagesSelected }
        let normalized = Set(indexes).sorted()
        guard normalized.allSatisfy({ $0 >= 0 && $0 < pageCount }) else {
            throw WorkspaceError.operationFailed(
                L10n.string(
                    "error.invalid_page_selection",
                    defaultValue: "선택한 페이지에 현재 PDF에 없는 페이지가 있습니다."
                )
            )
        }
        return normalized
    }

    private static func detachedPage(
        from document: PDFDocument,
        at index: Int
    ) throws -> PDFPage {
        guard
            let sourcePage = document.page(at: index),
            let page = detachedCopy(of: sourcePage)
        else {
            throw WorkspaceError.operationFailed(L10n.format("error.copy_page", index + 1))
        }
        return page
    }
}

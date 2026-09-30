// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Adapts repaired native geometry or local region recognition to the app's
/// existing selection consumers while retaining the original displayed page.
/// This object is model-only: never install it as a native PDFView selection.
/// It deliberately exposes no invented character ranges in the original PDF.
final class PDFRegionTextSelection: PDFSelection {
    private let sourceDocument: PDFDocument
    private let sourcePage: PDFPage
    let fragments: [PDFRegionTextFragment]

    init(document: PDFDocument, page: PDFPage, fragments: [PDFRegionTextFragment]) {
        sourceDocument = document
        sourcePage = page
        self.fragments = fragments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.bounds.origin.x.isFinite && $0.bounds.origin.y.isFinite
                && $0.bounds.width.isFinite && $0.bounds.height.isFinite
                && !$0.bounds.isNull && !$0.bounds.isEmpty
        }
        super.init(document: document)
    }

    override var pages: [PDFPage] { fragments.isEmpty ? [] : [sourcePage] }

    override var string: String? {
        fragments.map(\.text).joined(separator: "\n")
    }

    override var attributedString: NSAttributedString? {
        NSAttributedString(string: string ?? "")
    }

    override func bounds(for page: PDFPage) -> NSRect {
        guard page === sourcePage, !fragments.isEmpty else { return .zero }
        return fragments.reduce(CGRect.null) { $0.union($1.bounds) }
    }

    override func selectionsByLine() -> [PDFSelection] {
        fragments.map {
            let selection = PDFRegionTextSelection(
                document: sourceDocument,
                page: sourcePage,
                fragments: [$0]
            )
            selection.color = color
            return selection
        }
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let selection = PDFRegionTextSelection(
            document: sourceDocument,
            page: sourcePage,
            fragments: fragments
        )
        selection.color = color
        return selection
    }
}

// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The portion of a PDF that may be sent to a user-selected AI provider.
/// Extraction is always explicit and bounded by `PDFAIContextBudget`.
enum PDFAIContextScope: Equatable, Sendable {
    case selection
    case currentPage
    case selectedPages
    /// An immutable, request-owned page selection. Unlike `selectedPages`, this
    /// case never reads the workspace's mutable thumbnail selection while an AI
    /// request is being prepared.
    case pageIndices([Int])
    case pageRange(ClosedRange<Int>)
    case wholeDocument
}

struct PDFAIContextBudget: Equatable, Sendable {
    static let standard = PDFAIContextBudget()
    static let maximumDocumentTitleCharacters = 256

    let maximumCharacters: Int
    let maximumPages: Int
    let maximumCharactersPerPage: Int
    let maximumUTF8Bytes: Int
    let maximumUTF16CodeUnits: Int
    let maximumUTF8BytesPerPage: Int
    let maximumUTF16CodeUnitsPerPage: Int

    init(
        maximumCharacters: Int = 48_000,
        maximumPages: Int = 24,
        maximumCharactersPerPage: Int = 8_000,
        maximumUTF8Bytes: Int? = nil,
        maximumUTF16CodeUnits: Int? = nil,
        maximumUTF8BytesPerPage: Int? = nil,
        maximumUTF16CodeUnitsPerPage: Int? = nil
    ) {
        self.maximumCharacters = min(250_000, max(1, maximumCharacters))
        self.maximumPages = min(200, max(1, maximumPages))
        self.maximumCharactersPerPage = min(
            self.maximumCharacters,
            max(1, maximumCharactersPerPage)
        )
        let totalBudget = EncodedTextBudget(
            maximumCharacters: self.maximumCharacters
        )
        let pageBudget = EncodedTextBudget(
            maximumCharacters: self.maximumCharactersPerPage
        )
        // Callers normally use the documented character-to-encoding ratios.
        // Optional explicit ceilings only *tighten* those defaults. Keeping the
        // three axes independently configurable also lets boundary tests prove
        // that an incomplete first scalar cannot become an empty PDF source.
        self.maximumUTF8Bytes = min(
            totalBudget.maximumUTF8Bytes,
            max(1, maximumUTF8Bytes ?? totalBudget.maximumUTF8Bytes)
        )
        self.maximumUTF16CodeUnits = min(
            totalBudget.maximumUTF16CodeUnits,
            max(1, maximumUTF16CodeUnits ?? totalBudget.maximumUTF16CodeUnits)
        )
        self.maximumUTF8BytesPerPage = min(
            pageBudget.maximumUTF8Bytes,
            self.maximumUTF8Bytes,
            max(
                1,
                maximumUTF8BytesPerPage ?? pageBudget.maximumUTF8Bytes
            )
        )
        self.maximumUTF16CodeUnitsPerPage = min(
            pageBudget.maximumUTF16CodeUnits,
            self.maximumUTF16CodeUnits,
            max(
                1,
                maximumUTF16CodeUnitsPerPage
                    ?? pageBudget.maximumUTF16CodeUnits
            )
        )
    }

    var totalTextBudget: EncodedTextBudget {
        EncodedTextBudget(
            maximumCharacters: maximumCharacters,
            maximumUTF8Bytes: maximumUTF8Bytes,
            maximumUTF16CodeUnits: maximumUTF16CodeUnits
        )
    }

    var perPageTextBudget: EncodedTextBudget {
        EncodedTextBudget(
            maximumCharacters: maximumCharactersPerPage,
            maximumUTF8Bytes: maximumUTF8BytesPerPage,
            maximumUTF16CodeUnits: maximumUTF16CodeUnitsPerPage
        )
    }

    /// Source markers and a bounded filename are visible in consent and sent
    /// with each page. Reserve explicit overhead for those strings so limiting
    /// the final prompt never silently drops otherwise accepted source text.
    var promptTextBudget: EncodedTextBudget {
        let titleBudget = Self.documentTitleBudget
        let headerCharactersPerPage = titleBudget.maximumCharacters + 32
        let headerUTF8BytesPerPage = titleBudget.maximumUTF8Bytes + 128
        let headerUTF16UnitsPerPage = titleBudget.maximumUTF16CodeUnits + 64
        return EncodedTextBudget(
            maximumCharacters: maximumCharacters
                + maximumPages * headerCharactersPerPage,
            maximumUTF8Bytes: maximumUTF8Bytes
                + maximumPages * headerUTF8BytesPerPage,
            maximumUTF16CodeUnits: maximumUTF16CodeUnits
                + maximumPages * headerUTF16UnitsPerPage
        )
    }

    static var documentTitleBudget: EncodedTextBudget {
        EncodedTextBudget(maximumCharacters: maximumDocumentTitleCharacters)
    }
}

enum PDFAIContextSourceKind: String, Equatable, Sendable {
    case selection
    case pageText
}

/// One page-addressable excerpt. `citationID` is deliberately short so an AI
/// response can cite it without repeating a local path or other private data.
struct PDFAIContextSource: Identifiable, Equatable, Sendable {
    var id: String { citationID }

    let citationID: String
    let documentURL: URL?
    let documentTitle: String
    let pageIndex: Int
    let pageNumber: Int
    let text: String
    let kind: PDFAIContextSourceKind
    let wasTruncated: Bool
}

struct PDFAIContextBundle: Equatable, Sendable {
    let scope: PDFAIContextScope
    let documentTitle: String
    let documentURL: URL?
    let documentPageCount: Int
    let sources: [PDFAIContextSource]
    let omittedPageCount: Int
    let wasTruncated: Bool
    let promptText: String

    var characterCount: Int {
        sources.reduce(0) { $0 + $1.text.count }
    }

    var includedPageIndices: [Int] {
        sources.map(\.pageIndex)
    }

    /// Builds provider-neutral text without ever joining an unbounded source.
    /// The local filesystem path is intentionally excluded from transmission.
    init(
        scope: PDFAIContextScope,
        documentTitle: String,
        documentURL: URL?,
        documentPageCount: Int,
        sources: [PDFAIContextSource],
        omittedPageCount: Int,
        wasTruncated: Bool,
        promptTextBudget: EncodedTextBudget = PDFAIContextBudget.standard.promptTextBudget
    ) {
        self.scope = scope
        self.documentTitle = documentTitle
        self.documentURL = documentURL
        self.documentPageCount = documentPageCount
        self.sources = sources
        self.omittedPageCount = omittedPageCount

        var prompt = EncodedTextAccumulator(budget: promptTextBudget)
        for source in sources {
            let header = "[\(source.citationID) | \(source.documentTitle) | p.\(source.pageNumber)]"
            if !prompt.append(header, separator: "\n\n") { break }
            if !prompt.append(source.text, separator: "\n") { break }
        }
        promptText = prompt.text
        self.wasTruncated = wasTruncated || prompt.wasTruncated
    }

    var promptTextUTF8ByteCount: Int { promptText.utf8.count }
}

enum PDFAIContextExtractionError: LocalizedError, Equatable {
    case noDocument
    case selectionUnavailable
    case pageRangeUnavailable
    case noExtractableText

    var errorDescription: String? {
        switch self {
        case .noDocument:
            "열린 PDF가 없습니다."
        case .selectionUnavailable:
            "먼저 PDF에서 보낼 텍스트를 선택해 주세요."
        case .pageRangeUnavailable:
            "요청한 페이지 범위가 이 PDF에 없습니다."
        case .noExtractableText:
            "선택한 범위에서 추출할 수 있는 텍스트가 없습니다. OCR이 필요한 문서일 수 있습니다."
        }
    }
}

enum PDFRelatedDocumentSource: Equatable, Sendable {
    case openTab(UUID)
    case recentDocument(UUID)

    var openTabID: UUID? {
        guard case let .openTab(id) = self else { return nil }
        return id
    }

    var recentDocumentID: UUID? {
        guard case let .recentDocument(id) = self else { return nil }
        return id
    }
}

struct PDFRelatedPageMatch: Identifiable, Equatable, Sendable {
    var id: String { "\(pageIndex):\(snippet)" }

    let pageIndex: Int
    let pageNumber: Int
    let snippet: String
    let matchedTerms: [String]
    let score: Double
}

struct PDFRelatedDocumentResult: Identifiable, Equatable, Sendable {
    var id: String { documentURL.standardizedFileURL.path }

    let documentURL: URL
    let displayName: String
    let pageCount: Int
    let source: PDFRelatedDocumentSource
    let score: Double
    let matches: [PDFRelatedPageMatch]
}

struct PDFRelatedSearchBudget: Equatable, Sendable {
    static let standard = PDFRelatedSearchBudget()

    let maximumDocumentsScanned: Int
    let maximumPagesPerDocument: Int
    let maximumCharactersPerPage: Int
    let maximumCharactersPerDocument: Int
    let maximumResults: Int
    let maximumQueryTerms: Int

    init(
        maximumDocumentsScanned: Int = 16,
        maximumPagesPerDocument: Int = 6,
        maximumCharactersPerPage: Int = 3_000,
        maximumCharactersPerDocument: Int = 15_000,
        maximumResults: Int = 6,
        maximumQueryTerms: Int = 96
    ) {
        self.maximumDocumentsScanned = min(100, max(1, maximumDocumentsScanned))
        self.maximumPagesPerDocument = min(40, max(1, maximumPagesPerDocument))
        self.maximumCharactersPerPage = min(20_000, max(1, maximumCharactersPerPage))
        self.maximumCharactersPerDocument = min(
            200_000,
            max(self.maximumCharactersPerPage, maximumCharactersPerDocument)
        )
        self.maximumResults = min(30, max(1, maximumResults))
        self.maximumQueryTerms = min(512, max(1, maximumQueryTerms))
    }
}

struct PDFLocalTextSampleRequest: Hashable, Sendable {
    let preferredPageIndices: [Int]
    let maximumPages: Int
    let maximumCharactersPerPage: Int
    let maximumCharacters: Int

    init(
        preferredPageIndices: [Int] = [],
        maximumPages: Int,
        maximumCharactersPerPage: Int,
        maximumCharacters: Int
    ) {
        self.preferredPageIndices = preferredPageIndices
        self.maximumPages = max(1, maximumPages)
        self.maximumCharactersPerPage = max(1, maximumCharactersPerPage)
        self.maximumCharacters = max(1, maximumCharacters)
    }
}

struct PDFLocalTextPage: Equatable, Sendable {
    let pageIndex: Int
    let text: String
    let wasTruncated: Bool
}

struct PDFLocalTextSample: Equatable, Sendable {
    let documentURL: URL
    let pageCount: Int
    let pages: [PDFLocalTextPage]
}

protocol PDFLocalTextSampling: Sendable {
    func sample(
        url: URL,
        request: PDFLocalTextSampleRequest
    ) async throws -> PDFLocalTextSample
}

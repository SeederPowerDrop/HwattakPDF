// SPDX-License-Identifier: MPL-2.0

import Foundation

struct TranslationBlock: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let source: String
}

struct TranslatedPageBlock: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let source: String
    let translated: String
}

struct PageTranslationInput: Equatable, Sendable {
    static let sourceBudget = HwattakPluginLimits.renderedTextBudget
    static let maximumBlockUTF16Count = 1_200
    static let maximumBlockCount = 256

    let sourceText: String
    let sourceLanguageCode: String?
    let targetLanguageCode: String

    init(sourceText: String, sourceLanguageCode: String? = nil, targetLanguageCode: String) {
        self.sourceText = sourceText
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
    }

    /// Paragraph boundaries and line breaks survive extraction. Oversized
    /// paragraphs are split at a whitespace boundary when possible, without
    /// dropping their suffix or splitting a grapheme cluster.
    func blocks() throws -> [TranslationBlock] {
        guard !EncodedTextLimiter.limit(sourceText, budget: Self.sourceBudget).wasTruncated else {
            throw PageTranslationError.sourceTooLarge
        }
        guard Self.isValidLanguageCode(targetLanguageCode),
              sourceLanguageCode.map(Self.isValidLanguageCode) ?? true else {
            throw PageTranslationError.invalidLanguage
        }
        let normalized = sourceText.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { throw PageTranslationError.emptySource }

        var result: [TranslationBlock] = []
        for paragraph in paragraphs {
            var start = paragraph.startIndex
            while start < paragraph.endIndex {
                var end = start
                var preferredEnd: String.Index?
                var units = 0
                while end < paragraph.endIndex {
                    let next = paragraph.index(after: end)
                    let added = paragraph[end..<next].utf16.count
                    guard units + added <= Self.maximumBlockUTF16Count else { break }
                    units += added
                    if paragraph[end].isWhitespace { preferredEnd = next }
                    end = next
                }
                guard end > start else { throw PageTranslationError.sourceTooLarge }
                if end < paragraph.endIndex, let preferredEnd,
                   paragraph[start..<preferredEnd].utf16.count >= Self.maximumBlockUTF16Count / 2 {
                    end = preferredEnd
                }
                guard result.count < Self.maximumBlockCount else { throw PageTranslationError.sourceTooLarge }
                result.append(TranslationBlock(id: "b\(result.count + 1)", source: String(paragraph[start..<end])))
                start = end
            }
        }
        return result
    }

    static func isValidLanguageCode(_ code: String) -> Bool {
        !code.isEmpty && code.utf8.count <= 35 && code.unicodeScalars.allSatisfy {
            (65...90).contains($0.value) || (97...122).contains($0.value)
                || (48...57).contains($0.value) || $0 == "-"
        }
    }
}

struct PageTranslationResult: Equatable, Sendable {
    let blocks: [TranslatedPageBlock]
    let sourceLanguageCode: String?
    let targetLanguageCode: String
    let engineTitle: String
    let createdAt: Date

    init(
        blocks: [TranslatedPageBlock],
        sourceLanguageCode: String?,
        targetLanguageCode: String,
        engineTitle: String,
        createdAt: Date = Date()
    ) {
        self.blocks = blocks
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.engineTitle = engineTitle
        self.createdAt = createdAt
    }

    var translatedText: String { blocks.map(\.translated).joined(separator: "\n\n") }
}

enum PageTranslationError: LocalizedError, Equatable {
    case emptySource
    case sourceTooLarge
    case invalidLanguage
    case invalidResponse
    case incompleteResponse
    case invalidExport

    var errorDescription: String? {
        switch self {
        case .emptySource: return L10n.string("translation.error.empty_source", defaultValue: "No text is available to translate. Run OCR or select text first.")
        case .sourceTooLarge: return L10n.string("translation.error.source_too_large", defaultValue: "The text is too large to translate. Select a shorter passage.")
        case .invalidLanguage: return L10n.string("translation.error.invalid_language", defaultValue: "Select a valid source and target language.")
        case .invalidResponse: return L10n.string("translation.error.invalid_response", defaultValue: "The translation response was invalid. Try again.")
        case .incompleteResponse: return L10n.string("translation.error.incomplete_response", defaultValue: "The translation was incomplete. No partial result was saved.")
        case .invalidExport: return L10n.string("translation.error.invalid_export", defaultValue: "The complete translation could not be exported.")
        }
    }
}

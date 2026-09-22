// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import PDFKit

enum PDFLocalTextSamplingError: LocalizedError {
    case unreadable(URL)
    case invalidPDF(URL)

    var errorDescription: String? {
        switch self {
        case let .unreadable(url):
            "‘\(url.lastPathComponent)’ 파일을 읽을 수 없습니다."
        case let .invalidPDF(url):
            "‘\(url.lastPathComponent)’ 파일은 유효한 PDF가 아닙니다."
        }
    }
}

/// A bounded, serialized text reader for inactive and recent documents.
///
/// It never calls `PDFWorkspaceState.resumeIfNeeded()`: Core Graphics validates
/// the container and supplies page count first, then a short-lived PDFDocument
/// extracts only representative pages. Serial actor isolation ensures searches
/// cannot construct many 50–200 MB PDFKit graphs at once.
actor TransientPDFTextSampler: PDFLocalTextSampling {
    private struct FileSignature: Hashable {
        let fileSize: Int?
        let modificationDate: Date?
    }

    private struct CacheKey: Hashable {
        let canonicalPath: String
        let signature: FileSignature
        let request: PDFLocalTextSampleRequest
    }

    private struct CacheEntry {
        let sample: PDFLocalTextSample
        let sequence: UInt64
    }

    private let maximumCachedSamples: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var accessSequence: UInt64 = 0

    init(maximumCachedSamples: Int = 32) {
        self.maximumCachedSamples = min(128, max(1, maximumCachedSamples))
    }

    func sample(
        url: URL,
        request: PDFLocalTextSampleRequest
    ) async throws -> PDFLocalTextSample {
        let key = CacheKey(
            canonicalPath: Self.canonicalPath(for: url),
            signature: Self.fileSignature(for: url),
            request: request
        )
        if let cached = cache[key] {
            accessSequence &+= 1
            cache[key] = CacheEntry(
                sample: cached.sample,
                sequence: accessSequence
            )
            return cached.sample
        }

        let extracted = try Self.read(url: url, request: request)
        accessSequence &+= 1
        cache[key] = CacheEntry(sample: extracted, sequence: accessSequence)
        trimCacheIfNeeded()
        return extracted
    }

    func removeAllCachedSamples() {
        cache.removeAll(keepingCapacity: false)
    }

    private func trimCacheIfNeeded() {
        let excess = cache.count - maximumCachedSamples
        guard excess > 0 else { return }
        for key in cache
            .sorted(by: { $0.value.sequence < $1.value.sequence })
            .prefix(excess)
            .map(\.key)
        {
            cache.removeValue(forKey: key)
        }
    }

    private static func read(
        url: URL,
        request: PDFLocalTextSampleRequest
    ) throws -> PDFLocalTextSample {
        let access = SecurityScopedAccess(url: url)
        return try withExtendedLifetime(access) {
            guard
                url.isFileURL,
                FileManager.default.isReadableFile(atPath: url.path)
            else {
                throw PDFLocalTextSamplingError.unreadable(url)
            }
            let inspectedPageCount: Int? = autoreleasepool {
                CGPDFDocument(url as CFURL).map { max(0, $0.numberOfPages) }
            }
            guard let pageCount = inspectedPageCount else {
                throw PDFLocalTextSamplingError.invalidPDF(url)
            }
            let pageIndices = PDFRepresentativePageSampler.indices(
                from: Array(0..<pageCount),
                maximumCount: max(1, request.maximumPages),
                preferred: request.preferredPageIndices
            )

            guard let document = PDFDocument(url: url) else {
                throw PDFLocalTextSamplingError.invalidPDF(url)
            }
            var pages: [PDFLocalTextPage] = []
            var remainingBudget = EncodedTextBudget(
                maximumCharacters: max(1, request.maximumCharacters)
            )

            for pageIndex in pageIndices {
                guard
                    remainingBudget.maximumCharacters > 0,
                    remainingBudget.maximumUTF8Bytes > 0,
                    remainingBudget.maximumUTF16CodeUnits > 0
                else { break }
                let perPageLimit = max(1, request.maximumCharactersPerPage)
                let doubledLimit = perPageLimit.multipliedReportingOverflow(by: 2)
                let rawLimit = min(
                    64_000,
                    max(8_000, doubledLimit.overflow ? Int.max : doubledLimit.partialValue)
                )
                let perPageBudget = EncodedTextBudget(
                    maximumCharacters: perPageLimit
                )
                let outputBudget = EncodedTextBudget(
                    maximumCharacters: min(
                        perPageBudget.maximumCharacters,
                        remainingBudget.maximumCharacters
                    ),
                    maximumUTF8Bytes: min(
                        perPageBudget.maximumUTF8Bytes,
                        remainingBudget.maximumUTF8Bytes
                    ),
                    maximumUTF16CodeUnits: min(
                        perPageBudget.maximumUTF16CodeUnits,
                        remainingBudget.maximumUTF16CodeUnits
                    )
                )
                let excerpt: EncodedTextLimitResult = autoreleasepool {
                    guard let rawText = document.page(at: pageIndex)?.string else {
                        return EncodedTextLimitResult(text: "", wasTruncated: false)
                    }
                    // PDFKit creates the complete `page.string` before client
                    // code can inspect it. That unavoidable first allocation is
                    // documented as a known limit; from this boundary onward,
                    // however, raw, normalized, and cached text are all bounded
                    // by grapheme, UTF-8, and UTF-16 ceilings.
                    return Self.boundedNormalizedExcerpt(
                        rawText,
                        rawBudget: EncodedTextBudget(
                            maximumCharacters: rawLimit
                        ),
                        outputBudget: outputBudget
                    )
                }
                guard !excerpt.text.isEmpty else { continue }
                pages.append(
                    PDFLocalTextPage(
                        pageIndex: pageIndex,
                        text: excerpt.text,
                        wasTruncated: excerpt.wasTruncated
                    )
                )
                remainingBudget = remainingBudget.remaining(after: excerpt.text)
            }

            return PDFLocalTextSample(
                documentURL: url,
                pageCount: pageCount,
                pages: pages
            )
        }
    }

    /// Applies both encoded-size boundaries around normalization.
    ///
    /// Keeping this small transformation nonisolated makes the Unicode safety
    /// rule directly regression-testable without constructing a potentially
    /// pathological PDF fixture. The first limit prevents normalization from
    /// copying an unbounded grapheme; the second guarantees that only bounded
    /// text can enter `PDFLocalTextSample` and its in-memory cache.
    nonisolated static func boundedNormalizedExcerpt(
        _ rawText: String,
        rawBudget: EncodedTextBudget,
        outputBudget: EncodedTextBudget
    ) -> EncodedTextLimitResult {
        let raw = EncodedTextLimiter.limit(rawText, budget: rawBudget)
        let normalized = PDFAIContextExtractor.normalizedText(raw.text)
        let output = EncodedTextLimiter.limit(
            normalized,
            budget: outputBudget
        )
        return EncodedTextLimitResult(
            text: output.text,
            wasTruncated: raw.wasTruncated || output.wasTruncated
        )
    }

    private static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .path
            .precomposedStringWithCanonicalMapping
    }

    private static func fileSignature(for url: URL) -> FileSignature {
        let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        return FileSignature(
            fileSize: values?.fileSize,
            modificationDate: values?.contentModificationDate
        )
    }
}

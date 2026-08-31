// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation

/// Lightweight information needed to represent an unopened PDF tab. This
/// deliberately contains no PDFKit objects, page instances, or render caches.
struct PDFLazyDocumentDescriptor: Equatable, Sendable {
    let url: URL
    let pageCount: Int
    let isEncrypted: Bool

    init(url: URL, pageCount: Int, isEncrypted: Bool = false) {
        self.url = url
        self.pageCount = pageCount
        self.isEncrypted = isEncrypted
    }
}

protocol PDFLazyDocumentInspecting: Sendable {
    func inspect(_ url: URL) throws -> PDFLazyDocumentDescriptor
}

/// Reads only Core Graphics' document metadata. `CGPDFDocument` validates the
/// PDF container and exposes its page count without constructing PDFKit's much
/// larger document/page/view graph for every item in a multi-file selection.
struct CoreGraphicsPDFLazyDocumentInspector: PDFLazyDocumentInspecting {
    func inspect(_ url: URL) throws -> PDFLazyDocumentDescriptor {
        let access = SecurityScopedAccess(url: url)
        return try withExtendedLifetime(access) {
            guard
                url.isFileURL,
                FileManager.default.isReadableFile(atPath: url.path),
                let document = CGPDFDocument(url as CFURL)
            else {
                throw WorkspaceError.invalidPDF(url)
            }
            return PDFLazyDocumentDescriptor(
                url: url,
                pageCount: max(0, document.numberOfPages),
                isEncrypted: document.isEncrypted && !document.isUnlocked
            )
        }
    }
}

struct PDFLazyDocumentInspectionOutcome: Equatable, Sendable {
    let url: URL
    let descriptor: PDFLazyDocumentDescriptor?
}

/// Runs blocking Core Graphics metadata reads away from the main actor while
/// limiting concurrent file I/O. Tasks are added as earlier reads finish
/// instead of launching an unbounded task per file.
struct PDFLazyDocumentBatchInspector: Sendable {
    static let defaultMaximumConcurrency = 3

    let inspector: any PDFLazyDocumentInspecting
    let maximumConcurrency: Int

    init(
        inspector: any PDFLazyDocumentInspecting = CoreGraphicsPDFLazyDocumentInspector(),
        maximumConcurrency: Int = defaultMaximumConcurrency
    ) {
        self.inspector = inspector
        self.maximumConcurrency = min(4, max(2, maximumConcurrency))
    }

    func inspect(_ urls: [URL]) async -> [PDFLazyDocumentInspectionOutcome] {
        guard !urls.isEmpty, !Task.isCancelled else { return [] }
        let inspector = self.inspector
        let limit = min(maximumConcurrency, urls.count)

        return await withTaskGroup(
            of: (Int, PDFLazyDocumentDescriptor?).self,
            returning: [PDFLazyDocumentInspectionOutcome].self
        ) { group in
            var results = Array<PDFLazyDocumentDescriptor?>(repeating: nil, count: urls.count)
            for index in 0..<limit {
                let url = urls[index]
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    let descriptor = try? inspector.inspect(url)
                    guard !Task.isCancelled else { return (index, nil) }
                    return (index, descriptor)
                }
            }
            var nextIndex = limit

            while let (index, descriptor) = await group.next() {
                results[index] = descriptor
                if Task.isCancelled {
                    group.cancelAll()
                } else if nextIndex < urls.count {
                    let scheduledIndex = nextIndex
                    let url = urls[scheduledIndex]
                    nextIndex += 1
                    group.addTask {
                        guard !Task.isCancelled else { return (scheduledIndex, nil) }
                        let descriptor = try? inspector.inspect(url)
                        guard !Task.isCancelled else { return (scheduledIndex, nil) }
                        return (scheduledIndex, descriptor)
                    }
                }
            }

            guard !Task.isCancelled else { return [] }
            return urls.enumerated().map { index, url in
                PDFLazyDocumentInspectionOutcome(
                    url: url,
                    descriptor: results[index]
                )
            }
        }
    }
}

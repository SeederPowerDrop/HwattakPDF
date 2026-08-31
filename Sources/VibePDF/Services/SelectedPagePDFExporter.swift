// SPDX-License-Identifier: MPL-2.0

import Foundation
import PDFKit

/// Result of exporting selected pages as separate one-page PDF files.
struct IndividualPagePDFExportResult {
    let directoryURL: URL
    let fileURLs: [URL]
    let sourcePageIndices: [Int]
}

/// Non-mutating selected-page export utilities shared by the sidebar, toolbar,
/// app menu, and workspace model.
enum SelectedPagePDFExporter {
    private static let fallbackBaseName = "HwattakPDF"
    // APFS permits 255 UTF-8 bytes per path component. Keeping the source-
    // derived stem compact leaves ample room for page numbers, export suffixes,
    // collision counters, and the extension without splitting a grapheme.
    private static let maximumBaseNameUTF8Length = 120
    private static let maximumDirectoryNameAttempts = 10_000

    static func documentBaseName(for sourceURL: URL?) -> String {
        let candidate = sourceURL?
            .deletingPathExtension()
            .lastPathComponent
        return sanitizedBaseName(candidate)
    }

    static func combinedFileName(for sourceURL: URL?) -> String {
        "\(documentBaseName(for: sourceURL))-selected-pages.pdf"
    }

    static func individualDirectoryName(for sourceURL: URL?) -> String {
        "\(documentBaseName(for: sourceURL))-selected-pages"
    }

    static func individualFileName(baseName: String, sourcePageIndex: Int) -> String {
        let pageNumber = sourcePageIndex + 1
        let digits = String(pageNumber)
        let padded = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
        return "\(sanitizedBaseName(baseName))-page-\(padded).pdf"
    }

    /// Writes every one-page PDF to a hidden staging folder, validates it with
    /// `AtomicPDFWriter`, then moves the complete folder into view in one
    /// filesystem operation. Existing exports are never overwritten; a numeric
    /// suffix is added to the new folder when needed.
    static func exportIndividually(
        from document: PDFDocument,
        indexes: [Int],
        to parentDirectory: URL,
        sourceURL: URL?,
        fileManager: FileManager = .default
    ) throws -> IndividualPagePDFExportResult {
        try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
        // Validate the complete selection before creating anything in the
        // user-selected folder. Pages themselves are detached one at a time
        // below so a large, image-heavy selection cannot retain hundreds of
        // independent PDF object graphs in memory at once.
        let normalizedIndexes = try PDFPageOperations.normalizedSelection(
            indexes,
            pageCount: document.pageCount
        )
        let access = SecurityScopedAccess(url: parentDirectory)
        defer { withExtendedLifetime(access) {} }
        let baseName = documentBaseName(for: sourceURL)
        let stagingDirectory = parentDirectory.appendingPathComponent(
            ".HwattakPDF-selected-pages-\(UUID().uuidString)",
            isDirectory: true
        )

        var stagingWasCreated = false
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false
            )
            stagingWasCreated = true

            var fileNames: [String] = []
            fileNames.reserveCapacity(normalizedIndexes.count)
            for sourcePageIndex in normalizedIndexes {
                let fileName = individualFileName(
                    baseName: baseName,
                    sourcePageIndex: sourcePageIndex
                )
                let stagingURL = stagingDirectory.appendingPathComponent(fileName)
                try autoreleasepool {
                    let onePageDocument = try PDFPageOperations.extract(
                        from: document,
                        indexes: [sourcePageIndex]
                    )
                    try AtomicPDFWriter.write(onePageDocument, to: stagingURL)
                }
                fileNames.append(fileName)
            }

            let finalDirectory = try moveStagingDirectory(
                stagingDirectory,
                toUniqueDirectoryNamed: individualDirectoryName(for: sourceURL),
                in: parentDirectory,
                fileManager: fileManager
            )
            stagingWasCreated = false
            return IndividualPagePDFExportResult(
                directoryURL: finalDirectory,
                fileURLs: fileNames.map { finalDirectory.appendingPathComponent($0) },
                sourcePageIndices: normalizedIndexes
            )
        } catch {
            let exportError = error
            if
                stagingWasCreated,
                fileManager.fileExists(atPath: stagingDirectory.path)
            {
                do {
                    try fileManager.removeItem(at: stagingDirectory)
                } catch {
                    throw WorkspaceError.operationFailed(
                        L10n.format(
                            "error.selected_pages_cleanup_failed",
                            exportError.localizedDescription,
                            stagingDirectory.path,
                            error.localizedDescription
                        )
                    )
                }
            }
            throw exportError
        }
    }

    private static func sanitizedBaseName(_ candidate: String?) -> String {
        guard let candidate else { return fallbackBaseName }
        let forbiddenCharacters = CharacterSet.controlCharacters.union(
            CharacterSet(charactersIn: "/:\\")
        )
        let filteredScalars = candidate.unicodeScalars.filter {
            !forbiddenCharacters.contains($0)
        }
        let filtered = String(String.UnicodeScalarView(filteredScalars))
        let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ".")
        )
        let trimmed = filtered.trimmingCharacters(in: edgeCharacters)
        guard !trimmed.isEmpty else { return fallbackBaseName }

        var bounded = ""
        for character in trimmed {
            let next = bounded + String(character)
            guard next.utf8.count <= maximumBaseNameUTF8Length else { break }
            bounded = next
        }
        return bounded.isEmpty ? fallbackBaseName : bounded
    }

    private static func moveStagingDirectory(
        _ stagingDirectory: URL,
        toUniqueDirectoryNamed preferredName: String,
        in parentDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        for attempt in 1...maximumDirectoryNameAttempts {
            let suffix = attempt == 1 ? "" : "-\(attempt)"
            let candidate = parentDirectory.appendingPathComponent(
                preferredName + suffix,
                isDirectory: true
            )
            if fileManager.fileExists(atPath: candidate.path) { continue }

            do {
                try fileManager.moveItem(at: stagingDirectory, to: candidate)
                return candidate
            } catch {
                // A competing process may have created the candidate after the
                // existence check. Retry only that benign collision; any other
                // filesystem failure must remain visible to the user.
                if fileManager.fileExists(atPath: candidate.path) { continue }
                throw error
            }
        }

        throw WorkspaceError.cannotSave(
            parentDirectory.appendingPathComponent(preferredName, isDirectory: true)
        )
    }
}

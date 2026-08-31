// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit

struct IndividualPagePNGExportResult {
    let directoryURL: URL
    let fileURLs: [URL]
    let sourcePageIndices: [Int]
}

/// Renders selected pages into a hidden staging directory and publishes the
/// complete batch with one directory rename. No existing PNG or export folder
/// is overwritten, and a failed later page cannot leave an earlier partial
/// result visible in the user-selected directory.
enum SelectedPagePNGExporter {
    typealias PageRenderer = (PDFPage, Int, CGFloat) throws -> Data

    private static let maximumDirectoryNameAttempts = 10_000

    static func directoryName(for sourceURL: URL?) -> String {
        "\(SelectedPagePDFExporter.documentBaseName(for: sourceURL))-selected-pages-png"
    }

    static func fileName(baseName: String, sourcePageIndex: Int) -> String {
        let pageNumber = sourcePageIndex + 1
        let digits = String(pageNumber)
        let padded = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
        return "\(baseName)-page-\(padded).png"
    }

    static func export(
        from document: PDFDocument,
        indexes: [Int],
        to parentDirectory: URL,
        sourceURL: URL?,
        scale: CGFloat,
        fileManager: FileManager = .default
    ) throws -> IndividualPagePNGExportResult {
        try export(
            from: document,
            indexes: indexes,
            to: parentDirectory,
            sourceURL: sourceURL,
            scale: scale,
            fileManager: fileManager,
            renderer: renderPNG
        )
    }

    /// The renderer seam keeps failure cleanup deterministic in regression
    /// tests without weakening the production validation and staging path.
    static func export(
        from document: PDFDocument,
        indexes: [Int],
        to parentDirectory: URL,
        sourceURL: URL?,
        scale: CGFloat,
        fileManager: FileManager = .default,
        renderer: PageRenderer
    ) throws -> IndividualPagePNGExportResult {
        try PDFDocumentSecurityPolicy.validateCanRasterizePages(document)
        let normalizedIndexes = try PDFPageOperations.normalizedSelection(
            indexes,
            pageCount: document.pageCount
        )
        guard scale.isFinite, scale > 0 else {
            throw WorkspaceError.operationFailed(
                L10n.string(
                    "error.invalid_png_scale",
                    defaultValue: "PNG 내보내기 배율이 올바르지 않습니다."
                )
            )
        }

        let access = SecurityScopedAccess(url: parentDirectory)
        return try withExtendedLifetime(access) {
            try exportWithAccess(
                from: document,
                indexes: normalizedIndexes,
                to: parentDirectory,
                sourceURL: sourceURL,
                scale: scale,
                fileManager: fileManager,
                renderer: renderer
            )
        }
    }

    private static func exportWithAccess(
        from document: PDFDocument,
        indexes: [Int],
        to parentDirectory: URL,
        sourceURL: URL?,
        scale: CGFloat,
        fileManager: FileManager,
        renderer: PageRenderer
    ) throws -> IndividualPagePNGExportResult {
        let baseName = SelectedPagePDFExporter.documentBaseName(for: sourceURL)
        let stagingDirectory = parentDirectory.appendingPathComponent(
            ".HwattakPDF-selected-pages-png-\(UUID().uuidString)",
            isDirectory: true
        )
        var stagingWasCreated = false

        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: false
            )
            stagingWasCreated = true

            var names: [String] = []
            names.reserveCapacity(indexes.count)
            for index in indexes {
                guard let page = document.page(at: index) else {
                    throw WorkspaceError.operationFailed(
                        L10n.format("error.render_page_image", index + 1)
                    )
                }
                let data = try autoreleasepool {
                    try renderer(page, index, scale)
                }
                guard
                    let decoded = NSBitmapImageRep(data: data),
                    decoded.pixelsWide > 0,
                    decoded.pixelsHigh > 0
                else {
                    throw WorkspaceError.operationFailed(
                        L10n.format("error.render_page_image", index + 1)
                    )
                }
                let name = fileName(baseName: baseName, sourcePageIndex: index)
                try data.write(
                    to: stagingDirectory.appendingPathComponent(name),
                    options: [.atomic]
                )
                names.append(name)
            }

            let finalDirectory = try moveToUniqueDirectory(
                stagingDirectory,
                preferredName: directoryName(for: sourceURL),
                parentDirectory: parentDirectory,
                fileManager: fileManager
            )
            stagingWasCreated = false
            return IndividualPagePNGExportResult(
                directoryURL: finalDirectory,
                fileURLs: names.map { finalDirectory.appendingPathComponent($0) },
                sourcePageIndices: indexes
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

    private static func renderPNG(
        page: PDFPage,
        sourcePageIndex: Int,
        scale: CGFloat
    ) throws -> Data {
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation % 180) == 90
        let logicalSize = rotated
            ? CGSize(width: box.height, height: box.width)
            : box.size
        let target = PDFRasterBudget(
            maximumDimension: 6_000,
            maximumPixelCount: 20_000_000
        ).boundedPixelSize(logicalSize: logicalSize, scale: scale)
        let image = page.thumbnail(of: target, for: .cropBox)
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw WorkspaceError.operationFailed(
                L10n.format("error.render_page_image", sourcePageIndex + 1)
            )
        }
        return png
    }

    private static func moveToUniqueDirectory(
        _ stagingDirectory: URL,
        preferredName: String,
        parentDirectory: URL,
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
                if fileManager.fileExists(atPath: candidate.path) { continue }
                throw error
            }
        }
        throw WorkspaceError.cannotSave(
            parentDirectory.appendingPathComponent(preferredName, isDirectory: true)
        )
    }
}

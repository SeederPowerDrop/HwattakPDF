// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit

/// Imports common bitmap files as one-page PDFKit documents.
enum ImagePDFConverter {
    private static let previewRootName = "HwattakPDF-ImagePreviews"
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif", "heic", "heif", "webp",
    ]

    static func makeDocument(
        from imageURLs: [URL],
        efficientRenderingEnabled: Bool? = nil
    ) throws -> PDFDocument {
        guard !imageURLs.isEmpty else {
            throw WorkspaceError.operationFailed(
                L10n.string("conversion.error.no_images")
            )
        }

        let document = PDFDocument()
        let loader = efficientRenderingEnabled.map {
            BoundedImageLoader(efficientRenderingEnabled: $0)
        } ?? BoundedImageLoader()
        for (index, url) in imageURLs.enumerated() {
            let access = SecurityScopedAccess(url: url)
            let image = try withExtendedLifetime(access) {
                try loader.load(at: url)
            }
            let pageScale = 841.89 / max(image.size.width, image.size.height)
            image.size = CGSize(
                width: image.size.width * pageScale,
                height: image.size.height * pageScale
            )
            guard
                image.size.width.isFinite,
                image.size.height.isFinite,
                image.size.width > 0,
                image.size.height > 0,
                let page = PDFPage(image: image)
            else {
                throw WorkspaceError.operationFailed(
                    L10n.format("conversion.error.image_read", url.lastPathComponent)
                )
            }
            document.insert(page, at: index)
        }
        return document
    }

    @discardableResult
    static func export(imageURLs: [URL], to destination: URL) throws -> URL {
        let document = try makeDocument(from: imageURLs)
        let access = SecurityScopedAccess(url: destination)
        return try withExtendedLifetime(access) {
            try AtomicPDFWriter.write(document, to: destination)
        }
    }

    /// A preview needs a file-backed PDF because inactive tabs can hibernate.
    /// The unique temporary directory keeps equal image names independent.
    static func makePreviewPDF(from imageURL: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(previewRootName, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let previewURL = directory.appendingPathComponent(
            imageURL.lastPathComponent + ".pdf"
        )
        do {
            let document = try makeDocument(from: [imageURL])
            try AtomicPDFWriter.write(document, to: previewURL)
            return previewURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func previewDisplayName(for url: URL) -> String? {
        guard
            url.pathExtension.lowercased() == "pdf",
            url.deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent == previewRootName
        else { return nil }
        let candidate = url.deletingPathExtension().lastPathComponent
        guard supportedExtensions.contains(
            URL(fileURLWithPath: candidate).pathExtension.lowercased()
        ) else { return nil }
        return candidate
    }

    static func removePreview(at url: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(previewRootName, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let directory = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent() == root,
              UUID(uuidString: directory.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    static func makePreviewInBackground(from url: URL) async throws -> URL {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let preview = try autoreleasepool { try makePreviewPDF(from: url) }
            if Task.isCancelled {
                removePreview(at: preview)
                throw CancellationError()
            }
            return preview
        }
        return try await withTaskCancellationHandler {
            let preview = try await worker.value
            if Task.isCancelled {
                removePreview(at: preview)
                throw CancellationError()
            }
            return preview
        } onCancel: { worker.cancel() }
    }
}

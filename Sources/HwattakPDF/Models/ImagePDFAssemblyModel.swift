// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import SwiftUI

struct ImagePDFAssemblyItem: Identifiable, Equatable {
    enum Source: Equatable {
        case image(URL)
        case html(URL)
        case pdfPage(URL, pageIndex: Int)
        case blank(size: CGSize)
    }

    let id: UUID
    let source: Source
    let sourceVersion: PDFSourceFileVersion?

    init(id: UUID = UUID(), source: Source, sourceVersion: PDFSourceFileVersion? = nil) {
        self.id = id
        self.source = source
        self.sourceVersion = sourceVersion
    }

    var title: String {
        switch source {
        case let .image(url):
            url.lastPathComponent
        case let .html(url):
            url.lastPathComponent
        case let .pdfPage(url, pageIndex):
            L10n.format(
                "builder.item.pdf_page",
                url.lastPathComponent,
                pageIndex + 1
            )
        case .blank:
            L10n.string("builder.item.blank")
        }
    }

    var detail: String {
        switch source {
        case .image:
            L10n.string("builder.item.image")
        case .html:
            L10n.string("builder.item.html")
        case .pdfPage:
            L10n.string("builder.item.imported_pdf")
        case let .blank(size):
            L10n.format("builder.item.blank_size", Int(size.width), Int(size.height))
        }
    }

    var systemImage: String {
        switch source {
        case .image: "photo"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .pdfPage: "doc.richtext"
        case .blank: "doc"
        }
    }
}

/// Retains the security-scoped PDF while its page picker sheet is visible.
final class ImagePDFPageSelection: Identifiable {
    let id = UUID()
    let url: URL
    let pageCount: Int
    let sourceVersion: PDFSourceFileVersion
    fileprivate let access: SecurityScopedAccess

    init(url: URL) throws {
        let access = SecurityScopedAccess(url: url)
        let loaded = try PDFSourceFileAccess.loadDocument(at: url)
        let document = loaded.document
        guard
            !document.isLocked,
            document.pageCount > 0
        else {
            throw WorkspaceError.cannotOpen(url)
        }
        try PDFDocumentSecurityPolicy.validateCanExtractPages(document)
        self.url = url
        pageCount = document.pageCount
        sourceVersion = loaded.version
        self.access = access
    }
}

@MainActor
final class ImagePDFAssemblyModel: ObservableObject {
    @Published private(set) var items: [ImagePDFAssemblyItem] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var status = L10n.string("builder.status.ready")
    @Published var presentedError: String?
    @Published private(set) var recognizedText: String?
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var actualDuration: TimeInterval?
    @Published private(set) var actualOutputByteCount: Int64?
    @Published private(set) var actualProfile: PDFProcessingProfile?
    @Published private(set) var actualUsedOCR = false

    private var sourceAccesses: [URL: SecurityScopedAccess] = [:]
    private var exportTask: Task<Void, Never>?

    var canExport: Bool { !items.isEmpty && !isProcessing }
    var canCancel: Bool { exportTask != nil }

    func addImages(_ urls: [URL]) {
        guard !isProcessing else { return }
        guard !urls.isEmpty else { return }
        invalidateCompletedResult()
        for url in urls {
            sourceAccesses[url.standardizedFileURL] = SecurityScopedAccess(url: url)
            items.append(ImagePDFAssemblyItem(source: .image(url)))
        }
        refreshReadyStatus()
    }

    func addHTMLFiles(_ urls: [URL]) {
        guard !isProcessing else { return }
        guard !urls.isEmpty else { return }
        invalidateCompletedResult()
        for url in urls {
            sourceAccesses[url.standardizedFileURL] = SecurityScopedAccess(url: url)
            items.append(ImagePDFAssemblyItem(source: .html(url)))
        }
        refreshReadyStatus()
    }

    func preparePDFSelection(_ url: URL) throws -> ImagePDFPageSelection {
        try ImagePDFPageSelection(url: url)
    }

    func addPDFPages(from selection: ImagePDFPageSelection, indexes: Set<Int>) {
        guard !isProcessing else { return }
        let normalized = indexes.filter { $0 >= 0 && $0 < selection.pageCount }.sorted()
        guard !normalized.isEmpty else { return }
        invalidateCompletedResult()
        sourceAccesses[selection.url.standardizedFileURL] = selection.access
        items += normalized.map {
            ImagePDFAssemblyItem(source: .pdfPage(selection.url, pageIndex: $0), sourceVersion: selection.sourceVersion)
        }
        refreshReadyStatus()
    }

    func addBlankPage() {
        guard !isProcessing else { return }
        invalidateCompletedResult()
        // ISO A4 at 72 points per inch.
        items.append(
            ImagePDFAssemblyItem(
                source: .blank(size: CGSize(width: 595.28, height: 841.89))
            )
        )
        refreshReadyStatus()
    }

    func remove(_ id: UUID) {
        guard !isProcessing else { return }
        invalidateCompletedResult()
        items.removeAll { $0.id == id }
        releaseUnusedAccesses()
        refreshReadyStatus()
    }

    func removeAll() {
        guard !isProcessing else { return }
        items.removeAll()
        sourceAccesses.removeAll()
        recognizedText = nil
        lastSavedURL = nil
        actualDuration = nil
        actualOutputByteCount = nil
        actualProfile = nil
        actualUsedOCR = false
        refreshReadyStatus()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        guard !isProcessing else { return }
        invalidateCompletedResult()
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func move(_ id: UUID, by offset: Int) {
        guard
            !isProcessing,
            let sourceIndex = items.firstIndex(where: { $0.id == id })
        else { return }
        let destination = sourceIndex + offset
        guard items.indices.contains(destination) else { return }
        invalidateCompletedResult()
        items.swapAt(sourceIndex, destination)
    }

    func startExport(
        to destination: URL,
        ocrConfiguration: OCRConfiguration?,
        profile: PDFProcessingProfile = .stability
    ) {
        guard canExport else { return }
        let snapshot = items
        let effectiveOCRConfiguration = ocrConfiguration.map(profile.applying(to:))
        let destinationAccess = SecurityScopedAccess(url: destination)
        isProcessing = true
        progress = 0
        recognizedText = nil
        lastSavedURL = nil
        actualDuration = nil
        actualOutputByteCount = nil
        actualProfile = nil
        actualUsedOCR = false
        status = L10n.string("builder.status.assembling")
        let startedAt = ProcessInfo.processInfo.systemUptime

        exportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isProcessing = false
                self.exportTask = nil
                withExtendedLifetime(destinationAccess) {}
            }

            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("HwattakPDF-Builder-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: temporary) }

            do {
                let destinationPrecondition = try PDFDestinationPrecondition(destination: destination)
                let document = try await self.assemble(snapshot, profile: profile) { completed in
                    self.progress = Double(completed) / Double(max(1, snapshot.count)) * 0.25
                }
                try Task.checkCancellation()
                let expectedPageCount = document.pageCount

                if let effectiveOCRConfiguration {
                    try AtomicPDFWriter.write(document, to: temporary)
                    self.status = L10n.string("builder.status.ocr")
                    let checkpoint = try await VisionOCRService.recognize(
                        pdfURL: temporary,
                        configuration: effectiveOCRConfiguration
                    ) { value in
                        Task { @MainActor [weak self] in
                            self?.progress = 0.25 + (value.fraction * 0.65)
                            self?.status = L10n.format(
                                "builder.status.ocr_page",
                                value.currentPage,
                                value.total
                            )
                        }
                    }
                    try Task.checkCancellation()
                    self.status = L10n.string("builder.status.validating")
                    try SearchablePDFExporter.export(
                        document: document,
                        checkpoint: checkpoint,
                        to: destination,
                        beforeDestinationCommit: {
                            try Self.validateSources(snapshot, destination: destination)
                            try destinationPrecondition.validate()
                            try Task.checkCancellation()
                        }
                    )
                    self.recognizedText = checkpoint.pages.keys.sorted().compactMap {
                        checkpoint.pages[$0]?.text
                    }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                } else {
                    self.status = L10n.string("builder.status.validating")
                    try AtomicPDFWriter.write(document, to: destination, validateDestinationBeforeCommit: {
                        try Self.validateSources(snapshot, destination: destination)
                        try destinationPrecondition.validate()
                        try Task.checkCancellation()
                    })
                }

                guard
                    expectedPageCount > 0,
                    PDFDocument(url: destination)?.pageCount == expectedPageCount
                else {
                    throw WorkspaceError.operationFailed(
                        L10n.string("builder.error.validation")
                    )
                }
                self.progress = 1
                self.lastSavedURL = destination
                self.actualDuration = max(
                    0,
                    ProcessInfo.processInfo.systemUptime - startedAt
                )
                self.actualOutputByteCount = Self.fileByteCount(at: destination)
                self.actualProfile = profile
                self.actualUsedOCR = effectiveOCRConfiguration != nil
                self.status = L10n.format(
                    "builder.status.saved",
                    destination.lastPathComponent
                )
            } catch is CancellationError {
                self.status = L10n.string("builder.status.cancelled")
                self.progress = 0
            } catch {
                self.presentedError = error.localizedDescription
                self.status = L10n.string("builder.status.failed")
                self.progress = 0
            }
        }
    }

    func cancelExport() {
        guard let exportTask else { return }
        status = L10n.string("builder.status.cancelling")
        exportTask.cancel()
    }

    func waitForExportCompletion() async {
        await exportTask?.value
    }

    func copyRecognizedText() {
        guard let recognizedText, !recognizedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recognizedText, forType: .string)
        status = L10n.string("builder.status.text_copied")
    }

    func saveRecognizedText(to destination: URL) {
        guard let recognizedText, !recognizedText.isEmpty else { return }
        let access = SecurityScopedAccess(url: destination)
        do {
            try withExtendedLifetime(access) {
                let data = Data(recognizedText.utf8)
                do {
                    try data.write(to: destination, options: [.atomic])
                } catch where AtomicPDFWriter.isPermissionDeniedForFileScopeFallback(error) {
                    try data.write(to: destination, options: [])
                }
            }
            status = L10n.format("builder.status.text_saved", destination.lastPathComponent)
        } catch {
            presentedError = error.localizedDescription
        }
    }

    private func assemble(
        _ snapshot: [ImagePDFAssemblyItem],
        profile: PDFProcessingProfile,
        progress: (Int) -> Void
    ) async throws -> PDFDocument {
        guard !snapshot.isEmpty else {
            throw WorkspaceError.noDocument
        }
        let output = PDFDocument()
        var cachedPDFs: [URL: PDFDocument] = [:]

        for (index, item) in snapshot.enumerated() {
            try Task.checkCancellation()
            await Task.yield()
            let pages: [PDFPage]
            switch item.source {
            case let .image(url):
                let imageDocument = try ImagePDFConverter.makeDocument(
                    from: [url],
                    efficientRenderingEnabled: profile == .speed
                )
                guard
                    let sourcePage = imageDocument.page(at: 0),
                    let detached = PDFPageOperations.detachedCopy(of: sourcePage)
                else {
                    throw WorkspaceError.operationFailed(
                        L10n.format("conversion.error.image_read", url.lastPathComponent)
                    )
                }
                pages = [detached]

            case let .html(url):
                status = L10n.format("builder.status.html", url.lastPathComponent)
                let configuration = HTMLPDFConversionConfiguration.preset(
                    profile == .speed ? .fast : .reliable,
                    networkPolicy: .localFilesOnly
                )
                let htmlDocument = try await HTMLPDFConverter.makeDocument(
                    from: url,
                    configuration: configuration
                )
                let detachedPages = (0..<htmlDocument.pageCount).compactMap { pageIndex in
                    htmlDocument.page(at: pageIndex).flatMap(PDFPageOperations.detachedCopy)
                }
                guard
                    !detachedPages.isEmpty,
                    detachedPages.count == htmlDocument.pageCount
                else {
                    throw HTMLPDFConversionError.invalidGeneratedPDF
                }
                pages = detachedPages

            case let .pdfPage(url, pageIndex):
                guard let expected = item.sourceVersion,
                      try PDFSourceFileVersion.capture(at: url) == expected else {
                    throw WorkspaceError.externalModification(url)
                }
                let document: PDFDocument
                if let cached = cachedPDFs[url] {
                    document = cached
                } else {
                    guard let loaded = PDFDocument(url: url), !loaded.isLocked else {
                        throw WorkspaceError.cannotOpen(url)
                    }
                    try PDFDocumentSecurityPolicy.validateCanExtractPages(loaded)
                    cachedPDFs[url] = loaded
                    document = loaded
                }
                guard
                    pageIndex >= 0,
                    pageIndex < document.pageCount,
                    let sourcePage = document.page(at: pageIndex),
                    let detached = PDFPageOperations.detachedCopy(of: sourcePage)
                else {
                    throw WorkspaceError.operationFailed(
                        L10n.format("builder.error.pdf_page", pageIndex + 1)
                    )
                }
                pages = [detached]

            case let .blank(size):
                let image = NSImage(size: size, flipped: false) { bounds in
                    NSColor.white.setFill()
                    bounds.fill()
                    return true
                }
                guard let blank = PDFPage(image: image) else {
                    throw WorkspaceError.operationFailed(
                        L10n.string("builder.error.blank_page")
                    )
                }
                pages = [blank]
            }
            for page in pages {
                output.insert(page, at: output.pageCount)
            }
            progress(index + 1)
        }
        return output
    }

    private static func validateSources(_ items: [ImagePDFAssemblyItem], destination: URL) throws {
        for item in items {
            if case let .pdfPage(url, _) = item.source {
                guard let expected = item.sourceVersion,
                      try PDFSourceFileVersion.capture(at: url) == expected else {
                    throw WorkspaceError.externalModification(url)
                }
                guard !PDFSourceFileVersion.refersToSameLocation(url, destination) else {
                    throw WorkspaceError.operationFailed(L10n.string("error.save_copy_same_as_original"))
                }
            }
        }
    }

    private func releaseUnusedAccesses() {
        let usedURLs = Set(items.compactMap { item -> URL? in
            switch item.source {
            case let .image(url), let .html(url), let .pdfPage(url, _):
                url.standardizedFileURL
            case .blank: nil
            }
        })
        sourceAccesses = sourceAccesses.filter { usedURLs.contains($0.key) }
    }

    private func refreshReadyStatus() {
        status = items.isEmpty
            ? L10n.string("builder.status.ready")
            : L10n.format("builder.status.pages", items.count)
    }

    private func invalidateCompletedResult() {
        recognizedText = nil
        lastSavedURL = nil
        actualDuration = nil
        actualOutputByteCount = nil
        actualProfile = nil
        actualUsedOCR = false
    }

    private static func fileByteCount(at url: URL) -> Int64? {
        guard
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size >= 0
        else { return nil }
        return Int64(size)
    }
}

private extension VisionOCRService.Progress {
    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

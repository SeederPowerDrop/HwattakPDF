// SPDX-License-Identifier: MPL-2.0

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Finder에서 받은 파일을 앱이 지원하는 동작으로 분류한다.
enum WorkspaceDroppedFileKind: Equatable {
    case pdf
    case image
    case unsupported
}

/// Keeps the drag item's security scope alive through the main-actor callback.
/// Synchronous document operations consume it there; the asynchronous tab
/// opener establishes and captures its own scope before the callback returns.
final class WorkspaceDroppedFile {
    let url: URL
    let kind: WorkspaceDroppedFileKind
    private let scopedAccess: SecurityScopedAccess

    init(url: URL) {
        self.url = url
        scopedAccess = SecurityScopedAccess(url: url)
        // Read resource metadata only after acquiring the drag item's sandbox
        // extension; extensionless files may otherwise be misclassified.
        kind = Self.classify(url)
    }

    private static func classify(_ url: URL) -> WorkspaceDroppedFileKind {
        let resourceType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        let filenameType = UTType(filenameExtension: url.pathExtension)
        let filenameExtension = url.pathExtension.lowercased()

        // Some file systems report a generic `public.data` resource type even
        // for a correctly named file. Treat either authoritative signal as a
        // match so Finder drops remain reliable for local and mounted volumes.
        if resourceType?.conforms(to: .pdf) == true
            || filenameType?.conforms(to: .pdf) == true
            || filenameExtension == "pdf"
        {
            return .pdf
        }
        if resourceType?.conforms(to: .image) == true
            || filenameType?.conforms(to: .image) == true
            || ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "heif", "webp"]
                .contains(filenameExtension)
        {
            return .image
        }
        return .unsupported
    }
}

/// 여러 `NSItemProvider`의 비동기 결과를 원래 drag 순서대로 모은다.
///
/// provider callback은 임의 queue와 순서로 도착하므로 lock으로 결과 사전을
/// 보호하고, 모두 끝난 뒤 MainActor에서 정렬해 UI에 전달한다.
enum WorkspaceDroppedFileLoader {
    /// NSItemProvider callbacks are not ordered. Indexing results before the
    /// main-actor handoff preserves Finder's drag order for tab opening.
    static func load(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor ([WorkspaceDroppedFile]) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [Int: WorkspaceDroppedFile] = [:]

        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                defer { group.leave() }
                guard let url = fileURL(from: item), url.isFileURL else { return }

                let droppedFile = WorkspaceDroppedFile(url: url)
                lock.lock()
                results[index] = droppedFile
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let ordered = results.keys.sorted().compactMap { results[$0] }
            MainActor.assumeIsolated {
                completion(ordered)
            }
        }
    }

    private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }
}

/// Adapts Finder-style item providers to the ordered, security-scoped file
/// representation used by the workspace coordinator. Keeping this boundary
/// outside a private SwiftUI closure makes the real provider path testable and
/// ensures every surface applies the same fileURL-only admission rule.
enum WorkspaceExternalFileDropReceiver {
    @discardableResult
    static func receive(
        from providers: [NSItemProvider],
        completion: @escaping @MainActor ([WorkspaceDroppedFile]) -> Void
    ) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        WorkspaceDroppedFileLoader.load(
            from: fileProviders,
            completion: completion
        )
        return true
    }
}

/// Applies one consistent Finder-drop policy regardless of whether the active
/// tab is empty or already showing a document. PDFs always go through the
/// bounded asynchronous tab opener so one unreadable file cannot prevent the
/// remaining files from opening, and an existing URL cannot create a duplicate
/// tab. Images keep their existing current-document editing behavior.
@MainActor
enum WorkspaceFileDropCoordinator {
    @discardableResult
    static func handle(
        _ files: [WorkspaceDroppedFile],
        workspace: PDFWorkspaceState,
        multiDocumentWorkspace: MultiDocumentWorkspaceState
    ) -> Task<[UUID], Never>? {
        let pdfs = files.filter { $0.kind == .pdf }
        let images = files.filter { $0.kind == .image }
        let unsupportedCount = files.count - pdfs.count - images.count

        guard !pdfs.isEmpty || !images.isEmpty else {
            workspace.presentedError = L10n.string("PDF 또는 이미지 파일을 드롭해 주세요.")
            return nil
        }

        let hadOpenDocument = workspace.hasOpenDocument
        guard hadOpenDocument || !pdfs.isEmpty else {
            workspace.presentedError = L10n.string("이미지를 추가하려면 먼저 PDF를 열어 주세요.")
            return nil
        }

        let pdfURLs = pdfs.map(\.url)
        if pdfURLs.isEmpty {
            let blockedImageCount = insertImages(images, into: workspace)
            reportBlockedImages(blockedImageCount, on: workspace)
            appendSkippedFiles(unsupportedCount, to: workspace)
            return nil
        }

        // Retain every dropped image (and therefore its security scope) until
        // the asynchronous PDF batch has installed its tabs. For an existing
        // document the image still targets that original document; for a blank
        // tab it targets the first successfully opened PDF.
        let existingImageTarget = hadOpenDocument ? workspace : nil
        return multiDocumentWorkspace.beginOpeningPDFsInTabs(urls: pdfURLs) { openedIDs in
            let imageTarget: PDFWorkspaceState?
            if let existingImageTarget {
                imageTarget = existingImageTarget
            } else if let firstOpenedID = openedIDs.first {
                imageTarget = multiDocumentWorkspace.tabs.first(where: {
                    $0.id == firstOpenedID
                })?.workspace
            } else {
                imageTarget = nil
            }

            let blockedImageCount: Int
            if let imageTarget {
                blockedImageCount = insertImages(images, into: imageTarget)
            } else {
                blockedImageCount = 0
            }

            let reportingWorkspace = multiDocumentWorkspace.activeWorkspace
                ?? imageTarget
                ?? workspace
            reportBlockedImages(blockedImageCount, on: reportingWorkspace)
            appendSkippedFiles(unsupportedCount, to: reportingWorkspace)
        }
    }

    private static func insertImages(
        _ images: [WorkspaceDroppedFile],
        into workspace: PDFWorkspaceState
    ) -> Int {
        guard !images.isEmpty else { return 0 }
        guard workspace.allows(.imageInsertion) else { return images.count }
        _ = workspace.resumeIfNeeded()
        for image in images {
            workspace.insertImage(url: image.url)
        }
        return 0
    }

    private static func reportBlockedImages(
        _ count: Int,
        on workspace: PDFWorkspaceState
    ) {
        guard count > 0 else { return }
        let message = L10n.format("error.mode_image_drop_requires_editing", count)
        if workspace.presentedError == nil {
            workspace.presentedError = message
        } else {
            appendWarning(message, to: workspace)
        }
    }

    private static func appendSkippedFiles(
        _ count: Int,
        to workspace: PDFWorkspaceState
    ) {
        guard count > 0 else { return }
        appendWarning(L10n.format("status.skipped_files", count), to: workspace)
    }

    private static func appendWarning(_ message: String, to workspace: PDFWorkspaceState) {
        if let existing = workspace.presentedError, !existing.isEmpty {
            workspace.presentedError = existing + "\n" + message
        } else {
            workspace.presentedError = message
        }
    }
}

/// drag가 문서 위에 있을 때 실제 drop 의미를 미리 설명하는 시각/접근성 overlay다.
struct WorkspaceFileDropOverlay: View {
    let hasOpenDocument: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: hasOpenDocument ? "square.and.arrow.down.on.square" : "doc.badge.plus")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(theme.accent)
            Text(
                hasOpenDocument
                    ? L10n.string("PDF를 새 탭으로 열거나 이미지 추가")
                    : L10n.string("PDF를 열어 시작")
            )
                .font(.title3.weight(.semibold))
            Text(
                hasOpenDocument
                    ? L10n.string("PDF는 각각 새 탭에서 열고, 이미지는 현재 페이지 중앙에 놓습니다.")
                    : L10n.string("PDF 여러 개를 놓으면 각 파일을 별도의 탭으로 엽니다.")
            )
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(theme.primaryText)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(theme.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(theme.dropHighlight)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2.5, dash: [9, 7]))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .inset(by: 5)
                        .stroke(theme.border, lineWidth: 1)
                }
        }
        .shadow(color: theme.elevatedShadow, radius: 24, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            hasOpenDocument
                ? L10n.string("PDF를 새 탭으로 열거나 이미지 추가")
                : L10n.string("PDF를 열어 시작")
        )
        .accessibilityHint(
            hasOpenDocument
                ? L10n.string("PDF는 각각 새 탭에서 열고 이미지는 현재 페이지 중앙에 놓습니다.")
                : L10n.string("PDF 여러 개를 놓으면 각 파일을 별도의 탭으로 엽니다.")
        )
    }
}

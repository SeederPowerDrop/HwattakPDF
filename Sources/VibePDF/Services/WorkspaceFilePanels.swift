// SPDX-License-Identifier: MPL-2.0

import AppKit
import UniformTypeIdentifiers

/// macOS 표준 열기/저장 패널을 만드는 단일 진입점이다.
///
/// App Sandbox에서는 패널에서 사용자가 직접 고른 URL에 security-scoped 권한이
/// 부여된다. 임의 파일 경로를 직접 조합하는 대신 이 서비스를 거치게 하는 것은
/// UX 통일뿐 아니라 샌드박스 권한 모델을 지키기 위해서다. AppKit 패널은 UI이므로
/// 모든 메서드는 `@MainActor`에서 실행한다.
@MainActor
enum WorkspaceFilePanels {
    private static var viewableContentTypes: [UTType] {
        ["pdf", "png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif", "heic", "heif", "webp"]
            .compactMap { UTType(filenameExtension: $0) }
    }

    private static var imageContentTypes: [UTType] {
        viewableContentTypes.filter { $0.conforms(to: .image) }
    }

    private static var htmlContentTypes: [UTType] {
        [UTType.html, UTType(filenameExtension: "htm")].compactMap { $0 }
    }

    /// 여러 PDF 선택이 '병합'인지 '각각 탭으로 열기'인지에 따라 안내 문구를 바꾼다.
    enum PDFSelectionPurpose {
        case merge
        case openInTabs
    }

    /// 사용자가 취소하면 빈 배열을 반환한다. 취소는 오류가 아니다.
    static func choosePDFs(
        allowsMultipleSelection: Bool,
        purpose: PDFSelectionPurpose = .merge
    ) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        if allowsMultipleSelection, purpose == .openInTabs {
            panel.title = L10n.string("panel.title.open_pdfs")
            panel.prompt = L10n.string("action.open")
            panel.message = L10n.string("panel.open_tabs")
        } else {
            panel.title = allowsMultipleSelection
                ? L10n.string("panel.title.merge_pdfs")
                : L10n.string("panel.title.open_pdf")
            panel.prompt = allowsMultipleSelection
                ? L10n.string("action.merge")
                : L10n.string("action.open")
            panel.message = allowsMultipleSelection
                ? L10n.string("panel.merge_pdfs")
                : L10n.string("panel.open_pdf")
        }
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Opens PDFs and bitmap images through one familiar File > Open flow.
    static func chooseViewableFiles(allowsMultipleSelection: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = viewableContentTypes
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.title = L10n.string("panel.title.open_documents")
        panel.prompt = L10n.string("action.open")
        panel.message = L10n.string("panel.open_documents")
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// PDF 스탬프로 변환할 수 있는 대표적인 bitmap 형식만 허용한다.
    static func chooseImages(allowsMultipleSelection: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = imageContentTypes
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = L10n.string("panel.title.choose_image")
        panel.prompt = L10n.string("action.choose")
        panel.message = L10n.string("panel.choose_image")
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// HTML is imported only by the PDF builder; it is not routed to the PDF/image viewer.
    static func chooseHTMLFiles(allowsMultipleSelection: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = htmlContentTypes
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.title = L10n.string("builder.add_html")
        panel.prompt = L10n.string("action.choose")
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseSaveOfficeFile(
        suggestedName: String,
        format: PDFOfficeExportFormat
    ) -> URL? {
        guard let contentType = UTType(filenameExtension: format.fileExtension) else {
            return nil
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        panel.title = format == .word
            ? L10n.string("conversion.word.title")
            : L10n.string("conversion.powerpoint.title")
        panel.prompt = L10n.string("action.save")
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseSaveText(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        panel.title = L10n.string("builder.ocr.save_text")
        panel.prompt = L10n.string("action.save")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 저장 위치를 하나 선택한다. 실제 쓰기와 오류 처리는 writer가 담당한다.
    static func chooseSavePDF(
        suggestedName: String,
        title: String? = nil
    ) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        panel.title = title ?? L10n.string("panel.title.save_pdf")
        panel.prompt = L10n.string("action.save")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// PNG 일괄 추출처럼 폴더 권한이 필요한 기능에서 사용한다.
    static func chooseDirectory(
        title: String? = nil,
        message: String
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = title ?? L10n.string("panel.title.choose_folder")
        panel.prompt = L10n.string("action.choose")
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
}

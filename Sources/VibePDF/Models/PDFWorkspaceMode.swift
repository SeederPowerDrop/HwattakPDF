// SPDX-License-Identifier: MPL-2.0

import Foundation

/// PDF 탭을 어떤 목적으로 사용하는지 나타내는 작은 상태 값이다.
///
/// `PDFDocument`와 달리 mode는 PDF 바이트를 바꾸지 않는다. 따라서 mode를
/// 전환해도 문서가 dirty 상태가 되지 않으며, 탭별 session archive에만
/// 저장된다. `String` raw value는 JSON에 장기 저장되므로 한번 배포한
/// 값은 함부로 이름을 바꾸지 않는다.
enum PDFWorkspaceMode: String, CaseIterable, Codable, Identifiable {
    case viewer
    case editing
    case study

    var id: String { rawValue }

    var title: String {
        switch self {
        case .viewer: L10n.string("mode.viewer.title", defaultValue: "뷰어")
        case .editing: L10n.string("mode.editing.title", defaultValue: "에디팅")
        case .study: L10n.string("mode.study.title", defaultValue: "학습")
        }
    }

    var shortTitle: String {
        switch self {
        case .viewer: L10n.string("mode.viewer.short", defaultValue: "보기")
        case .editing: L10n.string("mode.editing.short", defaultValue: "편집")
        case .study: L10n.string("mode.study.short", defaultValue: "학습")
        }
    }

    var summary: String {
        switch self {
        case .viewer: L10n.string("mode.viewer.summary")
        case .editing: L10n.string("mode.editing.summary")
        case .study: L10n.string("mode.study.summary")
        }
    }

    var systemImage: String {
        switch self {
        case .viewer: "eye"
        case .editing: "pencil.and.outline"
        case .study: "graduationcap"
        }
    }

    /// View와 feature implementation은 mode를 직접 switch하지 않고 이 policy를
    /// 묻는다. 정책을 한 곳에 두면 나중에 mode가 늘어나도 화면별 조건이
    /// 서로 엇갈리지 않는다.
    var capabilities: Set<PDFWorkspaceCapability> {
        PDFWorkspaceModePolicy.capabilities(for: self)
    }

    var availableTools: [WorkspaceTool] {
        PDFWorkspaceModePolicy.availableTools(for: self)
    }

    var toolbarSections: Set<PDFWorkspaceToolbarSection> {
        PDFWorkspaceModePolicy.toolbarSections(for: self)
    }

    func allows(_ capability: PDFWorkspaceCapability) -> Bool {
        capabilities.contains(capability)
    }

    func allows(_ tool: WorkspaceTool) -> Bool {
        availableTools.contains(tool)
    }

    /// `WorkspaceTool.text`는 mode에 따라 서로 다른 사용자 의미를 갖는다.
    /// 뷰어/학습에서는 주석 메모이고, 에디팅에서는 PDF 본문 위의
    /// 직접 텍스트 입력이다. 같은 icon을 보여 주더라도 label은 솔직해야 한다.
    func title(for tool: WorkspaceTool) -> String {
        guard tool == .text else { return tool.title }
        return switch self {
        case .viewer: L10n.string("tool.comment_note", defaultValue: "주석 메모")
        case .editing: L10n.string("tool.pdf_text", defaultValue: "PDF 텍스트")
        case .study: L10n.string("tool.study_note", defaultValue: "학습 메모")
        }
    }
}

/// 사용자가 하려는 일을 mode와 분리한 의미 단위다.
///
/// 예를 들어 inline text overlay는 "editing mode인가?"를 직접 검사하기보다
/// `.inlineTextEditing`을 요청한다. 이런 경계는 제품 정책과 구현을 분리하고
/// 각 mode의 기능 표를 단위 테스트할 수 있게 한다.
enum PDFWorkspaceCapability: String, CaseIterable, Hashable {
    case reading
    case textSelection
    case copyAndPaste
    case comments
    case signature
    case translation
    case aiAssistance
    case noteSharing
    case inlineTextEditing
    case imageInsertion
    case signatureImageImport
    case handwriting
    case pageEditing
    case studyTools
    case calculationHelp
    case terminologyHelp
    case typedNotes
    case markup
    case ocr
    case documentSearch
}

/// Ribbon의 시각 구성도 capability policy와 같은 파일에서 결정한다.
/// View에 mode switch가 흩어지면 새 기능이 한 mode에서만 잘못 보이는
/// regression이 생기기 쉽다.
enum PDFWorkspaceToolbarSection: String, Hashable {
    case document
    case viewing
    case inputTools
    case penSettings
    case markup
    case signature
    case images
    case pages
    case ocr
    case ai
    case studyPalette
    case search
}

/// 세 mode의 유일한 capability 표다.
enum PDFWorkspaceModePolicy {
    static func capabilities(for mode: PDFWorkspaceMode) -> Set<PDFWorkspaceCapability> {
        let common: Set<PDFWorkspaceCapability> = [
            .reading,
            .textSelection,
            .copyAndPaste,
            .typedNotes,
            .markup,
            .documentSearch
        ]

        switch mode {
        case .viewer:
            return common.union([
                .comments,
                .signature,
                .translation,
                .aiAssistance,
                .noteSharing,
                .ocr
            ])
        case .editing:
            return common.union([
                .comments,
                .signature,
                .inlineTextEditing,
                .imageInsertion,
                .signatureImageImport,
                .handwriting,
                .pageEditing,
                .ocr
            ])
        case .study:
            return common.union([
                .comments,
                .translation,
                .aiAssistance,
                .handwriting,
                .noteSharing,
                .studyTools,
                .calculationHelp,
                .terminologyHelp,
                .ocr
            ])
        }
    }

    static func availableTools(for mode: PDFWorkspaceMode) -> [WorkspaceTool] {
        return switch mode {
        case .viewer:
            // Text means a FreeText comment in viewer mode, never direct body editing.
            [.select, .text]
        case .editing, .study:
            [.select, .text, .pen, .eraser]
        }
    }

    static func toolbarSections(for mode: PDFWorkspaceMode) -> Set<PDFWorkspaceToolbarSection> {
        let common: Set<PDFWorkspaceToolbarSection> = [
            .document,
            .viewing,
            .inputTools,
            .ocr,
            .search
        ]

        switch mode {
        case .viewer:
            return common.union([.markup, .signature, .ai])
        case .editing:
            return common.union([.markup, .penSettings, .signature, .images, .pages])
        case .study:
            // Study exposes one adjustable markup entry point: its palette.
            // Showing the legacy opaque highlight button beside it would
            // ignore the selected color/thickness/opacity and make identical
            // icons produce different output.
            return common.union([.penSettings, .ai, .studyPalette])
        }
    }

    static func normalizedTool(
        _ requestedTool: WorkspaceTool,
        for mode: PDFWorkspaceMode
    ) -> WorkspaceTool {
        mode.allows(requestedTool) ? requestedTool : .select
    }

    /// Classified annotations can share the Select tool while requiring
    /// different capabilities. The concrete workspace adds a second runtime
    /// provenance check: Viewer may position a newly added signature/comment,
    /// Study may revise its current-session notes, and only Editing may broadly
    /// manipulate persisted or imported objects.
    static func allowsAnnotationEditing(
        _ kind: EditableAnnotationKind,
        in mode: PDFWorkspaceMode
    ) -> Bool {
        return switch kind {
        case .image:
            mode.allows(.imageInsertion)
        case .signature:
            mode.allows(.signature)
        case .freeText:
            mode.allows(.comments)
        }
    }
}

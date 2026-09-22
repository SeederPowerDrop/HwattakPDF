// SPDX-License-Identifier: MPL-2.0

import Foundation

/// User-facing AI tasks. Keeping these separate from provider request models
/// prevents a quick-action button from silently changing network policy.
enum AIQuickAction: String, CaseIterable, Identifiable, Sendable {
    case summarize
    case analyze
    case solve
    case translate
    case explainTerms
    case studyPoints
    case quiz
    case fillDraft
    case relatedPDFs
    case webResearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summarize:
            L10n.string("ai.action.summarize", defaultValue: "요약")
        case .analyze:
            L10n.string("ai.action.analyze", defaultValue: "내용 분석")
        case .solve:
            L10n.string("ai.action.solve", defaultValue: "문제 풀이")
        case .translate:
            L10n.string("study.ai.translate", defaultValue: "번역")
        case .explainTerms:
            L10n.string("study.ai.explain_terms", defaultValue: "용어 설명")
        case .studyPoints:
            L10n.string("study.ai.study_points", defaultValue: "학습 포인트")
        case .quiz:
            L10n.string("study.ai.quiz", defaultValue: "퀴즈")
        case .fillDraft:
            L10n.string("ai.action.fill_draft", defaultValue: "채우기 초안")
        case .relatedPDFs:
            L10n.string("ai.action.related_pdfs", defaultValue: "관련 PDF")
        case .webResearch:
            L10n.string("ai.action.web_research", defaultValue: "웹에서 찾기")
        }
    }

    var systemImage: String {
        switch self {
        case .summarize: "text.alignleft"
        case .analyze: "chart.xyaxis.line"
        case .solve: "function"
        case .translate: "character.book.closed"
        case .explainTerms: "text.book.closed"
        case .studyPoints: "lightbulb"
        case .quiz: "questionmark.bubble"
        case .fillDraft: "square.and.pencil"
        case .relatedPDFs: "doc.on.doc"
        case .webResearch: "globe"
        }
    }

    var suggestedPrompt: String {
        switch self {
        case .summarize:
            L10n.string(
                "ai.prompt.summarize",
                defaultValue: "핵심 주장, 근거, 결론을 빠뜨리지 말고 간결하게 요약해 주세요."
            )
        case .analyze:
            L10n.string(
                "ai.prompt.analyze",
                defaultValue: "내용의 구조, 핵심 논점, 근거의 강점과 한계, 확인할 사항을 분석해 주세요."
            )
        case .solve:
            L10n.string(
                "ai.prompt.solve",
                defaultValue: "수학·과학 문제를 식과 추론 과정을 포함해 단계별로 풀고 마지막에 답을 검산해 주세요."
            )
        case .translate:
            L10n.string(
                "study.ai.prompt.translate",
                defaultValue: "선택한 내용을 사용 중인 언어로 자연스럽게 번역하고, 중요한 원문 용어는 괄호 안에 함께 표시해 주세요."
            )
        case .explainTerms:
            L10n.string(
                "study.ai.prompt.explain_terms",
                defaultValue: "핵심 용어를 골라 쉬운 정의, 문맥 속 의미, 짧은 예시를 함께 설명해 주세요."
            )
        case .studyPoints:
            L10n.string(
                "study.ai.prompt.study_points",
                defaultValue: "시험이나 복습에 중요한 개념, 반드시 기억할 관계, 헷갈리기 쉬운 점을 학습 포인트로 정리해 주세요."
            )
        case .quiz:
            L10n.string(
                "study.ai.prompt.quiz",
                defaultValue: "현재 내용을 점검할 수 있는 짧은 퀴즈를 만들고, 답은 바로 보이지 않도록 마지막에 별도로 정리해 주세요."
            )
        case .fillDraft:
            L10n.string(
                "ai.prompt.fill_draft",
                defaultValue: "문맥에 맞게 채울 내용을 초안으로 작성해 주세요. 모르는 값은 추측하지 말고 대괄호로 표시해 주세요."
            )
        case .relatedPDFs:
            L10n.string(
                "ai.prompt.related_pdfs",
                defaultValue: "선택한 내용과 관련 있는 열린 PDF 또는 최근 PDF를 찾아 주세요."
            )
        case .webResearch:
            L10n.string(
                "ai.prompt.web_research",
                defaultValue: "선택한 내용과 관련된 최신 자료를 웹에서 찾아 핵심 내용을 출처와 함께 정리해 주세요."
            )
        }
    }

    var requestsWebSearch: Bool { self == .webResearch }
    var usesLocalRelatedPDFSearch: Bool { self == .relatedPDFs }
    var producesApplicableDraft: Bool { self == .fillDraft }

    /// 번역은 읽기 중심인 viewer에서도 필요한 범용 동작이다. 용어 설명·학습
    /// 포인트·퀴즈만 `StudyModePalette`에 한정해 일반 패널이 붐비지 않게 한다.
    static let generalActions: [AIQuickAction] = [
        .summarize, .translate, .analyze, .solve, .fillDraft, .relatedPDFs, .webResearch
    ]
}

/// Compact, case-only scope used by the picker. The extraction layer converts
/// this value into its richer `PDFAIContextScope` (including explicit ranges).
enum AIAssistantScopeOption: String, CaseIterable, Identifiable, Sendable {
    case selection
    case currentPage
    case selectedPages
    case wholeDocument

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selection:
            L10n.string("ai.scope.selection", defaultValue: "선택한 텍스트")
        case .currentPage:
            L10n.string("ai.scope.current_page", defaultValue: "현재 페이지")
        case .selectedPages:
            L10n.string("ai.scope.selected_pages", defaultValue: "선택한 페이지")
        case .wholeDocument:
            L10n.string("ai.scope.whole_document", defaultValue: "문서 전체")
        }
    }

    var systemImage: String {
        switch self {
        case .selection: "selection.pin.in.out"
        case .currentPage: "doc.text"
        case .selectedPages: "square.stack.3d.up"
        case .wholeDocument: "doc.text.magnifyingglass"
        }
    }

    var pdfContextScope: PDFAIContextScope {
        switch self {
        case .selection: .selection
        case .currentPage: .currentPage
        case .selectedPages: .selectedPages
        case .wholeDocument: .wholeDocument
        }
    }
}

/// Keeps the visible quick-action buttons aligned with the model boundary.
/// Local related-PDF search deliberately remains usable without an API key,
/// while web research is offered only when the selected provider can actually
/// attach its web-search tool. This prevents a button from spending time
/// extracting PDF context only to fail for a capability known to be absent.
enum AIQuickActionExecutionPolicy {
    static func isAvailable(
        _ action: AIQuickAction,
        phase: AIAssistantPhase,
        hasOpenDocument: Bool,
        hasDocumentCollection: Bool,
        providerRequiresAPIKey: Bool,
        hasAPIKey: Bool,
        webSearchAvailable: Bool
    ) -> Bool {
        guard phase == .idle, hasOpenDocument else { return false }
        if action.usesLocalRelatedPDFSearch {
            return hasDocumentCollection
        }
        guard !providerRequiresAPIKey || hasAPIKey else { return false }
        if action.requestsWebSearch {
            return webSearchAvailable
        }
        return true
    }
}

enum AIAssistantRole: String, Sendable {
    case user
    case assistant
    case notice
}

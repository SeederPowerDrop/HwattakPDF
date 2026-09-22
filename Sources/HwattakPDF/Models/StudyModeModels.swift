// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

/// 학습 모드에서 선택한 문장에 적용할 PDF 표식의 종류다.
///
/// `highlight`는 글자 뒤를 형광펜처럼 칠하고, `underline`은 글자 아래에
/// 선을 긋는다. PDFKit은 표준 Highlight/Underline의 투명도를 재저장하지
/// 못하므로, 조절형 학습 표식은 투명도를 외형 스트림에 구운 Stamp로 저장한다.
/// enum의 kind는 앱 내 표시·그리기 의도이며, 저장된 PDF subtype을
/// Highlight/Underline으로 오해해서는 안 된다.
enum StudyMarkupKind: String, CaseIterable, Identifiable, Sendable {
    case highlight
    case underline

    var id: String { rawValue }

    var defaultThickness: CGFloat { self == .underline ? 1.5 : 9 }

    var thicknessRange: ClosedRange<CGFloat> {
        self == .underline ? 0.5...6 : StudyMarkupStyle.thicknessRange
    }

    var title: String {
        switch self {
        case .highlight:
            L10n.string("study.markup.highlight", defaultValue: "하이라이트")
        case .underline:
            L10n.string("study.markup.underline", defaultValue: "밑줄")
        }
    }

    var systemImage: String {
        switch self {
        case .highlight: "highlighter"
        case .underline: "underline"
        }
    }
}

/// 색·두께·불투명도를 한 번에 전달하는 값 타입이다.
///
/// 팔레트에서 슬라이더를 움직이는 동안 PDF를 바로 수정하지 않고 이 작은 설정만
/// 바꾼다. 사용자가 적용 버튼을 눌렀을 때 `PDFWorkspaceState`가 값을 안전한
/// 범위로 제한한 뒤 하나의 undo 명령으로 annotation을 추가한다.
struct StudyMarkupStyle: Equatable {
    static let thicknessRange: ClosedRange<CGFloat> = 1...16
    static let opacityRange: ClosedRange<CGFloat> = 0.12...1

    var kind: StudyMarkupKind
    var color: NSColor
    var thickness: CGFloat
    var opacity: CGFloat

    init(
        kind: StudyMarkupKind = .highlight,
        color: NSColor = .systemYellow,
        thickness: CGFloat? = nil,
        opacity: CGFloat = 0.42
    ) {
        self.kind = kind
        self.color = color
        self.thickness = thickness ?? kind.defaultThickness
        self.opacity = opacity
    }

    /// PDFKit에 넘기기 직전에 값을 제한한다. 복원 데이터나 미래 버전에서 범위를
    /// 벗어난 값이 들어와도 보이지 않는 표식이나 지나치게 굵은 선이 생기지 않는다.
    var normalized: StudyMarkupStyle {
        var result = self
        result.thickness = min(
            kind.thicknessRange.upperBound,
            max(kind.thicknessRange.lowerBound, thickness)
        )
        result.opacity = min(
            Self.opacityRange.upperBound,
            max(Self.opacityRange.lowerBound, opacity)
        )
        // ColorPicker에서 동적 색 공간이 들어와도 PDF에 기록할 수 있는 RGB 색을
        // 우선 사용한다. 변환할 수 없으면 원래 색을 그대로 보존한다.
        result.color = color.usingColorSpace(.deviceRGB) ?? color
        return result
    }
}

/// 학습 목적에 맞춘 빠른 AI 질문이다.
///
/// 이 enum은 네트워크 호출을 하지 않는다. 각 항목은 기존 `AIQuickAction`으로
/// 변환될 뿐이고, 실제 요청은 `AIAssistantSessionModel.beginRequest`가 PDF 문맥
/// 미리보기를 만든 뒤 기존 사용자 동의 화면에서 멈춘다.
enum StudyAIQuickAction: String, CaseIterable, Identifiable, Sendable {
    case translate
    case explainTerms
    case summarize
    case solveWithSteps
    case studyPoints
    case quiz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translate:
            L10n.string("study.ai.translate", defaultValue: "번역")
        case .explainTerms:
            L10n.string("study.ai.explain_terms", defaultValue: "용어 설명")
        case .summarize:
            L10n.string("study.ai.summarize", defaultValue: "요약")
        case .solveWithSteps:
            L10n.string("study.ai.solve_steps", defaultValue: "풀이 과정")
        case .studyPoints:
            L10n.string("study.ai.study_points", defaultValue: "학습 포인트")
        case .quiz:
            L10n.string("study.ai.quiz", defaultValue: "퀴즈")
        }
    }

    var systemImage: String {
        switch self {
        case .translate: "character.book.closed"
        case .explainTerms: "text.book.closed"
        case .summarize: "text.alignleft"
        case .solveWithSteps: "function"
        case .studyPoints: "lightbulb"
        case .quiz: "questionmark.bubble"
        }
    }

    /// AI session이 이미 알고 있는 action으로 연결한다. 새 버튼도 일반 AI 기능과
    /// 같은 개인정보 보호·공급자 설정·Keychain 경계를 통과하게 만드는 핵심이다.
    var assistantAction: AIQuickAction {
        switch self {
        case .translate: .translate
        case .explainTerms: .explainTerms
        case .summarize: .summarize
        case .solveWithSteps: .solve
        case .studyPoints: .studyPoints
        case .quiz: .quiz
        }
    }
}

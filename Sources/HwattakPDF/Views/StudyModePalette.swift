// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// 학습에 자주 쓰는 AI 질문과 필기 도구를 한 줄에 모은 보조 팔레트다.
///
/// 중요한 개인정보 보호 규칙: 이 뷰는 `AIService`를 직접 호출하지 않는다.
/// `beginRequest`는 전송할 PDF 문맥을 준비해 기존 미리보기/동의 sheet를 띄울
/// 뿐이며, 사용자가 그 sheet에서 확인해야만 외부 공급자 요청이 시작된다.
struct StudyModePalette: View {
    @ObservedObject var workspace: PDFWorkspaceState
    @ObservedObject var providerSettings: AIProviderSettingsStore

    let documentCollection: MultiDocumentWorkspaceState
    let onOpenAssistant: () -> Void
    let showOCR: () -> Void
    let shareNote: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showingMarkupSettings = false
    @State private var showingPenSettings = false

    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                aiStudyMenu

                Button(action: onOpenAssistant) {
                    Label(
                        L10n.string("ai.toolbar", defaultValue: "PDF AI"),
                        systemImage: "sparkles"
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!workspace.hasOpenDocument)
                .help(L10n.string("ai.open", defaultValue: "AI 패널 열기"))

                paletteDivider

                Picker(L10n.string("도구"), selection: $workspace.activeTool) {
                    ForEach(workspace.mode.availableTools) { tool in
                        Label(
                            workspace.mode.title(for: tool),
                            systemImage: tool.systemImage
                        )
                        .tag(tool)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 250)
                .disabled(!canUsePageTools)

                Button {
                    showingPenSettings.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canUsePageTools)
                .help(L10n.string("펜 설정"))
                .accessibilityLabel(L10n.string("펜 설정"))
                .popover(isPresented: $showingPenSettings, arrowEdge: .bottom) {
                    PenSettingsPopover(settings: $workspace.inkSettings)
                }

                paletteDivider

                Picker(
                    L10n.string("study.markup.kind", defaultValue: "표식 종류"),
                    selection: markupKindBinding
                ) {
                    ForEach(StudyMarkupKind.allCases) { kind in
                        Label(kind.title, systemImage: kind.systemImage)
                            .tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 156)
                .disabled(!canApplyMarkup)

                Button {
                    workspace.applyStudyMarkup(workspace.studyMarkupStyle)
                } label: {
                    Label(
                        L10n.string("study.markup.apply", defaultValue: "선택에 적용"),
                        systemImage: workspace.studyMarkupStyle.kind.systemImage
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(theme.ribbonSoft, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!canApplyMarkup)
                .help(
                    canApplyMarkup
                        ? L10n.string(
                            "study.markup.apply_help",
                            defaultValue: "현재 선택한 텍스트에 표식을 추가합니다."
                        )
                        : L10n.string(
                            "study.markup.select_first",
                            defaultValue: "먼저 PDF에서 텍스트를 선택하세요."
                        )
                )

                Button {
                    showingMarkupSettings.toggle()
                } label: {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(
                            Color(nsColor: workspace.studyMarkupStyle.color)
                                .opacity(Double(workspace.studyMarkupStyle.opacity)),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(theme.border, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help(L10n.string("study.markup.style", defaultValue: "표식 색상·두께·진하기"))
                .accessibilityLabel(
                    L10n.string("study.markup.style", defaultValue: "표식 색상·두께·진하기")
                )
                .popover(isPresented: $showingMarkupSettings, arrowEdge: .bottom) {
                    StudyMarkupSettingsPopover(workspace: workspace)
                }

                paletteDivider

                Button(action: showOCR) {
                    Label(L10n.string("OCR"), systemImage: "text.viewfinder")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(theme.card, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(L10n.string("완전 로컬 OCR"))
                .accessibilityHint(L10n.string("완전 로컬 OCR"))

                Button(action: shareNote) {
                    Label(
                        L10n.string("toolbar.share_note", defaultValue: "메모 공유"),
                        systemImage: "square.and.arrow.up"
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(L10n.string("toolbar.share_note", defaultValue: "메모 공유"))
                }
                .controlSize(.small)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(minWidth: geometry.size.width, alignment: .center)
            }
        }
        .frame(height: 46)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.string("study.palette.title", defaultValue: "학습 도구")
        )
    }

    private var paletteDivider: some View {
        Rectangle()
            .fill(theme.border)
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }

    private var canUsePageTools: Bool {
        workspace.hasOpenDocument && workspace.pageColumns <= 2
    }

    private var canApplyMarkup: Bool {
        canUsePageTools && workspace.currentSelection != nil
    }

    private var markupKindBinding: Binding<StudyMarkupKind> {
        Binding(
            get: { workspace.studyMarkupStyle.kind },
            set: { kind in
                workspace.selectStudyMarkupKind(kind)
            }
        )
    }

    private var aiStudyMenu: some View {
        Menu {
            ForEach(StudyAIQuickAction.allCases) { action in
                Button {
                    beginAIAction(action)
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        } label: {
            Label(
                L10n.string("study.ai.menu", defaultValue: "AI 학습"),
                systemImage: "brain.head.profile"
            )
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(theme.ribbonSoft, in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(
            !workspace.hasOpenDocument || workspace.aiAssistantSession.phase != .idle
        )
        .help(
            workspace.currentSelection == nil
                ? L10n.string(
                    "study.ai.current_page_help",
                    defaultValue: "현재 페이지를 미리보기로 준비합니다. 확인 전에는 외부 AI로 보내지 않습니다."
                )
                : L10n.string(
                    "study.ai.selection_help",
                    defaultValue: "선택한 텍스트를 미리보기로 준비합니다. 확인 전에는 외부 AI로 보내지 않습니다."
                )
        )
    }

    private func beginAIAction(_ action: StudyAIQuickAction) {
        // 선택이 있으면 작은 범위만 보내고, 없으면 학습 흐름이 끊기지 않도록
        // 현재 페이지만 사용한다. 문서 전체로 조용히 넓히지 않는 것이 중요하다.
        workspace.aiAssistantSession.scope = workspace.currentSelection == nil
            ? .currentPage
            : .selection
        onOpenAssistant()
        let configuration = providerSettings.selectedConfiguration
        workspace.aiAssistantSession.beginRequest(
            action: action.assistantAction,
            workspace: workspace,
            documentCollection: documentCollection,
            configuration: configuration,
            hasAPIKey: providerSettings.hasAPIKey(for: configuration.kind)
        )
    }
}

/// 팔레트 높이를 키우지 않으면서 세부 표식 값을 조절하는 작은 popover다.
private struct StudyMarkupSettingsPopover: View {
    @ObservedObject var workspace: PDFWorkspaceState
    @Environment(\.colorScheme) private var colorScheme

    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("study.markup.style", defaultValue: "표식 색상·두께·진하기"))
                .font(.headline)

            InlineColorPalette(
                selection: colorBinding,
                title: L10n.string("study.markup.color", defaultValue: "색상")
            )

            valueSlider(
                title: L10n.string("study.markup.thickness", defaultValue: "두께"),
                value: thicknessBinding,
                range: Double(workspace.studyMarkupStyle.kind.thicknessRange.lowerBound)...Double(workspace.studyMarkupStyle.kind.thicknessRange.upperBound),
                valueText: String(format: "%.1f pt", workspace.studyMarkupStyle.thickness)
            )

            valueSlider(
                title: L10n.string("study.markup.opacity", defaultValue: "진하기"),
                value: opacityBinding,
                range: Double(StudyMarkupStyle.opacityRange.lowerBound)...Double(StudyMarkupStyle.opacityRange.upperBound),
                valueText: "\(Int((workspace.studyMarkupStyle.opacity * 100).rounded()))%"
            )

            Text(
                L10n.string(
                    "study.markup.undo_hint",
                    defaultValue: "적용한 표식은 Command-Z로 되돌릴 수 있습니다."
                )
            )
            .font(.caption)
            .foregroundStyle(theme.secondaryText)
        }
        .padding(14)
        .frame(width: 280)
    }

    private var colorBinding: Binding<NSColor> {
        Binding(
            get: { workspace.studyMarkupStyle.color },
            set: { color in
                var style = workspace.studyMarkupStyle
                style.color = color
                workspace.studyMarkupStyle = style
            }
        )
    }

    private var thicknessBinding: Binding<Double> {
        Binding(
            get: { Double(workspace.studyMarkupStyle.thickness) },
            set: { value in
                var style = workspace.studyMarkupStyle
                style.thickness = CGFloat(value)
                workspace.studyMarkupStyle = style
            }
        )
    }

    private var opacityBinding: Binding<Double> {
        Binding(
            get: { Double(workspace.studyMarkupStyle.opacity) },
            set: { value in
                var style = workspace.studyMarkupStyle
                style.opacity = CGFloat(value)
                workspace.studyMarkupStyle = style
            }
        )
    }

    private func valueSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(theme.secondaryText)
            }
            .font(.caption)
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
        }
    }
}

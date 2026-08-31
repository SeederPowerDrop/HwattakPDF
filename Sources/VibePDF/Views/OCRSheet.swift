// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Configuration and progress surface for Apple Vision OCR.
///
/// The sheet owns only draft options. `PDFWorkspaceState` owns the running
/// task, cancellation, checkpoint and export state so closing this sheet does
/// not accidentally cancel a long document. OCR creates a separate searchable
/// copy; it never silently replaces the source PDF.
struct OCRSheet: View {
    @ObservedObject var workspace: PDFWorkspaceState
    let onExport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var configuration = OCRConfiguration()
    @State private var Korean = true
    @State private var English = true
    @State private var Japanese = true

    private var theme: VibePDFTheme {
        VibePDFTheme(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    privacyCard
                    languageCard
                    qualityCard
                    progressCard
                }
                .padding(22)
            }

            actionBar
        }
        .frame(minWidth: 650, idealWidth: 700, maxWidth: 760, minHeight: 650, idealHeight: 700)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 42, height: 42)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("로컬 OCR")
                    .font(.title2.weight(.semibold))
                Text("스캔 문서를 검색하고 선택할 수 있는 PDF로 변환")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()
            Label("Apple Vision · 오프라인", systemImage: "lock.shield.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.success)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(theme.success.opacity(0.11), in: Capsule())
        }
        .padding(.horizontal, 22)
        .frame(height: 82)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(theme.success)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("문서는 이 Mac을 떠나지 않습니다")
                        .font(.callout.weight(.semibold))
                    Text("각 페이지 결과를 안전하게 저장하므로 긴 문서도 중단한 지점부터 이어서 처리합니다.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            Label(
                "내보낸 OCR 사본은 페이지와 주석을 평탄화합니다. 편집 가능한 링크·폼·댓글은 원본 PDF에 보관하세요.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(theme.warning)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .vibePDFCard(theme)
    }

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("인식 언어", caption: "문서에 포함된 언어를 모두 선택하세요")
            HStack(spacing: 9) {
                languageButton("한국어", code: "KO", isOn: $Korean)
                languageButton("English", code: "EN", isOn: $English)
                languageButton("日本語", code: "JA", isOn: $Japanese)
                Spacer()
            }
        }
        .padding(16)
        .vibePDFCard(theme)
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("품질과 처리 방식", caption: "속도와 인식 정확도를 조절합니다")

            VStack(spacing: 10) {
                settingToggle(
                    "텍스트가 있는 페이지 건너뛰기",
                    caption: "이미 검색 가능한 페이지의 중복 처리를 방지합니다.",
                    isOn: $configuration.skipPagesWithText
                )
                Divider()
                settingToggle(
                    "언어 교정 사용",
                    caption: "문맥을 이용해 인식된 단어의 정확도를 높입니다.",
                    isOn: $configuration.useLanguageCorrection
                )
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("렌더링 해상도")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("\(Int(configuration.renderDPI)) DPI")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(theme.dropHighlight, in: Capsule())
                }
                Slider(value: $configuration.renderDPI, in: 150...320, step: 10)
                    .accessibilityLabel("렌더링 해상도")
                    .accessibilityValue("\(Int(configuration.renderDPI)) DPI")
                    .accessibilityHint("값이 높을수록 인식은 정밀하지만 처리 시간이 늘어납니다.")
                HStack {
                    Text("빠르게")
                    Spacer()
                    Text("정밀하게")
                }
                .font(.caption2)
                .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(16)
        .vibePDFCard(theme)
    }

    private var progressCard: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(theme.dropHighlight)
                Image(systemName: progressIcon)
                    .foregroundStyle(theme.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.ocrState.label)
                    .font(.callout.weight(.semibold))
                if let fraction = workspace.ocrState.fraction {
                    ProgressView(value: fraction)
                        .tint(theme.accent)
                } else {
                    Text("설정을 확인한 뒤 OCR을 시작하세요.")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer()
        }
        .padding(14)
        .vibePDFCard(theme)
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Button("닫기") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()

            if case .running = workspace.ocrState {
                Button("중단") { workspace.cancelOCR() }
            } else if case .cancelling = workspace.ocrState {
                Button("중단 중…") {}
                    .disabled(true)
            } else {
                Button {
                    // Convert friendly toggles to Vision's BCP-47 language
                    // identifiers immediately before starting. This keeps the
                    // persisted OCR configuration independent of UI labels.
                    updateLanguages()
                    workspace.startOCR(configuration: configuration)
                } label: {
                    Label("OCR 시작 / 재개", systemImage: "play.fill")
                }
                .disabled(!Korean && !English && !Japanese)
            }

            Button(action: onExport) {
                Label("검색 가능한 사본 내보내기", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(workspace.ocrCheckpoint == nil)
        }
        .padding(.horizontal, 22)
        .frame(height: 68)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.border).frame(height: 1)
        }
    }

    private var progressIcon: String {
        switch workspace.ocrState {
        case .running, .cancelling:
            return "ellipsis"
        default:
            return "text.viewfinder"
        }
    }

    private func sectionTitle(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string(title)).font(.headline)
            Text(L10n.string(caption))
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private func languageButton(
        _ title: String,
        code: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(code)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(isOn.wrappedValue ? .white : theme.secondaryText)
                    .frame(width: 27, height: 23)
                    .background(
                        isOn.wrappedValue ? theme.accent : theme.panel,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                Text(title)
                    .font(.callout.weight(.medium))
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn.wrappedValue ? theme.accent : theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(isOn.wrappedValue ? theme.dropHighlight : theme.panel, in: Capsule())
            .overlay {
                Capsule().stroke(isOn.wrappedValue ? theme.accent.opacity(0.35) : theme.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    private func settingToggle(
        _ title: String,
        caption: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string(title)).font(.callout.weight(.medium))
                Text(L10n.string(caption))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(L10n.string(title))
                .accessibilityValue(
                    isOn.wrappedValue ? L10n.string("toggle.on") : L10n.string("toggle.off")
                )
                .accessibilityHint(L10n.string(caption))
        }
    }

    private func updateLanguages() {
        // At least one toggle is enforced by the disabled Start button above.
        // Add a language only when selected; fewer languages generally reduce
        // Vision's ambiguity and improve recognition speed.
        var languages: [String] = []
        if Korean { languages.append("ko-KR") }
        if English { languages.append("en-US") }
        if Japanese { languages.append("ja-JP") }
        configuration.languages = languages
    }
}

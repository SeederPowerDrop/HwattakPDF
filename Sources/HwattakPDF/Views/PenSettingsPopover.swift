// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Small, live editor for the value-type `InkSettings` owned by the workspace.
/// The binding means every slider update immediately changes the next stroke;
/// this popover does not create an undo command because it changes a tool
/// preference, not PDF content.
struct PenSettingsPopover: View {
    @Binding var settings: InkSettings

    @Environment(\.colorScheme) private var colorScheme

    private var theme: HwattakPDFTheme {
        HwattakPDFTheme(colorScheme: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "pencil.tip.crop.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 38, height: 38)
                    .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("펜 설정")
                        .font(.headline)
                    Text("잉크 스타일을 미리 확인하세요")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }

            preview
            Toggle(L10n.string("pen.pressure.enabled"), isOn: $settings.pressureEnabled)
            Text(L10n.string("pen.pressure.help")).font(.caption2).foregroundStyle(theme.secondaryText)

            Text(
                L10n.string(
                    "pen.opacity.fixed_help",
                    defaultValue: "펜 잉크는 현재 PDF 호환성을 위해 100% 불투명도로 저장됩니다."
                )
            )
            .font(.caption2)
            .foregroundStyle(theme.secondaryText)

            VStack(spacing: 14) {
                InlineColorPalette(
                    selection: $settings.color,
                    title: L10n.string("색상")
                )
                .accessibilityLabel(L10n.string("펜 색상"))
                .accessibilityHint(L10n.string("PDF 주석 선 색상을 선택합니다."))

                Divider()
                settingSlider(
                    title: "굵기",
                    value: $settings.width,
                    range: 0.5...12,
                    step: 0.25,
                    valueText: String(format: "%.1f pt", settings.width)
                )
            }
            .padding(14)
            .hwattakPDFCard(theme, cornerRadius: 13)
        }
        .padding(16)
        .frame(width: 330)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
    }

    private var preview: some View {
        // Preview the exact opaque color and width written to native PDF Ink.
        // A future appearance-backed ink implementation may safely reintroduce
        // opacity, but the current control must not promise lossy PDFKit alpha.
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(theme.canvas)
            Capsule()
                .fill(Color(nsColor: settings.pdfInkColor))
                .frame(width: 218, height: max(1, min(settings.width, 12)))
        }
        .frame(height: 64)
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(theme.border, lineWidth: 1)
        }
    }

    private func settingSlider(
        title: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        step: CGFloat,
        valueText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(L10n.string(title)).font(.callout.weight(.medium))
                Spacer()
                Text(valueText)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(theme.dropHighlight, in: Capsule())
            }
            Slider(value: value, in: range, step: step)
                .accessibilityLabel(L10n.string(title))
                .accessibilityValue(valueText)
        }
    }
}

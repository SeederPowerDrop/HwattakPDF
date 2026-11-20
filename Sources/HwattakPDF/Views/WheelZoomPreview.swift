// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// A small sample page in Settings that zooms with the same modifier and
/// step curve as the main PDF canvas, so users can feel the sensitivity
/// before returning to a document.
struct WheelZoomPreview: View {
    let zoomModifier: PDFWheelZoomModifier
    let secondaryText: Color

    static let scaleRange: ClosedRange<CGFloat> = 0.5...4.0

    @State private var scale: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .underPageBackgroundColor))
                WheelZoomSamplePage()
                    .frame(width: 150, height: 110)
                    .scaleEffect(scale)
            }
            .frame(width: 360, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                WheelZoomScrollCatcher(zoomModifier: zoomModifier) { stepFactor in
                    let target = scale * stepFactor
                    scale = min(Self.scaleRange.upperBound, max(Self.scaleRange.lowerBound, target))
                }
            )

            HStack(spacing: 10) {
                Text(
                    L10n.string(
                        "settings.pdf_input.zoom_preview.hint",
                        defaultValue: "설정한 키를 누른 채 위 영역에서 스크롤해 보세요."
                    )
                )
                .font(.caption)
                .foregroundStyle(secondaryText)
                Spacer(minLength: 0)
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(secondaryText)
                Button(
                    L10n.string(
                        "settings.pdf_input.zoom_preview.reset",
                        defaultValue: "초기화"
                    )
                ) {
                    scale = 1
                }
                .controlSize(.small)
                .disabled(abs(scale - 1) < 0.001)
            }
            .frame(width: 360)
        }
        .disabled(zoomModifier == .disabled)
        .opacity(zoomModifier == .disabled ? 0.5 : 1)
    }
}

/// A language-neutral page mock-up: a title bar, text lines and a small grid.
private struct WheelZoomSamplePage: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 70, height: 6)
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.black.opacity(0.35))
                        .frame(width: index == 4 ? 80 : 126, height: 3)
                }
                HStack(spacing: 6) {
                    Path { path in
                        for step in 0...4 {
                            let offset = CGFloat(step) * 10
                            path.move(to: CGPoint(x: offset, y: 0))
                            path.addLine(to: CGPoint(x: offset, y: 40))
                            path.move(to: CGPoint(x: 0, y: offset))
                            path.addLine(to: CGPoint(x: 40, y: offset))
                        }
                    }
                    .stroke(Color.blue.opacity(0.6), lineWidth: 0.5)
                    .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.black.opacity(0.35))
                                .frame(width: 76, height: 3)
                        }
                    }
                }
                .padding(.top, 2)
            }
            .padding(8)
        }
    }
}

/// Transparent AppKit view that consumes only the configured zoom gesture.
/// Every other scroll event is passed on so the Settings form still scrolls.
private struct WheelZoomScrollCatcher: NSViewRepresentable {
    let zoomModifier: PDFWheelZoomModifier
    let onZoom: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.zoomModifier = zoomModifier
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.zoomModifier = zoomModifier
        view.onZoom = onZoom
    }

    final class CatcherView: NSView {
        var zoomModifier: PDFWheelZoomModifier = .defaultValue
        var onZoom: ((CGFloat) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let input = PDFViewportScrollInput(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                modifiers: InteractivePDFView.viewportModifiers(from: event.modifierFlags)
            )
            // Same resolver as the PDF canvas, so the live sensitivity setting applies.
            if case let .zoom(stepFactor) = PDFViewportScrollIntentResolver.resolve(
                input,
                zoomModifier: zoomModifier
            ) {
                onZoom?(stepFactor)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}

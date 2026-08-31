// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Transactional editor for a pending FreeText annotation.
///
/// Typing is kept in local `@State`; the PDF is touched only by `onCommit`.
/// Consequently Escape/cancel never leaves a half-created annotation or dirty
/// document behind. The workspace owns validation and undo registration.
struct TextEditSheet: View {
    let edit: PendingTextEdit
    let onCommit: (String) -> Void
    let onDraftChanged: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var text: String
    @State private var focused = false
    @State private var lengthLimitReached = false

    private var theme: VibePDFTheme {
        VibePDFTheme(colorScheme: colorScheme)
    }

    init(
        edit: PendingTextEdit,
        onCommit: @escaping (String) -> Void,
        onDraftChanged: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.edit = edit
        self.onCommit = onCommit
        self.onDraftChanged = onDraftChanged
        self.onCancel = onCancel
        // `State` must be seeded through its backing storage in an initializer.
        // Assigning `text` later in `body` would reset user typing on redraw.
        _text = State(initialValue: edit.initialText)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("주석 내용")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(L10n.format("text.character_count", text.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                }

                BoundedPlainTextEditor(
                    text: $text,
                    isFocused: $focused,
                    budget: PDFBoundedPlainTextView.freeTextBudget,
                    onLengthLimitReached: {
                        lengthLimitReached = true
                    }
                )
                    .frame(minHeight: 220)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(focused ? theme.accent.opacity(0.65) : theme.border, lineWidth: focused ? 1.5 : 1)
                    }

                if lengthLimitReached {
                    Label(
                        L10n.format(
                            "inline_text.length_limit",
                            InlineTextDraftLimiter.maximumCharacterCount
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Label(
                    "PDF 표준 자유 텍스트 주석으로 저장됩니다. 기존 본문 객체의 재배치는 고급 편집 엔진에서 지원할 예정입니다.",
                    systemImage: "info.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            actionBar
        }
        .frame(minWidth: 590, idealWidth: 650, maxWidth: 720, minHeight: 410, idealHeight: 450)
        .background(theme.panel)
        .foregroundStyle(theme.primaryText)
        .tint(theme.accent)
        .onAppear { focused = true }
        .onChange(of: text) { _, newValue in
            // Keep the non-PDF draft alive when a tab switch tears down this
            // sheet. It remains outside the PDF until the person explicitly
            // presses Apply; tab switching and Save only preserve the draft.
            onDraftChanged(newValue)
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 40, height: 40)
                .background(theme.dropHighlight, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    edit.isEditingExistingAnnotation
                        ? L10n.string("텍스트 수정")
                        : L10n.string("텍스트 추가")
                )
                    .font(.title3.weight(.semibold))
                Text("페이지 위에 읽기 쉬운 텍스트 주석을 배치합니다.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
            }
            Spacer()
            Label(L10n.format("page.number", edit.pageIndex + 1), systemImage: "doc.text")
                .font(.caption.weight(.medium))
                .foregroundStyle(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(theme.card, in: Capsule())
                .overlay { Capsule().stroke(theme.border, lineWidth: 1) }
        }
        .padding(.horizontal, 20)
        .frame(height: 74)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Spacer()
            Button("취소", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button {
                onCommit(text)
            } label: {
                Label("적용", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 1) }
    }
}

/// SwiftUI wrapper around the same preflighted AppKit text boundary used by
/// the direct-on-page editor.
///
/// `TextEditor` is intentionally not used here. Its Binding can shorten text
/// only after TextKit has already decoded and laid out a Paste/Services/drop
/// payload. This representable keeps native spell checking, selection, input
/// methods and Undo while enforcing the PDF FreeText budget *before* layout.
struct BoundedPlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let budget: EncodedTextBudget
    let onLengthLimitReached: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            isFocused: $isFocused,
            budget: budget,
            onLengthLimitReached: onLengthLimitReached
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView(frame: .zero)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = PDFBoundedPlainTextView(frame: .zero)
        textView.encodedTextBudget = budget
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.onLengthLimitReached = context.coordinator.reportLengthLimit

        let limited = EncodedTextLimiter.limit(text, budget: budget)
        textView.string = limited.text
        if limited.wasTruncated {
            // The model normally refuses an oversized existing annotation
            // before presenting this sheet. Keep this local guard as defense
            // in depth for previews and future call sites.
            DispatchQueue.main.async {
                context.coordinator.synchronizeFromTextView(textView)
                context.coordinator.reportLengthLimit()
            }
        }

        context.coordinator.textView = textView
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            text: $text,
            isFocused: $isFocused,
            budget: budget,
            onLengthLimitReached: onLengthLimitReached
        )
        guard let textView = scrollView.documentView as? PDFBoundedPlainTextView else {
            return
        }
        textView.encodedTextBudget = budget
        textView.onLengthLimitReached = context.coordinator.reportLengthLimit

        // Do not assign an equal String: replacing NSTextView contents during
        // marked-text composition would interrupt Korean/Japanese/Chinese IME.
        if textView.string != text {
            let limited = EncodedTextLimiter.limit(text, budget: budget)
            textView.string = limited.text
            if limited.wasTruncated {
                context.coordinator.synchronizeFromTextView(textView)
                context.coordinator.reportLengthLimit()
            }
        }

        if isFocused, textView.window?.firstResponder !== textView {
            // The view can be updated before AppKit attaches it to the sheet's
            // window. Deferring one run-loop turn gives `makeFirstResponder`
            // a real window without polling or retaining the panel.
            DispatchQueue.main.async { [weak textView] in
                guard let textView, textView.window != nil else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: PDFBoundedPlainTextView?
        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        private var budget: EncodedTextBudget
        private var onLengthLimitReached: () -> Void

        init(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            budget: EncodedTextBudget,
            onLengthLimitReached: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.budget = budget
            self.onLengthLimitReached = onLengthLimitReached
        }

        func update(
            text: Binding<String>,
            isFocused: Binding<Bool>,
            budget: EncodedTextBudget,
            onLengthLimitReached: @escaping () -> Void
        ) {
            self.text = text
            self.isFocused = isFocused
            self.budget = budget
            self.onLengthLimitReached = onLengthLimitReached
        }

        func reportLengthLimit() {
            onLengthLimitReached()
        }

        func synchronizeFromTextView(_ textView: NSTextView) {
            let limited = EncodedTextLimiter.limit(
                textView.string,
                budget: budget
            )
            if textView.string != limited.text {
                textView.string = limited.text
            }
            if text.wrappedValue != limited.text {
                text.wrappedValue = limited.text
            }
            if limited.wasTruncated {
                reportLengthLimit()
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            synchronizeFromTextView(textView)
        }
    }
}

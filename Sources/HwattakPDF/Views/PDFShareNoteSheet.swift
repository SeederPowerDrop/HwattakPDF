// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Lets the user add a private note before explicitly invoking macOS sharing.
///
/// `ShareLink` does not send anything when this view opens. The system share
/// picker appears only after the user presses Share, preserving the app's
/// local-first and explicit-consent behavior.
struct PDFShareNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var note: PDFShareNote
    @State private var memoIsFocused = false
    @State private var memoLengthLimitReached = false

    init(note: PDFShareNote) {
        _note = State(initialValue: note)
    }

    private var theme: HwattakPDFTheme { HwattakPDFTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("share_note.title", defaultValue: "메모 후 공유"))
                        .font(.headline)
                    Text(L10n.string(
                        "share_note.privacy",
                        defaultValue: "선택한 내용과 아래 메모만 공유합니다. PDF 파일 전체는 포함하지 않습니다."
                    ))
                    .font(.caption)
                    .foregroundStyle(theme.secondaryText)
                }
            }

            if !note.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                GroupBox(L10n.string("share_note.selection", defaultValue: "선택한 내용")) {
                    ScrollView {
                        Text(note.excerpt)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(minHeight: 70, maxHeight: 150)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("share_note.memo", defaultValue: "내 메모"))
                    .font(.subheadline.weight(.semibold))
                BoundedPlainTextEditor(
                    text: Binding(
                        get: { note.memo },
                        set: { note.replaceMemo(with: $0) }
                    ),
                    isFocused: $memoIsFocused,
                    budget: PDFShareNote.memoBudget,
                    onLengthLimitReached: {
                        memoLengthLimitReached = true
                    }
                )
                .background(theme.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            memoIsFocused ? theme.accent.opacity(0.65) : theme.border,
                            lineWidth: memoIsFocused ? 1.5 : 1
                        )
                }
                .frame(minHeight: 120)
                .accessibilityLabel(L10n.string("share_note.memo", defaultValue: "내 메모"))

                if memoLengthLimitReached {
                    Label(
                        L10n.format(
                            "inline_text.length_limit",
                            PDFShareNote.maximumMemoCharacters
                        ),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text(
                    L10n.format(
                        "share_note.memo_count",
                        note.memo.count,
                        PDFShareNote.maximumMemoCharacters
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Divider()

            HStack {
                Button(L10n.string("action.cancel", defaultValue: "취소")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(note.sharedText, forType: .string)
                } label: {
                    Label(
                        L10n.string("share_note.copy", defaultValue: "텍스트 복사"),
                        systemImage: "doc.on.doc"
                    )
                }
                .disabled(note.sharedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                ShareLink(item: note.sharedText) {
                    Label(
                        L10n.string("share_note.share", defaultValue: "공유…"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(note.sharedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 410)
        .background(theme.canvas)
    }
}

// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// A compact, non-persistent editor for navigating by a 1-based page number.
/// It is reused in the toolbar and sidebar header so navigation remains
/// available when either surface is hidden or moved.
struct PageJumpControl: View {
    @ObservedObject var workspace: PDFWorkspaceState
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool
    @State private var draft = ""
    @State private var isInvalid = false

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }

    var body: some View {
        HStack(spacing: 4) {
            TextField(
                L10n.string("page.jump.placeholder", defaultValue: "번호"),
                text: $draft
            )
            .textFieldStyle(.plain)
            .font(.caption.monospacedDigit().weight(.semibold))
            .multilineTextAlignment(.trailing)
            .frame(width: inputWidth)
            .focused($isFocused)
            .onSubmit(commit)
            .onKeyPress(.escape) {
                cancel()
                return .handled
            }
            .accessibilityLabel(
                L10n.string("page.jump.label", defaultValue: "페이지로 이동")
            )
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
            .onChange(of: draft) { _, _ in
                if isInvalid { isInvalid = false }
            }

            Text(isInvalid ? "1…\(workspace.pageCount)" : "/ \(workspace.pageCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isInvalid ? Color.red : theme.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .accessibilityHidden(true)

            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .opacity(isInvalid ? 1 : 0)
                .help(isInvalid ? invalidMessage : "")
                .accessibilityLabel(invalidMessage)
                .accessibilityHidden(!isInvalid)
        }
        .environment(\.layoutDirection, .leftToRight)
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isInvalid ? Color.red : theme.border, lineWidth: isInvalid ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear(perform: synchronizeDraft)
        .onChange(of: workspace.currentPageIndex) { _, _ in
            guard !isFocused else { return }
            synchronizeDraft()
        }
        .onChange(of: workspace.pageCount) { _, _ in
            guard !isFocused else { return }
            synchronizeDraft()
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                isInvalid = false
                DispatchQueue.main.async {
                    guard isFocused else { return }
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                }
            } else {
                synchronizeDraft()
            }
        }
        .disabled(workspace.pageCount == 0)
        .opacity(workspace.pageCount == 0 ? 0.5 : 1)
        .help(
            L10n.string(
                "page.jump.help",
                defaultValue: "페이지 번호를 입력하고 Return을 누르세요."
            )
        )
    }

    private var accessibilityValue: String {
        if isInvalid { return invalidMessage }
        return L10n.format(
            "page.current_total",
            min(workspace.currentPageIndex + 1, workspace.pageCount),
            workspace.pageCount
        )
    }

    private var inputWidth: CGFloat {
        let digitCount = max(2, String(max(1, workspace.pageCount)).count)
        return min(64, max(36, CGFloat(digitCount * 8 + 12)))
    }

    private var accessibilityHint: String {
        L10n.format("page.jump.hint", workspace.pageCount)
    }

    private var invalidMessage: String {
        L10n.format("page.jump.invalid", workspace.pageCount)
    }

    private func commit() {
        switch PDFPageJumpRequest.resolve(draft, pageCount: workspace.pageCount) {
        case .unavailable:
            cancel()
        case .invalid:
            isInvalid = true
        case let .destination(pageIndex, pageNumber):
            isInvalid = false
            draft = String(pageNumber)
            workspace.setCurrentPage(pageIndex)
            isFocused = false
        }
    }

    private func cancel() {
        isFocused = false
        synchronizeDraft()
    }

    private func synchronizeDraft() {
        isInvalid = false
        draft = workspace.pageCount > 0
            ? String(min(workspace.currentPageIndex + 1, workspace.pageCount))
            : ""
    }
}

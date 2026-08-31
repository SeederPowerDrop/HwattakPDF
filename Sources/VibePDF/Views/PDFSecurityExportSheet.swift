// SPDX-License-Identifier: MPL-2.0

import SwiftUI

struct PDFSecurityExportSheet: View {
    let onSubmit: (PDFProtectedExportRequest) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var password = ""
    @State private var confirmation = ""
    @State private var validationMessage: String?
    @FocusState private var focusedField: PasswordField?
    @AccessibilityFocusState private var validationAccessibilityFocused: Bool

    private enum PasswordField: Hashable {
        case password
        case confirmation
    }

    private var theme: VibePDFTheme { VibePDFTheme(colorScheme: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "lock.doc.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("security.export.title"))
                        .font(.title3.weight(.semibold))
                    Text(L10n.string("security.export.detail"))
                        .font(.callout)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent(L10n.string("security.export.password")) {
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 245)
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel(L10n.string("security.export.password"))
                        .onSubmit { focusedField = .confirmation }
                }

                LabeledContent(L10n.string("security.export.confirm")) {
                    SecureField("", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 245)
                        .focused($focusedField, equals: .confirmation)
                        .accessibilityLabel(L10n.string("security.export.confirm"))
                        .onSubmit { submit(shareAfterSaving: false) }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: validationMessage == nil ? "info.circle" : "exclamationmark.circle.fill")
                    Text(
                        validationMessage
                            ?? L10n.string("security.export.requirements")
                    )
                }
                .font(.caption)
                .foregroundStyle(validationMessage == nil ? theme.secondaryText : Color.red)
                .accessibilityElement(children: .combine)
                .accessibilityFocused($validationAccessibilityFocused)
            }
            .padding(14)
            .background(theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }

            HStack(spacing: 10) {
                Button(L10n.string("action.cancel")) {
                    clearPasswords()
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.string("security.export.save_share")) {
                    submit(shareAfterSaving: true)
                }

                Button(L10n.string("security.export.save")) {
                    submit(shareAfterSaving: false)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 500)
        .background(theme.panel)
        .onAppear { focusedField = .password }
        .onDisappear(perform: clearPasswords)
        .onChange(of: password) { _, _ in clearValidationMessage() }
        .onChange(of: confirmation) { _, _ in clearValidationMessage() }
    }

    private func submit(shareAfterSaving: Bool) {
        guard password == confirmation else {
            showValidationError(
                L10n.string("security.export.mismatch"),
                focus: .confirmation
            )
            return
        }
        do {
            try PDFPasswordPolicy.validate(password)
        } catch {
            showValidationError(error.localizedDescription, focus: .password)
            return
        }

        let request = PDFProtectedExportRequest(
            userPassword: password,
            shareAfterSaving: shareAfterSaving
        )
        clearPasswords()
        dismiss()
        // Let the sheet finish dismissing before NSSavePanel becomes the next
        // modal surface. The request lives only through this short callback.
        Task { @MainActor in
            await Task.yield()
            onSubmit(request)
        }
    }

    private func clearPasswords() {
        password = ""
        confirmation = ""
        validationMessage = nil
        validationAccessibilityFocused = false
    }

    private func clearValidationMessage() {
        validationMessage = nil
        validationAccessibilityFocused = false
    }

    private func showValidationError(
        _ message: String,
        focus field: PasswordField
    ) {
        validationMessage = message
        focusedField = field
        validationAccessibilityFocused = true
    }
}

// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation

@MainActor
enum PDFPasswordPrompt {
    /// Returns the password exactly as entered. It is never trimmed, copied to
    /// the clipboard, logged, or persisted by HwattakPDF.
    static func requestPassword(for url: URL, wasRejected: Bool) -> String? {
        let alert = NSAlert()
        alert.alertStyle = wasRejected ? .warning : .informational
        alert.messageText = L10n.string(
            "security.open.title",
            defaultValue: "암호가 필요한 PDF"
        )
        let fileMessage = L10n.format("security.open.message", url.lastPathComponent)
        alert.informativeText = wasRejected
            ? [
                fileMessage,
                L10n.string(
                    "security.open.retry",
                    defaultValue: "암호가 올바르지 않습니다. 다시 입력해 주세요."
                )
            ].joined(separator: "\n\n")
            : fileMessage

        let passwordField = NSSecureTextField(frame: .zero)
        let passwordLabel = L10n.string(
            "security.open.password",
            defaultValue: "열기 암호"
        )
        passwordField.placeholderString = passwordLabel
        passwordField.setAccessibilityLabel(passwordLabel)
        passwordField.translatesAutoresizingMaskIntoConstraints = false

        let privacyLabel = NSTextField(wrappingLabelWithString: L10n.string(
            "security.open.privacy",
            defaultValue: "암호는 이 Mac에 저장되지 않습니다."
        ))
        privacyLabel.textColor = .secondaryLabelColor
        privacyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack = NSStackView(views: [passwordField, privacyLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 2, right: 0)
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 58)
        passwordField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        alert.accessoryView = stack

        alert.addButton(withTitle: L10n.string("action.open"))
        alert.addButton(withTitle: L10n.string("action.cancel"))
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = passwordField

        guard alert.runModal() == .alertFirstButtonReturn else {
            passwordField.stringValue = ""
            return nil
        }
        let password = passwordField.stringValue
        passwordField.stringValue = ""
        return password
    }
}

/// Presents the native macOS share picker only after an encrypted file has
/// been fully written and reopened successfully.
@MainActor
enum PDFFileSharePresenter {
    private static var activeSession: ShareSession?

    /// Keeps both the native picker and the destination's sandbox grant alive
    /// until the selected sharing service has actually finished reading the
    /// encrypted file.
    @MainActor
    private final class ShareSession: NSObject,
        @preconcurrency NSSharingServicePickerDelegate,
        NSSharingServiceDelegate
    {
        let picker: NSSharingServicePicker
        let scopedAccess: SecurityScopedAccess
        private var selectedService: NSSharingService?

        init(fileURL: URL) {
            scopedAccess = SecurityScopedAccess(url: fileURL)
            picker = NSSharingServicePicker(items: [fileURL])
            super.init()
            picker.delegate = self
        }

        func show(relativeTo rect: NSRect, of view: NSView) {
            picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }

        func sharingServicePicker(
            _ sharingServicePicker: NSSharingServicePicker,
            didChoose service: NSSharingService?
        ) {
            guard let service else {
                finish()
                return
            }
            selectedService = service
            service.delegate = self
        }

        func sharingService(
            _ sharingService: NSSharingService,
            didShareItems items: [Any]
        ) {
            finish()
        }

        func sharingService(
            _ sharingService: NSSharingService,
            didFailToShareItems items: [Any],
            error: any Error
        ) {
            finish()
        }

        private func finish() {
            selectedService?.delegate = nil
            selectedService = nil
            if PDFFileSharePresenter.activeSession === self {
                PDFFileSharePresenter.activeSession = nil
            }
        }
    }

    @discardableResult
    static func present(fileURL: URL) -> Bool {
        guard let anchor = NSApp.keyWindow?.contentView else {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return false
        }
        let session = ShareSession(fileURL: fileURL)
        activeSession = session
        let anchorRect = NSRect(
            x: anchor.bounds.midX,
            y: anchor.bounds.maxY - 1,
            width: 1,
            height: 1
        )
        session.show(relativeTo: anchorRect, of: anchor)
        return true
    }
}

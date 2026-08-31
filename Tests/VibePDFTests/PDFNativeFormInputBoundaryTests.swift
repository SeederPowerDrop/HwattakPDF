// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import PDFKit
import XCTest
@testable import VibePDF

final class PDFNativeFormInputBoundaryTests: XCTestCase {
    @MainActor
    func testUserPasswordSessionBlocksWidgetClickAndTabButOwnerSessionAllowsThem() throws {
        let fixture = try makeEncryptedFormFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }

        let userWorkspace = PDFWorkspaceState(passwordProvider: { _, _ in fixture.userPassword })
        XCTAssertTrue(userWorkspace.open(url: fixture.url))
        XCTAssertEqual(userWorkspace.document?.permissionsStatus, .user)
        XCTAssertTrue(userWorkspace.document?.allowsFormFieldEntry == true)
        XCTAssertFalse(userWorkspace.allowsNativeFormEditing)

        let userView = try configuredFormView(workspace: userWorkspace)
        let userPage = try XCTUnwrap(userWorkspace.document?.page(at: 0))
        let userWidget = try XCTUnwrap(userPage.annotations.first)
        let userWidgetPoint = userView.convert(
            CGPoint(x: userWidget.bounds.midX, y: userWidget.bounds.midY),
            from: userPage
        )
        XCTAssertTrue(userView.blockedNativeFormWidget(at: userWidgetPoint) === userWidget)
        XCTAssertTrue(userView.suppressesNativeFormWidgetTraversal(keyCode: 48))
        XCTAssertFalse(userView.suppressesNativeFormWidgetTraversal(keyCode: 125))

        let ownerWorkspace = PDFWorkspaceState(passwordProvider: { _, _ in fixture.ownerPassword })
        XCTAssertTrue(ownerWorkspace.open(url: fixture.url))
        XCTAssertEqual(ownerWorkspace.document?.permissionsStatus, .owner)
        XCTAssertTrue(ownerWorkspace.allowsNativeFormEditing)

        let ownerView = try configuredFormView(workspace: ownerWorkspace)
        let ownerPage = try XCTUnwrap(ownerWorkspace.document?.page(at: 0))
        let ownerWidget = try XCTUnwrap(ownerPage.annotations.first)
        let ownerWidgetPoint = ownerView.convert(
            CGPoint(x: ownerWidget.bounds.midX, y: ownerWidget.bounds.midY),
            from: ownerPage
        )
        XCTAssertNil(ownerView.blockedNativeFormWidget(at: ownerWidgetPoint))
        XCTAssertFalse(ownerView.suppressesNativeFormWidgetTraversal(keyCode: 48))
    }

    @MainActor
    func testForbiddenNativeFieldEditorIsImmediatelyResigned() throws {
        let fixture = try makeEncryptedFormFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in fixture.userPassword })
        XCTAssertTrue(workspace.open(url: fixture.url))
        XCTAssertFalse(workspace.allowsNativeFormEditing)

        let pdfView = try configuredFormView(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = pdfView
        let owner = NativeFormFieldEditorOwner(frame: .zero)
        pdfView.addSubview(owner)
        let fieldEditor = NSTextView(frame: .zero)
        fieldEditor.isFieldEditor = true
        fieldEditor.delegate = owner

        let coordinator = PDFKitViewer.Coordinator(state: workspace)
        coordinator.attach(to: pdfView)
        defer { coordinator.detach() }
        coordinator.textFieldEditingBegan(
            Notification(name: NSText.didBeginEditingNotification, object: fieldEditor)
        )

        XCTAssertTrue(window.firstResponder === pdfView)
        XCTAssertEqual(
            workspace.presentedError,
            L10n.string(
                "security.user_session_read_only",
                defaultValue: "사용자 암호로 연 PDF는 보안을 유지해 저장할 수 없어 읽기 전용으로 열립니다. 편집하려면 소유자 암호로 다시 여세요."
            )
        )
    }

    @MainActor
    private func configuredFormView(workspace: PDFWorkspaceState) throws -> InteractivePDFView {
        let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 420, height: 560))
        view.viewportContext = .normal
        view.displayBox = .cropBox
        view.document = try XCTUnwrap(workspace.document)
        view.configure(with: workspace)
        view.autoScales = true
        view.layoutDocumentView()
        return view
    }

    private func makeEncryptedFormFixture() throws -> (
        directory: URL,
        url: URL,
        userPassword: String,
        ownerPassword: String
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibePDF-Native-Form-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("form-only.pdf")
        let document = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        let widget = PDFAnnotation(
            bounds: CGRect(x: 25, y: 175, width: 120, height: 28),
            forType: .widget,
            withProperties: nil
        )
        widget.widgetFieldType = .text
        widget.fieldName = "form-only-field"
        widget.widgetStringValue = "unchanged"
        page.addAnnotation(widget)
        document.insert(page, at: 0)

        let userPassword = "ReaderPass9"
        let ownerPassword = "OwnerPass9"
        let encryptionKeyLength = PDFDocumentWriteOption(
            rawValue: kCGPDFContextEncryptionKeyLength as String
        )
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: ownerPassword,
            .userPasswordOption: userPassword,
            .accessPermissionsOption: NSNumber(
                value: PDFAccessPermissions.allowsFormFieldEntry.rawValue
            ),
            encryptionKeyLength: NSNumber(value: 128),
        ]
        guard document.write(to: url, withOptions: options) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return (directory, url, userPassword, ownerPassword)
    }
}

private final class NativeFormFieldEditorOwner: NSView, NSTextViewDelegate {}

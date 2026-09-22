// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFWorkspaceSafetyTests: XCTestCase {
    @MainActor
    func testWidgetValueChangeMarksWorkspaceDirty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Form-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("form.pdf")

        let source = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        let widget = PDFAnnotation(
            bounds: CGRect(x: 20, y: 180, width: 120, height: 24),
            forType: .widget,
            withProperties: nil
        )
        widget.widgetFieldType = .text
        widget.fieldName = "student-name"
        widget.widgetStringValue = "before"
        page.addAnnotation(widget)
        source.insert(page, at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        workspace.open(url: url)
        XCTAssertFalse(workspace.isDirty)

        let reopenedWidget = try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first)
        reopenedWidget.widgetStringValue = "after"
        workspace.synchronizeWidgetValues(on: workspace.document?.page(at: 0))

        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.statusMessage, "PDF 양식 값을 변경했습니다.")
    }

    @MainActor
    func testTabTransitionCommitsFieldEditorBeforeHibernationPolicyRuns() throws {
        let fixture = try makeFormPDF()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let documentWorkspace = PDFWorkspaceState()
        XCTAssertTrue(documentWorkspace.open(url: fixture.url))
        let widget = try XCTUnwrap(
            documentWorkspace.document?.page(at: 0)?.annotations.first
        )
        var commitCount = 0
        documentWorkspace.installDeactivationCommitHandler(id: UUID()) {
            commitCount += 1
            widget.widgetStringValue = "committed by field editor"
        }
        let workspace = MultiDocumentWorkspaceState(initialWorkspace: documentWorkspace)

        _ = workspace.newTab()

        XCTAssertEqual(commitCount, 1)
        XCTAssertTrue(documentWorkspace.isDirty)
        XCTAssertFalse(documentWorkspace.canHibernate)
        XCTAssertFalse(documentWorkspace.hibernateIfPossible())
        XCTAssertNotNil(documentWorkspace.document)
    }

    @MainActor
    func testCloseGuardCommitsFieldEditorBeforeCheckingDirtyState() throws {
        let fixture = try makeFormPDF()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.url))
        let widget = try XCTUnwrap(
            workspace.document?.page(at: 0)?.annotations.first
        )
        var decisionCount = 0
        workspace.installDeactivationCommitHandler(id: UUID()) {
            widget.widgetStringValue = "typed but not yet resigned"
        }

        let shouldClose = UnsavedChangesGuard.confirmAndClose(
            workspaces: [workspace],
            decisionProvider: { _ in
                decisionCount += 1
                return .cancel
            }
        )

        XCTAssertFalse(shouldClose)
        XCTAssertEqual(decisionCount, 1)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNotNil(workspace.document)
        XCTAssertEqual(widget.widgetStringValue, "typed but not yet resigned")
    }

    @MainActor
    func testMultiplePDFViewsKeepIndependentDeactivationHandlers() {
        let workspace = PDFWorkspaceState()
        let normalViewID = UUID()
        let comparisonViewID = UUID()
        var normalCommitCount = 0
        var comparisonCommitCount = 0
        workspace.installDeactivationCommitHandler(id: normalViewID) {
            normalCommitCount += 1
        }
        workspace.installDeactivationCommitHandler(id: comparisonViewID) {
            comparisonCommitCount += 1
        }

        workspace.prepareForDeactivation()
        XCTAssertEqual(normalCommitCount, 1)
        XCTAssertEqual(comparisonCommitCount, 1)

        // Removing the comparison panel must not unregister the still-visible
        // normal editor's field-commit closure.
        workspace.removeDeactivationCommitHandler(id: comparisonViewID)
        workspace.prepareForDeactivation()

        XCTAssertEqual(normalCommitCount, 2)
        XCTAssertEqual(comparisonCommitCount, 1)
    }

    @MainActor
    func testResponderScopingRecognizesOnlyPDFViewHierarchy() {
        let pdfView = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let pdfChild = FieldEditorOwnerView(frame: .zero)
        let unrelated = NSView(frame: .zero)
        pdfView.addSubview(pdfChild)
        let fieldEditor = NSTextView(frame: .zero)
        fieldEditor.isFieldEditor = true
        fieldEditor.delegate = pdfChild

        XCTAssertTrue(PDFKitViewer.Coordinator.responder(pdfChild, belongsTo: pdfView))
        XCTAssertTrue(PDFKitViewer.Coordinator.responder(pdfView, belongsTo: pdfView))
        XCTAssertTrue(PDFKitViewer.Coordinator.responder(fieldEditor, belongsTo: pdfView))
        XCTAssertFalse(PDFKitViewer.Coordinator.responder(unrelated, belongsTo: pdfView))
    }

    @MainActor
    func testComparisonViewerAlsoRegistersFormDeactivationCommitHandler() {
        for context in [PDFViewerViewportContext.normal, .comparison] {
            let workspace = PDFWorkspaceState()
            let coordinator = PDFKitViewer.Coordinator(
                state: workspace,
                viewportContext: context
            )
            let pdfView = InteractivePDFView(frame: .zero)

            coordinator.attach(to: pdfView)
            XCTAssertTrue(coordinator.hasRegisteredDeactivationCommitHandler)

            coordinator.detach()
            XCTAssertFalse(coordinator.hasRegisteredDeactivationCommitHandler)
        }
    }

    @MainActor
    func testDismantlingSupersededViewerDoesNotInvokeReplacementHandler() {
        let workspace = PDFWorkspaceState()
        let outgoingCoordinator = PDFKitViewer.Coordinator(state: workspace)
        let outgoingView = InteractivePDFView(frame: .zero)
        outgoingCoordinator.attach(to: outgoingView)
        var replacementHandlerCalls = 0
        workspace.installDeactivationCommitHandler(id: UUID()) {
            replacementHandlerCalls += 1
        }

        outgoingCoordinator.prepareForDismantling()

        XCTAssertEqual(replacementHandlerCalls, 0)
        outgoingCoordinator.detach()
    }

    private func makeFormPDF() throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Form-Deactivation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("form.pdf")
        let source = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        let widget = PDFAnnotation(
            bounds: CGRect(x: 20, y: 180, width: 120, height: 24),
            forType: .widget,
            withProperties: nil
        )
        widget.widgetFieldType = .text
        widget.fieldName = "student-name"
        widget.widgetStringValue = "before"
        page.addAnnotation(widget)
        source.insert(page, at: 0)
        guard source.write(to: url) else { throw CocoaError(.fileWriteUnknown) }
        return (directory, url)
    }
}

private final class FieldEditorOwnerView: NSView, NSTextViewDelegate {}

// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import HwattakPDF

@MainActor
final class AppEditCommandRouterTests: XCTestCase {
    func testMenuTrackingDefersAndCoalescesCommandUpdatesUntilClosing() {
        let center = NotificationCenter()
        let router = AppEditCommandRouter(
            notificationCenter: center,
            observesMouseEvents: false
        )
        let menu = NSMenu(title: "Plugins")
        router.invalidate()
        XCTAssertEqual(router.revision, 1)

        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        router.invalidate()
        router.invalidate()
        XCTAssertEqual(router.revision, 1)

        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(router.revision, 2)
        router.invalidate()
        XCTAssertEqual(router.revision, 3)
    }

    func testClosingNestedMenuDoesNotRebuildAnOpenParentMenu() {
        let center = NotificationCenter()
        let router = AppEditCommandRouter(
            notificationCenter: center,
            observesMouseEvents: false
        )
        let parent = NSMenu(title: "Plugins")
        let submenu = NSMenu(title: "Translation Helper")
        center.post(name: NSMenu.didBeginTrackingNotification, object: parent)
        center.post(name: NSMenu.didBeginTrackingNotification, object: submenu)
        router.invalidate()

        center.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        XCTAssertEqual(router.revision, 0)
        center.post(name: NSMenu.didEndTrackingNotification, object: parent)
        XCTAssertEqual(router.revision, 1)
    }

    func testUnrelatedMenuEndDoesNotReleaseTrackingAndRepeatedBeginDoesNotLatchIt() {
        let center = NotificationCenter()
        let router = AppEditCommandRouter(
            notificationCenter: center,
            observesMouseEvents: false
        )
        let menu = NSMenu(title: "Plugins")
        let unrelated = NSMenu(title: "Other")
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        router.invalidate()
        center.post(name: NSMenu.didEndTrackingNotification, object: unrelated)
        XCTAssertEqual(router.revision, 0)

        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(router.revision, 1)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(router.revision, 1)
        router.invalidate()
        XCTAssertEqual(router.revision, 2)
    }

    func testMenuWithoutFocusChangesDoesNotTriggerAnUnnecessaryCommandUpdate() {
        let center = NotificationCenter()
        let router = AppEditCommandRouter(
            notificationCenter: center,
            observesMouseEvents: false
        )
        let menu = NSMenu(title: "Plugins")
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        XCTAssertEqual(router.revision, 0)
    }

    func testApplicationDeactivationReleasesCancelledMenuTracking() {
        let center = NotificationCenter()
        let router = AppEditCommandRouter(
            notificationCenter: center,
            observesMouseEvents: false
        )
        let menu = NSMenu(title: "Plugins")
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        router.invalidate()
        center.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(router.revision, 1)

        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        router.invalidate()
        XCTAssertEqual(router.revision, 2)
    }

    func testEditableTextHasPriorityOverDocumentAndPresentedSheet() {
        XCTAssertEqual(
            AppEditCommandDestination.resolve(
                hasEditableTextResponder: true,
                hasPresentedSheet: true
            ),
            .textEditing
        )
    }

    func testPresentedSheetBlocksDocumentHistoryWithoutAnEditor() {
        XCTAssertEqual(
            AppEditCommandDestination.resolve(
                hasEditableTextResponder: false,
                hasPresentedSheet: true
            ),
            .blockedBySheet
        )
    }

    func testDocumentHistoryIsTheNormalWorkspaceFallback() {
        XCTAssertEqual(
            AppEditCommandDestination.resolve(
                hasEditableTextResponder: false,
                hasPresentedSheet: false
            ),
            .document
        )
    }

    func testEditableTextResponderKeepsNativeUndoAndRedoOwnership() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = NSTextView(frame: window.contentView?.bounds ?? .zero)
        textView.isEditable = true
        textView.allowsUndo = true
        window.contentView = textView
        XCTAssertTrue(window.makeFirstResponder(textView))
        XCTAssertTrue(
            AppEditCommandRouter.editableTextView(startingAt: window.firstResponder)
                === textView
        )

        let manager = try XCTUnwrap(textView.undoManager)
        manager.groupsByEvent = false
        let counter = NativeUndoCounter()
        manager.beginUndoGrouping()
        counter.setValue(1, using: manager)
        manager.endUndoGrouping()

        XCTAssertTrue(AppEditCommandRouter.canNativeUndo(in: textView))
        XCTAssertTrue(AppEditCommandRouter.performNativeUndo(in: textView))
        XCTAssertEqual(counter.value, 0)
        XCTAssertTrue(AppEditCommandRouter.canNativeRedo(in: textView))
        XCTAssertTrue(AppEditCommandRouter.performNativeRedo(in: textView))
        XCTAssertEqual(counter.value, 1)

        let readOnlyView = NSTextView(frame: .zero)
        readOnlyView.isEditable = false
        XCTAssertNil(
            AppEditCommandRouter.editableTextView(startingAt: readOnlyView)
        )
    }

    func testFocusedNormalPDFDescendantOverridesTheActiveTabFallback() {
        let activeTab = PDFWorkspaceState()
        let focusedDocument = PDFWorkspaceState()
        let pdfView = InteractivePDFView(frame: .zero)
        pdfView.workspaceState = focusedDocument
        pdfView.viewportContext = .normal
        let internalPDFSubview = NSView(frame: .zero)
        pdfView.addSubview(internalPDFSubview)

        let result = AppEditCommandRouter.documentWorkspace(
            startingAt: internalPDFSubview,
            fallback: activeTab
        )

        XCTAssertTrue(result === focusedDocument)
    }

    func testFocusedComparisonPDFDescendantBlocksDocumentUndoFallback() {
        let activeTab = PDFWorkspaceState()
        let comparisonSource = PDFWorkspaceState()
        let pdfView = InteractivePDFView(frame: .zero)
        pdfView.workspaceState = comparisonSource
        pdfView.viewportContext = .comparison
        let internalPDFSubview = NSView(frame: .zero)
        pdfView.addSubview(internalPDFSubview)

        XCTAssertTrue(
            AppEditCommandRouter.isComparisonViewport(startingAt: internalPDFSubview)
        )
        XCTAssertNil(
            AppEditCommandRouter.documentWorkspace(
                startingAt: internalPDFSubview,
                fallback: activeTab
            )
        )
    }

    func testComparisonPanelFirstResponderTransitionInvalidatesMenuState() {
        let router = AppEditCommandRouter.shared
        let leftWorkspace = PDFWorkspaceState()
        let rightWorkspace = PDFWorkspaceState()
        let leftPDFView = InteractivePDFView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 400)
        )
        leftPDFView.workspaceState = leftWorkspace
        let rightPDFView = InteractivePDFView(
            frame: NSRect(x: 300, y: 0, width: 300, height: 400)
        )
        rightPDFView.workspaceState = rightWorkspace
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        container.addSubview(leftPDFView)
        container.addSubview(rightPDFView)
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container

        let initialRevision = router.revision
        XCTAssertTrue(window.makeFirstResponder(leftPDFView))
        let leftRevision = router.revision
        XCTAssertGreaterThan(leftRevision, initialRevision)
        XCTAssertTrue(
            AppEditCommandRouter.documentWorkspace(
                startingAt: window.firstResponder,
                fallback: nil
            ) === leftWorkspace
        )

        XCTAssertTrue(window.makeFirstResponder(rightPDFView))
        XCTAssertGreaterThan(router.revision, leftRevision)
        XCTAssertTrue(
            AppEditCommandRouter.documentWorkspace(
                startingAt: window.firstResponder,
                fallback: nil
            ) === rightWorkspace
        )
    }

    func testAnnotationOverlayResolvesItsOwningPDFWorkspace() {
        let activeTab = PDFWorkspaceState()
        let focusedComparisonPanel = PDFWorkspaceState()
        let pdfView = InteractivePDFView(frame: .zero)
        pdfView.workspaceState = focusedComparisonPanel
        pdfView.viewportContext = .normal
        let overlay = PDFAnnotationEditingOverlayView(frame: .zero)
        overlay.owner = pdfView

        let result = AppEditCommandRouter.documentWorkspace(
            startingAt: overlay,
            fallback: activeTab
        )

        XCTAssertTrue(result === focusedComparisonPanel)
    }

    func testNonPDFResponderUsesTheActiveTabFallback() {
        let activeTab = PDFWorkspaceState()
        let result = AppEditCommandRouter.documentWorkspace(
            startingAt: NSView(frame: .zero),
            fallback: activeTab
        )

        XCTAssertTrue(result === activeTab)
    }

    func testNonPDFResponderWithoutAFocusedPDFSceneHasNoDocumentTarget() {
        let result = AppEditCommandRouter.documentWorkspace(
            startingAt: NSView(frame: .zero),
            fallback: nil
        )

        XCTAssertNil(result)
    }

    func testDetachedWindowWithoutItsOwnSheetDoesNotBlockCommands() {
        let detachedWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        XCTAssertFalse(AppEditCommandRouter.hasPresentedSheet(in: detachedWindow))
    }
}

private final class NativeUndoCounter: NSObject {
    var value = 0

    func setValue(_ newValue: Int, using manager: UndoManager) {
        let oldValue = value
        manager.registerUndo(withTarget: self) { target in
            target.setValue(oldValue, using: manager)
        }
        value = newValue
    }
}

// SPDX-License-Identifier: MPL-2.0

import AppKit
import XCTest
@testable import VibePDF

final class AppFileCommandRouterTests: XCTestCase {
    @MainActor
    func testOnlyGuardedKeyPDFWindowOwnsDocumentCommands() {
        let workspace = MultiDocumentWorkspaceState()
        let pdfWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowCloseGuard.Coordinator(workspace: workspace)
        coordinator.attach(to: pdfWindow)
        defer { coordinator.detach() }

        XCTAssertTrue(
            AppFileCommandRouter.documentWorkspace(for: pdfWindow) === workspace
        )

        let auxiliaryWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        XCTAssertNil(AppFileCommandRouter.documentWorkspace(for: auxiliaryWindow))
    }

    @MainActor
    func testSheetBlocksParentDocumentCommandsAndIsTheCloseTarget() {
        let workspace = MultiDocumentWorkspaceState()
        let pdfWindow = SimulatedSheetParentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let coordinator = WindowCloseGuard.Coordinator(workspace: workspace)
        coordinator.attach(to: pdfWindow)
        defer { coordinator.detach() }
        let sheet = SimulatedSheetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        pdfWindow.simulatedAttachedSheet = sheet
        sheet.simulatedSheetParent = pdfWindow

        XCTAssertNil(AppFileCommandRouter.documentWorkspace(for: pdfWindow))
        XCTAssertNil(AppFileCommandRouter.documentWorkspace(for: sheet))

        guard case let .window(parentTarget) = AppFileCommandRouter.closeTarget(for: pdfWindow) else {
            return XCTFail("The parent key-window route must close its attached sheet.")
        }
        XCTAssertTrue(parentTarget === sheet)

        guard case let .window(sheetTarget) = AppFileCommandRouter.closeTarget(for: sheet) else {
            return XCTFail("A key sheet must remain the native close target.")
        }
        XCTAssertTrue(sheetTarget === sheet)
    }

    @MainActor
    func testDocumentCloseTargetsTabButAuxiliaryCloseTargetsWindow() {
        let workspace = MultiDocumentWorkspaceState()
        let pdfWindow = NSWindow()
        let coordinator = WindowCloseGuard.Coordinator(workspace: workspace)
        coordinator.attach(to: pdfWindow)
        defer { coordinator.detach() }

        guard case let .activeTab(targetWorkspace) = AppFileCommandRouter.closeTarget(
            for: pdfWindow
        ) else {
            return XCTFail("A PDF key window must close its active tab.")
        }
        XCTAssertTrue(targetWorkspace === workspace)

        let auxiliaryWindow = NSWindow()
        guard case let .window(targetWindow) = AppFileCommandRouter.closeTarget(
            for: auxiliaryWindow
        ) else {
            return XCTFail("An auxiliary key window must use AppKit window close.")
        }
        XCTAssertTrue(targetWindow === auxiliaryWindow)
    }
}

/// `NSWindow.beginSheet` is process-global AppKit presentation and can decline
/// to attach a hidden XCTest window after another test has changed key-window
/// state. Override only the two read-only relationships consumed by the router
/// so this unit test remains deterministic without changing production logic.
private final class SimulatedSheetParentWindow: NSWindow {
    var simulatedAttachedSheet: NSWindow?

    override var attachedSheet: NSWindow? {
        simulatedAttachedSheet
    }
}

private final class SimulatedSheetWindow: NSWindow {
    weak var simulatedSheetParent: NSWindow?

    override var sheetParent: NSWindow? {
        simulatedSheetParent
    }
}

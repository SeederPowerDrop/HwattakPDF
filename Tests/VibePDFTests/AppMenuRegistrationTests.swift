// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest

final class AppMenuRegistrationTests: XCTestCase {
    func testApplicationCommandsAreRegisteredExactlyOnceForAllPDFWindows() throws {
        let source = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/App/VibePDFApp.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(source.components(separatedBy: ".commands {").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "VibePDFCommands(").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "PluginCommands(").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: "HelpTutorialCommands()").count - 1, 1)
        XCTAssertEqual(
            source.components(separatedBy: ".focusedSceneObject(workspace)").count - 1,
            2,
            "The main and tear-out branches must still publish their active workspace."
        )
        XCTAssertEqual(
            source.components(separatedBy: "WindowGroup(\"HwattakPDF\", for: UUID.self)").count - 1,
            1
        )
        XCTAssertEqual(
            source.components(separatedBy: "Window(\"HwattakPDF\", id: \"main\")").count - 1,
            1,
            "The singleton default scene must remain the app-launch window."
        )
    }

    func testPluginsHaveAVisibleWorkspaceEntryPointAndSingleActionMenusAreFlat() throws {
        let toolbarSource = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/Views/WorkspaceToolbar.swift"),
            encoding: .utf8
        )
        let commandSource = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/App/PluginCommands.swift"),
            encoding: .utf8
        )
        let workspaceSource = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/Views/WorkspaceView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(toolbarSource.contains("pluginToolbarMenu"))
        XCTAssertTrue(toolbarSource.contains("plugin-toolbar-menu"))
        XCTAssertTrue(toolbarSource.contains("PluginActionLauncher.run("))
        XCTAssertTrue(commandSource.contains("plugin.manifest.actions.count == 1"))
        XCTAssertTrue(commandSource.contains("editCommandRouter.documentWorkspace("))
        XCTAssertTrue(
            workspaceSource.contains("if isFocusMode {\n                    setFocusMode(false)")
        )
    }

    func testNativeViewMenuOwnsDetailedWorkspacePresentationCommands() throws {
        let source = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/App/VibePDFApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("CommandGroup(after: .sidebar)"))
        XCTAssertTrue(source.contains("@FocusedValue(\\.workspacePresentationCommands)"))
        XCTAssertTrue(source.contains("private var viewCommandWorkspace"))
        XCTAssertTrue(source.contains("toolbar.mode_tools.show"))
        XCTAssertTrue(source.contains("view.focus.enter"))
        XCTAssertTrue(source.contains("view.focus.exit"))
        XCTAssertTrue(source.contains("view.sidebar.position"))
        XCTAssertTrue(source.contains("view.two_page.continuous.title"))
        XCTAssertTrue(source.contains("view.two_page.paged.title"))
        XCTAssertTrue(source.contains("ForEach(PDFGridLayoutMode.allCases)"))
        XCTAssertTrue(source.contains("ForEach(PDFGridPagingDirection.allCases)"))
        XCTAssertTrue(source.contains("ForEach([3] + Array(5...12)"))
        XCTAssertFalse(
            source.contains("CommandMenu(\"View\")"),
            "Workspace presentation commands must extend macOS's native View menu."
        )
    }

    func testSettingsMenuUsesOnlyTheNativeSettingsSceneRegistration() throws {
        let sourceURL = Self.projectRoot
            .appendingPathComponent("Sources/VibePDF/App/VibePDFApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertEqual(
            source.components(separatedBy: "Settings {").count - 1,
            1,
            "The Settings scene should be the single owner of the standard macOS Settings menu item."
        )
        XCTAssertFalse(
            source.contains("CommandGroup(replacing: .appSettings)"),
            "A custom appSettings command duplicates the item supplied by the Settings scene."
        )
        XCTAssertFalse(
            source.contains("SettingsLink"),
            "Register SettingsLink only if the native Settings scene menu item is removed."
        )
    }

    func testUndoRedoCommandsRouteThroughTheFocusedWorkspaceSafely() throws {
        let sourceURL = Self.projectRoot
            .appendingPathComponent("Sources/VibePDF/App/VibePDFApp.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let routerSource = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/App/AppEditCommandRouter.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("CommandGroup(replacing: .undoRedo)"))
        XCTAssertTrue(
            source.contains(
                "@FocusedObject private var focusedWorkspace: MultiDocumentWorkspaceState?"
            ),
            "Detached windows must observe their focused workspace so menu state stays live."
        )
        XCTAssertEqual(
            source.components(separatedBy: ".focusedSceneObject(workspace)").count - 1,
            2,
            "Both the main and detached PDF windows must publish their focused workspace."
        )
        XCTAssertTrue(source.contains("editCommandRouter.performUndo"))
        XCTAssertTrue(source.contains("fallback: fileCommandWorkspace?.activeWorkspace"))
        XCTAssertFalse(source.contains("focusedWorkspace ?? fallbackWorkspace"))
        XCTAssertTrue(source.contains("documentWorkspace?.undo()"))
        XCTAssertTrue(source.contains("editCommandRouter.performRedo"))
        XCTAssertTrue(source.contains("documentWorkspace?.redo()"))
        XCTAssertTrue(
            source.contains("editCommandRouter.destination == .blockedBySheet")
        )
        let blockedStart = try XCTUnwrap(
            source.range(of: "if editCommandRouter.destination == .blockedBySheet")
        )
        let normalBranch = try XCTUnwrap(
            source.range(
                of: "} else {",
                range: blockedStart.upperBound..<source.endIndex
            )
        )
        let blockedBranch = source[blockedStart.lowerBound..<normalBranch.lowerBound]
        XCTAssertFalse(
            blockedBranch.contains("keyboardShortcut"),
            "A sheet-local Command-Z must not be consumed by a disabled menu key equivalent."
        )
        XCTAssertFalse(
            routerSource.contains("NSApp.mainWindow?.attachedSheet"),
            "A sheet in the main window must not block a detached key window."
        )
        XCTAssertTrue(source.contains("keyboardShortcut(\"z\", modifiers: .command)"))
        XCTAssertTrue(
            source.contains(
                "keyboardShortcut(\"z\", modifiers: [.command, .shift])"
            )
        )
    }

    func testModeCommandsTargetOnlyTheFocusedPDFWindowAndUseControlNumbers() throws {
        let source = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/App/VibePDFApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var modeCommandWorkspace"))
        XCTAssertTrue(source.contains("private var mutationCommandWorkspace"))
        XCTAssertTrue(source.contains("comparisonReadOnlyActive != true"))
        XCTAssertTrue(source.contains("focusedWorkspace?.activeWorkspace"))
        XCTAssertTrue(source.contains("modeCommandWorkspace?.setMode(.viewer)"))
        XCTAssertTrue(source.contains("modeCommandWorkspace?.setMode(.editing)"))
        XCTAssertTrue(source.contains("modeCommandWorkspace?.setMode(.study)"))
        XCTAssertTrue(source.contains("keyboardShortcut(\"1\", modifiers: .control)"))
        XCTAssertTrue(source.contains("keyboardShortcut(\"2\", modifiers: .control)"))
        XCTAssertTrue(source.contains("keyboardShortcut(\"3\", modifiers: .control)"))
        XCTAssertFalse(
            source.contains("keyboardShortcut(\"1\", modifiers: .command)"),
            "Command-number remains available for the conventional numbered-tab behavior."
        )
    }

    func testSelectedPageExportsTargetOnlyTheFocusedPDFWindow() throws {
        let source = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/App/VibePDFApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var exportCommandWorkspace"))
        XCTAssertTrue(source.contains("let activeWorkspace = exportCommandWorkspace,"))
        XCTAssertTrue(
            source.contains(
                "exportCommandWorkspace?.canExtractPages != true"
            )
        )
        XCTAssertFalse(
            source.contains(
                "guard let activeWorkspace = workspace.activeWorkspace else { return }\n                    if let url = WorkspaceFilePanels.chooseSavePDF"
            ),
            "Settings, About, or Help must not export a hidden fallback document."
        )
    }

    func testFileAndTabCommandsRequireTheKeyPDFWindowWhileCloseKeepsNativeTargets() throws {
        let source = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/App/VibePDFApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("AppFileCommandRouter.documentWorkspace(for: NSApp.keyWindow)"))
        XCTAssertTrue(source.contains("fileCommandWorkspace?.newTab()"))
        XCTAssertTrue(source.contains("fileCommandWorkspace.beginOpeningPDFsInTabs"))
        XCTAssertTrue(source.contains("fileCommandWorkspace?.selectAdjacentTab"))
        XCTAssertTrue(source.contains("window.performClose(nil)"))
        XCTAssertFalse(
            source.contains("focusedWorkspace ?? fallbackWorkspace"),
            "Settings, About, Help, and sheets must never fall back to the hidden main PDF model."
        )
    }

    func testComparisonPresentationGatesEveryMutatingMenuSurface() throws {
        let source = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/App/VibePDFApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("mutationCommandWorkspace?.applyCurrentModeHighlight()"))
        XCTAssertFalse(source.contains("mutationCommandWorkspace?.highlightCurrentSelection()"))
        XCTAssertTrue(
            source.contains("editCommandRouter.destination != .document"),
            "A sheet or active text editor must not let Shift-Command-H mutate the PDF behind it."
        )
        XCTAssertTrue(source.contains("guard let activeWorkspace = mutationCommandWorkspace"))
        XCTAssertTrue(source.contains("private var modeCommandWorkspace"))
        XCTAssertTrue(source.contains("guard comparisonReadOnlyActive != true else { return nil }"))
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

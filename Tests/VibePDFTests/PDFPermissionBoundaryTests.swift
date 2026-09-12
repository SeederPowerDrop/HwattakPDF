// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

@MainActor
final class PDFPermissionBoundaryTests: XCTestCase {
    func testRestrictedSelectionNeverReachesPluginOutputsOrConsent() throws {
        let workspace = try openFixture(protected: true, copyingAllowed: false)
        let document = try XCTUnwrap(workspace.document)
        XCTAssertEqual(document.permissionsStatus, .user)
        XCTAssertFalse(document.allowsCopying)
        workspace.currentSelection = try selection(in: document)

        for output in [PluginActionOutput.showText, .copyText, .openURL] {
            let action = textAction(output: output)
            try assertBlocked(action, in: workspace)
        }
    }

    func testCopyPermissionAndOwnerUnlockAllowAllSelectionOutputs() throws {
        for protection in [(false, false, false), (true, true, false), (true, false, true)] {
            let workspace = try openFixture(
                protected: protection.0,
                copyingAllowed: protection.1,
                ownerUnlock: protection.2
            )
            let document = try XCTUnwrap(workspace.document)
            if protection.0 {
                XCTAssertEqual(document.permissionsStatus, protection.2 ? .owner : .user)
            }
            XCTAssertTrue(workspace.allows(.copyAndPaste))
            workspace.currentSelection = try selection(in: document)

            for output in [PluginActionOutput.showText, .copyText, .openURL] {
                let action = textAction(output: output)
                let recorder = EffectRecorder()
                XCTAssertTrue(PluginCommandAvailability.isAvailable(action, workspace: workspace))
                _ = try PluginActionRunner(environment: recorder.environment).run(
                    plugin: try plugin(action), action: action, workspace: workspace
                )
                switch output {
                case .showText:
                    XCTAssertEqual(recorder.shown, ["CONFIDENTIAL"])
                    XCTAssertTrue(recorder.copied.isEmpty)
                    XCTAssertTrue(recorder.approved.isEmpty)
                case .copyText:
                    XCTAssertEqual(recorder.copied, ["CONFIDENTIAL"])
                    XCTAssertTrue(recorder.shown.isEmpty)
                    XCTAssertTrue(recorder.approved.isEmpty)
                case .openURL:
                    let url = try XCTUnwrap(URL(string: "https://public.example.com/?text=CONFIDENTIAL"))
                    XCTAssertEqual(recorder.approved, [url])
                    XCTAssertEqual(recorder.opened, [url])
                    XCTAssertTrue(recorder.copied.isEmpty)
                default: XCTFail("Unexpected test output")
                }
            }
        }
    }

    func testForeignSelectionIsRejectedBeforeAnyTextOutput() throws {
        let workspace = try openFixture()
        let foreign = try textDocument("OTHER DOCUMENT SECRET")
        // PDFKit itself throws an Objective-C exception when selections from
        // different documents are combined. Exercise the supported object
        // shape that the host must reject: a complete foreign selection.
        workspace.currentSelection = try selection(in: foreign)
        for output in [PluginActionOutput.showText, .copyText, .openURL] {
            try assertBlocked(textAction(output: output), in: workspace)
        }
    }

    func testCurrentPageTextHonorsCopyPermissionForTranslation() throws {
        let action = PluginActionManifest(
            id: "translate-page", title: "Translate page", description: nil,
            output: .translatePanel, template: "{{page.text}}"
        )
        let restricted = try openFixture(protected: true, copyingAllowed: false)
        XCTAssertNil(restricted.currentSelection)
        try assertBlocked(action, in: restricted)
        XCTAssertNil(restricted.pluginPanelRequest)

        for ownerUnlock in [false, true] {
            let workspace = try openFixture(
                protected: true, copyingAllowed: !ownerUnlock, ownerUnlock: ownerUnlock
            )
            let recorder = EffectRecorder()
            XCTAssertTrue(PluginCommandAvailability.isAvailable(action, workspace: workspace))
            let result = try PluginActionRunner(environment: recorder.environment).run(
                plugin: try plugin(action), action: action, workspace: workspace
            )
            guard case .openedPanel(let request) = result else {
                return XCTFail("Expected the host's translation review panel")
            }
            XCTAssertEqual(request.sourceText, "CONFIDENTIAL permission boundary fixture")
            XCTAssertTrue(request.includesCurrentPageText)
            XCTAssertTrue(recorder.allEffectsAreEmpty, "Reviewing text must not send it")
        }
    }

    func testMetadataAndStaticActionsRemainUsableWithoutCopyPermission() throws {
        let workspace = try openFixture(protected: true, copyingAllowed: false)
        for template in ["Static help", "{{document.name}}:{{page.number}}"] {
            let action = PluginActionManifest(
                id: "metadata", title: "Metadata", description: nil,
                output: .showText, template: template
            )
            let recorder = EffectRecorder()
            XCTAssertTrue(PluginCommandAvailability.isAvailable(action, workspace: workspace))
            _ = try PluginActionRunner(environment: recorder.environment).run(
                plugin: try plugin(action), action: action, workspace: workspace
            )
            XCTAssertEqual(recorder.shown.count, 1)
            XCTAssertFalse(try XCTUnwrap(recorder.shown.first).contains("CONFIDENTIAL"))
        }
    }

    func testRestrictedEraserDoesNotCommitDraftOrChangeHistoryAndStatus() throws {
        let workspace = try openFixture(protected: true, copyingAllowed: false)
        workspace.setMode(.editing)
        workspace.activeTool = .eraser
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = try XCTUnwrap(page.annotations.first)
        let revision = workspace.revision
        let status = workspace.statusMessage
        var commitCalls = 0
        workspace.installDeactivationCommitHandler(id: UUID()) { commitCalls += 1 }
        XCTAssertFalse(workspace.allows(.markup))

        XCTAssertFalse(workspace.allowsEraserRemoval(of: annotation))
        XCTAssertFalse(workspace.removeAnnotationWithEraser(annotation, from: page))
        XCTAssertEqual(commitCalls, 0)
        XCTAssertTrue(page.annotations.contains(where: { $0 === annotation }))
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertEqual(workspace.statusMessage, status)
    }

    func testEditableEraserDeletionCanUndoAndRedo() throws {
        for ownerUnlock in [false, true] {
            let workspace = try openFixture(protected: ownerUnlock, ownerUnlock: ownerUnlock)
            workspace.setMode(.editing)
            workspace.activeTool = .eraser
            let page = try XCTUnwrap(workspace.document?.page(at: 0))
            let original = page.annotations
            let annotation = try XCTUnwrap(original.first)
            XCTAssertTrue(workspace.allowsEraserRemoval(of: annotation))
            XCTAssertTrue(workspace.removeAnnotationWithEraser(annotation, from: page))
            XCTAssertFalse(page.annotations.contains(where: { $0 === annotation }))
            XCTAssertTrue(workspace.isDirty)
            XCTAssertTrue(workspace.canUndo)

            workspace.undo()
            XCTAssertEqual(page.annotations.map(ObjectIdentifier.init), original.map(ObjectIdentifier.init))
            XCTAssertFalse(workspace.isDirty)
            XCTAssertFalse(workspace.canUndo)
            XCTAssertTrue(workspace.canRedo)

            workspace.redo()
            XCTAssertFalse(page.annotations.contains(where: { $0 === annotation }))
            XCTAssertTrue(workspace.isDirty)
        }
    }

    private func assertBlocked(
        _ action: PluginActionManifest,
        in workspace: PDFWorkspaceState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let recorder = EffectRecorder()
        let status = workspace.statusMessage
        XCTAssertFalse(PluginCommandAvailability.isAvailable(action, workspace: workspace), file: file, line: line)
        XCTAssertThrowsError(try PluginActionRunner(environment: recorder.environment).run(
            plugin: try plugin(action), action: action, workspace: workspace
        ), file: file, line: line) { error in
            guard case PluginSystemError.actionUnavailable = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
        XCTAssertTrue(recorder.allEffectsAreEmpty, file: file, line: line)
        XCTAssertEqual(workspace.statusMessage, status, file: file, line: line)
    }

    private func textAction(output: PluginActionOutput) -> PluginActionManifest {
        PluginActionManifest(
            id: "selection", title: "Selection", description: nil, output: output,
            template: output == .openURL
                ? "https://public.example.com/?text={{selection.urlEncoded}}" : "{{selection}}"
        )
    }

    private func plugin(_ action: PluginActionManifest) throws -> InstalledPlugin {
        let manifest = PluginManifest(
            schemaVersion: action.output == .translatePanel ? 2 : 1,
            identifier: "org.example.permission-test", displayName: "Permission Test",
            version: "1.0.0", author: "Tests", description: "Synthetic permission fixture",
            minimumHostVersion: action.output == .translatePanel ? "0.8.0" : nil,
            capabilities: action.requiredCapabilities.sorted { $0.rawValue < $1.rawValue },
            actions: [action]
        )
        // XCTest's bundle can expose a non-semantic tool version. Keep this
        // fixture aligned with the schema-2 translation companion's host.
        _ = try PluginManifestValidator(hostVersion: "0.8.0")
            .decodeAndValidate(JSONEncoder().encode(manifest))
        return InstalledPlugin(
            manifest: manifest, installURL: URL(fileURLWithPath: "/tmp/permission-test.hwattakplugin"),
            manifestDigest: "test", installedAt: Date(), isEnabled: true
        )
    }

    private func openFixture(
        protected: Bool = false,
        copyingAllowed: Bool = false,
        ownerUnlock: Bool = false
    ) throws -> PDFWorkspaceState {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HwattakPDF-Permissions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fixture.pdf")
        let document = try textDocument("CONFIDENTIAL permission boundary fixture")
        let page = try XCTUnwrap(document.page(at: 0))
        for x in [40, 90] {
            page.addAnnotation(PDFAnnotation(
                bounds: CGRect(x: x, y: 40, width: 30, height: 30),
                forType: .square, withProperties: nil
            ))
        }
        if protected {
            XCTAssertTrue(document.write(to: url, withOptions: [
                .ownerPasswordOption: "OwnerPass9", .userPasswordOption: "ReaderPass9",
                .accessPermissionsOption: NSNumber(value: copyingAllowed
                    ? PDFAccessPermissions.allowsContentCopying.rawValue : 0),
                PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128
            ]))
        } else {
            XCTAssertTrue(document.write(to: url))
        }
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in
            ownerUnlock ? "OwnerPass9" : "ReaderPass9"
        })
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.viewer)
        return workspace
    }

    private func selection(in document: PDFDocument) throws -> PDFSelection {
        try XCTUnwrap(document.page(at: 0)?.selection(for: NSRange(location: 0, length: 12)))
    }

    private func textDocument(_ text: String) throws -> PDFDocument {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 700))
        view.font = .systemFont(ofSize: 17)
        view.string = text
        return try XCTUnwrap(PDFDocument(data: view.dataWithPDF(inside: view.bounds)))
    }

    @MainActor
    private final class EffectRecorder {
        var shown: [String] = []
        var copied: [String] = []
        var approved: [URL] = []
        var opened: [URL] = []
        var allEffectsAreEmpty: Bool {
            shown.isEmpty && copied.isEmpty && approved.isEmpty && opened.isEmpty
        }
        var environment: PluginRuntimeEnvironment {
            PluginRuntimeEnvironment(
                showText: { _, text in self.shown.append(text) },
                writeClipboard: { self.copied.append($0); return true },
                approveExternalURL: { _, url, _ in self.approved.append(url); return true },
                openExternalURL: { self.opened.append($0); return true }
            )
        }
    }
}

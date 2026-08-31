// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest

final class AIAssistantWindowPresentationTests: XCTestCase {
    func testAssistantVisibilityIsSceneScopedInsteadOfProcessWide() throws {
        let workspaceSource = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/Views/WorkspaceView.swift"),
            encoding: .utf8
        )
        let sidebarSource = try String(
            contentsOf: Self.projectRoot
                .appendingPathComponent("Sources/VibePDF/Views/AIAssistantSidebar.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            workspaceSource.contains("@SceneStorage(\"ai.assistantPanelVisible\")"),
            "Each PDF window must own an independent assistant presentation value."
        )
        XCTAssertFalse(
            workspaceSource.contains("@AppStorage(\"ai.assistantPanelVisible\")"),
            "Closing one window's panel must not remove another window's sidebar and cancel its request."
        )
        XCTAssertFalse(
            sidebarSource.contains(".onDisappear {\n            viewModel.cancelActiveRequest()"),
            "A generic sidebar disappearance must not interpret another scene's reconstruction as cancellation."
        )
        XCTAssertTrue(workspaceSource.contains("workspace.aiAssistantSession.cancelActiveRequest()"))
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

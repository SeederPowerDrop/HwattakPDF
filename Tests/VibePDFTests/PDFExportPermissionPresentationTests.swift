// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest

final class PDFExportPermissionPresentationTests: XCTestCase {
    func testEverySelectedPageExportSurfaceChecksDocumentPermissions() throws {
        let app = try source("Sources/VibePDF/App/VibePDFApp.swift")
        let workspace = try source("Sources/VibePDF/Views/WorkspaceView.swift")
        let toolbar = try source("Sources/VibePDF/Views/WorkspaceToolbar.swift")
        let sidebar = try source("Sources/VibePDF/Views/PageSidebarView.swift")

        XCTAssertTrue(app.contains("activeWorkspace.canExtractPages"))
        XCTAssertTrue(app.contains("activeWorkspace.canRasterizePages"))
        XCTAssertTrue(app.contains("exportCommandWorkspace?.canExtractPages != true"))
        XCTAssertTrue(app.contains("exportCommandWorkspace?.canRasterizePages != true"))
        XCTAssertTrue(
            workspace.contains(
                "guard workspace.canExtractPages, !workspace.selectedPages.isEmpty else { return }"
            )
        )
        XCTAssertTrue(
            toolbar.contains(
                ".disabled(workspace.selectedPages.isEmpty || !workspace.canExtractPages)"
            )
        )
        XCTAssertTrue(sidebar.contains(".disabled(!workspace.canExtractPages)"))
        XCTAssertGreaterThanOrEqual(
            sidebar.components(separatedBy: "guard workspace.canExtractPages else { return }").count - 1,
            2
        )
    }

    private func source(_ path: String) throws -> String {
        try String(
            contentsOf: Self.projectRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

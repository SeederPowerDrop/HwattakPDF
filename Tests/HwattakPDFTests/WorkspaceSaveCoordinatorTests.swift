// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class WorkspaceSaveCoordinatorTests: XCTestCase {
    @MainActor
    func testRequestSaveOnCleanDocumentDoesNotRewriteFile() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let originalBytes = try Data(contentsOf: fixture.sourceURL)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)

        XCTAssertTrue(WorkspaceSaveCoordinator.requestSave(workspace: workspace))

        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), originalBytes)
        XCTAssertEqual(workspace.statusMessage, L10n.string("status.no_changes_to_save"))
    }

    @MainActor
    func testOverwriteOriginalWritesEditsAndClearsDirtyState() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        let outcome = WorkspaceSaveCoordinator.apply(.overwriteOriginal, to: workspace)

        XCTAssertEqual(outcome, .saved)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.page(at: 0)?.rotation, 90)
    }

    @MainActor
    func testOverwriteOriginalWorksWithFileScopedWriteAccess() throws {
        let fixture = try makeFixture()
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.directory.path
            )
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        // A user-selected file can be writable even when App Sandbox does not
        // grant permission to create the atomic writer's sibling temp file.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.directory.path
        )

        let outcome = WorkspaceSaveCoordinator.apply(.overwriteOriginal, to: workspace)

        XCTAssertEqual(outcome, .saved)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertNil(workspace.presentedError)
        XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.page(at: 0)?.rotation, 90)
    }

    @MainActor
    func testFileScopedOverwriteRejectsMultiplyLinkedOriginalAndKeepsDirtyEdits() throws {
        let fixture = try makeFixture()
        let secondLink = fixture.directory.appendingPathComponent("second-name.pdf")
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: fixture.directory.path
            )
            try? FileManager.default.removeItem(at: fixture.directory)
        }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        try FileManager.default.linkItem(at: fixture.sourceURL, to: secondLink)
        let originalBytes = try Data(contentsOf: fixture.sourceURL)
        workspace.rotateSelectedPages(clockwise: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: fixture.directory.path
        )

        XCTAssertEqual(
            WorkspaceSaveCoordinator.apply(.overwriteOriginal, to: workspace),
            .cancelled
        )

        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: secondLink), originalBytes)
        XCTAssertEqual(
            workspace.presentedError,
            L10n.string("error.save_copy_same_as_original")
        )
    }

    @MainActor
    func testSaveCopyPreservesOriginalAndContinuesFromNewCopy() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let copyURL = fixture.directory.appendingPathComponent("edited-copy.pdf")
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        let outcome = WorkspaceSaveCoordinator.apply(
            .saveCopy,
            to: workspace,
            copyDestination: { copyURL }
        )

        XCTAssertEqual(outcome, .saved)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, copyURL)
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.page(at: 0)?.rotation, 0)
        XCTAssertEqual(PDFDocument(url: copyURL)?.page(at: 0)?.rotation, 90)
    }

    @MainActor
    func testSaveCopyRejectsOriginalDestinationWithoutWriting() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        let outcome = WorkspaceSaveCoordinator.apply(
            .saveCopy,
            to: workspace,
            copyDestination: { fixture.sourceURL }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.page(at: 0)?.rotation, 0)
    }

    @MainActor
    func testSaveCopyRejectsHardLinkToOriginalAtCoordinatorAndModelBoundaries() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let hardLinkURL = fixture.directory.appendingPathComponent("original-hard-link.pdf")
        try FileManager.default.linkItem(at: fixture.sourceURL, to: hardLinkURL)
        let originalBytes = try Data(contentsOf: fixture.sourceURL)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        XCTAssertTrue(
            PDFSourceFileVersion.refersToSameLocation(fixture.sourceURL, hardLinkURL),
            "Different paths to one device/inode must be treated as the same file."
        )
        XCTAssertEqual(
            WorkspaceSaveCoordinator.apply(
                .saveCopy,
                to: workspace,
                copyDestination: { hardLinkURL }
            ),
            .cancelled
        )
        XCTAssertFalse(
            workspace.saveSynchronously(as: hardLinkURL),
            "Direct model callers must not bypass the coordinator's same-file guard."
        )

        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: hardLinkURL), originalBytes)
        XCTAssertEqual(
            workspace.presentedError,
            L10n.string("error.save_copy_same_as_original")
        )
    }

    @MainActor
    func testSaveCopyRechecksDestinationIfItBecomesAnOriginalAliasBeforeCommit() throws {
        for aliasKind in ["hard-link", "symbolic-link"] {
            let fixture = try makeFixture()
            addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
            let destination = fixture.directory.appendingPathComponent("late-\(aliasKind).pdf")
            try Data(contentsOf: fixture.sourceURL).write(to: destination)
            let originalBytes = try Data(contentsOf: fixture.sourceURL)
            var directFallbackCount = 0
            var didInstallAlias = false
            let workspace = PDFWorkspaceState(
                pdfWriter: { document, url, validateDestination in
                    try AtomicPDFWriter.write(
                        document,
                        to: url,
                        validateDestinationBeforeCommit: {
                            if !didInstallAlias {
                                try FileManager.default.removeItem(at: url)
                                if aliasKind == "hard-link" {
                                    try FileManager.default.linkItem(
                                        at: fixture.sourceURL,
                                        to: url
                                    )
                                } else {
                                    try FileManager.default.createSymbolicLink(
                                        at: url,
                                        withDestinationURL: fixture.sourceURL
                                    )
                                }
                                didInstallAlias = true
                            }
                            try validateDestination()
                        },
                        onDirectWriteFallback: { directFallbackCount += 1 }
                    )
                }
            )
            XCTAssertTrue(workspace.open(url: fixture.sourceURL))
            workspace.setMode(.editing)
            workspace.rotateSelectedPages(clockwise: true)

            XCTAssertFalse(workspace.saveSynchronously(as: destination))

            XCTAssertTrue(didInstallAlias)
            XCTAssertEqual(directFallbackCount, 0)
            XCTAssertTrue(workspace.isDirty)
            XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
            XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), originalBytes)
            XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
            XCTAssertEqual(
                workspace.presentedError,
                L10n.string("error.save_copy_same_as_original")
            )
        }
    }

    @MainActor
    func testSaveCopyPreservesExternalDestinationChangesMadeBeforeCommit() throws {
        for startsExisting in [false, true] {
            let fixture = try makeFixture()
            addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
            let destination = fixture.directory.appendingPathComponent(
                startsExisting ? "approved-existing.pdf" : "approved-new.pdf"
            )
            if startsExisting {
                try Data("panel-approved old bytes".utf8).write(to: destination)
            }
            let externalBytes = Data(
                "external \(startsExisting ? "replacement" : "creation")".utf8
            )
            var directFallbackCount = 0
            var didInstallExternalBytes = false
            let workspace = PDFWorkspaceState(
                pdfWriter: { document, url, validateDestination in
                    try AtomicPDFWriter.write(
                        document,
                        to: url,
                        validateDestinationBeforeCommit: {
                            if !didInstallExternalBytes {
                                try externalBytes.write(to: url, options: [.atomic])
                                didInstallExternalBytes = true
                            }
                            try validateDestination()
                        },
                        onDirectWriteFallback: { directFallbackCount += 1 }
                    )
                }
            )
            XCTAssertTrue(workspace.open(url: fixture.sourceURL))
            workspace.setMode(.editing)
            workspace.rotateSelectedPages(clockwise: true)

            XCTAssertFalse(workspace.saveSynchronously(as: destination))

            XCTAssertTrue(didInstallExternalBytes)
            XCTAssertEqual(directFallbackCount, 0)
            XCTAssertTrue(workspace.isDirty)
            XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
            XCTAssertEqual(try Data(contentsOf: destination), externalBytes)
            XCTAssertEqual(
                workspace.presentedError,
                L10n.format("error.external_file_modified", destination.lastPathComponent)
            )
        }
    }

    @MainActor
    func testSaveCopyWriteFailureKeepsOriginalAssociationAndDirtyState() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let unavailableDestination = fixture.directory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("edited-copy.pdf")
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        let outcome = WorkspaceSaveCoordinator.apply(
            .saveCopy,
            to: workspace,
            copyDestination: { unavailableDestination }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.documentURL, fixture.sourceURL)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.page(at: 0)?.rotation, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailableDestination.path))
    }

    @MainActor
    func testCancelledCopyAndExplicitCancelKeepDirtyDocumentOpen() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        XCTAssertEqual(
            WorkspaceSaveCoordinator.apply(
                .saveCopy,
                to: workspace,
                copyDestination: { nil }
            ),
            .cancelled
        )
        XCTAssertEqual(WorkspaceSaveCoordinator.apply(.cancel, to: workspace), .cancelled)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNotNil(workspace.document)
        XCTAssertEqual(PDFDocument(url: fixture.sourceURL)?.page(at: 0)?.rotation, 0)
    }

    @MainActor
    func testDontSaveDefersDestructiveCloseToUnsavedGuard() throws {
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: fixture.sourceURL))
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)

        XCTAssertEqual(WorkspaceSaveCoordinator.apply(.dontSave, to: workspace), .discarded)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNotNil(workspace.document)
    }

    @MainActor
    func testLaterCancelKeepsEarlierDontSaveDocumentLiveAndDirty() throws {
        let firstFixture = try makeFixture()
        let secondFixture = try makeFixture()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: firstFixture.directory)
            try? FileManager.default.removeItem(at: secondFixture.directory)
        }
        let first = PDFWorkspaceState()
        let second = PDFWorkspaceState()
        XCTAssertTrue(first.open(url: firstFixture.sourceURL))
        XCTAssertTrue(second.open(url: secondFixture.sourceURL))
        first.setMode(.editing)
        second.setMode(.editing)
        first.rotateSelectedPages(clockwise: true)
        second.rotateSelectedPages(clockwise: true)

        let shouldClose = UnsavedChangesGuard.confirmAndClose(
            workspaces: [first, second],
            decisionProvider: { workspace in
                workspace === first ? .dontSave : .cancel
            }
        )

        XCTAssertFalse(shouldClose)
        XCTAssertTrue(first.isDirty)
        XCTAssertTrue(second.isDirty)
        XCTAssertNotNil(first.document)
        XCTAssertNotNil(second.document)
        XCTAssertEqual(PDFDocument(url: firstFixture.sourceURL)?.page(at: 0)?.rotation, 0)
        XCTAssertEqual(PDFDocument(url: secondFixture.sourceURL)?.page(at: 0)?.rotation, 0)
    }

    @MainActor
    func testAcceptedCloseChoicesResolveAllDocumentsOnlyAfterConfirmation() throws {
        let firstFixture = try makeFixture()
        let secondFixture = try makeFixture()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: firstFixture.directory)
            try? FileManager.default.removeItem(at: secondFixture.directory)
        }
        let first = PDFWorkspaceState()
        let second = PDFWorkspaceState()
        XCTAssertTrue(first.open(url: firstFixture.sourceURL))
        XCTAssertTrue(second.open(url: secondFixture.sourceURL))
        first.setMode(.editing)
        second.setMode(.editing)
        first.rotateSelectedPages(clockwise: true)
        second.rotateSelectedPages(clockwise: true)

        let shouldClose = UnsavedChangesGuard.confirmAndClose(
            workspaces: [first, second],
            decisionProvider: { workspace in
                workspace === first ? .overwriteOriginal : .dontSave
            }
        )

        XCTAssertTrue(shouldClose)
        XCTAssertNil(first.document)
        XCTAssertNil(second.document)
        XCTAssertEqual(PDFDocument(url: firstFixture.sourceURL)?.page(at: 0)?.rotation, 90)
        XCTAssertEqual(PDFDocument(url: secondFixture.sourceURL)?.page(at: 0)?.rotation, 0)
    }

    private func makeFixture() throws -> (directory: URL, sourceURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Save-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("original.pdf")
        let document = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(document.write(to: sourceURL))
        return (directory, sourceURL)
    }
}

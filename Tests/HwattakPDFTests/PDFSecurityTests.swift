// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFSecurityTests: XCTestCase {
    func testProtectedExporterRejectsWrongPasswordAndUnlocksWithCorrectPassword() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.pdf")
        let destinationURL = directory.appendingPathComponent("protected.pdf")
        let password = "Correct9"
        let document = try makeDocument([CGSize(width: 180, height: 240)])
        XCTAssertTrue(document.write(to: sourceURL))

        let exportedURL = try ProtectedPDFExporter.export(
            document: document,
            sourceURL: sourceURL,
            to: destinationURL,
            userPassword: password
        )

        XCTAssertEqual(exportedURL.standardizedFileURL, destinationURL.standardizedFileURL)

        let wrongAttempt = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertTrue(wrongAttempt.isEncrypted)
        XCTAssertTrue(wrongAttempt.isLocked)
        XCTAssertFalse(wrongAttempt.unlock(withPassword: "WrongPass9"))
        XCTAssertTrue(wrongAttempt.isLocked)

        let correctAttempt = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertTrue(correctAttempt.isLocked)
        XCTAssertTrue(correctAttempt.unlock(withPassword: password))
        XCTAssertFalse(correctAttempt.isLocked)
        XCTAssertEqual(correctAttempt.permissionsStatus, .owner)
        XCTAssertEqual(correctAttempt.pageCount, 1)
    }

    @MainActor
    func testWorkspaceRetriesRejectedPasswordAndReportsRejectionToProvider() throws {
        let directory = try makeTemporaryDirectory()
        let protectedURL = directory.appendingPathComponent("locked.pdf")
        let correctPassword = "Correct9"
        try writeProtectedFixture(
            try makeDocument([
                CGSize(width: 160, height: 220),
                CGSize(width: 190, height: 270)
            ]),
            to: protectedURL,
            userPassword: correctPassword
        )

        var prompts: [(url: URL, wasRejected: Bool)] = []
        let workspace = PDFWorkspaceState(
            passwordProvider: { url, wasRejected in
                prompts.append((url, wasRejected))
                return wasRejected ? correctPassword : "WrongPass9"
            }
        )

        XCTAssertTrue(workspace.open(url: protectedURL))
        XCTAssertEqual(prompts.map { $0.wasRejected }, [false, true])
        XCTAssertEqual(
            prompts.map { $0.url.standardizedFileURL },
            [protectedURL.standardizedFileURL, protectedURL.standardizedFileURL]
        )
        XCTAssertEqual(workspace.documentURL?.standardizedFileURL, protectedURL.standardizedFileURL)
        XCTAssertEqual(workspace.document?.pageCount, 2)
        XCTAssertFalse(workspace.document?.isLocked ?? true)
        XCTAssertNil(workspace.presentedError)
    }

    @MainActor
    func testCancellingPasswordRetryDoesNotInstallDocumentOrExposeSecrets() throws {
        let directory = try makeTemporaryDirectory()
        let protectedURL = directory.appendingPathComponent("cancelled.pdf")
        let actualPassword = "ActualPass9"
        let rejectedSecret = "DoNotLeak9"
        try writeProtectedFixture(
            try makeDocument([CGSize(width: 170, height: 230)]),
            to: protectedURL,
            userPassword: actualPassword
        )

        var rejectionStates: [Bool] = []
        let workspace = PDFWorkspaceState(
            passwordProvider: { _, wasRejected in
                rejectionStates.append(wasRejected)
                return wasRejected ? nil : rejectedSecret
            }
        )

        XCTAssertFalse(workspace.open(url: protectedURL))
        XCTAssertEqual(rejectionStates, [false, true])
        XCTAssertNil(workspace.document)
        XCTAssertNil(workspace.documentURL)
        XCTAssertFalse(workspace.hasOpenDocument)

        let presentedError = workspace.presentedError ?? ""
        XCTAssertFalse(presentedError.contains(rejectedSecret))
        XCTAssertFalse(presentedError.contains(actualPassword))
        XCTAssertFalse(String(describing: workspace).contains(rejectedSecret))
        XCTAssertFalse(String(describing: workspace).contains(actualPassword))
    }

    @MainActor
    func testProtectedWorkspaceCopyPreservesPDFAndLeavesSourceStateUnchanged() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("workspace-source.pdf")
        let destinationURL = directory.appendingPathComponent("workspace-protected.pdf")
        let password = "Protect9"
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 210, height: 290)
        ])
        source.page(at: 1)?.rotation = 90
        let note = PDFAnnotation(
            bounds: CGRect(x: 18, y: 24, width: 110, height: 34),
            forType: .freeText,
            withProperties: nil
        )
        note.contents = "preserve this annotation"
        source.page(at: 0)?.addAnnotation(note)
        XCTAssertTrue(source.write(to: sourceURL))
        let originalBytes = try Data(contentsOf: sourceURL)

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: sourceURL))
        workspace.selectedPages = [1]
        workspace.setCurrentPage(1)
        let sourceDocument = try XCTUnwrap(workspace.document)
        let initialURL = workspace.documentURL
        let initialRevision = workspace.revision
        let initialSelection = workspace.selectedPages
        let initialPageIndex = workspace.currentPageIndex
        let initialDirtyState = workspace.isDirty

        XCTAssertTrue(
            workspace.exportProtectedCopy(
                to: destinationURL,
                userPassword: password
            )
        )

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertTrue(workspace.document === sourceDocument)
        XCTAssertEqual(workspace.documentURL, initialURL)
        XCTAssertEqual(workspace.revision, initialRevision)
        XCTAssertEqual(workspace.selectedPages, initialSelection)
        XCTAssertEqual(workspace.currentPageIndex, initialPageIndex)
        XCTAssertEqual(workspace.isDirty, initialDirtyState)
        XCTAssertNil(workspace.presentedError)

        let wrongAttempt = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertTrue(wrongAttempt.isEncrypted)
        XCTAssertTrue(wrongAttempt.isLocked)
        XCTAssertFalse(wrongAttempt.unlock(withPassword: "WrongPass9"))

        let protectedCopy = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertTrue(protectedCopy.unlock(withPassword: password))
        XCTAssertEqual(protectedCopy.permissionsStatus, .owner)
        XCTAssertEqual(protectedCopy.pageCount, sourceDocument.pageCount)
        for pageIndex in 0..<sourceDocument.pageCount {
            assertPageGeometry(
                protectedCopy.page(at: pageIndex),
                matches: sourceDocument.page(at: pageIndex)
            )
        }
        XCTAssertEqual(protectedCopy.page(at: 1)?.rotation, 90)
        let copiedNote = protectedCopy.page(at: 0)?.annotations.first
        XCTAssertEqual(copiedNote?.contents, "preserve this annotation")
    }

    func testProtectedCopyPasswordKeepsOwnerAuthorityForLaterReencryption() throws {
        let directory = try makeTemporaryDirectory()
        let firstURL = directory.appendingPathComponent("first-protected.pdf")
        let secondURL = directory.appendingPathComponent("second-protected.pdf")
        let original = try makeDocument([CGSize(width: 180, height: 240)])

        try ProtectedPDFExporter.export(
            document: original,
            sourceURL: nil,
            to: firstURL,
            userPassword: "FirstPass9"
        )
        let reopened = try XCTUnwrap(PDFDocument(url: firstURL))
        XCTAssertTrue(reopened.unlock(withPassword: "FirstPass9"))
        XCTAssertEqual(reopened.permissionsStatus, .owner)

        XCTAssertNoThrow(
            try ProtectedPDFExporter.export(
                document: reopened,
                sourceURL: firstURL,
                to: secondURL,
                userPassword: "SecondPass9"
            )
        )
        let second = try XCTUnwrap(PDFDocument(url: secondURL))
        XCTAssertFalse(second.unlock(withPassword: "FirstPass9"))
        XCTAssertTrue(second.unlock(withPassword: "SecondPass9"))
        XCTAssertEqual(second.permissionsStatus, .owner)
    }

    func testOwnerUnlockedOCRSnapshotNeedsNoRetainedPasswordAndIsUserOnly() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("ocr-source.pdf")
        let snapshotURL = directory.appendingPathComponent("ocr-snapshot.pdf")
        let password = "OwnerPass9"
        try writeProtectedFixture(
            try makeDocument([CGSize(width: 180, height: 240)]),
            to: sourceURL,
            userPassword: password,
            ownerPassword: password
        )

        let unlocked = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(unlocked.unlock(withPassword: password))
        XCTAssertEqual(unlocked.permissionsStatus, .owner)
        try PDFOCRSnapshotWriter.write(unlocked, to: snapshotURL)

        let snapshot = try XCTUnwrap(PDFDocument(url: snapshotURL))
        XCTAssertFalse(snapshot.isLocked)
        XCTAssertEqual(snapshot.pageCount, unlocked.pageCount)
        let attributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPasswordPolicyAcceptsOnlyASCIIPasswordsFromEightThroughThirtyTwoBytes() {
        XCTAssertNoThrow(try PDFPasswordPolicy.validate(String(repeating: "a", count: 8)))
        XCTAssertNoThrow(try PDFPasswordPolicy.validate(String(repeating: "Z", count: 32)))

        XCTAssertThrowsError(
            try PDFPasswordPolicy.validate(String(repeating: "a", count: 7))
        )
        XCTAssertThrowsError(
            try PDFPasswordPolicy.validate(String(repeating: "a", count: 33))
        )
        XCTAssertThrowsError(try PDFPasswordPolicy.validate("암호Password9"))
    }

    func testProtectedExporterRejectsSourcePathAndHardLinkWithoutChangingOriginal() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("original.pdf")
        let hardLinkURL = directory.appendingPathComponent("original-hard-link.pdf")
        let document = try makeDocument([
            CGSize(width: 150, height: 210),
            CGSize(width: 180, height: 250)
        ])
        XCTAssertTrue(document.write(to: sourceURL))
        let originalBytes = try Data(contentsOf: sourceURL)

        XCTAssertThrowsError(
            try ProtectedPDFExporter.export(
                document: document,
                sourceURL: sourceURL,
                to: sourceURL,
                userPassword: "Protect9"
            )
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)

        try FileManager.default.linkItem(at: sourceURL, to: hardLinkURL)
        XCTAssertThrowsError(
            try ProtectedPDFExporter.export(
                document: document,
                sourceURL: sourceURL,
                to: hardLinkURL,
                userPassword: "Protect9"
            )
        )
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: hardLinkURL), originalBytes)
    }

    @MainActor
    func testUserPasswordCannotReencryptAtExporterOrWorkspaceBoundaries() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("user-authority.pdf")
        let directDestination = directory.appendingPathComponent("direct-bypass.pdf")
        let modelDestination = directory.appendingPathComponent("model-bypass.pdf")
        let userPassword = "ReaderPass9"
        try writeProtectedFixture(
            try makeDocument([CGSize(width: 180, height: 240)]),
            to: sourceURL,
            userPassword: userPassword
        )

        let userDocument = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(userDocument.unlock(withPassword: userPassword))
        XCTAssertEqual(userDocument.permissionsStatus, .user)
        XCTAssertThrowsError(
            try ProtectedPDFExporter.export(
                document: userDocument,
                sourceURL: sourceURL,
                to: directDestination,
                userPassword: "Replacement9"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directDestination.path))

        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in userPassword })
        XCTAssertTrue(workspace.open(url: sourceURL))
        XCTAssertFalse(workspace.canRequestProtectedPDFExport)
        workspace.requestProtectedPDFExport(to: modelDestination)
        XCTAssertNil(workspace.pendingProtectedExport)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertFalse(
            workspace.exportProtectedCopy(
                to: modelDestination,
                userPassword: "Replacement9"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDestination.path))
    }

    @MainActor
    func testProtectedExportPresentationCannotBeRedirectedToAnotherDocument() throws {
        let directory = try makeTemporaryDirectory()
        let firstURL = directory.appendingPathComponent("first.pdf")
        let secondURL = directory.appendingPathComponent("second.pdf")
        let destinationURL = directory.appendingPathComponent("protected.pdf")
        XCTAssertTrue(
            try makeDocument([CGSize(width: 160, height: 220)]).write(to: firstURL)
        )
        XCTAssertTrue(
            try makeDocument([CGSize(width: 210, height: 290)]).write(to: secondURL)
        )

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: firstURL))
        workspace.requestProtectedPDFExport(to: destinationURL)
        let presentation = try XCTUnwrap(workspace.pendingProtectedExport)
        XCTAssertEqual(presentation.destinationURL, destinationURL)
        XCTAssertFalse(workspace.canRequestProtectedPDFExport)

        XCTAssertTrue(workspace.open(url: secondURL))
        XCTAssertNil(workspace.pendingProtectedExport)
        XCTAssertFalse(
            workspace.exportProtectedCopy(
                presentation: presentation,
                userPassword: "Protect9"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertNotNil(workspace.presentedError)
    }

    @MainActor
    func testOrdinarySaveAndSaveCopyFailClosedForEncryptedDocuments() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("owner-opened.pdf")
        let copyURL = directory.appendingPathComponent("ordinary-copy.pdf")
        let password = "OwnerPass9"
        try writeProtectedFixture(
            try makeDocument([CGSize(width: 180, height: 240)]),
            to: sourceURL,
            userPassword: password,
            ownerPassword: password
        )
        let originalBytes = try Data(contentsOf: sourceURL)
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in password })
        XCTAssertTrue(workspace.open(url: sourceURL))
        XCTAssertEqual(workspace.document?.permissionsStatus, .owner)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.isDirty)

        XCTAssertFalse(workspace.saveSynchronously())
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNotNil(workspace.presentedError)

        workspace.clearError()
        XCTAssertFalse(workspace.saveSynchronously(as: copyURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copyURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNotNil(workspace.presentedError)
    }

    @MainActor
    func testProtectedExportRefusesAStillPendingInlineDraftWithoutWriting() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("inline-source.pdf")
        let destinationURL = directory.appendingPathComponent("must-not-exist.pdf")
        let source = try makeDocument([
            CGSize(width: 180, height: 240),
            CGSize(width: 180, height: 240)
        ])
        XCTAssertTrue(source.write(to: sourceURL))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: sourceURL))
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 1,
                point: CGPoint(x: 40, y: 180),
                annotation: nil
            )
        )
        XCTAssertNotNil(workspace.pendingInlineTextEdit)
        let handlerID = UUID()
        workspace.installDeactivationCommitHandler(id: handlerID) {
            // Simulate a stale integration callback invalidating the target
            // page before the synchronized draft can be committed.
            workspace.document?.removePage(at: 1)
        }

        XCTAssertFalse(
            workspace.exportProtectedCopy(
                to: destinationURL,
                userPassword: "Protect9"
            )
        )
        workspace.removeDeactivationCommitHandler(id: handlerID)
        XCTAssertNotNil(workspace.pendingInlineTextEdit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(
            workspace.presentedError,
            L10n.string("error.finish_inline_text_before_export")
        )
    }

    @MainActor
    func testFormFieldEntryPermissionDoesNotAuthorizeNewAnnotations() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("form-only.pdf")
        let password = "FormPass9"
        try writeProtectedFixture(
            try makeDocument([CGSize(width: 180, height: 240)]),
            to: sourceURL,
            userPassword: password,
            accessPermissions: PDFAccessPermissions.allowsFormFieldEntry.rawValue
        )
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in password })
        XCTAssertTrue(workspace.open(url: sourceURL))
        XCTAssertTrue(workspace.document?.allowsFormFieldEntry == true)
        XCTAssertFalse(workspace.document?.allowsCommenting ?? true)

        workspace.setMode(.editing)
        XCTAssertFalse(workspace.allows(.comments))
        XCTAssertFalse(workspace.allows(.signature))
        XCTAssertFalse(workspace.allows(.handwriting))
        XCTAssertFalse(workspace.allows(.typedNotes))
        XCTAssertFalse(workspace.allows(.markup))

        workspace.setMode(.study)
        XCTAssertFalse(workspace.allows(.studyTools))
    }

    @MainActor
    func testEncryptedDocumentIsDetectedCanHibernateAndHonorsUserPermissions() throws {
        let directory = try makeTemporaryDirectory()
        let protectedURL = directory.appendingPathComponent("restricted.pdf")
        let password = "ReaderPass9"
        try writeProtectedFixture(
            try makeDocument([CGSize(width: 180, height: 240)]),
            to: protectedURL,
            userPassword: password,
            accessPermissions: 0
        )

        let descriptor = try CoreGraphicsPDFLazyDocumentInspector().inspect(protectedURL)
        XCTAssertTrue(descriptor.isEncrypted)

        let workspace = PDFWorkspaceState(
            passwordProvider: { _, _ in password }
        )
        XCTAssertTrue(workspace.open(url: protectedURL))
        XCTAssertTrue(workspace.canHibernate)

        workspace.setMode(.editing)
        XCTAssertTrue(workspace.allows(.reading))
        XCTAssertTrue(workspace.allows(.documentSearch))
        XCTAssertFalse(workspace.allows(.copyAndPaste))
        XCTAssertFalse(workspace.allows(.comments))
        XCTAssertFalse(workspace.allows(.inlineTextEditing))
        XCTAssertFalse(workspace.allows(.pageEditing))
        XCTAssertFalse(workspace.allows(.ocr))
    }

    @MainActor
    func testRestrictedUserPasswordBlocksSelectedPageAndPNGExportsAtBothBoundaries() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("restricted-derivatives.pdf")
        let combinedURL = directory.appendingPathComponent("combined.pdf")
        let password = "ReaderPass9"
        try writeProtectedFixture(
            try makeDocument([CGSize(width: 180, height: 240)]),
            to: sourceURL,
            userPassword: password,
            accessPermissions: 0
        )

        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in password })
        XCTAssertTrue(workspace.open(url: sourceURL))
        XCTAssertFalse(workspace.canExtractPages)
        XCTAssertFalse(workspace.canRasterizePages)
        workspace.exportSelectedPagesAsCombinedPDF(to: combinedURL)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: combinedURL.path))

        workspace.clearError()
        workspace.exportSelectedPagesAsIndividualPDFs(to: directory)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    SelectedPagePDFExporter.individualDirectoryName(for: sourceURL)
                ).path
            )
        )

        workspace.clearError()
        workspace.exportSelectedPagesAsImages(to: directory)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    SelectedPagePNGExporter.directoryName(for: sourceURL)
                ).path
            )
        )

        let direct = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(direct.unlock(withPassword: password))
        XCTAssertEqual(direct.permissionsStatus, .user)
        XCTAssertThrowsError(try PDFPageOperations.extract(from: direct, indexes: [0]))
        XCTAssertThrowsError(
            try SelectedPagePDFExporter.exportIndividually(
                from: direct,
                indexes: [0],
                to: directory,
                sourceURL: sourceURL
            )
        )
        XCTAssertThrowsError(
            try SelectedPagePNGExporter.export(
                from: direct,
                indexes: [0],
                to: directory,
                sourceURL: sourceURL,
                scale: 1
            )
        )
        let searchableURL = directory.appendingPathComponent("searchable.pdf")
        XCTAssertThrowsError(
            try SearchablePDFExporter.export(
                document: direct,
                checkpoint: OCRCheckpoint(
                    documentFingerprint: "restricted",
                    pageCount: 1,
                    configurationFingerprint: "settings"
                ),
                to: searchableURL,
                sourceURL: sourceURL
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: searchableURL.path))
    }

    func testUserPasswordDerivativePolicyDistinguishesRasterFromPageExtraction() throws {
        let directory = try makeTemporaryDirectory()
        let copyOnlyURL = directory.appendingPathComponent("copy-only.pdf")
        let fullExtractionURL = directory.appendingPathComponent("copy-and-assembly.pdf")
        let password = "ReaderPass9"
        let copying = PDFAccessPermissions.allowsContentCopying.rawValue
        let copyingAndAssembly = copying
            | PDFAccessPermissions.allowsDocumentAssembly.rawValue

        try writeProtectedFixture(
            try makeDocument([CGSize(width: 180, height: 240)]),
            to: copyOnlyURL,
            userPassword: password,
            accessPermissions: copying
        )
        let copyOnly = try XCTUnwrap(PDFDocument(url: copyOnlyURL))
        XCTAssertTrue(copyOnly.unlock(withPassword: password))
        XCTAssertTrue(copyOnly.allowsCopying)
        XCTAssertFalse(copyOnly.allowsDocumentAssembly)
        XCTAssertNoThrow(try PDFDocumentSecurityPolicy.validateCanRasterizePages(copyOnly))
        XCTAssertThrowsError(
            try PDFDocumentSecurityPolicy.validateCanExtractPages(copyOnly)
        )
        let png = try SelectedPagePNGExporter.export(
            from: copyOnly,
            indexes: [0],
            to: directory,
            sourceURL: copyOnlyURL,
            scale: 1
        )
        XCTAssertEqual(png.fileURLs.count, 1)
        XCTAssertThrowsError(try PDFPageOperations.extract(from: copyOnly, indexes: [0]))

        try writeProtectedFixture(
            try makeDocument([CGSize(width: 180, height: 240)]),
            to: fullExtractionURL,
            userPassword: password,
            accessPermissions: copyingAndAssembly
        )
        let extractable = try XCTUnwrap(PDFDocument(url: fullExtractionURL))
        XCTAssertTrue(extractable.unlock(withPassword: password))
        XCTAssertTrue(extractable.allowsCopying)
        XCTAssertTrue(extractable.allowsDocumentAssembly)
        XCTAssertNoThrow(try PDFDocumentSecurityPolicy.validateCanExtractPages(extractable))
        XCTAssertEqual(
            try PDFPageOperations.extract(from: extractable, indexes: [0]).pageCount,
            1
        )
    }

    @MainActor
    func testMergeRejectsRestrictedEncryptedInputBeforeAnyDestinationMutation() throws {
        let directory = try makeTemporaryDirectory()
        let destinationURL = directory.appendingPathComponent("destination.pdf")
        let allowedURL = directory.appendingPathComponent("allowed.pdf")
        let restrictedURL = directory.appendingPathComponent("restricted.pdf")
        let password = "ReaderPass9"
        XCTAssertTrue(
            try makeDocument([CGSize(width: 180, height: 240)]).write(to: destinationURL)
        )
        XCTAssertTrue(
            try makeDocument([CGSize(width: 190, height: 250)]).write(to: allowedURL)
        )
        try writeProtectedFixture(
            try makeDocument([CGSize(width: 200, height: 260)]),
            to: restrictedURL,
            userPassword: password,
            accessPermissions: 0
        )

        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in password })
        XCTAssertTrue(workspace.open(url: destinationURL))
        workspace.setMode(.editing)
        let initialRevision = workspace.revision
        workspace.merge(urls: [allowedURL, restrictedURL])
        XCTAssertEqual(workspace.document?.pageCount, 1)
        XCTAssertEqual(workspace.revision, initialRevision)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertNotNil(workspace.presentedError)

        let restricted = try XCTUnwrap(PDFDocument(url: restrictedURL))
        XCTAssertTrue(restricted.unlock(withPassword: password))
        let directDestination = try makeDocument([CGSize(width: 160, height: 220)])
        XCTAssertThrowsError(
            try PDFPageOperations.append(contentsOf: restricted, to: directDestination)
        )
        XCTAssertEqual(directDestination.pageCount, 1)
    }

    @MainActor
    func testUserPasswordSessionWithMutationBitsRemainsPersistablyReadOnly() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("user-mutation-rights.pdf")
        let password = "ReaderPass9"
        let source = try makeDocument([
            CGSize(width: 180, height: 240),
            CGSize(width: 190, height: 250)
        ])
        let sourcePage = try XCTUnwrap(source.page(at: 0))
        let widget = PDFAnnotation(
            bounds: CGRect(x: 20, y: 180, width: 120, height: 24),
            forType: .widget,
            withProperties: nil
        )
        widget.widgetFieldType = .text
        widget.fieldName = "student-name"
        widget.widgetStringValue = "before"
        sourcePage.addAnnotation(widget)
        let secondSourcePage = try XCTUnwrap(source.page(at: 1))
        let secondWidget = PDFAnnotation(
            bounds: CGRect(x: 20, y: 180, width: 120, height: 24),
            forType: .widget,
            withProperties: nil
        )
        secondWidget.widgetFieldType = .text
        secondWidget.fieldName = "unvisited-name"
        secondWidget.widgetStringValue = "before-unvisited"
        secondSourcePage.addAnnotation(secondWidget)
        let permissions = PDFAccessPermissions.allowsContentCopying.rawValue
            | PDFAccessPermissions.allowsDocumentAssembly.rawValue
            | PDFAccessPermissions.allowsDocumentChanges.rawValue
            | PDFAccessPermissions.allowsCommenting.rawValue
            | PDFAccessPermissions.allowsFormFieldEntry.rawValue
        try writeProtectedFixture(
            source,
            to: sourceURL,
            userPassword: password,
            accessPermissions: permissions
        )

        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in password })
        XCTAssertTrue(workspace.open(url: sourceURL))
        XCTAssertEqual(workspace.document?.permissionsStatus, .user)
        XCTAssertTrue(workspace.document?.allowsDocumentAssembly == true)
        XCTAssertTrue(workspace.document?.allowsDocumentChanges == true)
        XCTAssertTrue(workspace.document?.allowsCommenting == true)
        XCTAssertTrue(workspace.document?.allowsFormFieldEntry == true)
        XCTAssertFalse(workspace.allowsNativeFormEditing)
        XCTAssertTrue(workspace.canExtractPages)
        XCTAssertTrue(workspace.canRasterizePages)

        workspace.setMode(.editing)
        XCTAssertFalse(workspace.allows(.pageEditing))
        XCTAssertFalse(workspace.allows(.inlineTextEditing))
        XCTAssertFalse(workspace.allows(.imageInsertion))
        XCTAssertFalse(workspace.allows(.comments))
        XCTAssertFalse(workspace.allows(.signature))
        let originalRotation = workspace.document?.page(at: 0)?.rotation
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, originalRotation)

        let reopenedPage = try XCTUnwrap(workspace.document?.page(at: 0))
        let reopenedWidget = try XCTUnwrap(
            reopenedPage.annotations.first(where: { $0.fieldName == "student-name" })
        )
        reopenedWidget.widgetStringValue = "must not persist"
        workspace.synchronizeWidgetValues(on: reopenedPage)
        XCTAssertEqual(reopenedWidget.widgetStringValue, "before")
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertFalse(workspace.canSaveNormally)

        // Page 1 was never presented or primed. A direct/accessibility-style
        // mutation must not become its own trusted baseline; the workspace
        // discards that graph and reopens the unchanged encrypted source.
        let originalDocument = try XCTUnwrap(workspace.document)
        let unvisitedPage = try XCTUnwrap(originalDocument.page(at: 1))
        let unvisitedWidget = try XCTUnwrap(
            unvisitedPage.annotations.first(where: { $0.fieldName == "unvisited-name" })
        )
        unvisitedWidget.widgetStringValue = "must not become baseline"
        workspace.synchronizeWidgetValues(on: unvisitedPage)
        let recoveredDocument = try XCTUnwrap(workspace.document)
        XCTAssertFalse(recoveredDocument === originalDocument)
        let recoveredWidget = try XCTUnwrap(
            recoveredDocument.page(at: 1)?.annotations.first(where: {
                $0.fieldName == "unvisited-name"
            })
        )
        XCTAssertEqual(recoveredWidget.widgetStringValue, "before-unvisited")
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
    }

    @MainActor
    func testWorkspaceOCRExportRefusesItsSourcePathWithoutChangingBytes() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("ocr-source.pdf")
        XCTAssertTrue(
            try makeDocument([CGSize(width: 180, height: 240)]).write(to: sourceURL)
        )
        let originalBytes = try Data(contentsOf: sourceURL)
        let workspace = PDFWorkspaceState(
            ocrRecognizer: { _, fingerprint, configuration, _ in
                OCRCheckpoint(
                    documentFingerprint: fingerprint ?? "snapshot",
                    pageCount: 1,
                    configurationFingerprint: VisionOCRService.configurationFingerprint(
                        for: configuration
                    )
                )
            }
        )
        XCTAssertTrue(workspace.open(url: sourceURL))
        workspace.startOCR(configuration: OCRConfiguration())
        for _ in 0..<500 where workspace.ocrCheckpoint == nil {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertNotNil(workspace.ocrCheckpoint)

        workspace.exportSearchableOCRCopy(to: sourceURL)

        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertEqual(PDFDocument(url: sourceURL)?.pageCount, 1)
    }

    private func makeDocument(_ sizes: [CGSize]) throws -> PDFDocument {
        let document = PDFDocument()
        for size in sizes {
            document.insert(try makePage(size: size), at: document.pageCount)
        }
        return document
    }

    private func makePage(size: CGSize) throws -> PDFPage {
        let pixelsWide = max(1, Int(size.width.rounded()))
        let pixelsHigh = max(1, Int(size.height.rounded()))
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide,
                pixelsHigh: pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return try XCTUnwrap(PDFPage(image: image))
    }

    private func writeProtectedFixture(
        _ document: PDFDocument,
        to url: URL,
        userPassword: String,
        ownerPassword: String = "IndependentOwner9",
        accessPermissions: UInt? = nil
    ) throws {
        let encryptionKeyLength = PDFDocumentWriteOption(
            rawValue: kCGPDFContextEncryptionKeyLength as String
        )
        var options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: ownerPassword,
            .userPasswordOption: userPassword,
            encryptionKeyLength: 128
        ]
        if let accessPermissions {
            options[.accessPermissionsOption] = NSNumber(value: accessPermissions)
        }
        guard document.write(to: url, withOptions: options) else {
            throw PDFSecurityTestFixtureError.cannotWriteProtectedFixture
        }
    }

    private func assertPageGeometry(
        _ actual: PDFPage?,
        matches expected: PDFPage?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual, let expected else {
            XCTFail("Expected both PDF pages to exist", file: file, line: line)
            return
        }
        for box in [PDFDisplayBox.mediaBox, .cropBox] {
            let actualBounds = actual.bounds(for: box)
            let expectedBounds = expected.bounds(for: box)
            XCTAssertEqual(
                actualBounds.origin.x,
                expectedBounds.origin.x,
                accuracy: 0.01,
                file: file,
                line: line
            )
            XCTAssertEqual(
                actualBounds.origin.y,
                expectedBounds.origin.y,
                accuracy: 0.01,
                file: file,
                line: line
            )
            XCTAssertEqual(
                actualBounds.width,
                expectedBounds.width,
                accuracy: 0.01,
                file: file,
                line: line
            )
            XCTAssertEqual(
                actualBounds.height,
                expectedBounds.height,
                accuracy: 0.01,
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actual.rotation, expected.rotation, file: file, line: line)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PDFSecurityTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private enum PDFSecurityTestFixtureError: Error {
    case cannotWriteProtectedFixture
}

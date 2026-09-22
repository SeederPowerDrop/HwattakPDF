// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFPageOperationsTests: XCTestCase {
    func testPDFScrollProgressMapsBetweenDifferentDocumentAndViewportSizes() {
        let sourceDocument = CGRect(x: -20, y: 35, width: 1_200, height: 2_400)
        let sourceViewport = CGSize(width: 400, height: 600)
        let progress = PDFScrollProgress.progress(
            boundsOrigin: CGPoint(x: 180, y: 935),
            documentFrame: sourceDocument,
            viewportSize: sourceViewport
        )

        XCTAssertEqual(progress.horizontal, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(progress.vertical, 0.5, accuracy: 0.000_001)

        let targetOrigin = progress.boundsOrigin(
            documentFrame: CGRect(x: 10, y: -50, width: 2_100, height: 4_300),
            viewportSize: CGSize(width: 600, height: 700)
        )
        XCTAssertEqual(targetOrigin.x, 385, accuracy: 0.000_001)
        XCTAssertEqual(targetOrigin.y, 1_750, accuracy: 0.000_001)
    }

    func testPDFScrollProgressClampsOverscrollAndHandlesUnscrollableAxes() {
        let progress = PDFScrollProgress.progress(
            boundsOrigin: CGPoint(x: -400, y: 9_000),
            documentFrame: CGRect(x: 20, y: 30, width: 200, height: 800),
            viewportSize: CGSize(width: 300, height: 200)
        )

        XCTAssertEqual(progress.horizontal, 0)
        XCTAssertEqual(progress.vertical, 1)
        XCTAssertEqual(
            progress.boundsOrigin(
                documentFrame: CGRect(x: -15, y: 12, width: 100, height: 100),
                viewportSize: CGSize(width: 400, height: 500)
            ),
            CGPoint(x: -15, y: 12)
        )

        let invalid = PDFScrollProgress(horizontal: .infinity, vertical: .nan)
        XCTAssertEqual(invalid, PDFScrollProgress(horizontal: 0, vertical: 0))
    }

    func testExtractSortsIndexesAndDetachesPages() throws {
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240),
            CGSize(width: 200, height: 260)
        ])

        let extracted = try PDFPageOperations.extract(from: source, indexes: [2, 0])

        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertEqual(extracted.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 160, height: 220))
        XCTAssertEqual(extracted.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 200, height: 260))
        XCTAssertFalse(extracted.page(at: 0) === source.page(at: 0))
        XCTAssertFalse(extracted.page(at: 1) === source.page(at: 2))

        source.page(at: 0)?.rotation = 90
        XCTAssertEqual(extracted.page(at: 0)?.rotation, 0)
    }

    func testExtractRejectsAnOutOfRangeIndexWithoutChangingSource() throws {
        let source = try makeDocument([
            CGSize(width: 160, height: 220)
        ])

        XCTAssertThrowsError(try PDFPageOperations.extract(from: source, indexes: [1]))
        XCTAssertEqual(source.pageCount, 1)
        XCTAssertEqual(source.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 160, height: 220))
    }

    func testExtractedDocumentSurvivesPDFDataRoundTrip() throws {
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 190, height: 250)
        ])
        let extracted = try PDFPageOperations.extract(from: source, indexes: [1])

        let data = try XCTUnwrap(extracted.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertEqual(reopened.pageCount, 1)
        XCTAssertEqual(
            reopened.page(at: 0)?.bounds(for: .mediaBox).size,
            extracted.page(at: 0)?.bounds(for: .mediaBox).size
        )
    }

    func testNormalizedSelectionSortsDeduplicatesAndRejectsInvalidSelections() throws {
        XCTAssertEqual(
            try PDFPageOperations.normalizedSelection([4, 1, 4, 3], pageCount: 5),
            [1, 3, 4]
        )
        XCTAssertThrowsError(
            try PDFPageOperations.normalizedSelection([], pageCount: 5)
        )
        XCTAssertThrowsError(
            try PDFPageOperations.normalizedSelection([1, 5], pageCount: 5)
        )
        XCTAssertThrowsError(
            try PDFPageOperations.normalizedSelection([-1, 1], pageCount: 5)
        )
    }

    func testExtractIndividuallyPreservesSortedSourceIdentityAndPageProperties() throws {
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240),
            CGSize(width: 200, height: 260),
            CGSize(width: 220, height: 280)
        ])
        let annotatedPage = try XCTUnwrap(source.page(at: 3))
        annotatedPage.rotation = 90
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 24, y: 32, width: 96, height: 28),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "SELECTED PAGE NOTE"
        annotatedPage.addAnnotation(annotation)

        let extracted = try PDFPageOperations.extractIndividually(
            from: source,
            indexes: [3, 1, 3]
        )

        XCTAssertEqual(extracted.map(\.sourcePageIndex), [1, 3])
        XCTAssertTrue(extracted.allSatisfy { $0.document.pageCount == 1 })
        assertPageGeometry(
            extracted[0].document.page(at: 0),
            matches: source.page(at: 1)
        )
        assertPageGeometry(
            extracted[1].document.page(at: 0),
            matches: source.page(at: 3)
        )
        XCTAssertEqual(extracted[1].document.page(at: 0)?.rotation, 90)
        XCTAssertEqual(
            extracted[1].document.page(at: 0)?.annotations.map(\.contents),
            ["SELECTED PAGE NOTE"]
        )
        XCTAssertFalse(extracted[0].document.page(at: 0) === source.page(at: 1))
        XCTAssertFalse(extracted[1].document.page(at: 0) === source.page(at: 3))
    }

    func testIndividualExporterUsesStableNamesReopensPagesAndNeverOverwrites() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Lecture Notes.pdf")
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240),
            CGSize(width: 200, height: 260),
            CGSize(width: 220, height: 280)
        ])
        let annotatedPage = try XCTUnwrap(source.page(at: 3))
        annotatedPage.rotation = 270
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 30, y: 36, width: 100, height: 30),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "EXPORTED PAGE NOTE"
        annotatedPage.addAnnotation(annotation)

        XCTAssertEqual(
            SelectedPagePDFExporter.combinedFileName(for: sourceURL),
            "Lecture Notes-selected-pages.pdf"
        )
        XCTAssertEqual(
            SelectedPagePDFExporter.individualDirectoryName(for: sourceURL),
            "Lecture Notes-selected-pages"
        )
        XCTAssertEqual(
            SelectedPagePDFExporter.individualFileName(
                baseName: "Lecture Notes",
                sourcePageIndex: 3
            ),
            "Lecture Notes-page-0004.pdf"
        )

        let first = try SelectedPagePDFExporter.exportIndividually(
            from: source,
            indexes: [3, 1, 3],
            to: directory,
            sourceURL: sourceURL
        )

        XCTAssertEqual(first.directoryURL.lastPathComponent, "Lecture Notes-selected-pages")
        XCTAssertEqual(first.sourcePageIndices, [1, 3])
        XCTAssertEqual(first.fileURLs.map(\.lastPathComponent), [
            "Lecture Notes-page-0002.pdf",
            "Lecture Notes-page-0004.pdf"
        ])
        let reopenedSecondPage = try XCTUnwrap(PDFDocument(url: first.fileURLs[0]))
        let reopenedFourthPage = try XCTUnwrap(PDFDocument(url: first.fileURLs[1]))
        XCTAssertEqual(reopenedSecondPage.pageCount, 1)
        XCTAssertEqual(reopenedFourthPage.pageCount, 1)
        assertPageGeometry(reopenedSecondPage.page(at: 0), matches: source.page(at: 1))
        assertPageGeometry(reopenedFourthPage.page(at: 0), matches: source.page(at: 3))
        XCTAssertEqual(reopenedFourthPage.page(at: 0)?.rotation, 270)
        XCTAssertEqual(
            reopenedFourthPage.page(at: 0)?.annotations.map(\.contents),
            ["EXPORTED PAGE NOTE"]
        )

        let originalFileData = try Data(contentsOf: first.fileURLs[0])
        let sentinelURL = first.directoryURL.appendingPathComponent("keep.txt")
        try Data("do not replace".utf8).write(to: sentinelURL)

        let second = try SelectedPagePDFExporter.exportIndividually(
            from: source,
            indexes: [1],
            to: directory,
            sourceURL: sourceURL
        )

        XCTAssertEqual(second.directoryURL.lastPathComponent, "Lecture Notes-selected-pages-2")
        XCTAssertEqual(try Data(contentsOf: first.fileURLs[0]), originalFileData)
        XCTAssertEqual(try String(contentsOf: sentinelURL, encoding: .utf8), "do not replace")
        XCTAssertEqual(second.fileURLs.map(\.lastPathComponent), ["Lecture Notes-page-0002.pdf"])
    }

    func testIndividualExporterRejectsMixedInvalidSelectionWithoutCreatingOutput() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240)
        ])

        XCTAssertThrowsError(
            try SelectedPagePDFExporter.exportIndividually(
                from: source,
                indexes: [0, 99],
                to: directory,
                sourceURL: directory.appendingPathComponent("source.pdf")
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testPNGExporterUsesStagingAndUniqueDirectoryWithoutOverwriting() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("Lecture Notes.pdf")
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240)
        ])
        let reservedDirectory = directory.appendingPathComponent(
            SelectedPagePNGExporter.directoryName(for: sourceURL),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: reservedDirectory,
            withIntermediateDirectories: false
        )
        let sentinel = reservedDirectory.appendingPathComponent("keep.txt")
        try Data("do not overwrite".utf8).write(to: sentinel)

        let result = try SelectedPagePNGExporter.export(
            from: source,
            indexes: [1, 0, 1],
            to: directory,
            sourceURL: sourceURL,
            scale: 1
        )

        XCTAssertEqual(
            result.directoryURL.lastPathComponent,
            SelectedPagePNGExporter.directoryName(for: sourceURL) + "-2"
        )
        XCTAssertEqual(result.sourcePageIndices, [0, 1])
        XCTAssertEqual(result.fileURLs.map(\.lastPathComponent), [
            "Lecture Notes-page-0001.png",
            "Lecture Notes-page-0002.png"
        ])
        XCTAssertEqual(
            try String(contentsOf: sentinel, encoding: .utf8),
            "do not overwrite"
        )
        for url in result.fileURLs {
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
            XCTAssertGreaterThan(image.pixelsWide, 0)
            XCTAssertGreaterThan(image.pixelsHigh, 0)
        }
    }

    func testPNGExporterCleansStagingAndPublishesNothingAfterLaterFailure() throws {
        enum ExpectedFailure: Error { case laterPage }
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240)
        ])

        XCTAssertThrowsError(
            try SelectedPagePNGExporter.export(
                from: source,
                indexes: [0, 1],
                to: directory,
                sourceURL: directory.appendingPathComponent("source.pdf"),
                scale: 1,
                renderer: { _, index, _ in
                    if index == 1 { throw ExpectedFailure.laterPage }
                    return try self.onePixelPNGData()
                }
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ),
            []
        )
    }

    func testSelectedPageExportNamesAreVisibleBoundedAndFilesystemSafe() {
        let unsafeURL = URL(fileURLWithPath: "/tmp/.private\n:lecture.pdf")
        let safeBaseName = SelectedPagePDFExporter.documentBaseName(for: unsafeURL)

        XCTAssertEqual(safeBaseName, "privatelecture")
        XCTAssertFalse(SelectedPagePDFExporter.combinedFileName(for: unsafeURL).hasPrefix("."))
        XCTAssertFalse(
            SelectedPagePDFExporter.individualFileName(
                baseName: ".hidden/\n:chapter",
                sourcePageIndex: 8
            ).hasPrefix(".")
        )

        let veryLongName = String(repeating: "긴파일이름", count: 80)
        let longURL = URL(fileURLWithPath: "/tmp/\(veryLongName).pdf")
        let boundedBaseName = SelectedPagePDFExporter.documentBaseName(for: longURL)
        XCTAssertLessThanOrEqual(boundedBaseName.utf8.count, 120)
        XCTAssertLessThanOrEqual(
            SelectedPagePDFExporter.combinedFileName(for: longURL).utf8.count,
            255
        )
        XCTAssertLessThanOrEqual(
            SelectedPagePDFExporter.individualFileName(
                baseName: veryLongName,
                sourcePageIndex: 9_999
            ).utf8.count,
            255
        )
    }

    @MainActor
    func testWorkspaceSelectedPageExportsPreserveSourceStateAndDocumentOrder() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("workspace-source.pdf")
        let combinedURL = directory.appendingPathComponent("combined.pdf")
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240),
            CGSize(width: 200, height: 260)
        ])
        source.page(at: 2)?.rotation = 90
        try XCTUnwrap(source.dataRepresentation()).write(to: sourceURL)

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: sourceURL))
        workspace.selectedPages = [2, 0]
        workspace.setCurrentPage(2)
        let initialSelection = workspace.selectedPages
        let initialPageIndex = workspace.currentPageIndex
        let initialRevision = workspace.revision
        let initialDirtyState = workspace.isDirty

        workspace.exportSelectedPagesAsCombinedPDF(to: combinedURL)

        XCTAssertNil(workspace.presentedError)
        let combined = try XCTUnwrap(PDFDocument(url: combinedURL))
        XCTAssertEqual(combined.pageCount, 2)
        assertPageGeometry(combined.page(at: 0), matches: workspace.document?.page(at: 0))
        assertPageGeometry(combined.page(at: 1), matches: workspace.document?.page(at: 2))
        XCTAssertEqual(combined.page(at: 1)?.rotation, 90)

        workspace.exportSelectedPagesAsIndividualPDFs(to: directory)

        XCTAssertNil(workspace.presentedError)
        let individualDirectory = directory.appendingPathComponent(
            "workspace-source-selected-pages",
            isDirectory: true
        )
        let individualURLs = [
            individualDirectory.appendingPathComponent("workspace-source-page-0001.pdf"),
            individualDirectory.appendingPathComponent("workspace-source-page-0003.pdf")
        ]
        for url in individualURLs {
            let reopened = try XCTUnwrap(PDFDocument(url: url))
            XCTAssertEqual(reopened.pageCount, 1)
        }
        assertPageGeometry(
            PDFDocument(url: individualURLs[0])?.page(at: 0),
            matches: workspace.document?.page(at: 0)
        )
        assertPageGeometry(
            PDFDocument(url: individualURLs[1])?.page(at: 0),
            matches: workspace.document?.page(at: 2)
        )
        XCTAssertEqual(workspace.selectedPages, initialSelection)
        XCTAssertEqual(workspace.currentPageIndex, initialPageIndex)
        XCTAssertEqual(workspace.revision, initialRevision)
        XCTAssertEqual(workspace.isDirty, initialDirtyState)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testWorkspaceCombinedExportRefusesSourcePathWithoutChangingSourceOrState() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("same-path-source.pdf")
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240),
            CGSize(width: 200, height: 260)
        ])
        try XCTUnwrap(source.dataRepresentation()).write(to: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: sourceURL))
        workspace.selectedPages = [2, 0]
        workspace.setCurrentPage(2)
        let initialSelection = workspace.selectedPages
        let initialPageIndex = workspace.currentPageIndex
        let initialRevision = workspace.revision
        let initialDirtyState = workspace.isDirty

        workspace.exportSelectedPagesAsCombinedPDF(to: sourceURL)

        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertEqual(workspace.document?.pageCount, 3)
        XCTAssertEqual(workspace.selectedPages, initialSelection)
        XCTAssertEqual(workspace.currentPageIndex, initialPageIndex)
        XCTAssertEqual(workspace.revision, initialRevision)
        XCTAssertEqual(workspace.isDirty, initialDirtyState)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testWorkspaceCombinedExportRechecksACommitTimeHardLinkAlias() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("commit-source.pdf")
        let destinationURL = directory.appendingPathComponent("selected-pages.pdf")
        let source = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240)
        ])
        try XCTUnwrap(source.dataRepresentation()).write(to: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)

        let workspace = PDFWorkspaceState(
            pdfWriter: { _, destination, validateDestination in
                try FileManager.default.linkItem(at: sourceURL, to: destination)
                try validateDestination()
                return destination
            }
        )
        XCTAssertTrue(workspace.open(url: sourceURL))
        workspace.selectedPages = [1]

        workspace.exportSelectedPagesAsCombinedPDF(to: destinationURL)

        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: destinationURL), originalBytes)
        XCTAssertEqual(workspace.document?.pageCount, 2)
        XCTAssertFalse(workspace.isDirty)
    }

    func testAppendCopiesEveryPageInOrderAndLeavesSourceIntact() throws {
        let destination = try makeDocument([
            CGSize(width: 150, height: 210)
        ])
        let source = try makeDocument([
            CGSize(width: 170, height: 230),
            CGSize(width: 190, height: 250)
        ])

        let inserted = try PDFPageOperations.append(contentsOf: source, to: destination)

        XCTAssertEqual(inserted, 2)
        XCTAssertEqual(destination.pageCount, 3)
        XCTAssertEqual((0..<destination.pageCount).compactMap {
            destination.page(at: $0)?.bounds(for: .mediaBox).size
        }, [
            CGSize(width: 150, height: 210),
            CGSize(width: 170, height: 230),
            CGSize(width: 190, height: 250)
        ])
        XCTAssertEqual(source.pageCount, 2)
        XCTAssertFalse(destination.page(at: 1) === source.page(at: 0))

        destination.page(at: 1)?.rotation = 180
        XCTAssertEqual(source.page(at: 0)?.rotation, 0)
    }

    func testCheckpointStoreRoundTripsACompletedPage() throws {
        let directory = temporaryDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let store = OCRCheckpointStore(directory: directory)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var checkpoint = OCRCheckpoint(documentFingerprint: "document-sha256", pageCount: 3)
        checkpoint.updatedAt = timestamp
        checkpoint.pages[1] = OCRPageResult(
            pageIndex: 1,
            text: "테스트 OCR",
            observations: [
                OCRWordBox(
                    text: "테스트",
                    confidence: 0.97,
                    x: 0.1,
                    y: 0.2,
                    width: 0.3,
                    height: 0.04
                )
            ],
            completedAt: timestamp,
            skippedBecauseTextExists: false
        )

        try store.save(checkpoint)
        let loaded = try XCTUnwrap(store.load(fingerprint: "document-sha256", pageCount: 3))

        XCTAssertEqual(loaded, checkpoint)
        XCTAssertNil(store.load(fingerprint: "document-sha256", pageCount: 4))
    }

    func testCheckpointStoreMigratesSchema2MonolithToIncrementalLayout() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = OCRCheckpointStore(directory: directory)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_123)
        var legacy = OCRCheckpoint(
            documentFingerprint: "legacy-document",
            pageCount: 2,
            configurationFingerprint: "legacy-settings"
        )
        legacy.updatedAt = timestamp
        legacy.pages[0] = makeOCRResult(index: 0, timestamp: timestamp)

        let legacyURL = store.checkpointURL(
            fingerprint: legacy.documentFingerprint,
            configurationFingerprint: legacy.configurationFingerprint
        )
        try checkpointEncoder().encode(legacy).write(to: legacyURL, options: [.atomic])

        let migrated = try XCTUnwrap(
            store.load(
                fingerprint: legacy.documentFingerprint,
                pageCount: legacy.pageCount,
                configurationFingerprint: legacy.configurationFingerprint
            )
        )
        XCTAssertEqual(migrated, legacy)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.checkpointDirectoryURL(
                    fingerprint: legacy.documentFingerprint,
                    pageCount: legacy.pageCount,
                    configurationFingerprint: legacy.configurationFingerprint
                ).path
            )
        )

        // Prove subsequent resume no longer depends on the monolithic file.
        try FileManager.default.removeItem(at: legacyURL)
        XCTAssertEqual(
            store.load(
                fingerprint: legacy.documentFingerprint,
                pageCount: legacy.pageCount,
                configurationFingerprint: legacy.configurationFingerprint
            ),
            legacy
        )
    }

    func testCheckpointStoreMigratesSchema1WithoutConfigurationFingerprint() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = OCRCheckpointStore(directory: directory)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_456)
        let result = makeOCRResult(index: 1, timestamp: timestamp)
        let legacy = LegacyCheckpointV1Fixture(
            schemaVersion: 1,
            documentFingerprint: "schema-one-document",
            pageCount: 3,
            pages: [1: result],
            updatedAt: timestamp
        )
        let legacyURL = directory.appendingPathComponent("schema-one-document.json")
        try checkpointEncoder().encode(legacy).write(to: legacyURL, options: [.atomic])

        let migrated = try XCTUnwrap(
            store.load(
                fingerprint: legacy.documentFingerprint,
                pageCount: legacy.pageCount,
                configurationFingerprint: "current-settings"
            )
        )

        XCTAssertEqual(migrated.configurationFingerprint, "current-settings")
        XCTAssertEqual(migrated.pages, legacy.pages)
        XCTAssertEqual(migrated.updatedAt, timestamp)
        try FileManager.default.removeItem(at: legacyURL)
        XCTAssertEqual(
            store.load(
                fingerprint: legacy.documentFingerprint,
                pageCount: legacy.pageCount,
                configurationFingerprint: "current-settings"
            )?.pages,
            legacy.pages
        )
    }

    func testCheckpointStoreIncrementallyPersistsOneThousandPages() throws {
        let directory = temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = OCRCheckpointStore(directory: directory)
        let pageCount = 1_000
        let baseDate = Date(timeIntervalSince1970: 1_700_100_000)
        var checkpoint = OCRCheckpoint(
            documentFingerprint: "thousand-page-document",
            pageCount: pageCount,
            configurationFingerprint: "benchmark-settings"
        )

        let startedAt = Date()
        for index in 0..<pageCount {
            let result = makeOCRResult(
                index: index,
                timestamp: baseDate.addingTimeInterval(TimeInterval(index))
            )
            checkpoint.pages[index] = result
            checkpoint.updatedAt = result.completedAt
            try store.savePage(result, for: checkpoint)
        }
        let saveDuration = Date().timeIntervalSince(startedAt)

        let loadStartedAt = Date()
        let loaded = try XCTUnwrap(
            store.load(
                fingerprint: checkpoint.documentFingerprint,
                pageCount: pageCount,
                configurationFingerprint: checkpoint.configurationFingerprint
            )
        )
        let loadDuration = Date().timeIntervalSince(loadStartedAt)
        XCTAssertEqual(loaded, checkpoint)

        let checkpointDirectory = store.checkpointDirectoryURL(
            fingerprint: checkpoint.documentFingerprint,
            pageCount: pageCount,
            configurationFingerprint: checkpoint.configurationFingerprint
        )
        let pageFiles = recursiveFiles(in: checkpointDirectory).filter {
            $0.pathExtension == "json" && $0.lastPathComponent != "manifest.json"
        }
        let pageFileSizes = try pageFiles.map { url in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
        }
        let totalPageBytes = pageFileSizes.reduce(0, +)

        XCTAssertEqual(pageFiles.count, pageCount)
        XCTAssertLessThan(pageFileSizes.max() ?? .max, 2_048)
        XCTAssertLessThan(totalPageBytes, 2_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: store.checkpointURL(
                    fingerprint: checkpoint.documentFingerprint,
                    configurationFingerprint: checkpoint.configurationFingerprint
                ).path
            )
        )
        print(
            String(
                format: "OCR_CHECKPOINT_BENCHMARK pages=%d save=%.3fs load=%.3fs bytes=%d maxPageBytes=%d",
                pageCount,
                saveDuration,
                loadDuration,
                totalPageBytes,
                pageFileSizes.max() ?? 0
            )
        )

        // A corrupted final page file is ignored, so resume recomputes just it.
        let damagedIndex = 537
        let damagedURL = try XCTUnwrap(
            pageFiles.first { $0.lastPathComponent == String(format: "%08d.json", damagedIndex) }
        )
        try Data("{ interrupted write".utf8).write(to: damagedURL, options: [.atomic])
        let afterDamage = try XCTUnwrap(
            store.load(
                fingerprint: checkpoint.documentFingerprint,
                pageCount: pageCount,
                configurationFingerprint: checkpoint.configurationFingerprint
            )
        )
        XCTAssertEqual(afterDamage.pages.count, pageCount - 1)
        XCTAssertNil(afterDamage.pages[damagedIndex])

        let repaired = try XCTUnwrap(checkpoint.pages[damagedIndex])
        try store.savePage(repaired, for: checkpoint)
        XCTAssertEqual(
            store.load(
                fingerprint: checkpoint.documentFingerprint,
                pageCount: pageCount,
                configurationFingerprint: checkpoint.configurationFingerprint
            ),
            checkpoint
        )
    }

    func testCheckpointStoreFullSnapshotAtomicallyReplacesPriorGeneration() throws {
        let directory = temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = OCRCheckpointStore(directory: directory)
        let timestamp = Date(timeIntervalSince1970: 1_700_200_000)
        var first = OCRCheckpoint(
            documentFingerprint: "snapshot-document",
            pageCount: 3,
            configurationFingerprint: "snapshot-settings"
        )
        first.pages[0] = makeOCRResult(index: 0, timestamp: timestamp)
        first.pages[1] = makeOCRResult(index: 1, timestamp: timestamp.addingTimeInterval(1))
        first.updatedAt = timestamp.addingTimeInterval(1)
        try store.save(first)

        var replacement = OCRCheckpoint(
            documentFingerprint: first.documentFingerprint,
            pageCount: first.pageCount,
            configurationFingerprint: first.configurationFingerprint
        )
        replacement.pages[2] = makeOCRResult(index: 2, timestamp: timestamp.addingTimeInterval(2))
        replacement.updatedAt = timestamp.addingTimeInterval(2)
        try store.save(replacement)

        XCTAssertEqual(
            store.load(
                fingerprint: replacement.documentFingerprint,
                pageCount: replacement.pageCount,
                configurationFingerprint: replacement.configurationFingerprint
            ),
            replacement
        )
        let generations = recursiveFiles(
            in: store.checkpointDirectoryURL(
                fingerprint: replacement.documentFingerprint,
                pageCount: replacement.pageCount,
                configurationFingerprint: replacement.configurationFingerprint
            )
        ).filter { $0.lastPathComponent == "00000002.json" }
        XCTAssertEqual(generations.count, 1)
    }

    func testFingerprintIsDeterministicSHA256() {
        let data = Data("abc".utf8)

        let first = VisionOCRService.fingerprint(for: data)
        let second = VisionOCRService.fingerprint(for: data)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first,
            "ba7816bf8f01cfea414140de5dae2223" +
                "b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertNotEqual(first, VisionOCRService.fingerprint(for: Data("abd".utf8)))
    }

    func testOCRConfigurationFingerprintChangesWithMaterialSettings() {
        var first = OCRConfiguration()
        var second = first

        XCTAssertEqual(
            VisionOCRService.configurationFingerprint(for: first),
            VisionOCRService.configurationFingerprint(for: second)
        )

        second.renderDPI += 10
        XCTAssertNotEqual(
            VisionOCRService.configurationFingerprint(for: first),
            VisionOCRService.configurationFingerprint(for: second)
        )

        first.languages = ["ko-KR"]
        XCTAssertNotEqual(
            VisionOCRService.configurationFingerprint(for: first),
            VisionOCRService.configurationFingerprint(for: second)
        )
    }

    func testAtomicWriterOverwritesWithAValidatedPDF() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("atomic.pdf")

        try Data("not a pdf".utf8).write(to: destination)
        let document = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240)
        ])
        try AtomicPDFWriter.write(document, to: destination)

        let reopened = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(reopened.pageCount, 2)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .allSatisfy { !$0.lastPathComponent.hasSuffix(".tmp") }
        )
    }

    func testAtomicWriterCanOverwriteAFileWhenItsParentDirectoryIsNotWritable() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("file-scoped.pdf")
        let original = try makeDocument([CGSize(width: 120, height: 180)])
        XCTAssertTrue(original.write(to: destination))

        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path
        )

        // This models a sandbox extension for the selected PDF itself: the
        // destination remains writable, while a sibling staging file cannot
        // be created in its parent directory.
        let edited = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240)
        ])
        var directFallbackCount = 0
        try AtomicPDFWriter.write(
            edited,
            to: destination,
            onDirectWriteFallback: { directFallbackCount += 1 }
        )

        let reopened = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(reopened.pageCount, 2)
        XCTAssertEqual(directFallbackCount, 1)
    }

    func testAtomicWriterCanForbidDirectOverwriteAndPreserveExistingDestination() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("protected-existing.pdf")
        let original = try makeDocument([CGSize(width: 120, height: 180)])
        XCTAssertTrue(original.write(to: destination))
        let originalBytes = try Data(contentsOf: destination)

        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: directory.path
        )

        let edited = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240)
        ])
        var directFallbackCount = 0
        XCTAssertThrowsError(
            try AtomicPDFWriter.write(
                edited,
                to: destination,
                allowDirectOverwriteFallback: false,
                onDirectWriteFallback: { directFallbackCount += 1 }
            )
        )
        XCTAssertEqual(directFallbackCount, 0)
        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
    }

    func testDirectFallbackRejectsHardLinksAndSymbolicLinksWithoutWriting() throws {
        for aliasKind in ["hard-link", "symbolic-link"] {
            let directory = temporaryDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: directory.path
                )
                try? FileManager.default.removeItem(at: directory)
            }
            let target = directory.appendingPathComponent("target.pdf")
            let destination = directory.appendingPathComponent("selected-\(aliasKind).pdf")
            let original = try makeDocument([CGSize(width: 160, height: 220)])
            XCTAssertTrue(original.write(to: target))
            if aliasKind == "hard-link" {
                try FileManager.default.linkItem(at: target, to: destination)
            } else {
                try FileManager.default.createSymbolicLink(
                    at: destination,
                    withDestinationURL: target
                )
            }
            let originalBytes = try Data(contentsOf: target)
            let edited = try makeDocument([
                CGSize(width: 160, height: 220),
                CGSize(width: 180, height: 240)
            ])
            var directWriteCount = 0
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: directory.path
            )

            XCTAssertThrowsError(
                try AtomicPDFWriter.write(
                    edited,
                    to: destination,
                    onDirectWriteFallback: { directWriteCount += 1 }
                )
            ) { error in
                guard case .operationFailed = error as? WorkspaceError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }

            XCTAssertEqual(directWriteCount, 0)
            XCTAssertEqual(try Data(contentsOf: target), originalBytes)
            XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        }
    }

    func testAtomicWriterClassifiesOnlyPermissionErrorsForDirectFallback() {
        XCTAssertTrue(
            AtomicPDFWriter.isPermissionDeniedForFileScopeFallback(
                NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            )
        )
        XCTAssertTrue(
            AtomicPDFWriter.isPermissionDeniedForFileScopeFallback(
                CocoaError(.fileWriteNoPermission)
            )
        )
        XCTAssertFalse(
            AtomicPDFWriter.isPermissionDeniedForFileScopeFallback(
                NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            )
        )
        XCTAssertFalse(
            AtomicPDFWriter.isPermissionDeniedForFileScopeFallback(
                NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
            )
        )
    }

    func testAtomicWriterDoesNotFallbackAfterStagingValidationFailure() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("original.pdf")
        let original = try makeDocument([CGSize(width: 160, height: 220)])
        XCTAssertTrue(original.write(to: destination))
        let originalBytes = try Data(contentsOf: destination)
        let edited = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240)
        ])
        var directFallbackCount = 0

        XCTAssertThrowsError(
            try AtomicPDFWriter.write(
                edited,
                to: destination,
                validateStagedPDF: { _, _ in
                    throw WorkspaceError.operationFailed("injected invalid staging")
                },
                onDirectWriteFallback: { directFallbackCount += 1 }
            )
        )
        XCTAssertEqual(directFallbackCount, 0)
        XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
    }

    func testAtomicWriterDoesNotFallbackAfterDiskOrIOFailure() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("original.pdf")
        let original = try makeDocument([CGSize(width: 160, height: 220)])
        XCTAssertTrue(original.write(to: destination))
        let originalBytes = try Data(contentsOf: destination)
        let edited = try makeDocument([CGSize(width: 180, height: 240)])

        for code in [ENOSPC, EIO] {
            var directFallbackCount = 0
            XCTAssertThrowsError(
                try AtomicPDFWriter.write(
                    edited,
                    to: destination,
                    validateDestinationBeforeCommit: {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                    },
                    onDirectWriteFallback: { directFallbackCount += 1 }
                )
            ) { error in
                XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
                XCTAssertEqual((error as NSError).code, Int(code))
            }
            XCTAssertEqual(directFallbackCount, 0)
            XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
        }
    }

    func testAtomicWriterPreservesDestinationCreatedOrModifiedDuringSerialization() throws {
        for startsExisting in [false, true] {
            let directory = temporaryDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("approved-destination.pdf")
            if startsExisting {
                let approved = try makeDocument([CGSize(width: 160, height: 220)])
                XCTAssertTrue(approved.write(to: destination))
            }
            let edited = try makeDocument([CGSize(width: 180, height: 240)])
            let externalBytes = Data(
                "external destination \(startsExisting ? "modified" : "created")".utf8
            )
            var directFallbackCount = 0
            var didInstallExternalBytes = false

            XCTAssertThrowsError(
                try AtomicPDFWriter.write(
                    edited,
                    to: destination,
                    validateDestinationBeforeCommit: {
                        if !didInstallExternalBytes {
                            try externalBytes.write(to: destination, options: [.atomic])
                            didInstallExternalBytes = true
                        }
                    },
                    onDirectWriteFallback: { directFallbackCount += 1 }
                )
            ) { error in
                guard case .externalModification = error as? WorkspaceError else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertTrue(didInstallExternalBytes)
            XCTAssertEqual(directFallbackCount, 0)
            XCTAssertEqual(try Data(contentsOf: destination), externalBytes)
        }
    }

    func testSearchableExporterFlattensVisibleAnnotationAndKeepsPageCount() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("searchable.pdf")
        let document = try makeDocument([CGSize(width: 200, height: 300)])
        let page = try XCTUnwrap(document.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 120, height: 32),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "FLATTENED NOTE"
        annotation.fontColor = .black
        page.addAnnotation(annotation)

        var checkpoint = OCRCheckpoint(
            documentFingerprint: "fixture",
            pageCount: 1,
            configurationFingerprint: "settings"
        )
        checkpoint.pages[0] = OCRPageResult(
            pageIndex: 0,
            text: "OCR SEARCH TERM",
            observations: [
                OCRWordBox(
                    text: "OCR SEARCH TERM",
                    confidence: 1,
                    x: 0.1,
                    y: 0.75,
                    width: 0.45,
                    height: 0.06
                )
            ],
            completedAt: Date(),
            skippedBecauseTextExists: false
        )

        try SearchablePDFExporter.export(
            document: document,
            checkpoint: checkpoint,
            to: destination,
            sourceURL: nil
        )
        let reopened = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(reopened.pageCount, 1)
        XCTAssertTrue(reopened.page(at: 0)?.string?.contains("OCR SEARCH TERM") == true)
        XCTAssertEqual(reopened.page(at: 0)?.annotations.count, 0)
    }

    func testSearchableExporterRejectsSourceAliasesAndCommitTimeHardLink() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        let misleadingSourceURL = directory.appendingPathComponent("different-source.pdf")
        let symlinkURL = directory.appendingPathComponent("source-symlink.pdf")
        let hardLinkURL = directory.appendingPathComponent("source-hard-link.pdf")
        let raceURL = directory.appendingPathComponent("source-race.pdf")
        let document = try makeDocument([CGSize(width: 200, height: 300)])
        XCTAssertTrue(document.write(to: sourceURL))
        XCTAssertTrue(
            try makeDocument([CGSize(width: 120, height: 180)]).write(
                to: misleadingSourceURL
            )
        )
        let originalBytes = try Data(contentsOf: sourceURL)
        let checkpoint = OCRCheckpoint(
            documentFingerprint: "fixture",
            pageCount: 1,
            configurationFingerprint: "settings"
        )

        // The service must recover PDFKit's source URL when a direct caller
        // omits it, otherwise that caller could overwrite the open document.
        let diskDocument = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertThrowsError(
            try SearchablePDFExporter.export(
                document: diskDocument,
                checkpoint: checkpoint,
                to: sourceURL
            )
        )
        XCTAssertThrowsError(
            try SearchablePDFExporter.export(
                document: diskDocument,
                checkpoint: checkpoint,
                to: sourceURL,
                sourceURL: misleadingSourceURL
            )
        )

        XCTAssertThrowsError(
            try SearchablePDFExporter.export(
                document: document,
                checkpoint: checkpoint,
                to: sourceURL,
                sourceURL: sourceURL
            )
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: sourceURL
        )
        XCTAssertThrowsError(
            try SearchablePDFExporter.export(
                document: document,
                checkpoint: checkpoint,
                to: symlinkURL,
                sourceURL: sourceURL
            )
        )
        try FileManager.default.linkItem(at: sourceURL, to: hardLinkURL)
        XCTAssertThrowsError(
            try SearchablePDFExporter.export(
                document: document,
                checkpoint: checkpoint,
                to: hardLinkURL,
                sourceURL: sourceURL
            )
        )
        XCTAssertThrowsError(
            try SearchablePDFExporter.export(
                document: document,
                checkpoint: checkpoint,
                to: raceURL,
                sourceURL: sourceURL,
                beforeDestinationCommit: {
                    try FileManager.default.linkItem(at: sourceURL, to: raceURL)
                }
            )
        )

        XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: symlinkURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: hardLinkURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: raceURL), originalBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).contains {
                $0.hasSuffix(".ocr.tmp")
            }
        )
    }

    @MainActor
    func testViewerCoordinatorNavigatesWhenPageIdentityChangesAtSameIndex() throws {
        let document = try makeDocument([
            CGSize(width: 160, height: 220),
            CGSize(width: 180, height: 240)
        ])
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let replacementPage = try XCTUnwrap(document.page(at: 1))
        let workspace = PDFWorkspaceState()
        let coordinator = PDFKitViewer.Coordinator(state: workspace)
        coordinator.lastAppliedPageIndex = 0
        coordinator.lastAppliedPage = firstPage

        XCTAssertFalse(
            coordinator.requiresNavigation(
                to: firstPage,
                at: 0,
                visiblePage: firstPage
            )
        )
        XCTAssertTrue(
            coordinator.requiresNavigation(
                to: replacementPage,
                at: 0,
                visiblePage: firstPage
            )
        )
    }

    @MainActor
    func testPageMovesCommitExpectedPageIdentity() throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("move-source.pdf")
        try writeTextPDF(["FIRST", "SECOND", "THIRD"], to: sourceURL)

        let workspace = PDFWorkspaceState()
        workspace.open(url: sourceURL)
        workspace.setMode(.editing)
        let firstPage = try XCTUnwrap(workspace.document?.page(at: 0))
        let secondPage = try XCTUnwrap(workspace.document?.page(at: 1))
        let thirdPage = try XCTUnwrap(workspace.document?.page(at: 2))

        workspace.movePage(from: 0, before: 2)
        XCTAssertTrue(workspace.document?.page(at: 0) === secondPage)
        XCTAssertTrue(workspace.document?.page(at: 1) === firstPage)
        XCTAssertTrue(workspace.document?.page(at: 2) === thirdPage)

        workspace.movePageToEnd(from: 0)
        XCTAssertTrue(workspace.document?.page(at: 0) === firstPage)
        XCTAssertTrue(workspace.document?.page(at: 1) === thirdPage)
        XCTAssertTrue(workspace.document?.page(at: 2) === secondPage)
    }

    @MainActor
    func testStructuralMutationsInvalidateSelectionsAndAllowSafeResearch() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("search-source.pdf")
        let mergeURL = directory.appendingPathComponent("search-merge.pdf")
        try writeTextPDF(["needle first", "needle second", "unrelated"], to: sourceURL)
        try writeTextPDF(["needle merged"], to: mergeURL)

        let workspace = PDFWorkspaceState()
        workspace.open(url: sourceURL)
        workspace.setMode(.editing)

        func primeSearch() async {
            workspace.searchText = "needle"
            workspace.performSearch()
            await waitForSearchToFinish(workspace)
            XCTAssertFalse(workspace.searchResults.isEmpty)
            workspace.currentSelection = workspace.searchResults.first
            XCTAssertNotNil(workspace.activeSearchSelection)
            XCTAssertNotNil(workspace.currentSelection)
        }

        func assertInvalidated() {
            XCTAssertTrue(workspace.searchResults.isEmpty)
            XCTAssertEqual(workspace.searchResultIndex, 0)
            XCTAssertNil(workspace.activeSearchSelection)
            XCTAssertNil(workspace.currentSelection)
            XCTAssertEqual(workspace.searchText, "needle")
        }

        await primeSearch()
        workspace.movePage(from: 0, before: 2)
        assertInvalidated()

        await primeSearch()
        workspace.selectedPages = [0]
        workspace.rotateSelectedPages(clockwise: true)
        assertInvalidated()

        await primeSearch()
        workspace.selectedPages = [0]
        workspace.deleteSelectedPages()
        assertInvalidated()

        await primeSearch()
        workspace.merge(urls: [mergeURL])
        assertInvalidated()

        workspace.performSearch()
        await waitForSearchToFinish(workspace)
        XCTAssertFalse(workspace.searchResults.isEmpty)
        XCTAssertNotNil(workspace.activeSearchSelection)
    }

    @MainActor
    private func waitForSearchToFinish(
        _ workspace: PDFWorkspaceState,
        timeoutIterations: Int = 500
    ) async {
        for _ in 0..<timeoutIterations {
            if !workspace.isSearching { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Search did not finish before the test timeout")
    }

    private func makeDocument(
        _ sizes: [CGSize]
    ) throws -> PDFDocument {
        let document = PDFDocument()
        for size in sizes {
            document.insert(
                try makePage(size: size),
                at: document.pageCount
            )
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
        let actualBounds = actual.bounds(for: .mediaBox)
        let expectedBounds = expected.bounds(for: .mediaBox)
        XCTAssertEqual(actualBounds.origin.x, expectedBounds.origin.x, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actualBounds.origin.y, expectedBounds.origin.y, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actualBounds.width, expectedBounds.width, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actualBounds.height, expectedBounds.height, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(actual.rotation, expected.rotation, file: file, line: line)
    }

    private func writeTextPDF(_ pageTexts: [String], to url: URL) throws {
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: nil, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary

        for text in pageTexts {
            var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
            let pageInfo = [
                kCGPDFContextMediaBox as String: Data(
                    bytes: &mediaBox,
                    count: MemoryLayout<CGRect>.size
                )
            ] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            let attributed = try XCTUnwrap(
                CFAttributedStringCreate(nil, text as CFString, attributes)
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 24, y: 350)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDFTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func makeOCRResult(index: Int, timestamp: Date) -> OCRPageResult {
        OCRPageResult(
            pageIndex: index,
            text: "OCR PAGE \(String(format: "%04d", index))",
            observations: [
                OCRWordBox(
                    text: "PAGE \(index)",
                    confidence: 0.98,
                    x: 0.1,
                    y: 0.2,
                    width: 0.3,
                    height: 0.04
                )
            ],
            completedAt: timestamp,
            skippedBecauseTextExists: false
        )
    }

    private func onePixelPNGData() throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 1,
                pixelsHigh: 1,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func checkpointEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func recursiveFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private struct LegacyCheckpointV1Fixture: Codable {
        let schemaVersion: Int
        let documentFingerprint: String
        let pageCount: Int
        let pages: [Int: OCRPageResult]
        let updatedAt: Date
    }
}

// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

@MainActor
final class DocumentStabilizationTests: XCTestCase {
    private var output: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("work/stabilization/fixtures", isDirectory: true)
    }

    private func image(_ number: Int = 1) -> NSImage {
        NSImage(size: CGSize(width: 612, height: 792), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            NSColor.systemBlue.setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 24, dy: 24)).stroke()
            ("AUDIT PAGE \(number)" as NSString).draw(
                at: CGPoint(x: 60, y: 660),
                withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
            )
            return true
        }
    }

    private func sourceImage(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = output.appendingPathComponent(name)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image().tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func testImagePreviewMustNotReportDurableSaveInTemporaryDirectory() async throws {
        let original = try sourceImage("image-save.png")
        let originalBytes = try Data(contentsOf: original)
        let tabs = MultiDocumentWorkspaceState()
        _ = await tabs.beginOpeningViewableFilesInTabs(urls: [original]).value
        let workspace = try XCTUnwrap(tabs.activeWorkspace)
        let preview = try XCTUnwrap(workspace.documentURL)
        defer { try? FileManager.default.removeItem(at: preview.deletingLastPathComponent()) }
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        let outcome = WorkspaceSaveCoordinator.apply(.overwriteOriginal, to: workspace)
        print("AUDIT_IMAGE_SAVE outcome=\(outcome) dirty=\(workspace.isDirty) url=\(preview.path) originalUnchanged=\(try Data(contentsOf: original) == originalBytes)")
        XCTAssertEqual(outcome, .cancelled, "Temporary previews need a durable Save As destination before reporting saved.")
        XCTAssertTrue(workspace.isDirty, "Changes must remain unsaved until a durable destination is chosen.")
    }

    func testReopeningSameImageMustSelectExistingTab() async throws {
        let original = try sourceImage("duplicate.png")
        let tabs = MultiDocumentWorkspaceState()
        _ = await tabs.beginOpeningViewableFilesInTabs(urls: [original]).value
        let first = tabs.activeTabID
        _ = await tabs.beginOpeningViewableFilesInTabs(urls: [original]).value
        defer {
            for tab in tabs.allTabs {
                if let url = tab.workspace.documentURL {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
            }
        }
        print("AUDIT_IMAGE_DUPLICATE tabs=\(tabs.allTabs.count)")
        XCTAssertEqual(tabs.allTabs.count, 1)
        XCTAssertEqual(tabs.activeTabID, first)
    }

    func testBuilderMustDetectSourceChangedAfterPageSelection() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = output.appendingPathComponent("changing-source.pdf")
        let original = PDFDocument()
        original.insert(try XCTUnwrap(PDFPage(image: image())), at: 0)
        try AtomicPDFWriter.write(original, to: source)
        let builder = ImagePDFAssemblyModel()
        let selection = try builder.preparePDFSelection(source)
        builder.addPDFPages(from: selection, indexes: [0])
        original.page(at: 0)?.rotation = 90
        try AtomicPDFWriter.write(original, to: source)
        let destination = output.appendingPathComponent("changed-source-result.pdf")
        builder.startExport(to: destination, ocrConfiguration: nil)
        await builder.waitForExportCompletion()
        print("AUDIT_BUILDER_SOURCE selectedRotation=0 outputRotation=\(PDFDocument(url: destination)?.page(at: 0)?.rotation ?? -1) error=\(builder.presentedError ?? "nil")")
        XCTAssertNotNil(builder.presentedError, "The builder must reject or explicitly resolve an input changed after page selection.")
        XCTAssertNil(builder.lastSavedURL)
    }

    func testImageSaveAsPreservesSourceAndResumesDurablePDF() async throws {
        let original = try sourceImage("durable.png")
        let bytes = try Data(contentsOf: original)
        let tabs = MultiDocumentWorkspaceState()
        _ = await tabs.beginOpeningViewableFilesInTabs(urls: [original, original]).value
        XCTAssertEqual(tabs.allTabs.count, 1)
        let workspace = try XCTUnwrap(tabs.activeWorkspace)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertFalse(workspace.saveSynchronously(as: original))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let destination = output.appendingPathComponent("durable.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: destination))
        XCTAssertNil(workspace.imageSourceURL)
        XCTAssertFalse(workspace.requiresSaveDestination)
        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertTrue(workspace.resumeIfNeeded())
        XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 90)
        XCTAssertEqual(workspace.documentURL, destination)
    }

    func testCancelledImageOpenDoesNotInstallTabs() async throws {
        let original = try sourceImage("cancel.png")
        let tabs = MultiDocumentWorkspaceState()
        let task = tabs.beginOpeningViewableFilesInTabs(urls: [original])
        tabs.cancelPendingBatchOpen()
        let opened = await task.value
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(tabs.hasPendingBatchOpen)
        XCTAssertFalse(tabs.activeWorkspace?.hasOpenDocument ?? true)
    }

    func testImageLazyRestoreRegeneratesMissingBacking() throws {
        let original = try sourceImage("restore.png")
        let workspace = PDFWorkspaceState()
        workspace.restoreHibernated(url: original, pageCount: 1)
        workspace.associateImageSource(original)
        XCTAssertTrue(workspace.resumeIfNeeded())
        XCTAssertEqual(workspace.sessionDocumentURL, original)
        XCTAssertTrue(workspace.requiresSaveDestination)
        let preview = try XCTUnwrap(workspace.documentURL)
        XCTAssertTrue(workspace.hibernateIfPossible())
        ImagePDFConverter.removePreview(at: preview)
        XCTAssertTrue(workspace.resumeIfNeeded())
        XCTAssertNotEqual(workspace.documentURL, preview)
        XCTAssertEqual(workspace.pageCount, 1)
        workspace.close()
    }

    func testGenerateTwoPageOfficeCompatibilityFixtures() throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let document = PDFDocument()
        for number in 1...2 {
            document.insert(try XCTUnwrap(PDFPage(image: image(number))), at: document.pageCount)
        }
        try AtomicPDFWriter.write(document, to: output.appendingPathComponent("office-source-2-pages.pdf"))
        try PDFOfficeExporter.export(document, to: output.appendingPathComponent("office-2-pages.docx"), format: .word)
        try PDFOfficeExporter.export(document, to: output.appendingPathComponent("office-2-pages.pptx"), format: .powerpoint)
    }
}

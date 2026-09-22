// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class DocumentConversionTests: XCTestCase {
    func testMultipleImagesBecomeOrderedPDFPages() throws {
        let directory = try temporaryDirectory()
        let first = directory.appendingPathComponent("first.png")
        let second = directory.appendingPathComponent("second.jpg")
        try imageData(size: CGSize(width: 320, height: 180), color: .systemBlue, type: .png)
            .write(to: first)
        try imageData(size: CGSize(width: 180, height: 320), color: .systemOrange, type: .jpeg)
            .write(to: second)

        let destination = directory.appendingPathComponent("images.pdf")
        try ImagePDFConverter.export(imageURLs: [first, second], to: destination)

        let converted = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(converted.pageCount, 2)
        XCTAssertGreaterThan(converted.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 0)
        XCTAssertGreaterThan(converted.page(at: 1)?.bounds(for: .mediaBox).height ?? 0, 0)
    }

    func testImagePreviewKeepsRecognizableFilenameAndOpensAsPDF() throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("diagram.png")
        try imageData(size: CGSize(width: 240, height: 120), color: .systemGreen, type: .png)
            .write(to: source)

        let preview = try ImagePDFConverter.makePreviewPDF(from: source)

        XCTAssertEqual(preview.lastPathComponent, "diagram.png.pdf")
        XCTAssertEqual(ImagePDFConverter.previewDisplayName(for: preview), "diagram.png")
        XCTAssertEqual(PDFDocument(url: preview)?.pageCount, 1)
    }

    func testPDFExportsWordAndPowerPointOpenXMLPackages() throws {
        let directory = try temporaryDirectory()
        let document = PDFDocument()
        let image = NSImage(
            data: try imageData(
                size: CGSize(width: 612, height: 792),
                color: .white,
                type: .png
            )
        )
        document.insert(try XCTUnwrap(image.flatMap(PDFPage.init(image:))), at: 0)

        let wordURL = directory.appendingPathComponent("sample.docx")
        let powerpointURL = directory.appendingPathComponent("sample.pptx")
        try PDFOfficeExporter.export(document, to: wordURL, format: .word)
        try PDFOfficeExporter.export(document, to: powerpointURL, format: .powerpoint)

        try validateArchive(
            wordURL,
            requiredPaths: [
                "[Content_Types].xml",
                "word/document.xml",
                "word/_rels/document.xml.rels",
                "word/media/page-1.png",
            ]
        )
        try validateArchive(
            powerpointURL,
            requiredPaths: [
                "[Content_Types].xml",
                "ppt/presentation.xml",
                "ppt/slides/slide1.xml",
                "ppt/media/page-1.png",
            ]
        )

        let word = try Data(contentsOf: wordURL)
        let powerpoint = try Data(contentsOf: powerpointURL)
        XCTAssertTrue(word.starts(with: [0x50, 0x4B, 0x03, 0x04]))
        XCTAssertTrue(powerpoint.starts(with: [0x50, 0x4B, 0x03, 0x04]))
        XCTAssertNotNil(word.range(of: Data("word/document.xml".utf8)))
        XCTAssertNotNil(word.range(of: Data("word/media/page-1.png".utf8)))
        XCTAssertNotNil(powerpoint.range(of: Data("ppt/presentation.xml".utf8)))
        XCTAssertNotNil(powerpoint.range(of: Data("ppt/slides/slide1.xml".utf8)))
        XCTAssertNotNil(powerpoint.range(of: Data("ppt/media/page-1.png".utf8)))
    }

    func testOfficeSuggestedNamesUseExpectedExtensions() {
        let source = URL(fileURLWithPath: "/tmp/report.final.pdf")
        XCTAssertEqual(
            PDFOfficeExporter.suggestedFileName(for: source, format: .word),
            "report.final.docx"
        )
        XCTAssertEqual(
            PDFOfficeExporter.suggestedFileName(for: source, format: .powerpoint),
            "report.final.pptx"
        )
    }

    func testImageCanBeOpenedThroughDocumentTabFlow() async throws {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("photo.png")
        try imageData(size: CGSize(width: 200, height: 100), color: .purple, type: .png)
            .write(to: source)
        let workspace = MultiDocumentWorkspaceState()

        let opened = await workspace.beginOpeningViewableFilesInTabs(urls: [source]).value

        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(workspace.activeWorkspace?.pageCount, 1)
        XCTAssertEqual(workspace.activeWorkspace?.displayName, "photo.png")
    }

    func testBuilderCombinesImagesBlankPageAndSelectedPDFPagesInOrder() async throws {
        let directory = try temporaryDirectory()
        let imageURL = directory.appendingPathComponent("cover.png")
        try imageData(size: CGSize(width: 300, height: 200), color: .cyan, type: .png)
            .write(to: imageURL)

        let sourcePDFURL = directory.appendingPathComponent("source.pdf")
        let sourcePDF = PDFDocument()
        for size in [CGSize(width: 400, height: 500), CGSize(width: 500, height: 600)] {
            let data = try imageData(size: size, color: .white, type: .png)
            sourcePDF.insert(try XCTUnwrap(NSImage(data: data).flatMap(PDFPage.init(image:))), at: sourcePDF.pageCount)
        }
        try AtomicPDFWriter.write(sourcePDF, to: sourcePDFURL)

        let model = ImagePDFAssemblyModel()
        model.addImages([imageURL])
        let selection = try model.preparePDFSelection(sourcePDFURL)
        model.addPDFPages(from: selection, indexes: [1])
        model.addBlankPage()
        XCTAssertEqual(model.items.count, 3)
        XCTAssertTrue(model.items[1].title.contains("2"))

        model.move(model.items[2].id, by: -1)
        let destination = directory.appendingPathComponent("assembled.pdf")
        model.startExport(to: destination, ocrConfiguration: nil)
        await model.waitForExportCompletion()

        let result = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertNotNil(model.lastSavedURL)
        XCTAssertNil(model.presentedError)
        let blankBounds = try XCTUnwrap(result.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(blankBounds.width, 595.28, accuracy: 1)
        XCTAssertEqual(blankBounds.height, 841.89, accuracy: 1)
        let importedBounds = try XCTUnwrap(result.page(at: 2)).bounds(for: .mediaBox)
        XCTAssertEqual(importedBounds.width, 500, accuracy: 1)
        XCTAssertEqual(importedBounds.height, 600, accuracy: 1)
    }

    func testBuilderAddsHTMLAsSearchablePagesAndPublishesActualMetrics() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        let htmlURL = directory.appendingPathComponent("builder-source.html")
        try Data(
            """
            <!doctype html>
            <html><head><meta charset="utf-8"></head>
            <body><h1>Builder HTML marker</h1><p>Searchable source text.</p></body></html>
            """.utf8
        ).write(to: htmlURL, options: .atomic)

        let model = ImagePDFAssemblyModel()
        model.addHTMLFiles([htmlURL])
        guard case let .html(addedHTMLURL)? = model.items.first?.source else {
            return XCTFail("The HTML file should be retained as a builder item.")
        }
        XCTAssertEqual(addedHTMLURL, htmlURL)

        let destination = directory.appendingPathComponent("html-builder.pdf")
        model.startExport(
            to: destination,
            ocrConfiguration: nil,
            profile: .speed
        )
        await model.waitForExportCompletion()

        let result = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertGreaterThanOrEqual(result.pageCount, 1)
        XCTAssertTrue(
            (0..<result.pageCount).compactMap { result.page(at: $0)?.string }
                .joined(separator: "\n")
                .contains("Builder HTML marker")
        )
        XCTAssertNil(model.presentedError)
        XCTAssertNotNil(model.lastSavedURL)
        XCTAssertGreaterThanOrEqual(model.actualDuration ?? -1, 0)
        XCTAssertGreaterThan(model.actualOutputByteCount ?? 0, 0)
        XCTAssertEqual(model.actualProfile, .speed)
        XCTAssertFalse(model.actualUsedOCR)
    }

    func testBuilderPreservesOrderWhenMultipageHTMLPrecedesBlankAndPDF() async throws {
        _ = NSApplication.shared
        let directory = try temporaryDirectory()
        let htmlURL = directory.appendingPathComponent("multipage-order.html")
        let paragraphs = (1...18).map {
            "<p>Stable multipage HTML line \($0).</p>"
        }.joined(separator: "\n")
        try Data(
            """
            <!doctype html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <style>
                * { box-sizing: border-box; }
                html, body { margin: 0; padding: 0; }
                body { color: #18243a; font: 17px -apple-system, sans-serif; }
                section { min-height: 860px; padding: 28px; }
                section:first-child { background: #f1f6ff; }
                section:last-child { background: #fff8ed; }
                p { line-height: 1.45; margin: 8px 0; }
              </style>
            </head>
            <body>
              <section>
                <h1>HTML ORDER START</h1>
                \(paragraphs)
              </section>
              <section>
                <h2>HTML continuation</h2>
                \(paragraphs)
                <p><strong>HTML ORDER END</strong></p>
              </section>
            </body>
            </html>
            """.utf8
        ).write(to: htmlURL, options: .atomic)

        let sourcePDFURL = directory.appendingPathComponent("existing.pdf")
        let sourcePDF = PDFDocument()
        let importedSize = CGSize(width: 420, height: 620)
        let importedImage = NSImage(
            data: try imageData(
                size: importedSize,
                color: .systemOrange,
                type: .png
            )
        )
        sourcePDF.insert(
            try XCTUnwrap(importedImage.flatMap(PDFPage.init(image:))),
            at: 0
        )
        try AtomicPDFWriter.write(sourcePDF, to: sourcePDFURL)

        let model = ImagePDFAssemblyModel()
        model.addHTMLFiles([htmlURL])
        model.addBlankPage()
        let selection = try model.preparePDFSelection(sourcePDFURL)
        model.addPDFPages(from: selection, indexes: [0])
        XCTAssertEqual(model.items.count, 3)

        let destination = directory.appendingPathComponent("ordered-mixed.pdf")
        model.startExport(
            to: destination,
            ocrConfiguration: nil,
            profile: .stability
        )
        await model.waitForExportCompletion()

        let result = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertNil(model.presentedError)
        XCTAssertEqual(model.lastSavedURL, destination)
        XCTAssertFalse(model.isProcessing)
        XCTAssertEqual(model.progress, 1, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(result.pageCount, 4)

        let htmlPageCount = result.pageCount - 2
        XCTAssertGreaterThanOrEqual(htmlPageCount, 2)
        let htmlText = (0..<htmlPageCount).compactMap {
            result.page(at: $0)?.string
        }.joined(separator: "\n")
        XCTAssertTrue(htmlText.contains("HTML ORDER START"))
        XCTAssertTrue(htmlText.contains("HTML ORDER END"))
        XCTAssertTrue(
            result.page(at: htmlPageCount - 1)?.string?.contains("HTML ORDER END") == true,
            "The last expanded HTML page must remain immediately before the blank page."
        )
        for pageIndex in 0..<htmlPageCount {
            let bounds = try XCTUnwrap(result.page(at: pageIndex)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, 595.28, accuracy: 1)
            XCTAssertEqual(bounds.height, 841.89, accuracy: 1)
        }

        let blankPage = try XCTUnwrap(result.page(at: htmlPageCount))
        XCTAssertTrue(
            (blankPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        XCTAssertEqual(blankPage.bounds(for: .mediaBox).width, 595.28, accuracy: 1)
        XCTAssertEqual(blankPage.bounds(for: .mediaBox).height, 841.89, accuracy: 1)

        let importedPage = try XCTUnwrap(result.page(at: htmlPageCount + 1))
        XCTAssertEqual(importedPage.bounds(for: .mediaBox).width, importedSize.width, accuracy: 1)
        XCTAssertEqual(importedPage.bounds(for: .mediaBox).height, importedSize.height, accuracy: 1)

        let duration = try XCTUnwrap(model.actualDuration)
        XCTAssertTrue(duration.isFinite)
        XCTAssertGreaterThanOrEqual(duration, 0)
        let actualBytes = try XCTUnwrap(model.actualOutputByteCount)
        let savedBytes = try XCTUnwrap(
            destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        XCTAssertGreaterThan(actualBytes, 0)
        XCTAssertEqual(actualBytes, Int64(savedBytes))
        XCTAssertEqual(model.actualProfile, .stability)
        XCTAssertFalse(model.actualUsedOCR)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-ConversionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func imageData(
        size: CGSize,
        color: NSColor,
        type: NSBitmapImageRep.FileType
    ) throws -> Data {
        let image = NSImage(size: size, flipped: false) { bounds in
            color.setFill()
            bounds.fill()
            return true
        }
        let representation = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: representation))
        return try XCTUnwrap(
            bitmap.representation(
                using: type,
                properties: type == .jpeg ? [.compressionFactor: 0.85] : [:]
            )
        )
    }

    private func validateArchive(
        _ archiveURL: URL,
        requiredPaths: [String]
    ) throws {
        let extractionDirectory = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(archiveURL.lastPathComponent + "-expanded", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extractionDirectory,
            withIntermediateDirectories: true
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-qq", archiveURL.path, "-d", extractionDirectory.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        for path in requiredPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: extractionDirectory.appendingPathComponent(path).path
                ),
                "Missing Open XML package part: \(path)"
            )
        }

        let enumerator = FileManager.default.enumerator(
            at: extractionDirectory,
            includingPropertiesForKeys: nil
        )
        while let url = enumerator?.nextObject() as? URL {
            guard ["xml", "rels"].contains(url.pathExtension) else { continue }
            XCTAssertNoThrow(try XMLDocument(contentsOf: url))
        }
    }
}

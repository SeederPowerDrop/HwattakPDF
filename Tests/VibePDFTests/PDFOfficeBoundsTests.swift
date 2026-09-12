// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

@MainActor
final class PDFOfficeBoundsTests: XCTestCase {
    func testPersistedExtremePageFailsBothExportsWithoutReplacingDestination() async throws {
        let directory = try temporaryDirectory()
        let document = PDFDocument()
        let page = try makePage(size: CGSize(width: 100, height: 100))
        let extreme = CGRect(x: 0, y: 0, width: 1e20, height: 1e20)
        page.setBounds(extreme, for: .mediaBox)
        page.setBounds(extreme, for: .cropBox)
        document.insert(page, at: 0)
        let source = directory.appendingPathComponent("extreme.pdf")
        XCTAssertTrue(document.write(to: source))
        let reopened = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertGreaterThan(try XCTUnwrap(reopened.page(at: 0)).bounds(for: .cropBox).width, 1e19)

        for format in [PDFOfficeExportFormat.word, .powerpoint] {
            try await assertBothExportsFailPreservingDestination(reopened, directory: directory, format: format)
        }
    }

    func testInvalidGeometryFailsBeforePDFKitThumbnailRendering() async throws {
        let directory = try temporaryDirectory()
        let invalid: [CGRect] = [
            CGRect(x: 0, y: 0, width: 0, height: 100),
            CGRect(x: 0, y: 0, width: -100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100),
            CGRect(x: 0, y: 0, width: 100, height: CGFloat.infinity),
            CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100),
            CGRect(x: 0, y: 0, width: CGFloat.leastNonzeroMagnitude, height: 100),
        ]
        for bounds in invalid {
            let page = BoundsProbePage()
            page.suppliedBounds = bounds
            let document = PDFDocument()
            document.insert(page, at: 0)
            for format in [PDFOfficeExportFormat.word, .powerpoint] {
                try await assertBothExportsFailPreservingDestination(document, directory: directory, format: format)
            }
            XCTAssertEqual(page.thumbnailRequests, 0, "Invalid geometry must not reach PDFKit drawing: \(bounds)")
        }
    }

    func testUnsupportedOfficeCanvasSizesFailBeforeRendering() async throws {
        let directory = try temporaryDirectory()
        let cases: [(PDFOfficeExportFormat, CGSize)] = [
            (.word, CGSize(width: 1_584.1, height: 792)),
            (.word, CGSize(width: 612, height: 1_584.1)),
            (.word, CGSize(width: 0.01, height: 792)),
            (.powerpoint, CGSize(width: 4_032.1, height: 612)),
            (.powerpoint, CGSize(width: 792, height: 4_032.1)),
            (.powerpoint, CGSize(width: 71.9, height: 612)),
        ]
        for (format, size) in cases {
            let page = BoundsProbePage()
            page.suppliedBounds = CGRect(origin: .zero, size: size)
            let document = PDFDocument()
            document.insert(page, at: 0)
            try await assertBothExportsFailPreservingDestination(document, directory: directory, format: format)
            XCTAssertEqual(page.thumbnailRequests, 0)
        }
    }

    func testInvalidLaterPageDoesNotPublishPartialOfficeDocument() async throws {
        let directory = try temporaryDirectory()
        let document = PDFDocument()
        document.insert(try makePage(size: CGSize(width: 144, height: 216)), at: 0)
        let invalid = BoundsProbePage()
        invalid.suppliedBounds = CGRect(x: 0, y: 0, width: 1e20, height: 792)
        document.insert(invalid, at: 1)
        for format in [PDFOfficeExportFormat.word, .powerpoint] {
            try await assertBothExportsFailPreservingDestination(document, directory: directory, format: format)
        }
        XCTAssertEqual(invalid.thumbnailRequests, 0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".office.tmp") })
    }

    func testRotatedAndMixedPageSizesKeepBoundedProportionalLayouts() async throws {
        let directory = try temporaryDirectory()
        let document = PDFDocument()
        let rotated = try makePage(size: CGSize(width: 144, height: 216))
        rotated.rotation = 90
        document.insert(rotated, at: 0)
        document.insert(try makePage(size: CGSize(width: 144, height: 216)), at: 1)
        document.insert(try makePage(size: CGSize(width: 288, height: 144)), at: 2)

        for format in [PDFOfficeExportFormat.word, .powerpoint] {
            let synchronous = directory.appendingPathComponent("mixed-sync.\(format.fileExtension)")
            let responsive = directory.appendingPathComponent("mixed-async.\(format.fileExtension)")
            try PDFOfficeExporter.export(document, to: synchronous, format: format)
            try await PDFOfficeExporter.exportResponsive(document, to: responsive, format: format)
            for output in [synchronous, responsive] {
                let archive = try Data(contentsOf: output)
                if format == .word {
                    assertArchive(archive, contains: #"<w:pgSz w:w="4320" w:h="2880"/>"#)
                    assertArchive(archive, contains: #"<wp:extent cx="2743200" cy="1828800"/>"#)
                    assertArchive(archive, contains: #"<wp:extent cx="1219200" cy="1828800"/>"#)
                    assertArchive(archive, contains: #"<wp:extent cx="2743200" cy="1371600"/>"#)
                    assertArchive(archive, contains: "word/media/page-3.png")
                } else {
                    assertArchive(archive, contains: #"<p:sldSz cx="2743200" cy="1828800" type="custom"/>"#)
                    assertArchive(archive, contains: #"<a:off x="762000" y="0"/><a:ext cx="1219200" cy="1828800"/>"#)
                    assertArchive(archive, contains: #"<a:off x="0" y="228600"/><a:ext cx="2743200" cy="1371600"/>"#)
                    assertArchive(archive, contains: "ppt/media/page-3.png")
                }
            }
        }
    }

    func testMaximumSupportedCanvasDimensionsProduceValidOfficeUnits() async throws {
        let directory = try temporaryDirectory()
        for (format, points, expected) in [
            (PDFOfficeExportFormat.word, CGFloat(1_584), #"<w:pgSz w:w="31680" w:h="31680"/>"#),
            (.powerpoint, CGFloat(4_032), #"<p:sldSz cx="51206400" cy="51206400" type="custom"/>"#),
        ] {
            let document = PDFDocument()
            document.insert(try makePage(size: CGSize(width: points, height: points)), at: 0)
            let output = directory.appendingPathComponent("maximum.\(format.fileExtension)")
            try await PDFOfficeExporter.exportResponsive(document, to: output, format: format)
            assertArchive(try Data(contentsOf: output), contains: expected)
        }
    }

    private func assertBothExportsFailPreservingDestination(
        _ document: PDFDocument,
        directory: URL,
        format: PDFOfficeExportFormat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let destination = directory.appendingPathComponent("existing.\(format.fileExtension)")
        let original = Data("Existing user document must remain intact".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try PDFOfficeExporter.export(document, to: destination, format: format), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: destination), original, file: file, line: line)
        do {
            try await PDFOfficeExporter.exportResponsive(document, to: destination, format: format)
            XCTFail("Invalid page must fail responsive export", file: file, line: line)
        } catch {
            XCTAssertTrue(error is WorkspaceError, "Unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original, file: file, line: line)
    }

    private func assertArchive(_ archive: Data, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        // The Office writer uses stored ZIP entries, so XML bytes are directly
        // observable in both its in-memory and streaming output.
        XCTAssertNotNil(archive.range(of: Data(text.utf8)), text, file: file, line: line)
    }

    private func makePage(size: CGSize) throws -> PDFPage {
        let image = NSImage(size: CGSize(width: 100, height: 100), flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            NSColor.systemBlue.setFill()
            CGRect(x: 10, y: 10, width: 30, height: 20).fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        page.setBounds(CGRect(origin: .zero, size: size), for: .cropBox)
        return page
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PDFOfficeBounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private final class BoundsProbePage: PDFPage {
    var suppliedBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    var thumbnailRequests = 0

    override func bounds(for box: PDFDisplayBox) -> CGRect { suppliedBounds }

    override func thumbnail(of size: NSSize, for box: PDFDisplayBox) -> NSImage {
        thumbnailRequests += 1
        return NSImage(size: CGSize(width: 1, height: 1))
    }
}

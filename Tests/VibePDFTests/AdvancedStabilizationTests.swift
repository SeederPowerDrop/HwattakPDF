// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

@MainActor
final class AdvancedStabilizationTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HwattakPDF-Stability-\(UUID())")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func makePDF(pages: Int = 2) throws -> URL {
        let url = root.appendingPathComponent("\(UUID()).pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        for index in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Study page \(index + 1)" as NSString).draw(at: CGPoint(x: 20, y: 170),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    func testRecoveryReplacesGenerationAndKeepsWorkingCopyIndependent() throws {
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let document = try XCTUnwrap(PDFDocument(url: makePDF()))
        let id = UUID()
        try store.save(document: document, id: id, displayName: "Study.pdf")
        let first = try XCTUnwrap(store.records().first)
        document.page(at: 0)?.rotation = 90
        try store.save(document: document, id: id, displayName: "Study.pdf")
        let second = try XCTUnwrap(store.records().first)
        XCTAssertEqual(store.records().count, 1)
        XCTAssertNotEqual(first.fileName, second.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.pdfURL(for: first).path))
        let copy = try store.makeWorkingCopy(of: second)
        XCTAssertEqual(PDFDocument(url: copy)?.page(at: 0)?.rotation, 90)
        store.remove(id: id)
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertNotNil(PDFDocument(url: copy))
        store.removeWorkingCopy(at: copy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testAutomaticRecoveryCapturesCommittedEditsAndSaveRemovesItsRecord() async throws {
        let previous = UserDefaults.standard.object(forKey: PDFRecoveryStore.enabledKey)
        UserDefaults.standard.set(true, forKey: PDFRecoveryStore.enabledKey)
        defer { UserDefaults.standard.set(previous, forKey: PDFRecoveryStore.enabledKey) }
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Automatic"))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: try makePDF()))
        workspace.configureRecovery(store: store)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        try await Task.sleep(nanoseconds: 5_500_000_000)
        let record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(PDFDocument(url: store.pdfURL(for: record))?.page(at: 0)?.rotation, 90)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.saveSynchronously())
        XCTAssertTrue(store.records().isEmpty)
    }

    func testDisablingRecoveryCancelsAnAlreadyScheduledSnapshot() async throws {
        let previous = UserDefaults.standard.object(forKey: PDFRecoveryStore.enabledKey)
        UserDefaults.standard.set(true, forKey: PDFRecoveryStore.enabledKey)
        defer { UserDefaults.standard.set(previous, forKey: PDFRecoveryStore.enabledKey) }
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Disabled"))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: try makePDF()))
        workspace.configureRecovery(store: store)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        UserDefaults.standard.set(false, forKey: PDFRecoveryStore.enabledKey)
        try await Task.sleep(nanoseconds: 5_500_000_000)
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertTrue(workspace.isDirty)
    }

    func testRecoveryFailureRetainsPreviousGenerationAndRejectsEncryptedDocument() throws {
        let store = PDFRecoveryStore(directory: root.appendingPathComponent("Recovery"))
        let source = try makePDF()
        let document = try XCTUnwrap(PDFDocument(url: source))
        let id = UUID()
        try store.save(document: document, id: id, displayName: "Study.pdf")
        let record = try XCTUnwrap(store.records().first)
        let bytes = try Data(contentsOf: store.pdfURL(for: record))
        XCTAssertThrowsError(try store.save(document: PDFDocument(), id: id, displayName: "Empty"))
        let encrypted = root.appendingPathComponent("protected.pdf")
        XCTAssertTrue(document.write(to: encrypted, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "reader"]))
        let protected = try XCTUnwrap(PDFDocument(url: encrypted))
        XCTAssertTrue(protected.unlock(withPassword: "owner"))
        XCTAssertThrowsError(try store.save(document: protected, id: id, displayName: "Protected"))
        XCTAssertEqual(try Data(contentsOf: store.pdfURL(for: record)), bytes)
    }

    func testRecoveredWorkspaceRequiresSaveAsAndPreservesSnapshot() throws {
        let source = try makePDF()
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: source))
        workspace.markAsRecoveredCopy()
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.requiresSaveDestination)
        XCTAssertFalse(workspace.saveSynchronously())
        let saved = root.appendingPathComponent("saved.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: saved))
        XCTAssertFalse(workspace.isRecoveryCopy)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertNotNil(PDFDocument(url: source))
    }

    func testOCRCleanupRefusesActiveRecognitionAndSucceedsAfterLease() throws {
        let store = OCRCheckpointStore(directory: root.appendingPathComponent("Checkpoints"))
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let marker = store.directory.appendingPathComponent("retained.json")
        try Data("fixture".utf8).write(to: marker)
        try store.withProcessingLease {
            XCTAssertThrowsError(try store.removeAllIfIdle())
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
        try store.removeAllIfIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testPressureInkAppearanceSurvivesPDFSaveAndUndo() throws {
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: try makePDF(pages: 1)))
        workspace.setMode(.study)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let ink = try XCTUnwrap(PressureInkAnnotation(
            points: [CGPoint(x: 40, y: 100), CGPoint(x: 80, y: 100), CGPoint(x: 120, y: 100), CGPoint(x: 160, y: 100)],
            pressures: [0.1, 0.1, 1, 1], width: 12, color: .blue))
        page.addAnnotation(ink)
        workspace.registerAddedAnnotation(ink, on: page, message: "Pressure test")
        XCTAssertTrue(workspace.isDirty)
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
        workspace.redo()
        XCTAssertEqual(page.annotations.count, 1)
        let output = root.appendingPathComponent("pressure.pdf")
        XCTAssertTrue(workspace.saveSynchronously(as: output))
        let reopened = try XCTUnwrap(PDFDocument(url: output)?.page(at: 0))
        XCTAssertEqual(reopened.annotations.count, 1)
        XCTAssertEqual(reopened.annotations[0].type, "Stamp")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        reopened.draw(with: .mediaBox, to: graphics.cgContext)
        graphics.flushGraphics()
        let thinEdge = try XCTUnwrap(bitmap.colorAt(x: 60, y: 104)?.usingColorSpace(.deviceRGB))
        let thickEdge = try XCTUnwrap(bitmap.colorAt(x: 140, y: 104)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(thinEdge.redComponent, 0.8, "Low pressure should leave this pixel white")
        XCTAssertLessThan(thickEdge.redComponent, 0.3, "High pressure should paint this pixel blue")
    }

    func testPressureInkRejectsInvalidAndUnboundedSamples() {
        XCTAssertNil(PressureInkAnnotation(points: [.zero], pressures: [], width: 1, color: .blue))
        XCTAssertNil(PressureInkAnnotation(points: [.zero], pressures: [.nan], width: 1, color: .blue))
        XCTAssertNil(PressureInkAnnotation(points: [.zero], pressures: [1], width: .infinity, color: .blue))
        XCTAssertNil(PressureInkAnnotation(points: Array(repeating: .zero, count: 8_193),
            pressures: Array(repeating: 1, count: 8_193), width: 1, color: .blue))
    }

    func testStreamedOfficeArchivesPassIndependentZipIntegrityCheck() async throws {
        let document = try XCTUnwrap(PDFDocument(url: makePDF(pages: 3)))
        for format in [PDFOfficeExportFormat.word, .powerpoint] {
            let output = root.appendingPathComponent("study.\(format.fileExtension)")
            var progress: [Double] = []
            try await PDFOfficeExporter.exportResponsive(document, to: output, format: format, progress: { progress.append($0) })
            XCTAssertEqual(progress.last, 1)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-t", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
    }

    func testOfficeCancellationAndConcurrentEditsLeaveDestinationUntouched() async throws {
        let source = try makePDF(pages: 8)
        let output = root.appendingPathComponent("existing.docx")
        let original = Data("existing document".utf8)
        try original.write(to: output)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: source))
        workspace.exportAsOfficeDocument(to: output, format: .word)
        workspace.cancelOfficeExport()
        await workspace.waitForOfficeExport()
        XCTAssertNil(workspace.officeExportProgress)
        XCTAssertEqual(try Data(contentsOf: output), original)
        workspace.exportAsOfficeDocument(to: output, format: .word)
        workspace.setMode(.editing)
        workspace.rotateSelectedPages(clockwise: true)
        await workspace.waitForOfficeExport()
        XCTAssertNotNil(workspace.presentedError)
        XCTAssertEqual(try Data(contentsOf: output), original)
        XCTAssertTrue(workspace.isDirty)
    }

    func testThousandPageBatchKeepsOnlyActiveDocumentResident() async throws {
        let source = try makePDF(pages: 1_000)
        var urls: [URL] = [source]
        for index in 1..<20 {
            let copy = root.appendingPathComponent("textbook-\(index).pdf")
            try FileManager.default.copyItem(at: source, to: copy)
            urls.append(copy)
        }
        let workspace = MultiDocumentWorkspaceState()
        let start = Date()
        let ids = await workspace.openPDFsInTabsAsync(urls: urls)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(ids.count, 20)
        XCTAssertEqual(workspace.activeWorkspace?.pageCount, 1_000)
        let resident = workspace.allTabs.filter { $0.workspace.document != nil }.count
        XCTAssertEqual(resident, 1)
        workspace.selectTab(ids[0])
        XCTAssertEqual(workspace.activeWorkspace?.document?.pageCount, 1_000)
        print("STABILITY_LARGE_PDF pages=1000 tabs=20 initialResident=\(resident) openSeconds=\(elapsed)")
    }

    func testLargeScannedPDFOpensAndRendersLastPage() async throws {
        let source = root.appendingPathComponent("large-scan.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let writer = try XCTUnwrap(CGContext(source as CFURL, mediaBox: &bounds, nil))
        var bytes = Data(count: 1_024 * 1_024 * 3)
        var seed: UInt32 = 0x12345678
        bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in buffer.indices {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                buffer[index] = UInt8(truncatingIfNeeded: seed >> 16)
            }
        }
        for index in 0..<20 {
            bytes[0] = UInt8(index)
            let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
            let image = try XCTUnwrap(CGImage(width: 1_024, height: 1_024, bitsPerComponent: 8,
                bitsPerPixel: 24, bytesPerRow: 1_024 * 3, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
            writer.beginPDFPage(nil)
            writer.draw(image, in: bounds)
            writer.endPDFPage()
        }
        writer.closePDF()
        let size = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(size, 50 * 1_024 * 1_024)
        let workspace = MultiDocumentWorkspaceState()
        let start = Date()
        _ = await workspace.openPDFsInTabsAsync(urls: [source])
        let elapsed = Date().timeIntervalSince(start)
        let state = try XCTUnwrap(workspace.activeWorkspace)
        XCTAssertEqual(state.pageCount, 20)
        state.setCurrentPage(19)
        let page = try XCTUnwrap(state.document?.page(at: 19))
        XCTAssertNotNil(page.thumbnail(of: CGSize(width: 306, height: 396), for: .cropBox).tiffRepresentation)
        state.setMode(.study)
        XCTAssertTrue(state.allows(.handwriting))
        print("STABILITY_SCANNED_PDF bytes=\(size) pages=20 openSeconds=\(elapsed) lastPageRendered=true")
    }
}

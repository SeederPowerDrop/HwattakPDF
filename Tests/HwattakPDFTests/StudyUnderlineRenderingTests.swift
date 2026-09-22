// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class StudyUnderlineRenderingTests: XCTestCase {
    func testUnderlineStartsThinAndUsesItsOwnThicknessRange() {
        XCTAssertEqual(StudyMarkupStyle().thickness, 9)
        XCTAssertEqual(StudyMarkupStyle(kind: .underline).thickness, 1.5)
        XCTAssertEqual(StudyMarkupStyle(kind: .underline, thickness: 0).normalized.thickness, 0.5)
        XCTAssertEqual(StudyMarkupStyle(kind: .underline, thickness: 100).normalized.thickness, 6)
    }

    @MainActor
    func testSwitchingKindsRemembersWidthsWithoutChangingColorOrOpacity() {
        let workspace = PDFWorkspaceState()
        workspace.studyMarkupStyle = StudyMarkupStyle(color: .systemBlue, thickness: 12, opacity: 0.7)
        workspace.selectStudyMarkupKind(.underline)
        XCTAssertEqual(workspace.studyMarkupStyle.thickness, 1.5)
        workspace.studyMarkupStyle.thickness = 2.5
        workspace.selectStudyMarkupKind(.highlight)
        XCTAssertEqual(workspace.studyMarkupStyle.thickness, 12)
        workspace.selectStudyMarkupKind(.underline)
        XCTAssertEqual(workspace.studyMarkupStyle.thickness, 2.5)
        XCTAssertEqual(workspace.studyMarkupStyle.color, NSColor.systemBlue.usingColorSpace(.deviceRGB))
        XCTAssertEqual(workspace.studyMarkupStyle.opacity, 0.7)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
    }

    @MainActor
    func testSmallTextUnderlineStaysAThinLineBeforeAndAfterSaving() throws {
        for textHeight: CGFloat in [8, 14, 30] {
            let document = PDFDocument()
            let image = NSImage(size: CGSize(width: 100, height: 100), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                return true
            }
            let page = try XCTUnwrap(PDFPage(image: image))
            let annotation = StudyMarkupAnnotation(
                bounds: CGRect(x: 20, y: 30, width: 60, height: textHeight),
                style: StudyMarkupStyle(kind: .underline, color: .red, thickness: 16, opacity: 0.5)
            )
            page.addAnnotation(annotation)
            document.insert(page, at: 0)
            let reopened = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
            let savedPage = try XCTUnwrap(reopened.page(at: 0))
            XCTAssertEqual(StudyMarkupAnnotationIdentity.kind(of: try XCTUnwrap(savedPage.annotations.first)), .underline)

            for renderedPage in [page, savedPage] {
                let rows = try redRows(on: renderedPage)
                XCTAssertGreaterThan(rows.count, 0, "The underline must remain visible.")
                let first = try XCTUnwrap(rows.first)
                let last = try XCTUnwrap(rows.last)
                XCTAssertLessThanOrEqual(CGFloat(last - first + 1) / 4, textHeight * 0.2 + 0.5)
                XCTAssertEqual(rows.count, last - first + 1, "One continuous baseline, not a filled text band.")
            }
        }
    }

    func testInlinePaletteAcceptsCustomColorsAndRejectsInvalidInput() throws {
        XCTAssertEqual(InlineColorPalette.hexString(for: try XCTUnwrap(InlineColorPalette.color(forHex: " #39f "))), "#3399FF")
        XCTAssertEqual(InlineColorPalette.hexString(for: try XCTUnwrap(InlineColorPalette.color(forHex: "00aA7f"))), "#00AA7F")
        for invalid in ["", "#12", "#1234", "#GG0000", "#000000FF"] {
            XCTAssertNil(InlineColorPalette.color(forHex: invalid))
        }
    }

    private func redRows(on page: PDFPage) throws -> [Int] {
        let width = 400
        let height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        return try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.scaleBy(x: 4, y: 4)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            page.draw(with: .mediaBox, to: context)
            return (0..<height).filter { row in
                let offset = (row * width + width / 2) * 4
                return bytes[offset] > 230 && bytes[offset + 1] < 230 && bytes[offset + 2] < 230
            }
        }
    }
}

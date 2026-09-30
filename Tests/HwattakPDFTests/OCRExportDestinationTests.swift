// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

final class OCRExportDestinationTests: XCTestCase {
    func testCopyUsesOriginalFolderAndPreservesStem() {
        let source = URL(fileURLWithPath: "/Users/example/Documents/논문 자료/연구.v2 최종.PDF")
        let suggestion = OCRExportDestination(sourceURL: source)
        XCTAssertEqual(suggestion.directoryURL, source.deletingLastPathComponent())
        XCTAssertEqual(suggestion.fileName, "연구.v2 최종-ocr.pdf")
    }

    func testUnsavedDocumentDoesNotInventAnOriginalFolder() {
        let suggestion = OCRExportDestination(sourceURL: nil)
        XCTAssertNil(suggestion.directoryURL)
        XCTAssertEqual(suggestion.fileName, "HwattakPDF-ocr.pdf")
    }

    func testLongUnicodeStemLeavesRoomForSuffix() {
        let source = URL(fileURLWithPath: "/tmp/\(String(repeating: "한", count: 80)).pdf")
        let suggestion = OCRExportDestination(sourceURL: source)
        XCTAssertLessThanOrEqual(suggestion.fileName.utf8.count, 255)
        XCTAssertTrue(suggestion.fileName.hasSuffix("-ocr.pdf"))
        XCTAssertTrue(source.deletingPathExtension().lastPathComponent.hasPrefix(
            String(suggestion.fileName.dropLast("-ocr.pdf".count))
        ))
    }
}

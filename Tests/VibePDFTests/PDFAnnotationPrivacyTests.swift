// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

/// Guards a privacy boundary that is easy to miss when using PDFKit.
///
/// The framework populates a new annotation's author from the macOS account.
/// These tests serialize and reopen a real PDF so an in-memory nil assignment
/// cannot give false confidence while `/T` is still written to disk.
final class PDFAnnotationPrivacyTests: XCTestCase {
    func testClearedNativeAnnotationAuthorsRemainAbsentAfterRoundTrip() throws {
        let page = try XCTUnwrap(PDFPage(image: whitePageImage()))
        for (index, type) in [
            PDFAnnotationSubtype.freeText,
            .highlight,
            .ink,
        ].enumerated() {
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 20, y: 30 + CGFloat(index) * 45, width: 120, height: 30),
                forType: type,
                withProperties: nil
            )
            PDFAnnotationPrivacy.clearImplicitAuthor(on: annotation)
            page.addAnnotation(annotation)
        }

        let reopened = try roundTrip(page)
        XCTAssertEqual(reopened.annotations.count, 3)
        XCTAssertTrue(reopened.annotations.allSatisfy { $0.userName == nil })
        XCTAssertTrue(reopened.annotations.allSatisfy {
            $0.value(forAnnotationKey: .textLabel) == nil
        })
    }

    func testCustomAppearanceAnnotationAuthorsRemainAbsentAfterRoundTrip() throws {
        let page = try XCTUnwrap(PDFPage(image: whitePageImage()))
        let image = ImageStampAnnotation(
            image: whitePageImage(),
            bounds: CGRect(x: 20, y: 30, width: 80, height: 50)
        )
        let study = StudyMarkupAnnotation(
            bounds: CGRect(x: 20, y: 100, width: 100, height: 24),
            style: StudyMarkupStyle(
                kind: .highlight,
                color: .systemYellow,
                thickness: 10,
                opacity: 0.4
            )
        )
        page.addAnnotation(image)
        page.addAnnotation(study)

        let reopened = try roundTrip(page)
        XCTAssertEqual(reopened.annotations.count, 2)
        XCTAssertTrue(reopened.annotations.allSatisfy { $0.userName == nil })
        XCTAssertTrue(reopened.annotations.allSatisfy {
            $0.value(forAnnotationKey: .textLabel) == nil
        })
    }

    private func roundTrip(_ page: PDFPage) throws -> PDFPage {
        let document = PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        return try XCTUnwrap(reopened.page(at: 0))
    }

    private func whitePageImage() -> NSImage {
        NSImage(size: CGSize(width: 240, height: 320), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
    }
}

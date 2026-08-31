// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

final class ImageAnnotationEditingTests: XCTestCase {
    func testTransparentImageStampDoesNotRenderDefaultStampPlaceholder() throws {
        let size = CGSize(width: 120, height: 60)
        let transparentImage = NSImage(size: size, flipped: false) { _ in true }
        let annotation = ImageStampAnnotation(
            image: transparentImage,
            bounds: CGRect(origin: .zero, size: size)
        )
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border

        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.clear(CGRect(origin: .zero, size: size))

        annotation.draw(with: .cropBox, in: graphics.cgContext)

        let bitmapData = try XCTUnwrap(bitmap.bitmapData)
        let alphaOffset = bitmap.samplesPerPixel - 1
        var opaquePixelCount = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let offset = y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel + alphaOffset
                if bitmapData[offset] != 0 {
                    opaquePixelCount += 1
                }
            }
        }
        XCTAssertEqual(
            opaquePixelCount,
            0,
            "A transparent signature must not reveal PDFKit's default stamp placeholder."
        )
    }

    func testImageStampStillRendersOpaqueSourcePixelsWithoutAPlaceholder() throws {
        let size = CGSize(width: 120, height: 60)
        let sourceImage = NSImage(size: size, flipped: false) { _ in
            NSColor.systemRed.setFill()
            CGRect(x: 50, y: 25, width: 20, height: 10).fill()
            return true
        }
        let annotation = ImageStampAnnotation(
            image: sourceImage,
            bounds: CGRect(origin: .zero, size: size)
        )
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border

        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width),
                pixelsHigh: Int(size.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.clear(CGRect(origin: .zero, size: size))

        annotation.draw(with: .cropBox, in: graphics.cgContext)

        let bitmapData = try XCTUnwrap(bitmap.bitmapData)
        let alphaOffset = bitmap.samplesPerPixel - 1
        func alpha(x: Int, y: Int) -> UInt8 {
            bitmapData[y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel + alphaOffset]
        }

        XCTAssertGreaterThan(alpha(x: 60, y: 30), 0, "The source signature stroke must remain visible.")
        XCTAssertEqual(alpha(x: 2, y: 2), 0, "Transparent background must remain clean.")
        XCTAssertEqual(alpha(x: 117, y: 57), 0, "No default stamp box may surround the source image.")
    }

    func testSavedCroppedStampEmbedsOnlyVisibleRasterPixels() throws {
        // The red and blue quarters model sensitive material that the user
        // removes with the crop UI. The visible middle half is green.
        let sourceImage = try quarterStripedImage(width: 120, height: 60)
        let annotation = ImageStampAnnotation(
            image: sourceImage,
            bounds: CGRect(x: 40, y: 50, width: 120, height: 60),
            normalizedCropRect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
        )
        _ = ImageAnnotationIdentity.assign(to: annotation)
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border

        let pageImage = NSImage(size: CGSize(width: 220, height: 180), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: pageImage))
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)

        let data = try XCTUnwrap(document.dataRepresentation())
        let embeddedImages = try appearanceImageXObjects(in: data, annotationIndex: 0)
        XCTAssertFalse(embeddedImages.isEmpty, "The Stamp appearance should contain an image XObject.")

        // This is the security assertion. The old clipping-only renderer
        // embedded a 120x60 XObject and merely hid its outer quarters. The new
        // appearance owns a 60x60 detached buffer, so reopening/extracting the
        // PDF cannot reveal either removed 30-pixel strip.
        XCTAssertTrue(
            embeddedImages.contains(PDFImageXObjectMetadata(width: 60, height: 60)),
            "Expected the visible 60x60 crop in the saved appearance: \(embeddedImages)"
        )
        XCTAssertFalse(
            embeddedImages.contains(where: { $0.width == 120 && $0.height == 60 }),
            "The complete source raster must never enter the saved annotation appearance."
        )

        // Also validate the normal-user result after reopening. All three
        // horizontal samples lie inside the Stamp and must show the retained
        // green middle band, rather than a missing appearance or shifted crop.
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        let reopenedPage = try XCTUnwrap(reopened.page(at: 0))
        for point in [CGPoint(x: 45, y: 80), CGPoint(x: 100, y: 80), CGPoint(x: 155, y: 80)] {
            let color = try renderedPageColor(reopenedPage, at: point)
            XCTAssertGreaterThan(color.greenComponent, 0.7)
            XCTAssertLessThan(color.redComponent, 0.3)
            XCTAssertLessThan(color.blueComponent, 0.3)
        }
    }

    @MainActor
    func testModeChangeDuringLiveImageMoveRollsBackWithoutDirtyOrUndoEntry() throws {
        let fixture = try makeOverlayDragFixture()
        defer { fixture.detachOverlays() }
        let originalBounds = fixture.annotation.bounds
        let originalCrop = fixture.annotation.normalizedCropRect
        let originalDate = fixture.annotation.modificationDate
        let start = CGPoint(x: originalBounds.midX, y: originalBounds.midY)
        let destination = CGPoint(x: start.x + 35, y: start.y + 20)

        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: start, fixture: fixture)
        )
        fixture.overlay.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, pagePoint: destination, fixture: fixture)
        )
        XCTAssertNotEqual(fixture.annotation.bounds, originalBounds, "The live preview must move first.")
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)

        // Study mode revokes imported-image editing. `configure(with:)` models
        // the same SwiftUI update that arrives while the mouse is still down.
        fixture.workspace.setMode(.study)
        fixture.pdfView.configure(with: fixture.workspace)

        assertBounds(fixture.annotation.bounds, equalTo: originalBounds)
        XCTAssertEqual(fixture.annotation.normalizedCropRect, originalCrop)
        XCTAssertEqual(fixture.annotation.modificationDate, originalDate)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)

        // A delayed AppKit mouse-up from the old gesture must be inert.
        fixture.overlay.mouseUp(
            with: try mouseEvent(.leftMouseUp, pagePoint: destination, fixture: fixture)
        )
        assertBounds(fixture.annotation.bounds, equalTo: originalBounds)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
    }

    @MainActor
    func testAuthorizedRefreshDuringLiveImageMovePreservesAndCommitsPreview() throws {
        let fixture = try makeOverlayDragFixture()
        defer { fixture.detachOverlays() }
        let originalBounds = fixture.annotation.bounds
        let start = CGPoint(x: originalBounds.midX, y: originalBounds.midY)
        let destination = CGPoint(x: start.x + 28, y: start.y + 14)

        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: start, fixture: fixture)
        )
        fixture.overlay.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, pagePoint: destination, fixture: fixture)
        )
        let previewBounds = fixture.annotation.bounds
        XCTAssertNotEqual(previewBounds, originalBounds)

        // Search/status/sidebar publications can rebuild the representable.
        // Because mode, document and page identity are unchanged, that benign
        // refresh must not snap an in-progress drag back to its start.
        fixture.workspace.statusMessage = "Unrelated UI refresh"
        fixture.pdfView.configure(with: fixture.workspace)
        assertBounds(fixture.annotation.bounds, equalTo: previewBounds)

        fixture.overlay.mouseUp(
            with: try mouseEvent(.leftMouseUp, pagePoint: destination, fixture: fixture)
        )
        assertBounds(fixture.annotation.bounds, equalTo: previewBounds)
        XCTAssertTrue(fixture.workspace.isDirty)
        XCTAssertTrue(fixture.workspace.canUndo)

        fixture.workspace.undo()
        assertBounds(fixture.annotation.bounds, equalTo: originalBounds)
    }

    @MainActor
    func testArrowKeySettlesLiveDragBeforeRecordingKeyboardMove() throws {
        let fixture = try makeOverlayDragFixture()
        defer { fixture.detachOverlays() }
        let original = fixture.annotation.bounds
        let start = CGPoint(x: original.midX, y: original.midY)
        let previewPoint = CGPoint(x: start.x + 36, y: start.y + 18)

        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: start, fixture: fixture)
        )
        fixture.overlay.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, pagePoint: previewPoint, fixture: fixture)
        )
        XCTAssertNotEqual(fixture.annotation.bounds, original)

        // The keyboard transaction must start from A, not from the unrecorded
        // drag preview B. Otherwise two Undo operations can claim a saved
        // checkpoint while leaving B in the PDF graph.
        fixture.overlay.keyDown(with: try keyEvent(keyCode: 124)) // Right arrow
        XCTAssertEqual(fixture.annotation.bounds.minX, original.minX + 1, accuracy: 0.001)
        fixture.overlay.mouseUp(
            with: try mouseEvent(.leftMouseUp, pagePoint: previewPoint, fixture: fixture)
        )
        XCTAssertEqual(fixture.annotation.bounds.minX, original.minX + 1, accuracy: 0.001)
        XCTAssertTrue(fixture.workspace.isDirty)

        fixture.workspace.undo()
        assertBounds(fixture.annotation.bounds, equalTo: original)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testDeleteKeyRollsBackLiveDragBeforeRemovalAndUndo() throws {
        let fixture = try makeOverlayDragFixture()
        defer { fixture.detachOverlays() }
        let original = fixture.annotation.bounds
        let start = CGPoint(x: original.midX, y: original.midY)
        let previewPoint = CGPoint(x: start.x + 30, y: start.y + 12)

        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: start, fixture: fixture)
        )
        fixture.overlay.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, pagePoint: previewPoint, fixture: fixture)
        )
        fixture.overlay.keyDown(with: try keyEvent(keyCode: 51)) // Delete
        XCTAssertFalse(fixture.page.annotations.contains(where: { $0 === fixture.annotation }))

        fixture.workspace.undo()
        XCTAssertTrue(fixture.page.annotations.contains(where: { $0 === fixture.annotation }))
        assertBounds(fixture.annotation.bounds, equalTo: original)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testModeChangeDuringLiveImageResizeRollsBackExactly() throws {
        let fixture = try makeOverlayDragFixture()
        defer { fixture.detachOverlays() }
        let originalBounds = fixture.annotation.bounds
        let originalCrop = fixture.annotation.normalizedCropRect
        let originalDate = fixture.annotation.modificationDate
        let center = CGPoint(x: originalBounds.midX, y: originalBounds.midY)

        // Select the Stamp, then start a second gesture on its top-right
        // handle. Holding Shift disables the normal aspect-ratio constraint so
        // the test also exercises the general resize path.
        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: center, fixture: fixture)
        )
        fixture.overlay.mouseUp(
            with: try mouseEvent(.leftMouseUp, pagePoint: center, fixture: fixture)
        )
        let handle = CGPoint(x: originalBounds.maxX, y: originalBounds.maxY)
        let resizedCorner = CGPoint(x: handle.x + 35, y: handle.y + 18)
        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: handle, fixture: fixture)
        )
        fixture.overlay.mouseDragged(
            with: try mouseEvent(
                .leftMouseDragged,
                pagePoint: resizedCorner,
                modifierFlags: [.shift],
                fixture: fixture
            )
        )
        XCTAssertNotEqual(fixture.annotation.bounds, originalBounds)

        fixture.workspace.setMode(.study)
        fixture.pdfView.configure(with: fixture.workspace)

        assertBounds(fixture.annotation.bounds, equalTo: originalBounds)
        XCTAssertEqual(fixture.annotation.normalizedCropRect, originalCrop)
        XCTAssertEqual(fixture.annotation.modificationDate, originalDate)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
    }

    @MainActor
    func testModeChangeDuringLiveCropRestoresWholeCropSessionExactly() throws {
        let fixture = try makeOverlayDragFixture()
        defer { fixture.detachOverlays() }
        let originalBounds = fixture.annotation.bounds
        let originalCrop = fixture.annotation.normalizedCropRect
        let originalDate = fixture.annotation.modificationDate
        let center = CGPoint(x: originalBounds.midX, y: originalBounds.midY)

        // First select without changing geometry, then enter the same crop
        // command used by the context-menu item.
        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: center, fixture: fixture)
        )
        fixture.overlay.mouseUp(
            with: try mouseEvent(.leftMouseUp, pagePoint: center, fixture: fixture)
        )
        _ = fixture.overlay.perform(
            NSSelectorFromString("beginCroppingFromMenu:"),
            with: nil
        )

        let bottomLeft = CGPoint(x: originalBounds.minX, y: originalBounds.minY)
        let croppedCorner = CGPoint(x: originalBounds.minX + 30, y: originalBounds.minY + 20)
        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: bottomLeft, fixture: fixture)
        )
        fixture.overlay.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, pagePoint: croppedCorner, fixture: fixture)
        )
        XCTAssertNotEqual(fixture.annotation.normalizedCropRect, originalCrop)
        XCTAssertNotEqual(fixture.annotation.bounds, originalBounds)

        fixture.workspace.setMode(.viewer)
        fixture.pdfView.configure(with: fixture.workspace)

        assertBounds(fixture.annotation.bounds, equalTo: originalBounds)
        XCTAssertEqual(fixture.annotation.normalizedCropRect, originalCrop)
        XCTAssertEqual(fixture.annotation.modificationDate, originalDate)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
    }

    @MainActor
    func testModeChangeSettlesCompletedCropBeforeEditingAuthorityIsRevoked() throws {
        let fixture = try makeOverlayDragFixture()
        defer { fixture.detachOverlays() }
        let originalBounds = fixture.annotation.bounds
        let originalCrop = fixture.annotation.normalizedCropRect
        let center = CGPoint(x: originalBounds.midX, y: originalBounds.midY)

        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: center, fixture: fixture)
        )
        fixture.overlay.mouseUp(
            with: try mouseEvent(.leftMouseUp, pagePoint: center, fixture: fixture)
        )
        _ = fixture.overlay.perform(
            NSSelectorFromString("beginCroppingFromMenu:"),
            with: nil
        )
        let corner = CGPoint(x: originalBounds.minX, y: originalBounds.minY)
        let croppedCorner = CGPoint(x: corner.x + 24, y: corner.y + 14)
        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: corner, fixture: fixture)
        )
        fixture.overlay.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, pagePoint: croppedCorner, fixture: fixture)
        )
        fixture.overlay.mouseUp(
            with: try mouseEvent(.leftMouseUp, pagePoint: croppedCorner, fixture: fixture)
        )
        let completedBounds = fixture.annotation.bounds
        let completedCrop = fixture.annotation.normalizedCropRect
        XCTAssertNotEqual(completedBounds, originalBounds)
        XCTAssertNotEqual(completedCrop, originalCrop)
        XCTAssertFalse(fixture.workspace.isDirty, "The open crop session has not entered history yet.")

        // setMode must invoke the registered overlay hook synchronously before
        // Viewer revokes image-editing authority. The completed visible crop is
        // therefore retained and becomes one undoable document change.
        fixture.workspace.setMode(.viewer)
        assertBounds(fixture.annotation.bounds, equalTo: completedBounds)
        XCTAssertEqual(fixture.annotation.normalizedCropRect, completedCrop)
        XCTAssertTrue(fixture.workspace.isDirty)
        XCTAssertTrue(fixture.workspace.canUndo)

        fixture.workspace.undo()
        assertBounds(fixture.annotation.bounds, equalTo: originalBounds)
        XCTAssertEqual(fixture.annotation.normalizedCropRect, originalCrop)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testSaveSettlesCompletedCropBeforeCreatingSavedCheckpoint() throws {
        let fixture = try makeOverlayDragFixture()
        defer { fixture.detachOverlays() }
        let originalBounds = fixture.annotation.bounds
        let originalCrop = fixture.annotation.normalizedCropRect
        let center = CGPoint(x: originalBounds.midX, y: originalBounds.midY)

        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: center, fixture: fixture)
        )
        fixture.overlay.mouseUp(
            with: try mouseEvent(.leftMouseUp, pagePoint: center, fixture: fixture)
        )
        _ = fixture.overlay.perform(
            NSSelectorFromString("beginCroppingFromMenu:"),
            with: nil
        )
        let corner = CGPoint(x: originalBounds.minX, y: originalBounds.minY)
        let croppedCorner = CGPoint(x: corner.x + 26, y: corner.y + 16)
        fixture.overlay.mouseDown(
            with: try mouseEvent(.leftMouseDown, pagePoint: corner, fixture: fixture)
        )
        fixture.overlay.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, pagePoint: croppedCorner, fixture: fixture)
        )
        fixture.overlay.mouseUp(
            with: try mouseEvent(.leftMouseUp, pagePoint: croppedCorner, fixture: fixture)
        )
        let visibleCropBounds = fixture.annotation.bounds
        let visibleCropRect = fixture.annotation.normalizedCropRect
        XCTAssertNotEqual(visibleCropBounds, originalBounds)
        XCTAssertFalse(fixture.workspace.isDirty, "Crop session is not committed until deactivation.")

        XCTAssertTrue(fixture.workspace.saveSynchronously())
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertTrue(fixture.workspace.canUndo)
        assertBounds(fixture.annotation.bounds, equalTo: visibleCropBounds)
        XCTAssertEqual(fixture.annotation.normalizedCropRect, visibleCropRect)

        fixture.workspace.undo()
        assertBounds(fixture.annotation.bounds, equalTo: originalBounds)
        XCTAssertEqual(fixture.annotation.normalizedCropRect, originalCrop)
        XCTAssertTrue(
            fixture.workspace.isDirty,
            "Undo after saving crop B returns to A, which must differ from the saved checkpoint."
        )
        fixture.workspace.redo()
        assertBounds(fixture.annotation.bounds, equalTo: visibleCropBounds)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testToolDocumentPageAndAnnotationOrderChangesInvalidateLiveMove() throws {
        enum Invalidator: String, CaseIterable {
            case tool
            case document
            case pageOrder
            case annotationOrder
        }

        for invalidator in Invalidator.allCases {
            let fixture = try makeOverlayDragFixture()
            let originalBounds = fixture.annotation.bounds
            let originalCrop = fixture.annotation.normalizedCropRect
            let originalDate = fixture.annotation.modificationDate
            let start = CGPoint(x: originalBounds.midX, y: originalBounds.midY)
            let destination = CGPoint(x: start.x + 24, y: start.y + 12)
            fixture.overlay.mouseDown(
                with: try mouseEvent(.leftMouseDown, pagePoint: start, fixture: fixture)
            )
            fixture.overlay.mouseDragged(
                with: try mouseEvent(.leftMouseDragged, pagePoint: destination, fixture: fixture)
            )
            XCTAssertNotEqual(fixture.annotation.bounds, originalBounds)

            switch invalidator {
            case .tool:
                fixture.workspace.activeTool = .pen
            case .document:
                let replacement = PDFDocument()
                let image = NSImage(
                    size: CGSize(width: 300, height: 400),
                    flipped: false
                ) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    return true
                }
                replacement.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
                fixture.pdfView.document = replacement
            case .pageOrder:
                let image = NSImage(
                    size: CGSize(width: 300, height: 400),
                    flipped: false
                ) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    return true
                }
                fixture.workspace.document?.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
            case .annotationOrder:
                fixture.page.addAnnotation(
                    PDFAnnotation(
                        bounds: CGRect(x: 10, y: 10, width: 20, height: 20),
                        forType: .circle,
                        withProperties: nil
                    )
                )
            }

            fixture.pdfView.configure(with: fixture.workspace)
            assertBounds(
                fixture.annotation.bounds,
                equalTo: originalBounds,
                file: #filePath,
                line: #line
            )
            XCTAssertEqual(
                fixture.annotation.normalizedCropRect,
                originalCrop,
                "\(invalidator) must restore the original crop."
            )
            XCTAssertEqual(
                fixture.annotation.modificationDate,
                originalDate,
                "\(invalidator) must restore the original timestamp."
            )
            XCTAssertFalse(fixture.workspace.canUndo)
            fixture.detachOverlays()
        }
    }

    func testEditableAnnotationIdentityClassifiesAppOwnedAnnotationKinds() {
        let image = annotation(
            type: .stamp,
            name: "HwattakPDF-Image-current"
        )
        let currentSignature = annotation(
            type: .stamp,
            name: "HwattakPDF-Signature-current"
        )
        let legacySignature = annotation(
            type: .stamp,
            name: "VibePDF-Signature-legacy"
        )
        let currentFreeText = annotation(
            type: .freeText,
            name: "HwattakPDF-Annotation-current"
        )
        let legacyFreeText = annotation(
            type: .freeText,
            name: "VibePDF-Annotation-legacy"
        )

        assertKind(of: image, is: .image)
        assertKind(of: currentSignature, is: .signature)
        assertKind(of: legacySignature, is: .signature)
        assertKind(of: currentFreeText, is: .freeText)
        assertKind(of: legacyFreeText, is: .freeText)
    }

    func testEditableAnnotationIdentityRejectsExternalAndMismatchedAnnotations() {
        let annotations: [PDFAnnotation] = [
            annotation(type: .freeText, name: nil),
            annotation(type: .widget, name: nil),
            annotation(type: .ink, name: nil),
            annotation(type: .highlight, name: nil),
            annotation(type: .freeText, name: "HwattakPDF-Image-wrong-type"),
            annotation(type: .freeText, name: "HwattakPDF-Signature-wrong-type"),
            annotation(type: .stamp, name: "HwattakPDF-Annotation-wrong-type"),
        ]

        for annotation in annotations {
            XCTAssertNil(
                EditableAnnotationIdentity.kind(of: annotation),
                "Unexpectedly classified \(annotation.type ?? "unknown") annotation"
            )
        }
    }

    func testEditableAnnotationMarkersAndBoundsSurvivePDFDataRoundTrip() throws {
        let pageImage = NSImage(size: CGSize(width: 300, height: 400), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: pageImage))
        let fixtures: [(kind: EditableAnnotationKind, type: PDFAnnotationSubtype, bounds: CGRect)] = [
            (.image, .stamp, CGRect(x: 20, y: 30, width: 80, height: 60)),
            (.signature, .stamp, CGRect(x: 45, y: 125, width: 140, height: 50)),
            (.freeText, .freeText, CGRect(x: 70, y: 210, width: 170, height: 42)),
        ]

        for fixture in fixtures {
            let annotation = annotation(type: fixture.type, name: nil, bounds: fixture.bounds)
            if fixture.kind == .freeText {
                annotation.contents = "Round-trip text"
            }
            EditableAnnotationIdentity.assign(fixture.kind, to: annotation)
            page.addAnnotation(annotation)
        }

        let document = PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        let reopenedPage = try XCTUnwrap(reopened.page(at: 0))

        let editableAnnotations = reopenedPage.annotations.filter {
            EditableAnnotationIdentity.kind(of: $0) != nil
        }
        XCTAssertEqual(editableAnnotations.count, fixtures.count)

        for fixture in fixtures {
            let reopenedAnnotation = try XCTUnwrap(editableAnnotations.first(where: {
                EditableAnnotationIdentity.kind(of: $0) == fixture.kind
            }))
            assertKind(of: reopenedAnnotation, is: fixture.kind)
            assertBounds(reopenedAnnotation.bounds, equalTo: fixture.bounds)
        }
    }

    @MainActor
    func testCancellingExistingExternalFreeTextDoesNotAdoptOrDirtyIt() {
        let workspace = PDFWorkspaceState()
        let externalFreeText = annotation(type: .freeText, name: nil)
        externalFreeText.contents = "External text"

        workspace.requestTextEdit(
            pageIndex: 0,
            point: CGPoint(x: 30, y: 40),
            annotation: externalFreeText
        )

        XCTAssertNotNil(workspace.pendingTextEdit)
        assertUnadopted(externalFreeText)

        workspace.cancelPendingText()

        XCTAssertNil(workspace.pendingTextEdit)
        assertUnadopted(externalFreeText)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testCommittingExistingExternalFreeTextAdoptsAndUpdatesIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibePDF-External-FreeText-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("external-free-text.pdf")

        let source = PDFDocument()
        let pageImage = NSImage(size: CGSize(width: 300, height: 400), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: pageImage))
        let externalFreeText = annotation(
            type: .freeText,
            name: nil,
            bounds: CGRect(x: 40, y: 180, width: 160, height: 48)
        )
        externalFreeText.contents = "Before edit"
        page.addAnnotation(externalFreeText)
        source.insert(page, at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.activeTool = .text
        let reopenedPage = try XCTUnwrap(workspace.document?.page(at: 0))
        let reopenedFreeText = try XCTUnwrap(reopenedPage.annotations.first(where: {
            $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "FreeText"
        }))
        assertUnadopted(reopenedFreeText)
        XCTAssertFalse(workspace.isDirty)

        workspace.requestTextEdit(
            pageIndex: 0,
            point: CGPoint(x: 50, y: 190),
            annotation: reopenedFreeText
        )
        workspace.commitPendingText("Updated external sentence")

        XCTAssertEqual(reopenedFreeText.contents, "Updated external sentence")
        XCTAssertNotNil(reopenedFreeText.value(forAnnotationKey: .name) as? String)
        assertKind(of: reopenedFreeText, is: .freeText)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.activeTool, .select)
        XCTAssertNil(workspace.pendingTextEdit)
    }

    func testMovingImageBoundsClampsEveryEdgeToThePage() {
        let pageBounds = CGRect(x: 10, y: 20, width: 200, height: 300)
        let original = CGRect(x: 40, y: 70, width: 80, height: 100)

        XCTAssertEqual(
            ImageAnnotationGeometry.movedBounds(
                original,
                translation: CGSize(width: -100, height: 500),
                within: pageBounds
            ),
            CGRect(x: 10, y: 220, width: 80, height: 100)
        )
    }

    func testCornerResizePreservesAspectRatioAndStaysInsidePage() {
        let resized = ImageAnnotationGeometry.resizedBounds(
            CGRect(x: 50, y: 50, width: 100, height: 50),
            handle: .topRight,
            draggedTo: CGPoint(x: 290, y: 260),
            within: CGRect(x: 0, y: 0, width: 300, height: 200),
            preservingAspectRatio: true
        )

        XCTAssertEqual(resized.minX, 50, accuracy: 0.000_001)
        XCTAssertEqual(resized.minY, 50, accuracy: 0.000_001)
        XCTAssertEqual(resized.width / resized.height, 2, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(resized.maxX, 300)
        XCTAssertLessThanOrEqual(resized.maxY, 200)
    }

    func testCropRectMapsDisplayedSubrectangleIntoExistingImageCrop() {
        let crop = ImageAnnotationGeometry.cropRect(
            CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6),
            displayedIn: CGRect(x: 100, y: 200, width: 400, height: 300),
            croppedTo: CGRect(x: 200, y: 250, width: 200, height: 150)
        )

        XCTAssertEqual(crop.minX, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(crop.minY, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(crop.width, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(crop.height, 0.3, accuracy: 0.000_001)
    }

    func testLayerOrderingSupportsSingleStepAndEdgeCommands() {
        let values = ["back", "selected", "front"]

        XCTAssertEqual(
            ImageLayerOrder.reordered(values, selectedIndex: 1, command: .bringForward),
            ["back", "front", "selected"]
        )
        XCTAssertEqual(
            ImageLayerOrder.reordered(values, selectedIndex: 1, command: .sendBackward),
            ["selected", "back", "front"]
        )
        XCTAssertEqual(
            ImageLayerOrder.reordered(values, selectedIndex: 1, command: .bringToFront),
            ["back", "front", "selected"]
        )
        XCTAssertEqual(
            ImageLayerOrder.reordered(values, selectedIndex: 1, command: .sendToBack),
            ["selected", "back", "front"]
        )
    }

    @MainActor
    func testWorkspaceReordersOnlyEditableImagesAndMarksDocumentDirty() throws {
        let pageImage = NSImage(size: CGSize(width: 300, height: 400), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: pageImage))
        let first = editableImageAnnotation(bounds: CGRect(x: 20, y: 20, width: 80, height: 60))
        let note = PDFAnnotation(
            bounds: CGRect(x: 30, y: 100, width: 100, height: 30),
            forType: .freeText,
            withProperties: nil
        )
        let signature = annotation(
            type: .stamp,
            name: "HwattakPDF-Signature-layer-order",
            bounds: CGRect(x: 45, y: 145, width: 100, height: 40)
        )
        let appFreeText = annotation(
            type: .freeText,
            name: "HwattakPDF-Annotation-layer-order",
            bounds: CGRect(x: 55, y: 195, width: 120, height: 40)
        )
        let second = editableImageAnnotation(bounds: CGRect(x: 60, y: 50, width: 80, height: 60))
        page.addAnnotation(first)
        page.addAnnotation(note)
        page.addAnnotation(signature)
        page.addAnnotation(appFreeText)
        page.addAnnotation(second)

        let workspace = PDFWorkspaceState()
        workspace.setMode(.editing)
        XCTAssertTrue(workspace.reorderImageAnnotation(first, on: page, command: .bringToFront))

        let images = page.annotations.filter(ImageAnnotationIdentity.isEditableImage)
        XCTAssertTrue(images[0] === second)
        XCTAssertTrue(images[1] === first)
        XCTAssertTrue(page.annotations.contains(where: { $0 === note }))
        XCTAssertTrue(page.annotations.contains(where: { $0 === signature }))
        XCTAssertTrue(page.annotations.contains(where: { $0 === appFreeText }))
        XCTAssertFalse(ImageAnnotationIdentity.isEditableImage(signature))
        XCTAssertFalse(ImageAnnotationIdentity.isEditableImage(appFreeText))
        assertKind(of: signature, is: .signature)
        assertKind(of: appFreeText, is: .freeText)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(workspace.statusMessage, "이미지를 맨 앞으로 가져왔습니다.")
    }

    @MainActor
    func testViewerAndStudyModelBoundariesRejectImageMutationsWithoutDirtying() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Image-Mode-Guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pdfURL = directory.appendingPathComponent("fixture.pdf")
        let imageURL = directory.appendingPathComponent("insert.png")

        let pageImage = NSImage(size: CGSize(width: 300, height: 400), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let source = PDFDocument()
        source.insert(try XCTUnwrap(PDFPage(image: pageImage)), at: 0)
        XCTAssertTrue(source.write(to: pdfURL))
        try writePNG(quarterStripedImage(width: 120, height: 60), to: imageURL)

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: pdfURL))
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let first = editableImageAnnotation(bounds: CGRect(x: 20, y: 20, width: 80, height: 60))
        let second = editableImageAnnotation(bounds: CGRect(x: 120, y: 20, width: 80, height: 60))
        page.addAnnotation(first)
        page.addAnnotation(second)
        let originalOrder = page.annotations

        for deniedMode in [PDFWorkspaceMode.viewer, .study] {
            workspace.setMode(deniedMode)
            XCTAssertFalse(
                workspace.reorderImageAnnotation(first, on: page, command: .bringToFront)
            )
            XCTAssertFalse(workspace.deleteImageAnnotation(first, on: page))
            workspace.insertImage(url: imageURL)

            XCTAssertEqual(page.annotations.count, originalOrder.count)
            XCTAssertTrue(
                zip(page.annotations, originalOrder).allSatisfy { $0 === $1 },
                "\(deniedMode) must leave image content and layer order untouched."
            )
            XCTAssertFalse(workspace.isDirty)
            XCTAssertFalse(workspace.canUndo)
        }
    }

    private func annotation(
        type: PDFAnnotationSubtype,
        name: String?,
        bounds: CGRect = CGRect(x: 20, y: 20, width: 80, height: 60)
    ) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
        if let name {
            annotation.setValue(name, forAnnotationKey: .name)
        }
        return annotation
    }

    private func assertKind(
        of annotation: PDFAnnotation,
        is expected: EditableAnnotationKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual = EditableAnnotationIdentity.kind(of: annotation) else {
            XCTFail("Expected editable annotation kind, got nil", file: file, line: line)
            return
        }

        switch (actual, expected) {
        case (.image, .image), (.signature, .signature), (.freeText, .freeText):
            break
        default:
            XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    private func assertBounds(
        _ actual: CGRect,
        equalTo expected: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.001, file: file, line: line)
    }

    private func assertUnadopted(
        _ annotation: PDFAnnotation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let markerKey = PDFAnnotationKey(rawValue: "/HwattakPDFKind")
        XCTAssertNil(annotation.value(forAnnotationKey: .name), file: file, line: line)
        XCTAssertNil(annotation.value(forAnnotationKey: markerKey), file: file, line: line)
        XCTAssertNil(EditableAnnotationIdentity.kind(of: annotation), file: file, line: line)
    }

    @MainActor
    private struct OverlayDragFixture {
        let workspace: PDFWorkspaceState
        let page: PDFPage
        let annotation: ImageStampAnnotation
        let pdfView: InteractivePDFView
        let overlay: PDFAnnotationEditingOverlayView
        let deactivationToken: UUID

        func detachOverlays() {
            // PDFKit owns private subviews with AppKit notifications. Explicitly
            // detach our observers before this headless fixture is released so
            // a later form-field test in the same xctest process cannot receive
            // a callback through a stale overlay.
            pdfView.prepareInlineTextEditingOverlayForRemoval()
            pdfView.prepareAnnotationEditingOverlayForRemoval()
            workspace.removeDeactivationCommitHandler(id: deactivationToken)
        }
    }

    @MainActor
    private func makeOverlayDragFixture() throws -> OverlayDragFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Live-Image-Drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf")

        let blankPageImage = NSImage(
            size: CGSize(width: 300, height: 400),
            flipped: false
        ) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let source = PDFDocument()
        source.insert(try XCTUnwrap(PDFPage(image: blankPageImage)), at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        workspace.activeTool = .select
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let stampImage = NSImage(size: CGSize(width: 100, height: 80), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let annotation = ImageStampAnnotation(
            image: stampImage,
            bounds: CGRect(x: 80, y: 140, width: 100, height: 80)
        )
        _ = ImageAnnotationIdentity.assign(to: annotation)
        annotation.modificationDate = Date(timeIntervalSince1970: 1_700_000_000)
        page.addAnnotation(annotation)

        let pdfView = InteractivePDFView(
            frame: CGRect(x: 0, y: 0, width: 500, height: 600)
        )
        pdfView.displayBox = .cropBox
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.document = workspace.document
        pdfView.autoScales = true
        pdfView.go(to: page)
        pdfView.layoutDocumentView()
        pdfView.layoutSubtreeIfNeeded()
        pdfView.configure(with: workspace)
        let overlay = try XCTUnwrap(
            pdfView.subviews.compactMap { $0 as? PDFAnnotationEditingOverlayView }.last
        )
        overlay.layoutSubtreeIfNeeded()
        let deactivationToken = UUID()
        workspace.installDeactivationCommitHandler(id: deactivationToken) { [weak pdfView] in
            pdfView?.commitAnnotationEditingBeforeDeactivation()
        }

        return OverlayDragFixture(
            workspace: workspace,
            page: page,
            annotation: annotation,
            pdfView: pdfView,
            overlay: overlay,
            deactivationToken: deactivationToken
        )
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        pagePoint: CGPoint,
        modifierFlags: NSEvent.ModifierFlags = [],
        fixture: OverlayDragFixture
    ) throws -> NSEvent {
        let viewPoint = fixture.pdfView.convert(pagePoint, from: fixture.page)
        let windowPoint = fixture.pdfView.convert(viewPoint, to: nil)
        return try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        characters: String = "",
        modifierFlags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func editableImageAnnotation(bounds: CGRect) -> ImageStampAnnotation {
        let image = NSImage(size: CGSize(width: 80, height: 60), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let annotation = ImageStampAnnotation(image: image, bounds: bounds)
        _ = ImageAnnotationIdentity.assign(to: annotation)
        return annotation
    }

    /// Builds an exact 1x bitmap-backed NSImage. Avoiding a resolution-
    /// independent drawing-only NSImage makes the expected PDF XObject size a
    /// stable security assertion on both Retina and non-Retina test hosts.
    private func quarterStripedImage(width: Int, height: Int) throws -> NSImage {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor.systemRed.setFill()
        CGRect(x: 0, y: 0, width: width / 4, height: height).fill()
        NSColor.systemGreen.setFill()
        CGRect(x: width / 4, y: 0, width: width / 2, height: height).fill()
        NSColor.systemBlue.setFill()
        CGRect(x: width * 3 / 4, y: 0, width: width / 4, height: height).fill()
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(bitmap)
        return image
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url, options: [.atomic])
    }

    private func appearanceImageXObjects(
        in data: Data,
        annotationIndex: Int
    ) throws -> [PDFImageXObjectMetadata] {
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(document.page(at: 1))
        let pageDictionary = try XCTUnwrap(page.dictionary)
        var annotations: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(pageDictionary, "Annots", &annotations))
        let annotationArray = try XCTUnwrap(annotations)
        var annotationDictionary: CGPDFDictionaryRef?
        XCTAssertTrue(
            CGPDFArrayGetDictionary(annotationArray, annotationIndex, &annotationDictionary)
        )
        var appearanceDictionary: CGPDFDictionaryRef?
        XCTAssertTrue(
            CGPDFDictionaryGetDictionary(
                try XCTUnwrap(annotationDictionary),
                "AP",
                &appearanceDictionary
            )
        )
        var normalAppearance: CGPDFStreamRef?
        XCTAssertTrue(
            CGPDFDictionaryGetStream(
                try XCTUnwrap(appearanceDictionary),
                "N",
                &normalAppearance
            )
        )
        let streamDictionary = try XCTUnwrap(
            CGPDFStreamGetDictionary(try XCTUnwrap(normalAppearance))
        )
        var resources: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(streamDictionary, "Resources", &resources))

        let collector = PDFImageXObjectCollector()
        collectPDFImageXObjects(
            in: try XCTUnwrap(resources),
            collector: collector
        )
        return collector.images
    }

    private func renderedPageColor(_ page: PDFPage, at point: CGPoint) throws -> NSColor {
        let bounds = page.bounds(for: .cropBox)
        let width = max(1, Int(ceil(bounds.width)))
        let height = max(1, Int(ceil(bounds.height)))
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        graphics.cgContext.setFillColor(NSColor.white.cgColor)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .cropBox, to: graphics.cgContext)
        let sampled = try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y)))
        return try XCTUnwrap(sampled.usingColorSpace(.deviceRGB))
    }
}

private struct PDFImageXObjectMetadata: Equatable, CustomStringConvertible {
    let width: Int
    let height: Int

    var description: String { "\(width)x\(height)" }
}

private final class PDFImageXObjectCollector {
    var images: [PDFImageXObjectMetadata] = []
}

/// Traverses an appearance resource dictionary. PDF generators may wrap an
/// image in one or more Form XObjects, so looking only at the first resource
/// would make the privacy regression test dependent on a PDFKit implementation
/// detail rather than on the bytes a recipient can actually extract.
private func collectPDFImageXObjects(
    in resources: CGPDFDictionaryRef,
    collector: PDFImageXObjectCollector
) {
    var xObjects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else {
        return
    }
    CGPDFDictionaryApplyFunction(
        xObjects,
        inspectPDFXObject,
        Unmanaged.passUnretained(collector).toOpaque()
    )
}

private func inspectPDFXObject(
    _ key: UnsafePointer<CChar>,
    _ object: CGPDFObjectRef,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let collector = Unmanaged<PDFImageXObjectCollector>
        .fromOpaque(context)
        .takeUnretainedValue()
    var stream: CGPDFStreamRef?
    guard
        CGPDFObjectGetValue(object, .stream, &stream),
        let stream,
        let dictionary = CGPDFStreamGetDictionary(stream)
    else {
        return
    }

    var subtypePointer: UnsafePointer<CChar>?
    guard
        CGPDFDictionaryGetName(dictionary, "Subtype", &subtypePointer),
        let subtypePointer
    else {
        return
    }
    let subtype = String(cString: subtypePointer)
    if subtype == "Image" {
        var width = 0
        var height = 0
        if
            CGPDFDictionaryGetInteger(dictionary, "Width", &width),
            CGPDFDictionaryGetInteger(dictionary, "Height", &height)
        {
            collector.images.append(PDFImageXObjectMetadata(width: width, height: height))
        }
    } else if subtype == "Form" {
        var nestedResources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nestedResources),
           let nestedResources
        {
            collectPDFImageXObjects(in: nestedResources, collector: collector)
        }
    }
}

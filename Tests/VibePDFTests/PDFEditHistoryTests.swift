// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreText
import PDFKit
import XCTest
@testable import VibePDF

final class PDFEditHistoryTests: XCTestCase {
    @MainActor
    func testHistoryKeepsOnlyLatestTwentyTwoCommandsAndSupportsRedo() throws {
        let history = PDFEditHistory(limit: 22)
        let navigation = PDFEditNavigationSnapshot(currentPageIndex: 0, selectedPages: [0])
        var value = 0

        for nextValue in 1...25 {
            let previousValue = nextValue - 1
            value = nextValue
            history.register(
                actionName: "edit \(nextValue)",
                beforeNavigation: navigation,
                afterNavigation: navigation,
                undo: { value = previousValue },
                redo: { value = nextValue }
            )
        }

        XCTAssertEqual(history.undoCount, 22)
        XCTAssertEqual(history.undoActionName, "edit 25")
        for _ in 0..<22 {
            _ = try history.undo()
        }
        XCTAssertEqual(value, 3, "The three evicted edits remain part of the document state.")
        XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redoCount, 22)

        for _ in 0..<22 {
            _ = try history.redo()
        }
        XCTAssertEqual(value, 25)
        XCTAssertFalse(history.canRedo)
    }

    @MainActor
    func testNewEditClearsRedoAndRetainedPageBudgetTrimsOldestCommands() throws {
        let history = PDFEditHistory(limit: 22, retainedPageLimit: 3)
        let navigation = PDFEditNavigationSnapshot(currentPageIndex: 0, selectedPages: [0])
        var value = 0

        func register(_ name: String, value next: Int, cost: Int) {
            let previous = value
            value = next
            history.register(
                actionName: name,
                beforeNavigation: navigation,
                afterNavigation: navigation,
                retainedPageCost: cost,
                undo: { value = previous },
                redo: { value = next }
            )
        }

        register("two pages", value: 1, cost: 2)
        register("two newer pages", value: 2, cost: 2)
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.undoActionName, "two newer pages")

        _ = try history.undo()
        XCTAssertTrue(history.canRedo)
        register("branch", value: 3, cost: 0)
        XCTAssertFalse(history.canRedo)

        register("oversized", value: 4, cost: 10)
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.undoActionName, "oversized")
        register("after oversized", value: 5, cost: 0)
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.undoActionName, "after oversized")
    }

    @MainActor
    func testFailedCommandDoesNotMoveHistoryStacksOrSavedToken() {
        enum ExpectedFailure: Error { case failed }
        let history = PDFEditHistory()
        let navigation = PDFEditNavigationSnapshot(currentPageIndex: 0, selectedPages: [0])
        history.register(
            actionName: "failing edit",
            beforeNavigation: navigation,
            afterNavigation: navigation,
            undo: { throw ExpectedFailure.failed },
            redo: {}
        )

        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertEqual(history.redoCount, 0)
        XCTAssertFalse(history.isAtSavedState)
    }

    @MainActor
    func testSavedCheckpointTracksUndoAndRedoPosition() throws {
        let fixture = try makeWorkspace(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace

        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.saveSynchronously())
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)

        workspace.undo()
        XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 0)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canRedo)

        workspace.redo()
        XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 90)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testPenThenPageDeleteUsesExactPageAndAnnotationIdentity() throws {
        let fixture = try makeWorkspace(pageCount: 2)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let ink = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 40, height: 20),
            forType: .ink,
            withProperties: nil
        )
        page.addAnnotation(ink)
        workspace.registerAddedAnnotation(ink, on: page, message: "pen")
        workspace.selectedPages = [0]

        workspace.deleteSelectedPages()
        XCTAssertEqual(workspace.pageCount, 1)
        workspace.undo()
        XCTAssertEqual(workspace.pageCount, 2)
        XCTAssertTrue(workspace.document?.page(at: 0) === page)
        XCTAssertTrue(page.annotations.contains(where: { $0 === ink }))

        workspace.undo()
        XCTAssertFalse(page.annotations.contains(where: { $0 === ink }))
        workspace.redo()
        XCTAssertTrue(page.annotations.contains(where: { $0 === ink }))
        workspace.redo()
        XCTAssertEqual(workspace.pageCount, 1)
    }

    @MainActor
    func testMergeAnnotationUndoRedoKeepsExactMergedPageIdentity() throws {
        let fixture = try makeWorkspace(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let mergeURL = fixture.directory.appendingPathComponent("merge.pdf")
        try writePDF(pageCount: 1, to: mergeURL)
        let workspace = fixture.workspace

        workspace.merge(urls: [mergeURL])
        let mergedPage = try XCTUnwrap(workspace.document?.page(at: 1))
        let ink = PDFAnnotation(
            bounds: CGRect(x: 12, y: 12, width: 30, height: 20),
            forType: .ink,
            withProperties: nil
        )
        mergedPage.addAnnotation(ink)
        workspace.registerAddedAnnotation(ink, on: mergedPage, message: "pen")

        workspace.undo()
        workspace.undo()
        XCTAssertEqual(workspace.pageCount, 1)
        workspace.redo()
        XCTAssertEqual(workspace.pageCount, 2)
        XCTAssertTrue(workspace.document?.page(at: 1) === mergedPage)
        workspace.redo()
        XCTAssertTrue(mergedPage.annotations.contains(where: { $0 === ink }))
    }

    @MainActor
    func testAnnotationLayerAndDeletionUndoRestoreAbsoluteInterleaving() throws {
        let fixture = try makeWorkspace(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let image = solidImage()
        let imageA = ImageStampAnnotation(image: image, bounds: CGRect(x: 10, y: 10, width: 30, height: 30))
        let signature = ImageStampAnnotation(image: image, bounds: CGRect(x: 50, y: 10, width: 30, height: 30))
        let imageB = ImageStampAnnotation(image: image, bounds: CGRect(x: 90, y: 10, width: 30, height: 30))
        _ = ImageAnnotationIdentity.assign(to: imageA)
        signature.setValue("HwattakPDF-Signature-test", forAnnotationKey: .name)
        EditableAnnotationIdentity.assign(.signature, to: signature)
        _ = ImageAnnotationIdentity.assign(to: imageB)
        [imageA, signature, imageB].forEach(page.addAnnotation)

        XCTAssertTrue(workspace.reorderImageAnnotation(imageA, on: page, command: .bringToFront))
        assertIdentityOrder(page.annotations, [imageB, signature, imageA])
        workspace.undo()
        assertIdentityOrder(page.annotations, [imageA, signature, imageB])
        workspace.redo()
        assertIdentityOrder(page.annotations, [imageB, signature, imageA])
        workspace.undo()

        let originalIndex = try XCTUnwrap(page.annotations.firstIndex(where: { $0 === signature }))
        page.removeAnnotation(signature)
        workspace.registerRemovedAnnotation(
            signature,
            from: page,
            originalIndex: originalIndex,
            message: "delete"
        )
        workspace.undo()
        assertIdentityOrder(page.annotations, [imageA, signature, imageB])
    }

    @MainActor
    func testGeometryNoOpDoesNotCreateHistoryAndFailureIsAtomic() throws {
        let fixture = try makeWorkspace(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = ImageStampAnnotation(
            image: solidImage(),
            bounds: CGRect(x: 10, y: 10, width: 40, height: 40)
        )
        _ = ImageAnnotationIdentity.assign(to: annotation)
        page.addAnnotation(annotation)
        let originalBounds = annotation.bounds
        let originalDate = annotation.modificationDate

        annotation.bounds.origin.x += 0.005
        annotation.modificationDate = Date(timeIntervalSince1970: 1_900_000_000)
        workspace.registerAnnotationGeometryChange(
            annotation,
            on: page,
            from: originalBounds,
            originalModificationDate: originalDate,
            message: "no-op"
        )
        XCTAssertFalse(workspace.canUndo)
        XCTAssertEqual(annotation.bounds, originalBounds)
        XCTAssertEqual(annotation.modificationDate, originalDate)

        annotation.bounds.origin.x += 20
        annotation.modificationDate = Date()
        let finalBounds = annotation.bounds
        let finalDate = annotation.modificationDate
        workspace.registerAnnotationGeometryChange(
            annotation,
            on: page,
            from: originalBounds,
            originalModificationDate: originalDate,
            message: "move"
        )
        XCTAssertTrue(workspace.canUndo)

        workspace.undo()
        XCTAssertEqual(annotation.bounds, originalBounds)
        XCTAssertEqual(annotation.modificationDate, originalDate)
        workspace.redo()
        XCTAssertEqual(annotation.bounds, finalBounds)
        XCTAssertEqual(annotation.modificationDate, finalDate)

        page.removeAnnotation(annotation)
        workspace.undo()
        XCTAssertTrue(workspace.canUndo, "A failed inverse must remain on the undo stack.")
        XCTAssertFalse(workspace.canRedo)
        XCTAssertEqual(annotation.bounds, finalBounds)
        XCTAssertNotNil(workspace.presentedError)
    }

    @MainActor
    func testTextAndCheckboxWidgetValuesUndoSemantically() throws {
        let fixture = try makeFormWorkspace()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let text = try XCTUnwrap(page.annotations.first(where: { $0.fieldName == "name" }))
        let checkbox = try XCTUnwrap(page.annotations.first(where: { $0.fieldName == "agree" }))

        text.widgetStringValue = "after"
        checkbox.buttonWidgetState = .onState
        workspace.synchronizeWidgetValues(on: page)
        XCTAssertTrue(workspace.canUndo)
        XCTAssertTrue(workspace.isDirty)

        workspace.undo()
        XCTAssertEqual(text.widgetStringValue, "before")
        XCTAssertEqual(checkbox.buttonWidgetState, .offState)
        XCTAssertFalse(workspace.isDirty)

        workspace.redo()
        XCTAssertEqual(text.widgetStringValue, "after")
        XCTAssertEqual(checkbox.buttonWidgetState, .onState)
        XCTAssertTrue(workspace.isDirty)

        XCTAssertTrue(workspace.saveSynchronously())
        XCTAssertFalse(workspace.isDirty)
        workspace.undo()
        XCTAssertTrue(workspace.isDirty)
        workspace.redo()
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testFieldEditorEndNotificationCommitsOneFormCommandAndDetachesObserver() throws {
        let fixture = try makeFormWorkspace()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let widget = try XCTUnwrap(page.annotations.first(where: { $0.fieldName == "name" }))
        let pdfView = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        // This test exercises field-editor notification routing through the
        // coordinator. Giving the offscreen PDFView a document starts PDFKit
        // tile work that can outlive XCTest on macOS 15; the coordinator uses
        // its workspace state for the semantic commit and needs no rendered
        // page here.
        let owner = UndoFieldEditorOwnerView(frame: .zero)
        pdfView.addSubview(owner)
        let fieldEditor = NSTextView(frame: .zero)
        fieldEditor.isFieldEditor = true
        fieldEditor.delegate = owner
        let coordinator = PDFKitViewer.Coordinator(state: workspace)
        coordinator.attach(to: pdfView)

        widget.widgetStringValue = "ended edit"
        NotificationCenter.default.post(
            name: NSText.didEndEditingNotification,
            object: fieldEditor
        )
        workspace.rotateSelectedPages(clockwise: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(workspace.canUndo)
        XCTAssertTrue(workspace.isDirty)
        workspace.undo()
        XCTAssertEqual(page.rotation, 0)
        XCTAssertEqual(widget.widgetStringValue, "ended edit")
        workspace.undo()
        XCTAssertEqual(widget.widgetStringValue, "before")
        XCTAssertFalse(workspace.isDirty)

        coordinator.detach()
        widget.widgetStringValue = "after detach"
        NotificationCenter.default.post(
            name: NSText.didEndEditingNotification,
            object: fieldEditor
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(workspace.canUndo)
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testCleanHibernateReleasesHistoryBeforeFreshResume() throws {
        let fixture = try makeWorkspace(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.rotateSelectedPages(clockwise: true)
        XCTAssertTrue(workspace.saveSynchronously())
        XCTAssertTrue(workspace.canUndo)

        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertFalse(workspace.canUndo)
        XCTAssertNil(workspace.document)
        XCTAssertTrue(workspace.resumeIfNeeded())
        workspace.undo()
        XCTAssertEqual(workspace.document?.page(at: 0)?.rotation, 90)
    }

    @MainActor
    func testExistingFreeTextUndoRemovesAdoptionMetadata() throws {
        let fixture = try makeWorkspace(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 100, height: 40),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "old"
        page.addAnnotation(annotation)
        XCTAssertNil(annotation.value(forAnnotationKey: .name))
        XCTAssertNil(EditableAnnotationIdentity.storedKind(of: annotation))

        workspace.requestTextEdit(pageIndex: 0, point: .zero, annotation: annotation)
        workspace.commitPendingText("new")
        XCTAssertNotNil(annotation.value(forAnnotationKey: .name))
        XCTAssertEqual(EditableAnnotationIdentity.storedKind(of: annotation), .freeText)

        workspace.undo()
        XCTAssertEqual(annotation.contents, "old")
        XCTAssertNil(annotation.value(forAnnotationKey: .name))
        XCTAssertNil(EditableAnnotationIdentity.storedKind(of: annotation))
    }

    @MainActor
    func testNewTextSignatureAndImageAdditionsUndoAndRedo() throws {
        let fixture = try makeWorkspace(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))

        workspace.requestTextEdit(
            pageIndex: 0,
            point: CGPoint(x: 40, y: 160),
            annotation: nil
        )
        workspace.commitPendingText("new text")
        XCTAssertEqual(page.annotations.count, 1)

        let stroke = SignatureStroke(points: [
            SignaturePoint(x: 10, y: 10, pressure: 0.4, timestamp: 0),
            SignaturePoint(x: 80, y: 40, pressure: 0.7, timestamp: 0.1),
            SignaturePoint(x: 140, y: 20, pressure: 0.5, timestamp: 0.2),
        ])
        XCTAssertTrue(workspace.addSignature([stroke], canvasSize: CGSize(width: 180, height: 80)))
        XCTAssertEqual(page.annotations.count, 2)

        let imageURL = fixture.directory.appendingPathComponent("insert.png")
        try writePNG(solidImage(), to: imageURL)
        workspace.insertImage(url: imageURL)
        XCTAssertEqual(page.annotations.count, 3)

        workspace.undo()
        workspace.undo()
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
        workspace.redo()
        workspace.redo()
        workspace.redo()
        XCTAssertEqual(page.annotations.count, 3)
    }

    @MainActor
    func testHighlightSelectionUndoAndRedoAsOneCommand() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-UndoHighlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("text.pdf")
        try writeTextPDF(["highlight this phrase"], to: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.currentSelection = try XCTUnwrap(
            workspace.document?.findString("highlight", withOptions: []).first
        )

        workspace.highlightCurrentSelection()
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let highlights = page.annotations.filter {
            $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Highlight"
        }
        XCTAssertFalse(highlights.isEmpty)
        XCTAssertTrue(workspace.canUndo)

        workspace.undo()
        XCTAssertFalse(page.annotations.contains(where: { annotation in
            highlights.contains(where: { $0 === annotation })
        }))
        workspace.redo()
        XCTAssertTrue(highlights.allSatisfy { highlight in
            page.annotations.contains(where: { $0 === highlight })
        })
    }

    @MainActor
    func testViewerAndEditingHighlightUseSelectedHueAndPreserveSavedCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HwattakPDF-Selected-Highlight-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        // A device-RGB color avoids dynamic system-color differences between
        // light/dark appearances and makes a silently restored yellow default
        // immediately visible in the component assertions below.
        let selectedColor = NSColor(
            deviceRed: 0.16,
            green: 0.63,
            blue: 0.84,
            alpha: 1
        )
        let expectedRGB = try XCTUnwrap(selectedColor.usingColorSpace(.deviceRGB))

        for mode in [PDFWorkspaceMode.viewer, .editing] {
            let url = directory.appendingPathComponent("\(mode.rawValue).pdf")
            try writeTextPDF(["selected highlight color"], to: url)
            let workspace = PDFWorkspaceState()
            XCTAssertTrue(workspace.open(url: url))
            workspace.setMode(mode)
            workspace.studyMarkupStyle = StudyMarkupStyle(
                kind: .highlight,
                color: selectedColor,
                thickness: 5,
                // Viewer/Editing deliberately keep a native, opaque PDF
                // Highlight. Only the hue is shared with the style picker.
                opacity: 0.23
            )
            workspace.currentSelection = try XCTUnwrap(
                workspace.document?.findString("highlight", withOptions: []).first
            )
            let page = try XCTUnwrap(workspace.document?.page(at: 0))
            let revisionBeforeHighlight = workspace.revision

            // Exercise the same mode-aware entry point used by the toolbar and
            // Shift-Command-H, rather than bypassing it with a color argument.
            workspace.applyCurrentModeHighlight()

            let highlight = try XCTUnwrap(page.annotations.first { annotation in
                annotation.type?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                ) == "Highlight"
            })
            let actualRGB = try XCTUnwrap(highlight.color.usingColorSpace(.deviceRGB))
            XCTAssertEqual(actualRGB.redComponent, expectedRGB.redComponent, accuracy: 0.001)
            XCTAssertEqual(actualRGB.greenComponent, expectedRGB.greenComponent, accuracy: 0.001)
            XCTAssertEqual(actualRGB.blueComponent, expectedRGB.blueComponent, accuracy: 0.001)
            XCTAssertEqual(
                actualRGB.alphaComponent,
                1,
                accuracy: 0.001,
                "Viewer/Editing native highlights must not inherit Study opacity."
            )
            XCTAssertNil(workspace.currentSelection)
            XCTAssertNotEqual(workspace.revision, revisionBeforeHighlight)
            XCTAssertTrue(workspace.isDirty)
            XCTAssertTrue(workspace.canUndo)
            XCTAssertFalse(workspace.canRedo)
            XCTAssertEqual(workspace.undoActionName, L10n.string("status.highlight_added"))

            // With no older commands, one Undo must remove every annotation
            // created for the selection and return to the opening checkpoint.
            workspace.undo()
            XCTAssertFalse(page.annotations.contains(where: { $0 === highlight }))
            XCTAssertFalse(workspace.isDirty)
            XCTAssertFalse(workspace.canUndo)
            XCTAssertTrue(workspace.canRedo)
            XCTAssertEqual(workspace.redoActionName, L10n.string("status.highlight_added"))

            workspace.redo()
            XCTAssertTrue(page.annotations.contains(where: { $0 === highlight }))
            XCTAssertTrue(workspace.isDirty)
            XCTAssertTrue(workspace.canUndo)
            XCTAssertFalse(workspace.canRedo)

            // Saving moves only the checkpoint; it must retain the reversible
            // command. Undoing away from the saved mark is dirty, while Redo
            // back to the exact saved state becomes clean again.
            XCTAssertTrue(workspace.saveSynchronously())
            XCTAssertFalse(workspace.isDirty)
            XCTAssertTrue(workspace.canUndo)
            workspace.undo()
            XCTAssertFalse(page.annotations.contains(where: { $0 === highlight }))
            XCTAssertTrue(workspace.isDirty)
            XCTAssertTrue(workspace.canRedo)
            workspace.redo()
            XCTAssertTrue(page.annotations.contains(where: { $0 === highlight }))
            XCTAssertFalse(workspace.isDirty)
        }
    }

    @MainActor
    func testStudyHighlightDispatcherUsesSelectedColorOpacityAndOneUndoStep() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HwattakPDF-Study-Selected-Highlight-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study-highlight.pdf")
        try writeTextPDF(["study highlight selection"], to: url)

        let selectedColor = NSColor(
            deviceRed: 0.77,
            green: 0.24,
            blue: 0.58,
            alpha: 1
        )
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.study)
        workspace.studyMarkupStyle = StudyMarkupStyle(
            kind: .highlight,
            color: selectedColor,
            thickness: 6.5,
            opacity: 0.31
        )
        workspace.currentSelection = try XCTUnwrap(
            workspace.document?.findString("highlight", withOptions: []).first
        )
        let page = try XCTUnwrap(workspace.document?.page(at: 0))

        workspace.applyCurrentModeHighlight()

        let annotation = try XCTUnwrap(page.annotations.first { annotation in
            (annotation as? StudyMarkupAnnotation)?.markupKind == .highlight
        })
        let studyHighlight = try XCTUnwrap(annotation as? StudyMarkupAnnotation)
        let expectedRGB = try XCTUnwrap(selectedColor.usingColorSpace(.deviceRGB))
        let actualRGB = try XCTUnwrap(studyHighlight.markupColor.usingColorSpace(.deviceRGB))
        XCTAssertEqual(actualRGB.redComponent, expectedRGB.redComponent, accuracy: 0.001)
        XCTAssertEqual(actualRGB.greenComponent, expectedRGB.greenComponent, accuracy: 0.001)
        XCTAssertEqual(actualRGB.blueComponent, expectedRGB.blueComponent, accuracy: 0.001)
        XCTAssertEqual(studyHighlight.markupOpacity, 0.31, accuracy: 0.001)
        XCTAssertEqual(studyHighlight.markupThickness, 6.5, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(studyHighlight.color.usingColorSpace(.deviceRGB)).alphaComponent,
            1,
            accuracy: 0.001,
            "Opacity belongs in the saved appearance and must not be applied twice through /C."
        )
        XCTAssertNil(workspace.currentSelection)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)
        XCTAssertFalse(workspace.canRedo)

        workspace.undo()
        XCTAssertFalse(page.annotations.contains(where: { $0 === studyHighlight }))
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertTrue(workspace.canRedo)

        workspace.redo()
        XCTAssertTrue(page.annotations.contains(where: { $0 === studyHighlight }))
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)
        XCTAssertFalse(workspace.canRedo)
        XCTAssertEqual(studyHighlight.markupOpacity, 0.31, accuracy: 0.001)
    }

    @MainActor
    func testStudyUnderlinePreservesStyleSerializationAndUndoHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-StudyUnderline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("underline.pdf")
        try writeTextPDF(["derive the result step by step"], to: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.study)
        workspace.currentSelection = try XCTUnwrap(
            workspace.document?.findString("result step", withOptions: []).first
        )
        let revisionBeforeMarkup = workspace.revision

        workspace.applyStudyMarkup(
            StudyMarkupStyle(
                kind: .underline,
                color: .systemBlue,
                thickness: 4.5,
                opacity: 0.35
            )
        )

        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let underline = try XCTUnwrap(page.annotations.first { annotation in
            (annotation as? StudyMarkupAnnotation)?.markupKind == .underline
        })
        XCTAssertEqual(try XCTUnwrap(underline.border).lineWidth, 4.5, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(underline as? StudyMarkupAnnotation).markupOpacity,
            0.35,
            accuracy: 0.01
        )
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)
        XCTAssertNotEqual(workspace.revision, revisionBeforeMarkup)

        // A round trip through PDF bytes checks the actual PDFKit serialization,
        // not merely the in-memory annotation object used by the workspace.
        let serialized = try XCTUnwrap(workspace.document?.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: serialized))
        let reopenedAnnotations = try XCTUnwrap(reopened.page(at: 0)?.annotations)
        let reopenedUnderline = try XCTUnwrap(
            reopenedAnnotations.first { annotation in
                annotation.type?.trimmingCharacters(
                    in: CharacterSet(charactersIn: "/")
                ) == "Stamp" && annotation.hasAppearanceStream
            },
            "The saved visual underline should be an appearance-backed Stamp."
        )
        XCTAssertEqual(try XCTUnwrap(reopenedUnderline.border).lineWidth, 4.5, accuracy: 0.001)
        XCTAssertTrue(
            reopenedUnderline.hasAppearanceStream,
            "The serialized annotation must carry the translucent custom appearance."
        )
        XCTAssertEqual(
            StudyMarkupAnnotationIdentity.kind(of: reopenedUnderline),
            .underline,
            "The standard Stamp /Name marker must survive PDFKit's custom-object rebuild."
        )

        workspace.undo()
        XCTAssertFalse(page.annotations.contains(where: { $0 === underline }))
        XCTAssertTrue(workspace.canRedo)
        workspace.redo()
        XCTAssertTrue(page.annotations.contains(where: { $0 === underline }))
        XCTAssertEqual(
            try XCTUnwrap(underline as? StudyMarkupAnnotation).markupOpacity,
            0.35,
            accuracy: 0.01
        )
    }

    @MainActor
    func testStudyHighlightClampsBandThicknessAndOpacity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-StudyHighlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("highlight.pdf")
        try writeTextPDF(["important learning point"], to: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.study)
        let selection = try XCTUnwrap(
            workspace.document?.findString("learning", withOptions: []).first
        )
        let line = try XCTUnwrap(selection.selectionsByLine().first)
        let page = try XCTUnwrap(line.pages.first)
        let originalHeight = line.bounds(for: page).height
        workspace.currentSelection = selection

        workspace.applyStudyMarkup(
            StudyMarkupStyle(
                kind: .highlight,
                color: .systemGreen,
                thickness: 3,
                opacity: 0.24
            )
        )

        let highlight = try XCTUnwrap(page.annotations.first { annotation in
            (annotation as? StudyMarkupAnnotation)?.markupKind == .highlight
        })
        XCTAssertEqual(highlight.bounds.height, min(originalHeight, 3), accuracy: 0.01)
        XCTAssertEqual(
            try XCTUnwrap(highlight as? StudyMarkupAnnotation).markupOpacity,
            0.24,
            accuracy: 0.01
        )

        let normalized = StudyMarkupStyle(
            kind: .underline,
            color: .red,
            thickness: 100,
            opacity: 0
        ).normalized
        XCTAssertEqual(normalized.thickness, StudyMarkupStyle.thicknessRange.upperBound)
        XCTAssertEqual(normalized.opacity, StudyMarkupStyle.opacityRange.lowerBound)
    }

    @MainActor
    func testStudyMarkupAppearanceKeepsTranslucencyAfterPDFRoundTrip() throws {
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: solidImage()))
        let annotation = StudyMarkupAnnotation(
            bounds: CGRect(x: 30, y: 90, width: 100, height: 40),
            style: StudyMarkupStyle(
                kind: .highlight,
                color: .systemRed,
                thickness: 12,
                opacity: 0.25
            )
        )
        page.addAnnotation(annotation)
        document.insert(page, at: 0)

        let serialized = try XCTUnwrap(document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: serialized))
        let reopenedPage = try XCTUnwrap(reopened.page(at: 0))
        let reopenedMarkup = try XCTUnwrap(reopenedPage.annotations.first)
        XCTAssertTrue(reopenedMarkup.hasAppearanceStream)
        XCTAssertEqual(StudyMarkupAnnotationIdentity.kind(of: reopenedMarkup), .highlight)

        // Render the reopened PDF, not the authoring subclass. A 25% red mark
        // over white should leave green and blue near 75%; an opaque fallback
        // would drive them near zero, and a missing appearance near 100%.
        let pixel = try renderedColor(
            on: reopenedPage,
            at: CGPoint(x: 80, y: 110)
        )
        let rgb = try XCTUnwrap(pixel.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(rgb.redComponent, 0.9)
        XCTAssertGreaterThan(rgb.greenComponent, 0.55)
        XCTAssertLessThan(rgb.greenComponent, 0.9)
        XCTAssertGreaterThan(rgb.blueComponent, 0.55)
        XCTAssertLessThan(rgb.blueComponent, 0.9)
    }

    @MainActor
    func testPageMoveUndoRedoPreservesPageIdentity() throws {
        let fixture = try makeWorkspace(pageCount: 3)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let first = try XCTUnwrap(workspace.document?.page(at: 0))
        let second = try XCTUnwrap(workspace.document?.page(at: 1))

        workspace.movePage(from: 0, before: 2)
        XCTAssertTrue(workspace.document?.page(at: 0) === second)
        XCTAssertTrue(workspace.document?.page(at: 1) === first)
        workspace.undo()
        XCTAssertTrue(workspace.document?.page(at: 0) === first)
        XCTAssertTrue(workspace.document?.page(at: 1) === second)
        workspace.redo()
        XCTAssertTrue(workspace.document?.page(at: 1) === first)
    }

    @MainActor
    func testCropGeometryUndoRedoRestoresBoundsCropAndDate() throws {
        let fixture = try makeWorkspace(pageCount: 1)
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = ImageStampAnnotation(
            image: solidImage(),
            bounds: CGRect(x: 10, y: 10, width: 100, height: 80)
        )
        _ = ImageAnnotationIdentity.assign(to: annotation)
        page.addAnnotation(annotation)
        let originalBounds = annotation.bounds
        let originalCrop = annotation.normalizedCropRect
        let originalDate = annotation.modificationDate
        let finalBounds = CGRect(x: 30, y: 20, width: 70, height: 60)
        let finalCrop = CGRect(x: 0.2, y: 0.1, width: 0.7, height: 0.75)
        annotation.bounds = finalBounds
        annotation.updateCropRect(finalCrop)
        let finalDate = annotation.modificationDate

        workspace.registerAnnotationGeometryChange(
            annotation,
            on: page,
            from: originalBounds,
            originalCropRect: originalCrop,
            originalModificationDate: originalDate,
            message: "crop"
        )
        workspace.undo()
        XCTAssertEqual(annotation.bounds, originalBounds)
        XCTAssertEqual(annotation.normalizedCropRect, originalCrop)
        XCTAssertEqual(annotation.modificationDate, originalDate)
        workspace.redo()
        XCTAssertEqual(annotation.bounds, finalBounds)
        XCTAssertEqual(annotation.normalizedCropRect, finalCrop)
        XCTAssertEqual(annotation.modificationDate, finalDate)
    }

    @MainActor
    func testPageMoveSettlesWidgetEditAndReprimesShiftedPages() throws {
        let fixture = try makeIndexedFormWorkspace()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let firstPage = fixture.pages[0]
        let secondPage = fixture.pages[1]
        let firstWidget = fixture.widgets[0]
        let commitToken = UUID()
        var commitCount = 0
        workspace.installDeactivationCommitHandler(id: commitToken) {
            commitCount += 1
            firstWidget.widgetStringValue = "changed before move"
        }

        workspace.movePage(from: 0, before: 2)
        XCTAssertEqual(commitCount, 1)
        XCTAssertTrue(workspace.document?.page(at: 0) === secondPage)
        XCTAssertTrue(workspace.document?.page(at: 1) === firstPage)
        // The shifted page was unchanged. Synchronizing it must only prime the
        // new index, not insert a phantom form command ahead of page undo.
        workspace.synchronizeWidgetValues(on: secondPage)

        workspace.undo()
        XCTAssertTrue(workspace.document?.page(at: 0) === firstPage)
        XCTAssertTrue(workspace.document?.page(at: 1) === secondPage)
        XCTAssertEqual(firstWidget.widgetStringValue, "changed before move")
        workspace.undo()
        XCTAssertEqual(firstWidget.widgetStringValue, "before-0")
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testPageDeleteSettlesWidgetEditAndReprimesRemainingPage() throws {
        let fixture = try makeIndexedFormWorkspace()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let firstPage = fixture.pages[0]
        let secondPage = fixture.pages[1]
        let firstWidget = fixture.widgets[0]
        firstWidget.widgetStringValue = "changed before delete"
        workspace.selectedPages = [0]

        workspace.deleteSelectedPages()
        XCTAssertEqual(workspace.pageCount, 1)
        XCTAssertTrue(workspace.document?.page(at: 0) === secondPage)
        workspace.synchronizeWidgetValues(on: secondPage)

        workspace.undo()
        XCTAssertEqual(workspace.pageCount, 2)
        XCTAssertTrue(workspace.document?.page(at: 0) === firstPage)
        XCTAssertEqual(firstWidget.widgetStringValue, "changed before delete")
        workspace.undo()
        XCTAssertEqual(firstWidget.widgetStringValue, "before-0")
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    func testMergeSettlesWidgetEditAndReprimesInsertedPageIndexes() throws {
        let fixture = try makeIndexedFormWorkspace()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let firstPage = fixture.pages[0]
        let firstWidget = fixture.widgets[0]
        let mergeURL = fixture.directory.appendingPathComponent("merge.pdf")
        try writePDF(pageCount: 1, to: mergeURL)
        firstWidget.widgetStringValue = "changed before merge"

        workspace.merge(urls: [mergeURL], insertionIndex: 0)
        XCTAssertEqual(workspace.pageCount, 3)
        XCTAssertTrue(workspace.document?.page(at: 1) === firstPage)
        workspace.synchronizeWidgetValues(on: firstPage)

        workspace.undo()
        XCTAssertEqual(workspace.pageCount, 2)
        XCTAssertTrue(workspace.document?.page(at: 0) === firstPage)
        XCTAssertEqual(firstWidget.widgetStringValue, "changed before merge")
        workspace.undo()
        XCTAssertEqual(firstWidget.widgetStringValue, "before-0")
        XCTAssertFalse(workspace.isDirty)
    }

    @MainActor
    private func makeWorkspace(pageCount: Int) throws -> (directory: URL, workspace: PDFWorkspaceState) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-UndoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("document.pdf")
        try writePDF(pageCount: pageCount, to: url)
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        // History fixtures exercise byte-changing page/annotation operations.
        // Make that authority explicit now that Viewer is read-focused.
        workspace.setMode(.editing)
        return (directory, workspace)
    }

    @MainActor
    private func makeFormWorkspace() throws -> (directory: URL, workspace: PDFWorkspaceState) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-UndoFormTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("form.pdf")
        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: solidImage()))
        let text = PDFAnnotation(
            bounds: CGRect(x: 10, y: 120, width: 120, height: 24),
            forType: .widget,
            withProperties: nil
        )
        text.widgetFieldType = .text
        text.fieldName = "name"
        text.widgetStringValue = "before"
        let checkbox = PDFAnnotation(
            bounds: CGRect(x: 10, y: 80, width: 24, height: 24),
            forType: .widget,
            withProperties: nil
        )
        checkbox.widgetFieldType = .button
        checkbox.widgetControlType = .checkBoxControl
        checkbox.fieldName = "agree"
        checkbox.buttonWidgetState = .offState
        page.addAnnotation(text)
        page.addAnnotation(checkbox)
        document.insert(page, at: 0)
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        return (directory, workspace)
    }

    @MainActor
    private func makeIndexedFormWorkspace() throws -> (
        directory: URL,
        workspace: PDFWorkspaceState,
        pages: [PDFPage],
        widgets: [PDFAnnotation]
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-UndoIndexedFormTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("forms.pdf")
        let document = PDFDocument()
        for index in 0..<2 {
            let page = try XCTUnwrap(PDFPage(image: solidImage()))
            let widget = PDFAnnotation(
                bounds: CGRect(x: 10, y: 120, width: 120, height: 24),
                forType: .widget,
                withProperties: nil
            )
            widget.widgetFieldType = .text
            widget.fieldName = "shared-field"
            widget.widgetStringValue = "before-\(index)"
            page.addAnnotation(widget)
            document.insert(page, at: document.pageCount)
        }
        XCTAssertTrue(document.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.editing)
        let pages = try (0..<2).map { index in
            try XCTUnwrap(workspace.document?.page(at: index))
        }
        let widgets = try pages.map { page in
            try XCTUnwrap(
                page.annotations.first(where: { $0.fieldName == "shared-field" })
            )
        }
        return (directory, workspace, pages, widgets)
    }

    @MainActor
    private func writePDF(pageCount: Int, to url: URL) throws {
        let document = PDFDocument()
        for _ in 0..<pageCount {
            let page = try XCTUnwrap(PDFPage(image: solidImage()))
            document.insert(page, at: document.pageCount)
        }
        XCTAssertTrue(document.write(to: url))
    }

    private func writePNG(_ image: NSImage, to url: URL) throws {
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url, options: [.atomic])
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
                ),
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

    private func solidImage() -> NSImage {
        NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
    }

    private func renderedColor(on page: PDFPage, at point: CGPoint) throws -> NSColor {
        let bounds = page.bounds(for: .mediaBox)
        let width = max(1, Int(bounds.width.rounded(.up)))
        let height = max(1, Int(bounds.height.rounded(.up)))
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
        let context = graphics.cgContext
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .mediaBox, to: context)

        let x = min(max(0, Int((point.x - bounds.minX).rounded())), width - 1)
        // The chosen test rectangle is vertically centered, so this remains
        // inside it whether the bitmap storage reports a flipped row origin.
        let y = min(max(0, Int((point.y - bounds.minY).rounded())), height - 1)
        return try XCTUnwrap(bitmap.colorAt(x: x, y: y))
    }

    private func assertIdentityOrder(
        _ actual: [PDFAnnotation],
        _ expected: [PDFAnnotation],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertTrue(actual === expected, file: file, line: line)
        }
    }
}

private final class UndoFieldEditorOwnerView: NSView, NSTextViewDelegate {}

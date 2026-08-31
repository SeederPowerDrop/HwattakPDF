// SPDX-License-Identifier: MPL-2.0

import AppKit
import Foundation
import PDFKit
import XCTest
@testable import VibePDF

/// The mode policy is intentionally tested without rendering SwiftUI. These
/// small tests fail quickly when a future toolbar feature is accidentally
/// exposed in the wrong working context.
@MainActor
final class PDFWorkspaceModeTests: XCTestCase {
    func testSidebarExportsSelectionInEveryModeButKeepsPageMutationsEditOnly() throws {
        let sidebar = try source("Sources/VibePDF/Views/PageSidebarView.swift")

        XCTAssertTrue(sidebar.contains("let contextualPageButton = pageButton.contextMenu"))
        XCTAssertTrue(sidebar.contains("Menu(L10n.string(\"menu.export_selected_pages\"))"))
        XCTAssertTrue(sidebar.contains("exportSelectedPagesCombined(clickedIndex: index)"))
        XCTAssertTrue(sidebar.contains("exportSelectedPagesIndividually(clickedIndex: index)"))
        XCTAssertTrue(sidebar.contains("if canEditPages {\n                Divider()"))
        XCTAssertTrue(sidebar.contains("workspace.rotateSelectedPages(clockwise: false)"))
        XCTAssertTrue(sidebar.contains("workspace.deleteSelectedPages()"))
        XCTAssertTrue(
            sidebar.contains("if !workspace.selectedPages.contains(index)"),
            "Right-clicking inside a multi-selection must preserve the full selection."
        )
    }

    func testDocumentWorkspaceDoesNotReserveABottomStatusBar() throws {
        let workspaceView = try source("Sources/VibePDF/Views/WorkspaceView.swift")
        let toolbar = try source("Sources/VibePDF/Views/WorkspaceToolbar.swift")
        let start = try XCTUnwrap(
            workspaceView.range(of: "private var openedDocumentWorkspace: some View")?.lowerBound
        )
        let end = try XCTUnwrap(
            workspaceView.range(
                of: "private var workspaceWithAIAssistant: some View",
                range: start..<workspaceView.endIndex
            )?.lowerBound
        )
        let openedWorkspace = String(workspaceView[start..<end])

        XCTAssertFalse(workspaceView.contains("private var statusBar: some View"))
        XCTAssertFalse(openedWorkspace.contains("statusBar"))
        XCTAssertTrue(workspaceView.contains("migrateLegacyHorizontalPageSidebarHeightIfNeeded()"))
        XCTAssertTrue(workspaceView.contains("didMigrateCompactHorizontalPanelHeight"))
        XCTAssertTrue(toolbar.contains("PageJumpControl(workspace: workspace)"))
        XCTAssertTrue(toolbar.contains("workspace.isDirty ? theme.ribbon"))
        XCTAssertTrue(toolbar.contains("workspace.ocrState.isActivelyProcessing"))
        XCTAssertTrue(toolbar.contains(".accessibilityValue("))
    }

    func testTwoTierToolbarsKeepOverflowAndVoiceOverControlsDiscoverable() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let toolbar = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Sources/VibePDF/Views/WorkspaceToolbar.swift"),
            encoding: .utf8
        )
        let studyPalette = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Sources/VibePDF/Views/StudyModePalette.swift"),
            encoding: .utf8
        )
        let workspaceView = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Sources/VibePDF/Views/WorkspaceView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(toolbar.contains("ScrollView(.horizontal, showsIndicators: true)"))
        XCTAssertTrue(studyPalette.contains("ScrollView(.horizontal, showsIndicators: true)"))
        XCTAssertTrue(toolbar.contains("primaryToolbarRow"))
        XCTAssertTrue(toolbar.contains("contextualToolbarRow"))
        XCTAssertTrue(toolbar.contains("if modeToolsVisible, workspace.mode != .study"))
        XCTAssertTrue(
            workspaceView.contains(
                "if !isFocusMode, modeToolsVisible, workspace.allows(.studyTools)"
            ),
            "Viewer, Editing and Study must share the same collapsible second-row policy."
        )
        XCTAssertTrue(toolbar.contains(".frame(minWidth: geometry.size.width, alignment: .center)"))
        XCTAssertTrue(studyPalette.contains(".frame(minWidth: geometry.size.width, alignment: .center)"))
        XCTAssertFalse(toolbar.contains("systemImage: workspace.mode.systemImage"))
        XCTAssertFalse(studyPalette.contains("systemImage: \"graduationcap.fill\""))
        XCTAssertTrue(toolbar.contains("mode-tools-toggle"))
        XCTAssertTrue(toolbar.contains("showingPenSettings = false"))
        XCTAssertTrue(toolbar.contains("showingHighlightSettings = false"))
        XCTAssertTrue(
            studyPalette.contains("ForEach(workspace.mode.availableTools)"),
            "Study's only tool picker must retain Select and Eraser as well as note and pen."
        )
        XCTAssertFalse(
            studyPalette.contains("toolButton("),
            "Typed note and pen must not be duplicated beside the complete Study picker."
        )
        XCTAssertGreaterThanOrEqual(
            toolbar.components(separatedBy: ".accessibilityLabel(help)").count - 1,
            2,
            "Both generic toolbar icons and compact search navigation icons need explicit names."
        )
        XCTAssertTrue(studyPalette.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(studyPalette.contains(".accessibilityValue(valueText)"))
    }

    func testDirectLayoutIconsExposeDistinctContinuousAndPagedTwoPageChoices() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let toolbar = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Sources/VibePDF/Views/WorkspaceToolbar.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(toolbar.contains("view-layout-controls"))
        XCTAssertTrue(toolbar.contains("layout-one-page"))
        XCTAssertTrue(toolbar.contains("layout-two-page-continuous"))
        XCTAssertTrue(toolbar.contains("layout-two-page-paged"))
        XCTAssertTrue(toolbar.contains("layout-four-page"))
        XCTAssertFalse(toolbar.contains("view-layout-menu"))
        XCTAssertTrue(toolbar.contains("view.two_page.continuous.title"))
        XCTAssertTrue(toolbar.contains("view.two_page.paged.title"))
        XCTAssertTrue(toolbar.contains("workspace.twoPageDisplayMode == .continuous"))
        XCTAssertTrue(toolbar.contains("workspace.twoPageDisplayMode == .paged"))
        XCTAssertTrue(toolbar.contains("workspace.selectTwoPageDisplayMode(.continuous)"))
        XCTAssertTrue(toolbar.contains("workspace.selectTwoPageDisplayMode(.paged)"))
        XCTAssertTrue(toolbar.contains("TwoPageLayoutIcon(mode: .continuous)"))
        XCTAssertTrue(toolbar.contains("TwoPageLayoutIcon(mode: .paged)"))
        XCTAssertTrue(toolbar.contains("FourPageLayoutIcon(mode: gridLayoutMode)"))
        XCTAssertTrue(toolbar.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        XCTAssertTrue(toolbar.contains("workspace.pageColumns = 1"))
        XCTAssertTrue(toolbar.contains("workspace.pageColumns = 4"))
    }

    func testHighlightToolbarUsesModeAwareColorAndVisibleDocumentHistory() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let toolbar = try String(
            contentsOf: projectRoot
                .appendingPathComponent("Sources/VibePDF/Views/WorkspaceToolbar.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            toolbar.contains("workspace.applyCurrentModeHighlight()"),
            "The visible marker and Shift-Command-H must share the mode-aware color path."
        )
        XCTAssertFalse(
            toolbar.contains("workspace.highlightCurrentSelection()"),
            "The toolbar must not bypass the selected-color dispatcher."
        )
        XCTAssertTrue(toolbar.contains("showingHighlightSettings"))
        XCTAssertTrue(toolbar.contains("selection: highlightColorBinding"))
        XCTAssertTrue(
            toolbar.contains("Color(nsColor: workspace.studyMarkupStyle.color)"),
            "The toolbar should show the color that the next highlight will use."
        )

        // Command-Z remains the keyboard path, but pointer users also need an
        // affordance whose enabled state follows the same document history.
        XCTAssertTrue(toolbar.contains("editCommandRouter.performUndo"))
        XCTAssertTrue(
            toolbar.contains(
                "editCommandRouter.canUndo(documentCanUndo: workspace.canUndo)"
            )
        )
        XCTAssertTrue(toolbar.contains("editCommandRouter.performRedo"))
        XCTAssertTrue(
            toolbar.contains(
                "editCommandRouter.canRedo(documentCanRedo: workspace.canRedo)"
            )
        )
    }

    func testDefaultModeIsViewerAndModeSwitchDoesNotDirtyDocument() {
        let workspace = PDFWorkspaceState()

        XCTAssertEqual(workspace.mode, .viewer)
        XCTAssertFalse(workspace.isDirty)

        workspace.setMode(.editing)

        XCTAssertEqual(workspace.mode, .editing)
        XCTAssertTrue(workspace.allowsInlineTextEditing)
        XCTAssertFalse(workspace.isDirty)
    }

    func testPagedTwoPageSelectionRetainsDocumentStateAndLastSubtype() {
        let workspace = PDFWorkspaceState()
        workspace.currentPageIndex = 7
        workspace.selectedPages = [6, 7]
        workspace.recordPDFViewport(
            autoScales: false,
            scaleFactor: 1.8,
            scrollProgress: PDFScrollProgress(horizontal: 0.2, vertical: 0.6)
        )
        let revision = workspace.revision

        workspace.selectTwoPageDisplayMode(.paged)

        XCTAssertEqual(workspace.pageColumns, 2)
        XCTAssertEqual(workspace.twoPageDisplayMode, .paged)
        XCTAssertEqual(workspace.currentPageIndex, 7)
        XCTAssertEqual(workspace.selectedPages, [6, 7])
        XCTAssertEqual(workspace.revision, revision)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertEqual(workspace.pdfViewportState.scaleFactor, 1.8)
        XCTAssertNil(workspace.pdfViewportState.scrollProgress)

        workspace.pageColumns = 1
        XCTAssertEqual(workspace.twoPageDisplayMode, .paged)
        workspace.pageColumns = 4
        workspace.pageColumns = 2
        XCTAssertEqual(workspace.twoPageDisplayMode, .paged)

        workspace.recordPDFViewport(
            autoScales: false,
            scaleFactor: 2,
            scrollProgress: PDFScrollProgress(horizontal: 0.4, vertical: 0.7)
        )
        workspace.pageColumns = 4
        workspace.selectTwoPageDisplayMode(.continuous)
        XCTAssertEqual(workspace.twoPageDisplayMode, .continuous)
        XCTAssertNil(workspace.pdfViewportState.scrollProgress)
    }

    func testModeCapabilityMatrixMatchesProductBoundaries() {
        XCTAssertTrue(PDFWorkspaceMode.viewer.allows(.comments))
        XCTAssertTrue(PDFWorkspaceMode.viewer.allows(.signature))
        XCTAssertTrue(PDFWorkspaceMode.viewer.allows(.translation))
        XCTAssertTrue(PDFWorkspaceMode.viewer.allows(.aiAssistance))
        XCTAssertTrue(PDFWorkspaceMode.viewer.allows(.noteSharing))
        XCTAssertFalse(PDFWorkspaceMode.viewer.allows(.inlineTextEditing))
        XCTAssertFalse(PDFWorkspaceMode.viewer.allows(.pageEditing))

        XCTAssertTrue(PDFWorkspaceMode.editing.allows(.inlineTextEditing))
        XCTAssertTrue(PDFWorkspaceMode.editing.allows(.imageInsertion))
        XCTAssertTrue(PDFWorkspaceMode.editing.allows(.signatureImageImport))
        XCTAssertTrue(PDFWorkspaceMode.editing.allows(.handwriting))
        XCTAssertTrue(PDFWorkspaceMode.editing.allows(.pageEditing))
        XCTAssertFalse(PDFWorkspaceMode.editing.allows(.studyTools))
        XCTAssertFalse(PDFWorkspaceMode.editing.allows(.aiAssistance))

        XCTAssertTrue(PDFWorkspaceMode.study.allows(.studyTools))
        XCTAssertTrue(PDFWorkspaceMode.study.allows(.calculationHelp))
        XCTAssertTrue(PDFWorkspaceMode.study.allows(.terminologyHelp))
        XCTAssertTrue(PDFWorkspaceMode.study.allows(.translation))
        XCTAssertTrue(PDFWorkspaceMode.study.allows(.aiAssistance))
        XCTAssertTrue(PDFWorkspaceMode.study.allows(.noteSharing))
        XCTAssertFalse(PDFWorkspaceMode.study.allows(.inlineTextEditing))
        XCTAssertFalse(PDFWorkspaceMode.study.allows(.pageEditing))
    }

    func testViewerAndStudyRejectEveryPageOperationWithoutAnySideEffect() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Page-Mode-Guard-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.pdf")
        let mergeURL = directory.appendingPathComponent("merge.pdf")

        // Real files make this a final-boundary test: merge receives a valid
        // external PDF and therefore would mutate immediately if the mode
        // guard were accidentally moved below its file-reading path.
        func writePDF(pageCount: Int, to url: URL) throws {
            let document = PDFDocument()
            for index in 0..<pageCount {
                let image = NSImage(
                    size: CGSize(width: 180 + index, height: 240 + index),
                    flipped: false
                ) { rect in
                    NSColor.white.setFill()
                    rect.fill()
                    return true
                }
                document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
            }
            XCTAssertTrue(document.write(to: url))
        }

        try writePDF(pageCount: 3, to: sourceURL)
        try writePDF(pageCount: 1, to: mergeURL)

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: sourceURL))

        for mode in [PDFWorkspaceMode.viewer, .study] {
            workspace.setMode(mode)
            workspace.selectedPages = [0]
            workspace.statusMessage = "sentinel-status-\(mode.rawValue)"
            workspace.presentedError = "sentinel-error-\(mode.rawValue)"

            let document = try XCTUnwrap(workspace.document)
            let originalDocument = document
            let originalPageIDs = (0..<document.pageCount).compactMap { index in
                document.page(at: index).map(ObjectIdentifier.init)
            }
            let originalRotations = (0..<document.pageCount).map {
                document.page(at: $0)?.rotation
            }
            let originalPageCount = workspace.pageCount
            let originalSelection = workspace.selectedPages
            let originalCurrentPage = workspace.currentPageIndex
            let originalRevision = workspace.revision
            let originalDirtyState = workspace.isDirty
            let originalCanUndo = workspace.canUndo
            let originalCanRedo = workspace.canRedo
            let originalStatus = workspace.statusMessage
            let originalError = workspace.presentedError

            // Exercise both public primitives and their convenience wrappers.
            // None may rely solely on a toolbar check because delayed drag,
            // menu, automation, or future integration events can call here.
            workspace.merge(urls: [mergeURL])
            workspace.movePage(from: 0, before: 2)
            workspace.movePageToEnd(from: 0)
            workspace.moveSelectedPage(by: 1)
            workspace.rotateSelectedPages(clockwise: true)
            workspace.deleteSelectedPages()

            XCTAssertTrue(workspace.document === originalDocument)
            XCTAssertEqual(workspace.pageCount, originalPageCount)
            XCTAssertEqual(
                (0..<document.pageCount).compactMap { index in
                    document.page(at: index).map(ObjectIdentifier.init)
                },
                originalPageIDs
            )
            XCTAssertEqual(
                (0..<document.pageCount).map { document.page(at: $0)?.rotation },
                originalRotations
            )
            XCTAssertEqual(workspace.selectedPages, originalSelection)
            XCTAssertEqual(workspace.currentPageIndex, originalCurrentPage)
            XCTAssertEqual(workspace.revision, originalRevision)
            XCTAssertEqual(workspace.isDirty, originalDirtyState)
            XCTAssertEqual(workspace.canUndo, originalCanUndo)
            XCTAssertEqual(workspace.canRedo, originalCanRedo)
            XCTAssertEqual(workspace.statusMessage, originalStatus)
            XCTAssertEqual(workspace.presentedError, originalError)
        }
    }

    func testModesExposeOnlyTheirSupportedPointerTools() {
        XCTAssertEqual(PDFWorkspaceMode.viewer.availableTools, [.select, .text])
        XCTAssertEqual(
            PDFWorkspaceMode.editing.availableTools,
            [.select, .text, .pen, .eraser]
        )
        XCTAssertEqual(
            PDFWorkspaceMode.study.availableTools,
            [.select, .text, .pen, .eraser]
        )
    }

    func testLeavingEditingNormalizesAnUnavailableToolToSelection() {
        let workspace = PDFWorkspaceState()
        workspace.setMode(.editing)
        workspace.activeTool = .pen

        workspace.setMode(.viewer)

        XCTAssertEqual(workspace.activeTool, .select)
        XCTAssertFalse(workspace.allowsInlineTextEditing)
    }

    func testToolbarSectionsComeFromTheCentralPolicy() {
        XCTAssertEqual(
            PDFWorkspaceMode.viewer.toolbarSections,
            [.document, .viewing, .inputTools, .markup, .signature, .ocr, .ai, .search]
        )
        XCTAssertEqual(
            PDFWorkspaceMode.editing.toolbarSections,
            [
                .document, .viewing, .inputTools, .penSettings, .markup,
                .signature, .images, .pages, .ocr, .search
            ]
        )
        XCTAssertEqual(
            PDFWorkspaceMode.study.toolbarSections,
            [
                .document, .viewing, .inputTools, .penSettings, .ocr,
                .ai, .studyPalette, .search
            ]
        )
    }

    func testAnnotationEditingRespectsEachModeWithoutBlockingNotes() {
        XCTAssertTrue(
            PDFWorkspaceModePolicy.allowsAnnotationEditing(.signature, in: .viewer)
        )
        XCTAssertTrue(
            PDFWorkspaceModePolicy.allowsAnnotationEditing(.freeText, in: .viewer)
        )
        XCTAssertFalse(
            PDFWorkspaceModePolicy.allowsAnnotationEditing(.image, in: .viewer)
        )

        for kind in [EditableAnnotationKind.image, .signature, .freeText] {
            XCTAssertTrue(
                PDFWorkspaceModePolicy.allowsAnnotationEditing(kind, in: .editing)
            )
        }

        XCTAssertTrue(
            PDFWorkspaceModePolicy.allowsAnnotationEditing(.freeText, in: .study)
        )
        XCTAssertFalse(
            PDFWorkspaceModePolicy.allowsAnnotationEditing(.signature, in: .study)
        )
        XCTAssertFalse(
            PDFWorkspaceModePolicy.allowsAnnotationEditing(.image, in: .study)
        )
    }

    func testStudyEraserRequiresRuntimeTrustForRecognizedStudyContent() {
        let studyMark = StudyMarkupAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 80, height: 12),
            style: StudyMarkupStyle(kind: .highlight, color: .yellow, thickness: 8, opacity: 0.4)
        )
        let appNote = PDFAnnotation(bounds: .zero, forType: .freeText, withProperties: nil)
        EditableAnnotationIdentity.assign(.freeText, to: appNote)
        let appInk = PDFAnnotation(bounds: .zero, forType: .ink, withProperties: nil)
        appInk.setValue("HwattakPDF-Ink-test", forAnnotationKey: .name)
        let appHighlight = PDFAnnotation(bounds: .zero, forType: .highlight, withProperties: nil)
        appHighlight.setValue("HwattakPDF-Annotation-test", forAnnotationKey: .name)

        for annotation in [studyMark, appNote, appInk, appHighlight] {
            XCTAssertFalse(
                PDFAnnotationErasePolicy.allows(annotation, in: .study),
                "A marker read from a PDF must never prove destructive authority."
            )
            XCTAssertTrue(
                PDFAnnotationErasePolicy.allows(
                    annotation,
                    in: .study,
                    isTrustedRuntimeAnnotation: true
                )
            )
        }

        let image = PDFAnnotation(bounds: .zero, forType: .stamp, withProperties: nil)
        EditableAnnotationIdentity.assign(.image, to: image)
        let signature = PDFAnnotation(bounds: .zero, forType: .stamp, withProperties: nil)
        EditableAnnotationIdentity.assign(.signature, to: signature)
        let externalInk = PDFAnnotation(bounds: .zero, forType: .ink, withProperties: nil)
        let externalHighlight = PDFAnnotation(bounds: .zero, forType: .highlight, withProperties: nil)
        let externalStamp = PDFAnnotation(bounds: .zero, forType: .stamp, withProperties: nil)

        for annotation in [image, signature, externalInk, externalHighlight, externalStamp] {
            XCTAssertFalse(PDFAnnotationErasePolicy.allows(annotation, in: .study))
        }
        XCTAssertFalse(PDFAnnotationErasePolicy.allows(appInk, in: .viewer))
        XCTAssertTrue(PDFAnnotationErasePolicy.allows(externalHighlight, in: .editing))
    }

    func testStudyEraserModelBoundaryRejectsImageAndRegistersAllowedUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Study-Eraser-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("eraser.pdf")
        let source = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        source.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.study)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let importedImage = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 40, height: 40),
            forType: .stamp,
            withProperties: nil
        )
        EditableAnnotationIdentity.assign(.image, to: importedImage)
        let studyMark = StudyMarkupAnnotation(
            bounds: CGRect(x: 70, y: 10, width: 60, height: 12),
            style: StudyMarkupStyle(kind: .underline, color: .blue, thickness: 3, opacity: 0.5)
        )
        let forgedNote = PDFAnnotation(
            bounds: CGRect(x: 140, y: 10, width: 60, height: 24),
            forType: .freeText,
            withProperties: nil
        )
        EditableAnnotationIdentity.assign(.freeText, to: forgedNote)
        page.addAnnotation(importedImage)
        page.addAnnotation(studyMark)
        page.addAnnotation(forgedNote)

        XCTAssertFalse(
            workspace.allowsAnnotationEditing(.freeText, annotation: forgedNote),
            "A public marker in the PDF must not unlock Study overlay editing."
        )
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.allowsAnnotationEditing(.freeText, annotation: forgedNote),
            "Editing mode is the explicit broad authoring surface."
        )
        workspace.setMode(.study)
        XCTAssertFalse(
            workspace.allowsAnnotationEditing(.freeText, annotation: forgedNote)
        )
        workspace.registerAddedAnnotation(
            forgedNote,
            on: page,
            message: "Study note added"
        )
        XCTAssertTrue(
            workspace.allowsAnnotationEditing(.freeText, annotation: forgedNote),
            "An object explicitly registered in this session may be revised."
        )
        workspace.registerAddedAnnotation(
            studyMark,
            on: page,
            message: "Study mark added"
        )

        XCTAssertEqual(workspace.activeTool, .select)
        XCTAssertFalse(workspace.removeAnnotationWithEraser(studyMark, from: page))
        XCTAssertTrue(page.annotations.contains(where: { $0 === studyMark }))
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)

        workspace.activeTool = .eraser
        XCTAssertFalse(workspace.removeAnnotationWithEraser(importedImage, from: page))
        XCTAssertTrue(page.annotations.contains(where: { $0 === importedImage }))
        XCTAssertTrue(workspace.removeAnnotationWithEraser(studyMark, from: page))
        XCTAssertFalse(page.annotations.contains(where: { $0 === studyMark }))
        XCTAssertTrue(workspace.canUndo)

        workspace.undo()
        XCTAssertTrue(page.annotations.contains(where: { $0 === studyMark }))
        XCTAssertTrue(page.annotations.contains(where: { $0 === importedImage }))
    }

    func testRuntimeAnnotationTrustEndsWhenCleanTabHibernatesAndReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Annotation-Provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("provenance.pdf")
        let source = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        source.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.requestTextEdit(
            pageIndex: 0,
            point: CGPoint(x: 30, y: 100),
            annotation: nil
        )
        workspace.commitPendingText("runtime note")
        let liveNote = try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first)
        XCTAssertTrue(
            workspace.allowsAnnotationEditing(.freeText, annotation: liveNote)
        )
        XCTAssertTrue(workspace.saveSynchronously())
        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertTrue(workspace.resumeIfNeeded())

        let reopenedNote = try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first)
        XCTAssertFalse(workspace.isRuntimeTrustedAnnotation(reopenedNote))
        XCTAssertFalse(
            workspace.allowsAnnotationEditing(.freeText, annotation: reopenedNote),
            "A persisted marker classifies the note but cannot restore Viewer authority."
        )
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.allowsAnnotationEditing(.freeText, annotation: reopenedNote)
        )
    }

    func testEditingGeometryChangeExplicitlyReadoptsPersistedSignatureForViewer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Signature-Readoption-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("signature.pdf")
        let pageImage = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: pageImage))
        let signature = PDFAnnotation(
            bounds: CGRect(x: 30, y: 50, width: 80, height: 30),
            forType: .stamp,
            withProperties: nil
        )
        signature.setValue("HwattakPDF-Signature-persisted", forAnnotationKey: .name)
        EditableAnnotationIdentity.assign(.signature, to: signature)
        page.addAnnotation(signature)
        let source = PDFDocument()
        source.insert(page, at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        let reopenedPage = try XCTUnwrap(workspace.document?.page(at: 0))
        let reopenedSignature = try XCTUnwrap(reopenedPage.annotations.first)
        XCTAssertFalse(
            workspace.allowsAnnotationEditing(.signature, annotation: reopenedSignature)
        )

        workspace.setMode(.editing)
        let originalBounds = reopenedSignature.bounds
        let originalDate = reopenedSignature.modificationDate
        reopenedSignature.bounds = originalBounds.offsetBy(dx: 12, dy: 4)
        reopenedSignature.modificationDate = Date()
        workspace.registerAnnotationGeometryChange(
            reopenedSignature,
            on: reopenedPage,
            from: originalBounds,
            originalModificationDate: originalDate,
            message: "Signature moved"
        )
        workspace.setMode(.viewer)
        XCTAssertTrue(
            workspace.allowsAnnotationEditing(.signature, annotation: reopenedSignature)
        )
    }

    func testViewerAndStudyDirectGeometryRegistrationCannotAdoptPersistedAnnotations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Geometry-Policy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("annotations.pdf")
        let pageImage = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: pageImage))
        let signature = PDFAnnotation(
            bounds: CGRect(x: 20, y: 40, width: 70, height: 28),
            forType: .stamp,
            withProperties: nil
        )
        EditableAnnotationIdentity.assign(.signature, to: signature)
        let note = PDFAnnotation(
            bounds: CGRect(x: 20, y: 100, width: 100, height: 40),
            forType: .freeText,
            withProperties: nil
        )
        note.contents = "Persisted note"
        EditableAnnotationIdentity.assign(.freeText, to: note)
        page.addAnnotation(signature)
        page.addAnnotation(note)
        let source = PDFDocument()
        source.insert(page, at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        let reopenedPage = try XCTUnwrap(workspace.document?.page(at: 0))
        let reopenedSignature = try XCTUnwrap(
            reopenedPage.annotations.first {
                EditableAnnotationIdentity.kind(of: $0) == .signature
            }
        )
        let reopenedNote = try XCTUnwrap(
            reopenedPage.annotations.first {
                EditableAnnotationIdentity.kind(of: $0) == .freeText
            }
        )

        // Viewer supports newly created signatures, and Study supports current-
        // session notes. Persisted objects with the same public markers still
        // need runtime provenance; calling the history API directly must not
        // become an adoption back door for either mode.
        let signatureBounds = reopenedSignature.bounds
        let signatureDate = reopenedSignature.modificationDate
        reopenedSignature.bounds = signatureBounds.offsetBy(dx: 18, dy: 0)
        reopenedSignature.modificationDate = Date()
        workspace.registerAnnotationGeometryChange(
            reopenedSignature,
            on: reopenedPage,
            from: signatureBounds,
            originalModificationDate: signatureDate,
            message: "Viewer bypass"
        )
        XCTAssertEqual(reopenedSignature.bounds, signatureBounds)
        XCTAssertEqual(reopenedSignature.modificationDate, signatureDate)
        XCTAssertFalse(
            workspace.allowsAnnotationEditing(.signature, annotation: reopenedSignature)
        )

        workspace.setMode(.study)
        let noteBounds = reopenedNote.bounds
        let noteDate = reopenedNote.modificationDate
        reopenedNote.bounds = noteBounds.offsetBy(dx: 0, dy: 16)
        reopenedNote.modificationDate = Date()
        workspace.registerAnnotationGeometryChange(
            reopenedNote,
            on: reopenedPage,
            from: noteBounds,
            originalModificationDate: noteDate,
            message: "Study bypass"
        )
        XCTAssertEqual(reopenedNote.bounds, noteBounds)
        XCTAssertEqual(reopenedNote.modificationDate, noteDate)
        XCTAssertFalse(workspace.allowsAnnotationEditing(.freeText, annotation: reopenedNote))
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
    }

    func testNativePenSettingsExposeOnlyTheOpaqueColorThatPDFKitCanSave() {
        var settings = InkSettings()
        settings.color = NSColor.systemBlue.withAlphaComponent(0.2)

        let converted = settings.pdfInkColor.usingColorSpace(.deviceRGB)
        XCTAssertEqual(converted?.alphaComponent ?? -1, 1, accuracy: 0.001)
    }

    func testFinalSignatureStudyMarkupAndPenBoundariesRecheckLiveMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Mode-Final-Boundary-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boundary.pdf")
        let source = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        source.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let signatureStroke = SignatureStroke(points: [
            SignaturePoint(x: 10, y: 10, pressure: 0.5, timestamp: 0),
            SignaturePoint(x: 80, y: 40, pressure: 0.7, timestamp: 0.1),
            SignaturePoint(x: 140, y: 20, pressure: 0.5, timestamp: 0.2),
        ])

        // Simulate opening the sheet in Viewer, then pressing the global Study
        // shortcut before the sheet's Apply button finishes dismissing.
        workspace.setMode(.study)
        XCTAssertFalse(
            workspace.addSignature([signatureStroke], canvasSize: CGSize(width: 180, height: 80))
        )
        XCTAssertTrue(page.annotations.isEmpty)

        // `applyStudyMarkup` is also a model API, not merely a palette action.
        // Editing must reject it before the missing-selection error path.
        workspace.setMode(.editing)
        workspace.applyStudyMarkup(StudyMarkupStyle())
        XCTAssertNil(workspace.presentedError)
        XCTAssertTrue(page.annotations.isEmpty)

        let pdfView = InteractivePDFView(frame: .zero)
        workspace.activeTool = .pen
        pdfView.viewportContext = .normal
        pdfView.configure(with: workspace)
        XCTAssertEqual(pdfView.activeTool, .pen)

        // The view deliberately remains stale at Pen to model a mode shortcut
        // occurring between mouse-down and mouse-up.
        workspace.setMode(.viewer)
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 70, y: 80)]
        XCTAssertFalse(pdfView.commitInkStroke(points, on: page))
        XCTAssertTrue(page.annotations.isEmpty)

        workspace.setMode(.editing)
        workspace.activeTool = .pen
        pdfView.configure(with: workspace)
        XCTAssertTrue(pdfView.commitInkStroke(points, on: page))
        let ink = try XCTUnwrap(page.annotations.first)
        XCTAssertNil(ink.userName)

        let serialized = try XCTUnwrap(workspace.document?.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: serialized))
        let reopenedInk = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertNil(reopenedInk.userName)
        XCTAssertNil(reopenedInk.value(forAnnotationKey: .textLabel))
    }

    func testSchemaV1TabWithoutModeFieldStillDecodesAsLegacyRecord() throws {
        let workspaceID = UUID()
        let tabID = UUID()
        let json = """
        {
          "schemaVersion": 1,
          "activeWorkspaceID": "\(workspaceID.uuidString)",
          "workspaces": [{
            "id": "\(workspaceID.uuidString)",
            "title": "Legacy",
            "activeTabID": "\(tabID.uuidString)",
            "tabs": [{
              "id": "\(tabID.uuidString)",
              "document": null,
              "currentPageIndex": 0,
              "selectedPages": [],
              "pageColumns": 1,
              "overviewScale": 1.0
            }],
            "groups": []
          }],
          "detachedWorkspaceIDs": []
        }
        """

        let archive = try JSONDecoder().decode(
            WorkspaceSessionArchive.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(archive.workspaces[0].tabs[0].workspaceMode)
        XCTAssertEqual(
            archive.workspaces[0].tabs[0].workspaceMode.flatMap(PDFWorkspaceMode.init(rawValue:))
                ?? .viewer,
            .viewer
        )
    }

    func testModeRawValuesAreStableForSessionArchives() throws {
        let data = try JSONEncoder().encode(PDFWorkspaceMode.study)
        XCTAssertEqual(try JSONDecoder().decode(PDFWorkspaceMode.self, from: data), .study)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"study\"")
    }

    func testTwoPageDisplayModeRawValuesAreStableForSessionArchives() throws {
        XCTAssertEqual(PDFTwoPageDisplayMode.continuous.rawValue, "continuous")
        XCTAssertEqual(PDFTwoPageDisplayMode.paged.rawValue, "paged")
        let data = try JSONEncoder().encode(PDFTwoPageDisplayMode.paged)
        XCTAssertEqual(
            try JSONDecoder().decode(PDFTwoPageDisplayMode.self, from: data),
            .paged
        )
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"paged\"")
    }

    func testDropBatchSkipsDamagedFirstPDFAndStillOpensLaterValidPDF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Drop-Partial-Failure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let damagedURL = directory.appendingPathComponent("damaged.pdf")
        try Data("not a PDF".utf8).write(to: damagedURL)
        let validURL = directory.appendingPathComponent("valid.pdf")
        try writeDropTestPDF(pageCount: 2, to: validURL)
        let imageURL = directory.appendingPathComponent("blocked.png")
        try Data("image access should be blocked before decoding".utf8).write(to: imageURL)
        let unsupportedURL = directory.appendingPathComponent("notes.txt")
        try Data("unsupported".utf8).write(to: unsupportedURL)

        let collection = MultiDocumentWorkspaceState()
        let initialTabID = try XCTUnwrap(collection.activeTabID)
        let initialWorkspace = try XCTUnwrap(collection.activeWorkspace)
        let task = try XCTUnwrap(
            WorkspaceFileDropCoordinator.handle(
                [
                    WorkspaceDroppedFile(url: damagedURL),
                    WorkspaceDroppedFile(url: validURL),
                    WorkspaceDroppedFile(url: imageURL),
                    WorkspaceDroppedFile(url: unsupportedURL),
                ],
                workspace: initialWorkspace,
                multiDocumentWorkspace: collection
            )
        )

        let openedIDs = await task.value

        XCTAssertEqual(openedIDs, [initialTabID])
        XCTAssertEqual(collection.tabs.count, 1)
        XCTAssertEqual(collection.activeWorkspace?.documentURL, validURL)
        XCTAssertEqual(collection.activeWorkspace?.pageCount, 2)
        XCTAssertTrue(collection.activeWorkspace?.presentedError?.contains("damaged.pdf") == true)
        XCTAssertTrue(collection.activeWorkspace?.presentedError?.contains(
            L10n.format("error.mode_image_drop_requires_editing", 1)
        ) == true)
        XCTAssertTrue(collection.activeWorkspace?.presentedError?.contains(
            L10n.format("status.skipped_files", 1)
        ) == true)
    }

    func testDropOnOpenDocumentCreatesTabWithoutMergingPages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Drop-New-Tab-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let originalURL = directory.appendingPathComponent("original.pdf")
        let droppedURL = directory.appendingPathComponent("dropped.pdf")
        try writeDropTestPDF(pageCount: 3, to: originalURL)
        try writeDropTestPDF(pageCount: 2, to: droppedURL)

        let collection = MultiDocumentWorkspaceState()
        let originalTabID = try XCTUnwrap(collection.openPDFsInTabs(urls: [originalURL]).first)
        let originalWorkspace = try XCTUnwrap(collection.activeWorkspace)
        originalWorkspace.setMode(.editing)
        let task = try XCTUnwrap(
            WorkspaceFileDropCoordinator.handle(
                [WorkspaceDroppedFile(url: droppedURL)],
                workspace: originalWorkspace,
                multiDocumentWorkspace: collection
            )
        )

        let openedIDs = await task.value

        XCTAssertEqual(openedIDs.count, 1)
        XCTAssertNotEqual(openedIDs.first, originalTabID)
        XCTAssertEqual(originalWorkspace.pageCount, 3)
        XCTAssertEqual(
            collection.tabs.compactMap { $0.workspace.documentURL },
            [originalURL, droppedURL]
        )
        XCTAssertEqual(collection.activeWorkspace?.documentURL, droppedURL)
    }

    func testEmptyEditingTabDropRechecksImagePermissionOnDeduplicatedTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Drop-Deduplicated-Target-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let pdfURL = directory.appendingPathComponent("already-open.pdf")
        try writeDropTestPDF(pageCount: 1, to: pdfURL)
        let imageURL = directory.appendingPathComponent("blocked.png")
        try Data("must not be decoded".utf8).write(to: imageURL)

        let collection = MultiDocumentWorkspaceState()
        let existingTabID = try XCTUnwrap(collection.openPDFsInTabs(urls: [pdfURL]).first)
        let existingWorkspace = try XCTUnwrap(collection.activeWorkspace)
        XCTAssertEqual(existingWorkspace.mode, .viewer)

        _ = collection.newTab()
        let emptyEditingWorkspace = try XCTUnwrap(collection.activeWorkspace)
        emptyEditingWorkspace.setMode(.editing)
        let task = try XCTUnwrap(
            WorkspaceFileDropCoordinator.handle(
                [WorkspaceDroppedFile(url: pdfURL), WorkspaceDroppedFile(url: imageURL)],
                workspace: emptyEditingWorkspace,
                multiDocumentWorkspace: collection
            )
        )

        let openedIDs = await task.value

        XCTAssertEqual(openedIDs, [existingTabID])
        XCTAssertEqual(collection.tabs.count, 2)
        XCTAssertEqual(collection.activeTabID, existingTabID)
        XCTAssertFalse(existingWorkspace.isDirty)
        XCTAssertNotNil(existingWorkspace.presentedError)
    }

    func testMutationSurfacesConsultCapabilitiesInsteadOfBypassingMode() throws {
        let sidebar = try source("Sources/VibePDF/Views/PageSidebarView.swift")
        let grid = try source("Sources/VibePDF/Views/PDFGridOverview.swift")
        let workspaceView = try source("Sources/VibePDF/Views/WorkspaceView.swift")
        let tabbedWorkspace = try source(
            "Sources/VibePDF/Views/TabbedWorkspaceView.swift"
        )
        let fileDrop = try source("Sources/VibePDF/Views/WorkspaceFileDrop.swift")
        let app = try source("Sources/VibePDF/App/VibePDFApp.swift")
        let annotationOverlay = try source(
            "Sources/VibePDF/Views/PDFImageEditingOverlay.swift"
        )

        XCTAssertTrue(sidebar.contains("private var canEditPages"))
        XCTAssertTrue(sidebar.contains("workspace.allows(.pageEditing)"))
        XCTAssertTrue(grid.contains("workspace.allows(.pageEditing)"))
        XCTAssertTrue(app.contains("activeWorkspace.allows(.pageEditing)"))
        XCTAssertTrue(workspaceView.contains("guard workspace.allows(.pageEditing)"))
        XCTAssertTrue(workspaceView.contains("guard workspace.allows(.imageInsertion)"))
        XCTAssertTrue(
            workspaceView.contains("aiPanelVisible, workspace.allows(.aiAssistance)")
        )
        XCTAssertTrue(tabbedWorkspace.contains("WorkspaceFileDropCoordinator.handle("))
        XCTAssertTrue(fileDrop.contains("beginOpeningPDFsInTabs(urls: pdfURLs)"))
        XCTAssertFalse(
            fileDrop.contains("workspace.merge("),
            "A Finder PDF drop must not silently merge into the active document."
        )
        XCTAssertTrue(annotationOverlay.contains("allowsAnnotationEditing("))
        XCTAssertTrue(annotationOverlay.contains("annotation: annotation"))
    }

    func testFinderFileDropReceiverCoversTheFullWorkspaceBoundaryExactlyOnce() throws {
        let tabbedWorkspace = try source(
            "Sources/VibePDF/Views/TabbedWorkspaceView.swift"
        )
        let workspaceView = try source("Sources/VibePDF/Views/WorkspaceView.swift")
        let pageSidebar = try source("Sources/VibePDF/Views/PageSidebarView.swift")
        let grid = try source("Sources/VibePDF/Views/PDFGridOverview.swift")

        XCTAssertTrue(
            tabbedWorkspace.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)")
        )
        XCTAssertTrue(tabbedWorkspace.contains("of: [UTType.fileURL]"))
        XCTAssertTrue(tabbedWorkspace.contains("perform: acceptWorkspaceFileDrop"))
        XCTAssertTrue(
            tabbedWorkspace.contains("let targetWorkspace = workspace.activeWorkspace")
        )
        XCTAssertTrue(tabbedWorkspace.contains("WorkspaceFileDropCoordinator.handle("))
        XCTAssertTrue(tabbedWorkspace.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(
            tabbedWorkspace.contains("WorkspaceTabTearOutDropTargetModifier(")
        )
        XCTAssertTrue(tabbedWorkspace.contains("isEnabled: draggedTabID != nil"))
        XCTAssertTrue(pageSidebar.contains("PageReorderDropTargetModifier("))
        XCTAssertTrue(pageSidebar.contains("PageEndDropTargetModifier("))
        XCTAssertTrue(grid.contains("GridPageReorderDropTargetModifier("))
        XCTAssertTrue(grid.contains("GridPageEndDropTargetModifier("))
        XCTAssertGreaterThanOrEqual(
            [tabbedWorkspace, pageSidebar, grid]
                .map { $0.components(separatedBy: "isEnabled: pageDragSession != nil").count - 1 }
                .reduce(0, +),
            4
        )
        XCTAssertFalse(
            workspaceView.contains("of: [UTType.fileURL]"),
            "A nested receiver can be bypassed over PDFKit and sidebar scroll views."
        )
        XCTAssertFalse(
            workspaceView.contains("WorkspaceDroppedFileLoader.load("),
            "One drop must not be loaded by both the workspace boundary and a child view."
        )

        let fileDrop = try XCTUnwrap(
            tabbedWorkspace.range(of: "of: [UTType.fileURL]")?.lowerBound
        )
        let tabTearOutDrop = try XCTUnwrap(
            tabbedWorkspace.range(of: "of: [UTType.utf8PlainText.identifier]")?.lowerBound
        )
        XCTAssertLessThan(
            fileDrop,
            tabTearOutDrop,
            "Mirror the proven tab-bar modifier order: Finder files before internal text drags."
        )
    }

    func testFinderLikeProviderLoadsThroughTheSharedWorkspaceReceiver() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-receiver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let pdfURL = temporaryDirectory.appendingPathComponent("canvas-drop.pdf")
        try writeDropTestPDF(pageCount: 1, to: pdfURL)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: pdfURL))
        let loaded = expectation(description: "Finder file provider loaded")
        var droppedFiles: [WorkspaceDroppedFile] = []

        XCTAssertTrue(
            WorkspaceExternalFileDropReceiver.receive(from: [provider]) { files in
                droppedFiles = files
                loaded.fulfill()
            }
        )
        await fulfillment(of: [loaded], timeout: 2)

        XCTAssertEqual(droppedFiles.count, 1)
        XCTAssertEqual(droppedFiles.first?.url.standardizedFileURL, pdfURL.standardizedFileURL)
        XCTAssertEqual(droppedFiles.first?.kind, .pdf)

        let internalPageProvider = PDFPageDragPayload.itemProvider(
            for: PDFPageDragSession(
                sourceIndex: 0,
                documentRevision: UUID()
            )
        )
        XCTAssertFalse(
            WorkspaceExternalFileDropReceiver.receive(from: [internalPageProvider]) { _ in
                XCTFail("An internal page drag must never enter the Finder file route.")
            }
        )
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func writeDropTestPDF(pageCount: Int, to url: URL) throws {
        let document = PDFDocument()
        for index in 0..<pageCount {
            let image = NSImage(
                size: CGSize(width: 220 + index, height: 300 + index),
                flipped: false
            ) { rect in
                NSColor.white.setFill()
                rect.fill()
                return true
            }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: index)
        }
        XCTAssertTrue(document.write(to: url))
    }

    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

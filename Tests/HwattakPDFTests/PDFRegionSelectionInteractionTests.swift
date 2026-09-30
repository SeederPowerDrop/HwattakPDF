// SPDX-License-Identifier: MPL-2.0

import AppKit
import CoreGraphics
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFRegionSelectionInteractionTests: XCTestCase {
    @MainActor
    func testMalformedPageOrdinaryDragSelectsPartialLinesImmediatelyAndSurvivesSynchronization() throws {
        for rotation in [0, 90, 180, 270] {
            let fixture = try makeFixture(malformedMetrics: true, rotation: rotation)
            defer { fixture.detach() }
            _ = try XCTUnwrap(PDFTextSelectionGeometry.needsRegionSelection(on: fixture.page) ? true : nil)
            let originalText = fixture.page.string
            let revision = fixture.workspace.revision
            let anchor = CGPoint(x: 94.1, y: 405)
            let endpoint = CGPoint(x: 192.9, y: 375)

            fixture.view.mouseDown(with: try event(.leftMouseDown, point: anchor, fixture: fixture))
            fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: endpoint, fixture: fixture))

            let duringDrag = try XCTUnwrap(fixture.workspace.currentSelection)
            XCTAssertEqual(duringDrag.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                           "bravo charlie delta.\nEcho foxtrot golf")
            XCTAssertTrue(fixture.view.regionSelection.isDragging)
            XCTAssertTrue(duringDrag.pages.first === fixture.page)
            XCTAssertNil(fixture.view.currentSelection)
            XCTAssertEqual(duringDrag.selectionsByLine().count, 2)
            for line in duringDrag.selectionsByLine() {
                XCTAssertLessThan(line.bounds(for: fixture.page).height, 30)
            }

            fixture.view.configure(with: fixture.workspace)
            fixture.view.regionSelection.synchronize()
            XCTAssertTrue(fixture.view.regionSelection.isDragging)
            XCTAssertTrue(fixture.workspace.currentSelection === duringDrag)
            fixture.view.mouseUp(with: try event(.leftMouseUp, point: endpoint, fixture: fixture))
            fixture.view.regionSelection.synchronize()

            XCTAssertTrue(fixture.view.regionSelection.isActive)
            XCTAssertFalse(fixture.view.regionSelection.isDragging)
            XCTAssertEqual(fixture.workspace.currentSelection?.string, duringDrag.string)
            XCTAssertEqual(fixture.page.string, originalText)
            XCTAssertEqual(fixture.workspace.revision, revision)
            XCTAssertFalse(fixture.workspace.isDirty)
            XCTAssertFalse(fixture.workspace.canUndo)

            // A fresh reverse drag selects exactly the same text range.
            fixture.view.mouseDown(with: try event(.leftMouseDown, point: endpoint, fixture: fixture))
            fixture.view.mouseDragged(with: try event(.leftMouseDragged, point: anchor, fixture: fixture))
            fixture.view.mouseUp(with: try event(.leftMouseUp, point: anchor, fixture: fixture))
            XCTAssertEqual(fixture.workspace.currentSelection?.string, duringDrag.string)

            fixture.view.mouseDown(with: try event(.leftMouseDown, point: anchor, fixture: fixture))
            fixture.view.mouseUp(with: try event(.leftMouseUp, point: anchor, fixture: fixture))
            XCTAssertNil(fixture.workspace.currentSelection)
            XCTAssertFalse(fixture.view.regionSelection.isActive)
        }
    }

    @MainActor
    func testMalformedPageDoubleClickSelectsWholeWordAndDragExtendsByWords() throws {
        let fixture = try makeFixture(malformedMetrics: true)
        defer { fixture.detach() }
        _ = try XCTUnwrap(PDFTextSelectionGeometry.needsRegionSelection(on: fixture.page) ? true : nil)
        let anchor = CGPoint(x: 100, y: 405)
        let endpoint = CGPoint(x: 175, y: 375)

        fixture.view.mouseDown(with: try event(
            .leftMouseDown, point: anchor, clickCount: 2, fixture: fixture
        ))
        XCTAssertEqual(fixture.workspace.currentSelection?.string, "bravo")
        fixture.view.mouseDragged(with: try event(
            .leftMouseDragged, point: endpoint, clickCount: 2, fixture: fixture
        ))
        fixture.view.mouseUp(with: try event(
            .leftMouseUp, point: endpoint, clickCount: 2, fixture: fixture
        ))

        XCTAssertEqual(fixture.workspace.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "bravo charlie delta.\nEcho foxtrot golf")
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testOrdinaryDragLeavesNativeTextSelectionUntouched() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let native = try XCTUnwrap(fixture.page.selection(for: NSRange(location: 0, length: 6)))
        fixture.view.setCurrentSelection(native, animate: false)
        fixture.workspace.currentSelection = native

        XCTAssertFalse(fixture.view.regionSelection.begin(with: try event(.leftMouseDown, fixture: fixture)))

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertEqual(fixture.view.currentSelection?.string, native.string)
        XCTAssertTrue(fixture.workspace.currentSelection === native)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testOptionDragUsesEphemeralSelectionAndEscapeCancelsIt() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let revision = fixture.workspace.revision
        let text = fixture.page.string
        let annotationCount = fixture.page.annotations.count

        fixture.view.mouseDown(with: try event(.leftMouseDown, modifiers: .option, fixture: fixture))
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        fixture.view.mouseDragged(with: try event(
            .leftMouseDragged, point: CGPoint(x: 250, y: 250), modifiers: .option, fixture: fixture
        ))

        // Status/sidebar updates must not cancel the rectangle while dragging.
        fixture.view.configure(with: fixture.workspace)
        fixture.view.regionSelection.synchronize()
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        XCTAssertNil(fixture.view.currentSelection)
        XCTAssertNil(fixture.workspace.currentSelection)

        fixture.view.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        )))

        // Escape can arrive while the button is still held. PDFKit must not
        // inherit the rest of a gesture whose mouse-down it never received.
        fixture.view.mouseDragged(with: try event(
            .leftMouseDragged, point: CGPoint(x: 280, y: 240), fixture: fixture
        ))
        fixture.view.mouseUp(with: try event(
            .leftMouseUp, point: CGPoint(x: 280, y: 240), fixture: fixture
        ))

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertFalse(fixture.view.regionSelection.isDragging)
        XCTAssertNil(fixture.view.currentSelection)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertEqual(fixture.workspace.revision, revision)
        XCTAssertEqual(fixture.page.string, text)
        XCTAssertEqual(fixture.page.annotations.count, annotationCount)
        XCTAssertFalse(fixture.workspace.isDirty)
        XCTAssertFalse(fixture.workspace.canUndo)
    }

    @MainActor
    func testOptionClickWithoutAnAreaDoesNotStartRecognition() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }

        fixture.view.mouseDown(with: try event(.leftMouseDown, modifiers: .option, fixture: fixture))
        fixture.view.mouseUp(with: try event(.leftMouseUp, modifiers: .option, fixture: fixture))

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertNil(fixture.view.regionSelection.selection)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testOptionDragDoesNotTakeOverLinksOrFormWidgets() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        let point = CGPoint(x: 100, y: 330)

        for subtype in [PDFAnnotationSubtype.link, .widget] {
            let annotation = PDFAnnotation(
                bounds: CGRect(x: 80, y: 300, width: 100, height: 60),
                forType: subtype, withProperties: nil
            )
            fixture.page.addAnnotation(annotation)
            XCTAssertFalse(fixture.view.regionSelection.begin(with: try event(
                .leftMouseDown, point: point, modifiers: .option, fixture: fixture
            )))
            XCTAssertFalse(fixture.view.regionSelection.isActive)
            fixture.page.removeAnnotation(annotation)
        }
    }

    @MainActor
    func testClearSelectionCancelsQueuedRecognitionWithoutRestoringOldText() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        try finishRegionGesture(in: fixture)
        XCTAssertTrue(fixture.view.regionSelection.isActive)
        XCTAssertFalse(fixture.view.regionSelection.isDragging)

        // The task first yields on MainActor, so this cancellation happens
        // before snapshot/Vision work and requires no OCR service in XCTest.
        fixture.view.clearSelection()
        fixture.workspace.statusMessage = "Selection cleared"
        for _ in 0..<3 { await Task.yield() }

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertNil(fixture.view.regionSelection.selection)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertEqual(fixture.workspace.statusMessage, "Selection cleared")
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testNavigationCancelsQueuedRecognitionFromPreviousPage() async throws {
        let fixture = try makeFixture(pageCount: 2, hostsWindow: true)
        defer { fixture.detach() }
        try finishRegionGesture(in: fixture)
        XCTAssertTrue(fixture.view.regionSelection.isActive)

        let nextPage = try XCTUnwrap(fixture.workspace.document?.page(at: 1))
        fixture.view.go(to: nextPage)
        fixture.view.layoutDocumentView()
        fixture.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(fixture.view.visiblePages.contains { $0 === nextPage })
        XCTAssertFalse(fixture.view.visiblePages.contains { $0 === fixture.page })
        fixture.view.regionSelection.synchronize()
        fixture.workspace.statusMessage = "Navigated to next page"
        for _ in 0..<3 { await Task.yield() }

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertNil(fixture.view.regionSelection.selection)
        XCTAssertNil(fixture.workspace.currentSelection)
        XCTAssertEqual(fixture.workspace.statusMessage, "Navigated to next page")
    }

    @MainActor
    func testNewSearchSelectionCancelsQueuedRecognitionOnSamePage() async throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        try finishRegionGesture(in: fixture)
        let native = try XCTUnwrap(fixture.page.selection(for: NSRange(location: 0, length: 6)))

        // Search state is applied while the coordinator suppresses PDFKit's
        // selection notification. Synchronization must preserve the new owner.
        fixture.workspace.currentSelection = native
        fixture.view.regionSelection.synchronize()
        fixture.workspace.statusMessage = "Search result selected"
        XCTAssertFalse(fixture.view.regionSelection.isActive)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertTrue(fixture.workspace.currentSelection === native)
        XCTAssertEqual(fixture.workspace.statusMessage, "Search result selected")
    }

    @MainActor
    func testToolChangeCancelsInProgressRegion() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        fixture.workspace.setMode(.editing)
        fixture.view.configure(with: fixture.workspace)
        XCTAssertTrue(fixture.view.regionSelection.begin(with: try event(
            .leftMouseDown, modifiers: .option, fixture: fixture
        )))

        fixture.workspace.activeTool = .pen
        fixture.view.configure(with: fixture.workspace)
        fixture.view.regionSelection.synchronize()

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertFalse(fixture.view.regionSelection.isDragging)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    @MainActor
    func testOptionCannotBypassDocumentCopyPermission() throws {
        let fixture = try makeFixture(copyingForbidden: true)
        defer { fixture.detach() }
        XCTAssertEqual(fixture.workspace.document?.permissionsStatus, .user)
        XCTAssertFalse(fixture.workspace.allows(.copyAndPaste))

        XCTAssertFalse(fixture.view.regionSelection.begin(with: try event(
            .leftMouseDown, modifiers: .option, fixture: fixture
        )))

        XCTAssertFalse(fixture.view.regionSelection.isActive)
        XCTAssertNil(fixture.workspace.currentSelection)
    }

    @MainActor
    private struct Fixture {
        let workspace: PDFWorkspaceState
        let view: InteractivePDFView
        let page: PDFPage
        let window: NSWindow?

        func detach() {
            view.regionSelection.cancel()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
            window?.makeFirstResponder(nil)
            window?.contentView = nil
            window?.close()
        }
    }

    @MainActor
    private func makeFixture(
        pageCount: Int = 1,
        copyingForbidden: Bool = false,
        malformedMetrics: Bool = false,
        rotation: Int = 0,
        hostsWindow: Bool = false
    ) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-Region-Interaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf")
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        textView.font = .systemFont(ofSize: 17)
        textView.string = "Choose only this phrase.\nThe remaining page stays unchanged."
        let source = try XCTUnwrap(PDFDocument(data: malformedMetrics
            ? PDFMalformedSelectionTestFixture.data(ascent: 67_306_242, rotation: rotation)
            : textView.dataWithPDF(inside: textView.bounds)))
        for _ in 1..<pageCount {
            source.insert(try XCTUnwrap(source.page(at: 0)?.copy() as? PDFPage), at: source.pageCount)
        }
        if copyingForbidden {
            XCTAssertTrue(source.write(to: url, withOptions: [
                .ownerPasswordOption: "OwnerPass9", .userPasswordOption: "ReaderPass9",
                .accessPermissionsOption: NSNumber(value: 0),
                PDFDocumentWriteOption(rawValue: kCGPDFContextEncryptionKeyLength as String): 128
            ]))
        } else if malformedMetrics {
            // PDFKit's writer can replace the malformed font while rewriting;
            // load the original bytes just as opening the user's file does.
            try PDFMalformedSelectionTestFixture.data(ascent: 67_306_242, rotation: rotation).write(to: url)
        } else {
            XCTAssertTrue(source.write(to: url))
        }
        let workspace = PDFWorkspaceState(passwordProvider: { _, _ in "ReaderPass9" })
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.viewer)
        workspace.activeTool = .select
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        // Page navigation followed by an async yield flushes PDFKit's tile
        // deliveries. Give that fixture a real buffered host before attaching
        // its document; a windowless autoscaled view can release a null tile
        // surface on macOS 15. The window stays owned through cancellation.
        let window: NSWindow?
        if hostsWindow {
            let host = NSWindow(contentRect: view.frame, styleMask: .borderless,
                                backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentView = view
            window = host
        } else {
            window = nil
        }
        view.displayBox = .cropBox
        view.displayMode = .singlePage
        if hostsWindow {
            view.autoScales = false
            view.scaleFactor = 1
        }
        view.document = workspace.document
        if !hostsWindow { view.autoScales = true }
        view.go(to: page)
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        view.configure(with: workspace)
        view.regionSelection.synchronize()
        return Fixture(workspace: workspace, view: view, page: page, window: window)
    }

    @MainActor
    private func finishRegionGesture(in fixture: Fixture) throws {
        fixture.view.mouseDown(with: try event(.leftMouseDown, modifiers: .option, fixture: fixture))
        XCTAssertTrue(fixture.view.regionSelection.isDragging)
        fixture.view.mouseUp(with: try event(
            .leftMouseUp, point: CGPoint(x: 250, y: 250), modifiers: .option, fixture: fixture
        ))
    }

    @MainActor
    private func event(
        _ type: NSEvent.EventType,
        point: CGPoint = CGPoint(x: 100, y: 330),
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1,
        fixture: Fixture
    ) throws -> NSEvent {
        let viewPoint = fixture.view.convert(point, from: fixture.page)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: fixture.view.convert(viewPoint, to: nil),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: fixture.window?.windowNumber ?? 0,
            context: nil, eventNumber: 1, clickCount: clickCount, pressure: 1
        ))
    }
}

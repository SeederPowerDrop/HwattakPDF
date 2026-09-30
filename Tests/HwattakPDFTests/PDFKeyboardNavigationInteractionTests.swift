// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

final class PDFKeyboardNavigationInteractionTests: XCTestCase {
    @MainActor
    func testVerticalArrowsMoveFortyScreenPointsAndReverseAtDifferentZoomLevels() throws {
        for scale: CGFloat in [0.75, 1, 2.5] {
            let fixture = try makeFixture(scale: scale)
            defer { fixture.detach() }
            let scrollView = try XCTUnwrap(fixture.view.firstDocumentScrollView())
            let clip = scrollView.contentView
            let documentView = try XCTUnwrap(clip.documentView)
            centerScrollPosition(scrollView)
            let start = clip.bounds.origin

            XCTAssertTrue(fixture.view.handlePageNavigationKey(try arrow(125)))

            let displacement = clip.bounds.origin.y - start.y
            let screenDisplacement = fixture.view.convert(
                CGSize(width: 0, height: displacement), from: clip
            )
            // NSClipView aligns constrained origins to pixels, so fractional
            // zoom can round the requested distance by half a screen point.
            XCTAssertEqual(abs(screenDisplacement.height), 40, accuracy: 0.5, "scale: \(scale)")
            XCTAssertGreaterThan(displacement * (documentView.isFlipped ? 1 : -1), 0)
            XCTAssertEqual(clip.bounds.origin.x, start.x, accuracy: 0.01)
            XCTAssertFalse(fixture.view.arrowKeyRepeater.isRepeating)

            XCTAssertTrue(fixture.view.handlePageNavigationKey(try arrow(126)))
            XCTAssertEqual(clip.bounds.origin.y, start.y, accuracy: 0.01)
            XCTAssertEqual(clip.bounds.origin.x, start.x, accuracy: 0.01)
        }
    }

    @MainActor
    func testSpeedModifiersKeepTheFirstScrollStepPrecise() throws {
        let fixture = try makeFixture(scale: 2)
        defer { fixture.detach() }
        let scrollView = try XCTUnwrap(fixture.view.firstDocumentScrollView())
        let clip = scrollView.contentView

        for modifiers: NSEvent.ModifierFlags in [[], .shift] {
            centerScrollPosition(scrollView)
            let start = clip.bounds.origin.y

            XCTAssertTrue(fixture.view.handlePageNavigationKey(try arrow(125, modifiers: modifiers)))

            let movement = fixture.view.convert(
                CGSize(width: 0, height: clip.bounds.origin.y - start), from: clip
            )
            XCTAssertEqual(abs(movement.height), 40, accuracy: 0.5)
            XCTAssertFalse(fixture.view.arrowKeyRepeater.isRepeating)
        }
    }

    @MainActor
    func testHorizontalPagingTurnsExactlyOnePageForPlainAndShiftArrows() throws {
        for modifiers: NSEvent.ModifierFlags in [[], .shift] {
            let fixture = try makeFixture(navigation: .horizontalPaging)
            defer { fixture.detach() }

            XCTAssertTrue(fixture.view.handlePageNavigationKey(try arrow(124, modifiers: modifiers)))
            XCTAssertEqual(fixture.workspace.currentPageIndex, 1)
            XCTAssertEqual(fixture.workspace.selectedPages, [1])
            XCTAssertTrue(fixture.view.currentPage === fixture.workspace.document?.page(at: 1))
            XCTAssertFalse(fixture.view.arrowKeyRepeater.isRepeating)

            XCTAssertTrue(fixture.view.handlePageNavigationKey(try arrow(123, modifiers: modifiers)))
            XCTAssertEqual(fixture.workspace.currentPageIndex, 0)
            XCTAssertTrue(fixture.view.currentPage === fixture.workspace.document?.page(at: 0))
        }
    }

    @MainActor
    func testCommandControlAndCombinedModifiersRemainAvailableToOtherHandlers() throws {
        let fixture = try makeFixture(navigation: .horizontalPaging)
        defer { fixture.detach() }

        for modifiers: NSEvent.ModifierFlags in [.command, .control, [.shift, .option]] {
            XCTAssertFalse(fixture.view.handlePageNavigationKey(try arrow(124, modifiers: modifiers)))
            XCTAssertEqual(fixture.workspace.currentPageIndex, 0)
            XCTAssertTrue(fixture.view.currentPage === fixture.workspace.document?.page(at: 0))
            XCTAssertFalse(fixture.view.arrowKeyRepeater.isRepeating)
        }
    }

    @MainActor
    func testOptionArrowsYieldToNativePDFKitInBothNavigationModes() throws {
        for navigation: PDFPageNavigationMode in [.verticalScroll, .horizontalPaging] {
            let fixture = try makeFixture(navigation: navigation)
            defer { fixture.detach() }
            let clip = try XCTUnwrap(fixture.view.firstDocumentScrollView()).contentView
            let originalBounds = clip.bounds
            for keyCode: UInt16 in [123, 124, 125, 126] {
                XCTAssertFalse(fixture.view.handlePageNavigationKey(try arrow(keyCode, modifiers: .option)))
                XCTAssertEqual(clip.bounds, originalBounds)
                XCTAssertEqual(fixture.workspace.currentPageIndex, 0)
                XCTAssertFalse(fixture.view.arrowKeyRepeater.isRepeating)
            }
        }
    }

    @MainActor
    func testShiftAndOptionArrowsLeaveNativeTextSelectionUntouched() throws {
        let fixture = try makeFixture(navigation: .horizontalPaging)
        defer { fixture.detach() }
        let page = try XCTUnwrap(fixture.workspace.document?.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: 6)))
        fixture.view.setCurrentSelection(selection, animate: false)
        fixture.workspace.currentSelection = selection
        let bounds = selection.bounds(for: page)

        for modifiers: NSEvent.ModifierFlags in [.shift, .option] {
            for keyCode: UInt16 in [123, 124, 125, 126] {
                XCTAssertFalse(fixture.view.handlePageNavigationKey(try arrow(keyCode, modifiers: modifiers)))
                XCTAssertEqual(fixture.view.currentSelection?.string, selection.string)
                XCTAssertEqual(fixture.view.currentSelection?.bounds(for: page), bounds)
                XCTAssertTrue(fixture.workspace.currentSelection === selection)
                XCTAssertEqual(fixture.workspace.currentPageIndex, 0)
                XCTAssertFalse(fixture.view.arrowKeyRepeater.isRepeating)
            }
        }
    }

    @MainActor
    func testFieldEditorRetainsArrowKeysWhileFocusedInsideThePDFView() throws {
        let fixture = try makeFixture(navigation: .horizontalPaging)
        defer { fixture.detach() }
        let window = NSWindow(
            contentRect: fixture.view.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = fixture.view
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        let editor = NSTextView(frame: CGRect(x: 20, y: 20, width: 150, height: 30))
        editor.isFieldEditor = true
        editor.string = "Editable field"
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        fixture.view.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))

        for modifiers: NSEvent.ModifierFlags in [[], .shift, .option] {
            XCTAssertFalse(fixture.view.handlePageNavigationKey(try arrow(
                124, modifiers: modifiers, windowNumber: window.windowNumber
            )))
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 0))
            XCTAssertEqual(fixture.workspace.currentPageIndex, 0)
            XCTAssertFalse(fixture.view.arrowKeyRepeater.isRepeating)
        }
    }

    @MainActor
    func testComparisonViewsRetainNativeArrowHandling() throws {
        let fixture = try makeFixture()
        defer { fixture.detach() }
        fixture.view.viewportContext = .comparison
        let clip = try XCTUnwrap(fixture.view.firstDocumentScrollView()).contentView
        let originalBounds = clip.bounds

        for keyCode: UInt16 in [123, 124, 125, 126] {
            for modifiers: NSEvent.ModifierFlags in [[], .shift, .option] {
                XCTAssertFalse(fixture.view.handlePageNavigationKey(try arrow(keyCode, modifiers: modifiers)))
                XCTAssertEqual(clip.bounds, originalBounds)
                XCTAssertEqual(fixture.workspace.currentPageIndex, 0)
            }
        }
        XCTAssertFalse(fixture.view.arrowKeyRepeater.isRepeating)
    }

    @MainActor
    func testArrowsWithoutAnOpenDocumentAreNotIntercepted() throws {
        _ = NSApplication.shared
        let workspace = PDFWorkspaceState()
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.configure(with: workspace)
        defer { view.workspaceState = nil }

        for keyCode: UInt16 in [123, 124, 125, 126] {
            XCTAssertFalse(view.handlePageNavigationKey(try arrow(keyCode)))
        }
        XCTAssertFalse(view.arrowKeyRepeater.isRepeating)
    }

    @MainActor
    func testVerticalFixedSpreadArrowsTurnAtThePageBoundary() throws {
        let fixture = try makeFixture(columns: 2, fixedSpread: true)
        defer { fixture.detach() }
        XCTAssertEqual(fixture.view.displayMode, .twoUp)
        let scrollView = try XCTUnwrap(fixture.view.firstDocumentScrollView())

        scrollToVerticalBoundary(scrollView, down: true)
        XCTAssertTrue(fixture.view.handlePageNavigationKey(try arrow(125)))
        XCTAssertEqual(fixture.workspace.currentPageIndex, 2)
        XCTAssertEqual(fixture.workspace.selectedPages, [2])

        fixture.view.layoutDocumentView()
        fixture.view.layoutSubtreeIfNeeded()
        scrollToVerticalBoundary(scrollView, down: false)
        XCTAssertTrue(fixture.view.handlePageNavigationKey(try arrow(126)))
        XCTAssertEqual(fixture.workspace.currentPageIndex, 0)
        XCTAssertFalse(fixture.view.arrowKeyRepeater.isRepeating)
    }

    @MainActor
    private struct Fixture {
        let workspace: PDFWorkspaceState
        let view: InteractivePDFView

        func detach() {
            view.arrowKeyRepeater.stop()
            view.resetPageTurnGesture()
            view.regionSelection.cancel()
            view.prepareInlineTextEditingOverlayForRemoval()
            view.prepareAnnotationEditingOverlayForRemoval()
            view.workspaceState = nil
        }
    }

    @MainActor
    private func makeFixture(
        scale: CGFloat = 1,
        navigation: PDFPageNavigationMode = .verticalScroll,
        columns: Int = 1,
        fixedSpread: Bool = false
    ) throws -> Fixture {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HwattakPDF-Keyboard-Navigation-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf")
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 1800))
        textView.font = .systemFont(ofSize: 17)
        textView.string = "Select this phrase.\nArrow keys scroll the PDF or turn a page."
        let source = try XCTUnwrap(PDFDocument(data: textView.dataWithPDF(inside: textView.bounds)))
        for _ in 1..<4 {
            source.insert(try XCTUnwrap(source.page(at: 0)?.copy() as? PDFPage), at: source.pageCount)
        }
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        workspace.setMode(.viewer)
        workspace.activeTool = .select
        workspace.pageColumns = columns
        workspace.twoPageDisplayMode = fixedSpread ? .paged : .continuous
        workspace.setCurrentPage(0)
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.pageNavigationMode = navigation
        view.displayDirection = navigation == .horizontalPaging ? .horizontal : .vertical
        view.displayMode = PDFKitViewer.requestedDisplayMode(
            pageColumns: columns, twoPageDisplayMode: workspace.twoPageDisplayMode,
            navigationMode: navigation
        )
        view.displaysAsBook = false
        view.displayBox = .cropBox
        view.document = workspace.document
        view.autoScales = false
        view.scaleFactor = scale
        view.configure(with: workspace)
        view.go(to: try XCTUnwrap(workspace.document?.page(at: 0)))
        view.layoutDocumentView()
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(view.window)
        return Fixture(workspace: workspace, view: view)
    }

    @MainActor
    private func centerScrollPosition(_ scrollView: NSScrollView) {
        let clip = scrollView.contentView
        guard let document = clip.documentView else { return }
        var proposed = clip.bounds
        proposed.origin = CGPoint(
            x: document.frame.midX - proposed.width / 2,
            y: document.frame.midY - proposed.height / 2
        )
        clip.setBoundsOrigin(clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    @MainActor
    private func scrollToVerticalBoundary(_ scrollView: NSScrollView, down: Bool) {
        let clip = scrollView.contentView
        guard let document = clip.documentView else { return }
        var proposed = clip.bounds
        proposed.origin.y = (down == document.isFlipped) ? 1_000_000 : -1_000_000
        clip.setBoundsOrigin(clip.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    @MainActor
    private func arrow(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [],
        windowNumber: Int = 0
    ) throws -> NSEvent {
        let character: String
        switch keyCode {
        case 123: character = "\u{F702}"
        case 124: character = "\u{F703}"
        case 125: character = "\u{F701}"
        default: character = "\u{F700}"
        }
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode
        ))
    }
}

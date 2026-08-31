// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import VibePDF

final class PDFViewportScrollInteractionTests: XCTestCase {
    @MainActor
    func testPDFKitDisplayModeResolverSeparatesPagedSpreadAndComparison() {
        for mode in PDFTwoPageDisplayMode.allCases {
            XCTAssertEqual(
                PDFKitViewer.requestedDisplayMode(
                    pageColumns: 1,
                    twoPageDisplayMode: mode
                ),
                .singlePageContinuous
            )
            XCTAssertEqual(
                PDFKitViewer.requestedDisplayMode(
                    pageColumns: 0,
                    twoPageDisplayMode: mode
                ),
                .singlePageContinuous
            )
        }

        XCTAssertEqual(
            PDFKitViewer.requestedDisplayMode(
                pageColumns: 2,
                twoPageDisplayMode: .continuous
            ),
            .twoUpContinuous
        )
        XCTAssertEqual(
            PDFKitViewer.requestedDisplayMode(
                pageColumns: 2,
                twoPageDisplayMode: .paged
            ),
            .twoUp
        )

        for count in [3, 4, 12] {
            for mode in PDFTwoPageDisplayMode.allCases {
                XCTAssertEqual(
                    PDFKitViewer.requestedDisplayMode(
                        pageColumns: count,
                        twoPageDisplayMode: mode
                    ),
                    .twoUpContinuous
                )
            }
        }
        XCTAssertEqual(
            PDFKitViewer.requestedDisplayMode(
                pageColumns: 2,
                twoPageDisplayMode: .paged,
                viewportContext: .comparison
            ),
            .twoUpContinuous
        )
    }

    @MainActor
    func testNativePagedTwoUpShowsOneExactSpreadWithoutBookCoverOffset() throws {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 {
            throw XCTSkip(
                "macOS 15 PDFKit can release offscreen tile surfaces during XCTest teardown."
            )
        }

        let document = PDFDocument()
        for _ in 0..<5 {
            document.insert(blankPage(size: CGSize(width: 400, height: 560)), at: document.pageCount)
        }
        let pdfView = InteractivePDFView(
            frame: CGRect(x: 0, y: 0, width: 900, height: 680)
        )
        pdfView.displayDirection = .vertical
        pdfView.displaysAsBook = false
        pdfView.displayMode = .twoUp
        pdfView.document = document
        pdfView.autoScales = true

        func visibleIndices() -> Set<Int> {
            pdfView.layoutDocumentView()
            pdfView.layoutSubtreeIfNeeded()
            return Set(pdfView.visiblePages.compactMap { page in
                let index = document.index(for: page)
                return index == NSNotFound ? nil : index
            })
        }

        pdfView.go(to: try XCTUnwrap(document.page(at: 0)))
        XCTAssertEqual(visibleIndices(), [0, 1])
        pdfView.go(to: try XCTUnwrap(document.page(at: 1)))
        XCTAssertEqual(visibleIndices(), [0, 1])
        pdfView.go(to: try XCTUnwrap(document.page(at: 2)))
        XCTAssertEqual(visibleIndices(), [2, 3])
        pdfView.go(to: try XCTUnwrap(document.page(at: 4)))
        XCTAssertEqual(visibleIndices(), [4])

        let workspace = PDFWorkspaceState()
        workspace.selectTwoPageDisplayMode(.paged)
        let coordinator = PDFKitViewer.Coordinator(state: workspace)
        let rightPage = try XCTUnwrap(document.page(at: 1))
        pdfView.go(to: rightPage)
        _ = visibleIndices()
        coordinator.lastAppliedPageIndex = 1
        coordinator.lastAppliedPage = rightPage
        XCTAssertFalse(
            coordinator.requiresNavigation(to: rightPage, at: 1, in: pdfView),
            "A requested right-hand page is already satisfied by its visible spread."
        )
    }

    func testOptionOnlyZoomUsesDifferentTrackpadAndMouseSensitivity() throws {
        let precise = try zoomFactor(
            for: input(deltaY: 2, precise: true, modifiers: .option),
            zoomModifier: .option
        )
        let mouse = try zoomFactor(
            for: input(deltaY: 2, precise: false, modifiers: .option),
            zoomModifier: .option
        )

        XCTAssertGreaterThan(precise, 1)
        XCTAssertGreaterThan(mouse, precise)
        XCTAssertEqual(precise, exp(0.024), accuracy: 0.0001)
        XCTAssertEqual(mouse, exp(0.24), accuracy: 0.0001)

        let zoomOut = try zoomFactor(
            for: input(deltaY: -2, precise: false, modifiers: .option),
            zoomModifier: .option
        )
        XCTAssertLessThan(zoomOut, 1)
    }

    func testZoomRequiresExactConfiguredModifierAndAmbiguousCombinationsStayNative() {
        XCTAssertNative(input(deltaY: 8, modifiers: []), zoomModifier: .option)
        XCTAssertNative(input(deltaY: 8, modifiers: .command), zoomModifier: .option)
        XCTAssertNative(input(deltaY: 8, modifiers: [.option, .shift]), zoomModifier: .option)
        XCTAssertNative(input(deltaY: 8, modifiers: [.option, .command]), zoomModifier: .option)
        XCTAssertNative(input(deltaY: 8, modifiers: .option), zoomModifier: .disabled)

        guard case .zoom = PDFViewportScrollIntentResolver.resolve(
            input(deltaY: 8, modifiers: .command),
            zoomModifier: .command
        ) else {
            return XCTFail("Command should zoom only when explicitly configured")
        }
    }

    func testShiftMapsVerticalWheelToHorizontalAndPreservesUsefulNativeX() {
        XCTAssertHorizontalDelta(
            input(deltaY: -6, precise: true, modifiers: .shift),
            expected: -6
        )
        XCTAssertHorizontalDelta(
            input(deltaX: -2, deltaY: -6, precise: true, modifiers: .shift),
            expected: -8
        )
        XCTAssertHorizontalDelta(
            input(deltaX: 2, deltaY: -6, precise: true, modifiers: .shift),
            expected: -6
        )
        XCTAssertHorizontalDelta(
            input(deltaY: 1, precise: false, modifiers: .shift),
            expected: PDFViewportScrollIntentResolver.mouseWheelLineMultiplier
        )
    }

    func testNativeHorizontalOrdinaryAndControlScrollingAreNeverConsumed() {
        XCTAssertNative(input(deltaX: 14, deltaY: 0), zoomModifier: .option)
        XCTAssertNative(input(deltaY: 14), zoomModifier: .option)
        XCTAssertNative(input(deltaY: 14, modifiers: .control), zoomModifier: .option)
        XCTAssertNative(input(deltaY: 14, modifiers: [.command, .shift]), zoomModifier: .option)
    }

    @MainActor
    func testAppKitModifierMappingIgnoresCapsLockAndFunction() {
        XCTAssertEqual(
            InteractivePDFView.viewportModifiers(
                from: [.option, .capsLock, .function]
            ),
            .option
        )
        XCTAssertEqual(
            InteractivePDFView.viewportModifiers(from: [.option, .shift]),
            [.option, .shift]
        )
    }

    @MainActor
    func testRepeatedViewerConfigurationKeepsEditorOverlaysAttachedOnce() throws {
        let workspace = PDFWorkspaceState()
        let pdfView = InteractivePDFView(
            frame: CGRect(x: 0, y: 0, width: 420, height: 520)
        )

        pdfView.configure(with: workspace)
        let annotationOverlay = try XCTUnwrap(
            pdfView.subviews.compactMap { $0 as? PDFAnnotationEditingOverlayView }.first
        )
        let inlineOverlay = try XCTUnwrap(
            pdfView.subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }.first
        )
        XCTAssertEqual(annotationOverlay.superviewAttachmentCount, 1)
        XCTAssertEqual(inlineOverlay.superviewAttachmentCount, 1)
        XCTAssertTrue(inlineOverlay.isHidden)

        for _ in 0..<50 {
            pdfView.configure(with: workspace)
        }

        XCTAssertEqual(annotationOverlay.superviewAttachmentCount, 1)
        XCTAssertEqual(inlineOverlay.superviewAttachmentCount, 1)
        XCTAssertTrue(annotationOverlay.superview === pdfView)
        XCTAssertTrue(inlineOverlay.superview === pdfView)
        XCTAssertEqual(
            pdfView.subviews.compactMap { $0 as? PDFAnnotationEditingOverlayView }.count,
            1
        )
        XCTAssertEqual(
            pdfView.subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }.count,
            1
        )

        let simulatedPDFKitReplacement = NSView(frame: .zero)
        pdfView.addSubview(simulatedPDFKitReplacement, positioned: .above, relativeTo: nil)
        pdfView.configure(with: workspace)

        let inkPreviewIndex = try XCTUnwrap(pdfView.inkPreviewSubviewIndexForTesting)
        XCTAssertEqual(inkPreviewIndex, pdfView.subviews.count - 3)
        XCTAssertTrue(pdfView.subviews.suffix(2).first === annotationOverlay)
        XCTAssertTrue(pdfView.subviews.last === inlineOverlay)
        XCTAssertEqual(annotationOverlay.superviewAttachmentCount, 1)
        XCTAssertEqual(inlineOverlay.superviewAttachmentCount, 1)
    }

    @MainActor
    func testInteractivePDFViewRelinquishesNativeFinderFileDestination() {
        let pdfView = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 320, height: 420))
        let legacyFilenameType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

        XCTAssertFalse(pdfView.registeredDraggedTypes.contains(legacyFilenameType))
        XCTAssertFalse(pdfView.registeredDraggedTypes.contains(.fileURL))

        // Defend against a future PDFKit lifecycle change that re-registers
        // its native filename destination after document/layout replacement.
        pdfView.registerForDraggedTypes([legacyFilenameType, .fileURL])
        XCTAssertTrue(pdfView.registeredDraggedTypes.contains(legacyFilenameType))
        pdfView.relinquishNativeFileDropDestination()

        XCTAssertFalse(pdfView.registeredDraggedTypes.contains(legacyFilenameType))
        XCTAssertFalse(pdfView.registeredDraggedTypes.contains(.fileURL))
    }

    func testScaleClampHonorsPDFViewBoundsInsideWorkspaceSafetyEnvelope() {
        XCTAssertEqual(
            PDFViewportScrollIntentResolver.clampedScale(
                currentScale: 1,
                stepFactor: 100,
                minimumScale: 0,
                maximumScale: 100
            ),
            20
        )
        XCTAssertEqual(
            PDFViewportScrollIntentResolver.clampedScale(
                currentScale: 1,
                stepFactor: 0.0001,
                minimumScale: 0,
                maximumScale: 100
            ),
            0.05
        )
        XCTAssertEqual(
            PDFViewportScrollIntentResolver.clampedScale(
                currentScale: 1,
                stepFactor: 0.01,
                minimumScale: 0.25,
                maximumScale: 3
            ),
            0.25
        )
        XCTAssertEqual(
            PDFViewportScrollIntentResolver.clampedScale(
                currentScale: 2,
                stepFactor: 10,
                minimumScale: 0.25,
                maximumScale: 3
            ),
            3
        )
    }

    func testWheelAccumulatorMultipliesStepsAgainstOneGestureBaseline() {
        var accumulator = PDFWheelZoomAccumulator()
        XCTAssertEqual(accumulator.consume(stepFactor: 1.1), 1.1, accuracy: 0.0001)
        XCTAssertEqual(accumulator.consume(stepFactor: 1.2), 1.32, accuracy: 0.0001)
        XCTAssertEqual(accumulator.consume(stepFactor: .infinity), 1.32, accuracy: 0.0001)
        accumulator.reset()
        XCTAssertEqual(accumulator.relativeFactor, 1, accuracy: 0.0001)
    }

    func testLiveScrollReportingThrottlesHUDWorkAndIgnoresHorizontalOnlyMovement() {
        XCTAssertEqual(
            PDFLiveScrollReportingPolicy.deliveryDelay(
                lastDeliveryTime: nil,
                currentTime: 10
            ),
            0
        )
        XCTAssertEqual(
            PDFLiveScrollReportingPolicy.deliveryDelay(
                lastDeliveryTime: 10,
                currentTime: 10.01
            ),
            PDFLiveScrollReportingPolicy.minimumInterval - 0.01,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PDFLiveScrollReportingPolicy.deliveryDelay(
                lastDeliveryTime: 10,
                currentTime: 10.1
            ),
            0
        )

        XCTAssertFalse(
            PDFLiveScrollReportingPolicy.hasMeaningfulVerticalMovement(
                from: 420,
                to: 420.05
            )
        )
        XCTAssertTrue(
            PDFLiveScrollReportingPolicy.hasMeaningfulVerticalMovement(
                from: 420,
                to: 421
            )
        )
        XCTAssertFalse(
            PDFLiveScrollReportingPolicy.hasMeaningfulVerticalMovement(
                from: 420,
                to: .nan
            )
        )
    }

    @MainActor
    func testCoordinatorCoalescesLiveScrollFlushesEndAndPersistsHorizontalSettle() {
        let workspace = PDFWorkspaceState()
        let pdfView = InteractivePDFView(
            frame: CGRect(x: 0, y: 0, width: 240, height: 280)
        )
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.7

        let scrollView = NSScrollView(
            frame: CGRect(x: 0, y: 0, width: 240, height: 280)
        )
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = NSView(
            frame: CGRect(x: 0, y: 0, width: 1_200, height: 2_400)
        )
        pdfView.addSubview(scrollView, positioned: .below, relativeTo: nil)

        var hudReportCount = 0
        let coordinator = PDFKitViewer.Coordinator(
            state: workspace,
            onScrollActivity: { _ in hudReportCount += 1 },
            currentTime: { 10 }
        )
        coordinator.attach(to: pdfView)

        // All 120 notifications arrive in one main-actor turn at the same
        // injected time. The coordinator delivers the newest metrics once now
        // and keeps at most one pending flush instead of invoking SwiftUI 120x.
        for offset in 1...120 {
            scrollView.contentView.setBoundsOrigin(
                CGPoint(x: 0, y: CGFloat(offset * 4))
            )
            NotificationCenter.default.post(
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
        }
        XCTAssertEqual(hudReportCount, 1)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        XCTAssertEqual(hudReportCount, 2)
        let verticalViewport = workspace.pdfViewportState(for: .normal)
        XCTAssertGreaterThan(verticalViewport.verticalScrollProgress ?? 0, 0)

        // A horizontal-only move should not wake the vertical page HUD, but
        // the settled position must still be persisted at didEndLiveScroll.
        scrollView.contentView.setBoundsOrigin(CGPoint(x: 360, y: 480))
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        XCTAssertEqual(hudReportCount, 2)
        let horizontalViewport = workspace.pdfViewportState(for: .normal)
        XCTAssertGreaterThan(horizontalViewport.horizontalScrollProgress ?? 0, 0)

        coordinator.detach()
        let persistedVertical = horizontalViewport.verticalScrollProgress
        scrollView.contentView.setBoundsOrigin(CGPoint(x: 360, y: 700))
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        XCTAssertEqual(hudReportCount, 2)
        XCTAssertEqual(
            workspace.pdfViewportState(for: .normal).verticalScrollProgress,
            persistedVertical
        )
    }

    func testModifiedGestureOwnershipSurvivesModifierReleaseIntoMomentum() {
        var zoomLatch = PDFViewportModifiedScrollGestureLatch()
        XCTAssertEqual(
            zoomLatch.ownerForEvent(
                intent: .zoom(stepFactor: 1.1),
                touchPhasePresent: true,
                touchPhaseBegan: true,
                momentumPhasePresent: false
            ),
            .zoom
        )
        zoomLatch.touchEnded()
        XCTAssertEqual(
            zoomLatch.ownerForEvent(
                intent: .native,
                touchPhasePresent: false,
                touchPhaseBegan: false,
                momentumPhasePresent: true
            ),
            .zoom
        )

        var panLatch = PDFViewportModifiedScrollGestureLatch()
        XCTAssertEqual(
            panLatch.ownerForEvent(
                intent: .horizontalPan(delta: -8),
                touchPhasePresent: true,
                touchPhaseBegan: true,
                momentumPhasePresent: false
            ),
            .horizontalPan
        )
        panLatch.touchEnded()
        XCTAssertEqual(
            panLatch.ownerForEvent(
                intent: .native,
                touchPhasePresent: false,
                touchPhaseBegan: false,
                momentumPhasePresent: true
            ),
            .horizontalPan
        )
    }

    func testAwaitingMomentumDoesNotCaptureANewMayBeginGesture() {
        var latch = PDFViewportModifiedScrollGestureLatch()
        _ = latch.ownerForEvent(
            intent: .zoom(stepFactor: 1.1),
            touchPhasePresent: true,
            touchPhaseBegan: true,
            momentumPhasePresent: false
        )
        latch.touchEnded()

        XCTAssertNil(
            latch.ownerForEvent(
                intent: .native,
                touchPhasePresent: true,
                touchPhaseBegan: true,
                momentumPhasePresent: false
            )
        )
        XCTAssertNil(latch.owner)
    }

    @MainActor
    func testPDFKitZoomKeepsThePDFPointUnderAnOffCenterPointer() throws {
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 15 {
            throw XCTSkip(
                "macOS 15 PDFKit double-releases an offscreen PDFTileSurface "
                    + "after scale changes when XCTest next flushes Core Animation."
            )
        }

        let document = PDFDocument()
        let page = blankPage(size: CGSize(width: 600, height: 800))
        document.insert(page, at: 0)

        for (pointer, targetScale) in [
            (CGPoint(x: 96, y: 118), CGFloat(1.5)),
            // Regression: pre-scale clip offsets jump badly at this interior
            // point because PDFKit halves clip.bounds at 1x -> 2x.
            (CGPoint(x: 300, y: 250), CGFloat(2))
        ] {
            let pdfView = InteractivePDFView(
                frame: CGRect(x: 0, y: 0, width: 400, height: 500)
            )
            pdfView.displayMode = .singlePageContinuous
            pdfView.document = document
            pdfView.autoScales = false
            pdfView.scaleFactor = 1
            pdfView.layoutDocumentView()

            let pagePoint = pdfView.convert(pointer, to: page)
            XCTAssertTrue(
                pdfView.zoomAroundPointer(
                    stepFactor: targetScale,
                    pointerInView: pointer
                )
            )

            let pointAfterZoom = pdfView.convert(pagePoint, from: page)
            XCTAssertEqual(pointAfterZoom.x, pointer.x, accuracy: 1.1)
            XCTAssertEqual(pointAfterZoom.y, pointer.y, accuracy: 1.1)
            XCTAssertFalse(pdfView.autoScales)
            XCTAssertEqual(pdfView.scaleFactor, targetScale, accuracy: 0.001)
        }
    }

    @MainActor
    func testUnmodifiedScrollRoutingDoesNotMutateFormOrAnnotationState() throws {
        let document = PDFDocument()
        let page = blankPage(size: CGSize(width: 300, height: 400))
        let widget = PDFAnnotation(
            bounds: CGRect(x: 20, y: 320, width: 140, height: 24),
            forType: .widget,
            withProperties: nil
        )
        widget.widgetFieldType = .text
        widget.widgetStringValue = "unchanged"
        let ink = PDFAnnotation(
            bounds: CGRect(x: 30, y: 80, width: 80, height: 50),
            forType: .ink,
            withProperties: nil
        )
        page.addAnnotation(widget)
        page.addAnnotation(ink)
        document.insert(page, at: 0)

        let pdfView = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        let beforeAnnotations = page.annotations

        let event = try XCTUnwrap(scrollEvent(deltaY: -12))
        XCTAssertFalse(pdfView.handleViewportScroll(event))
        XCTAssertEqual(widget.widgetStringValue, "unchanged")
        XCTAssertEqual(page.annotations.count, beforeAnnotations.count)
        XCTAssertTrue(page.annotations[0] === beforeAnnotations[0])
        XCTAssertTrue(page.annotations[1] === beforeAnnotations[1])
    }

    @MainActor
    func testCoordinatorPersistsWheelZoomSeparatelyForNormalAndComparisonViews() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibePDF-Wheel-Zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("viewport.pdf")

        let source = PDFDocument()
        source.insert(blankPage(size: CGSize(width: 400, height: 600)), at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))

        let normalView = configuredView(workspace: workspace, scale: 1.6)
        let normalCoordinator = PDFKitViewer.Coordinator(
            state: workspace,
            viewportContext: .normal
        )
        normalCoordinator.attach(to: normalView)
        normalCoordinator.captureViewportState()
        normalCoordinator.detach()

        let comparisonView = configuredView(workspace: workspace, scale: 2.25)
        let comparisonCoordinator = PDFKitViewer.Coordinator(
            state: workspace,
            viewportContext: .comparison
        )
        comparisonCoordinator.attach(to: comparisonView)
        comparisonCoordinator.captureViewportState()
        comparisonCoordinator.detach()

        XCTAssertEqual(
            workspace.pdfViewportState(for: .normal).scaleFactor ?? 0,
            1.6,
            accuracy: 0.001
        )
        XCTAssertEqual(
            workspace.pdfViewportState(for: .comparison).scaleFactor ?? 0,
            2.25,
            accuracy: 0.001
        )
    }

    private func input(
        deltaX: CGFloat = 0,
        deltaY: CGFloat,
        precise: Bool = true,
        modifiers: PDFViewportScrollModifiers = []
    ) -> PDFViewportScrollInput {
        PDFViewportScrollInput(
            deltaX: deltaX,
            deltaY: deltaY,
            hasPreciseDeltas: precise,
            modifiers: modifiers
        )
    }

    private func zoomFactor(
        for input: PDFViewportScrollInput,
        zoomModifier: PDFWheelZoomModifier
    ) throws -> CGFloat {
        guard case let .zoom(factor) = PDFViewportScrollIntentResolver.resolve(
            input,
            zoomModifier: zoomModifier
        ) else {
            throw TestFailure.unexpectedIntent
        }
        return factor
    }

    private func XCTAssertNative(
        _ input: PDFViewportScrollInput,
        zoomModifier: PDFWheelZoomModifier,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            PDFViewportScrollIntentResolver.resolve(
                input,
                zoomModifier: zoomModifier
            ),
            .native,
            file: file,
            line: line
        )
    }

    private func XCTAssertHorizontalDelta(
        _ input: PDFViewportScrollInput,
        expected: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .horizontalPan(delta) = PDFViewportScrollIntentResolver.resolve(
            input,
            zoomModifier: .option
        ) else {
            return XCTFail("Expected horizontal pan", file: file, line: line)
        }
        XCTAssertEqual(delta, expected, accuracy: 0.0001, file: file, line: line)
    }

    private func scrollEvent(deltaY: Int32) -> NSEvent? {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: deltaY,
            wheel2: 0,
            wheel3: 0
        ) else { return nil }
        return NSEvent(cgEvent: event)
    }

    @MainActor
    private func blankPage(size: CGSize) -> PDFPage {
        let page = PDFPage()
        let bounds = CGRect(origin: .zero, size: size)
        page.setBounds(bounds, for: .mediaBox)
        page.setBounds(bounds, for: .cropBox)
        return page
    }

    @MainActor
    private func configuredView(
        workspace: PDFWorkspaceState,
        scale: CGFloat
    ) -> InteractivePDFView {
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 420, height: 520))
        // This verifies coordinator state routing, not PDF rendering. Attaching
        // a document here starts offscreen PDFKit tile work that outlives the
        // unit test on macOS 15 and can crash a later XCTest run-loop flush.
        view.autoScales = false
        view.scaleFactor = scale
        return view
    }

    private enum TestFailure: Error {
        case unexpectedIntent
    }
}

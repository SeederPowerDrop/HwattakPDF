// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import HwattakPDF

final class PDFComparisonConfigurationTests: XCTestCase {
    @MainActor
    func testComparisonViewerAlwaysDerivesSelectAsItsEffectiveTool() {
        let workspace = PDFWorkspaceState()
        workspace.setMode(.editing)
        workspace.activeTool = .pen
        let pdfView = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 320, height: 420))
        pdfView.viewportContext = .comparison

        pdfView.configure(with: workspace)
        XCTAssertEqual(pdfView.activeTool, .select)
        XCTAssertEqual(workspace.activeTool, .pen)
        XCTAssertTrue(pdfView.suppressesComparisonWidgetTraversal(keyCode: 48))
        XCTAssertFalse(
            pdfView.suppressesComparisonWidgetTraversal(keyCode: 125),
            "Arrow/page navigation keys must remain native in comparison mode."
        )

        workspace.activeTool = .eraser
        pdfView.configure(with: workspace)
        XCTAssertEqual(pdfView.activeTool, .select)
        XCTAssertEqual(workspace.activeTool, .eraser)

        pdfView.viewportContext = .normal
        pdfView.configure(with: workspace)
        XCTAssertEqual(pdfView.activeTool, .eraser)
        XCTAssertFalse(pdfView.suppressesComparisonWidgetTraversal(keyCode: 48))
    }

    @MainActor
    func testComparisonViewerDetectsWidgetHitWithoutBlockingOrdinaryPageHit() throws {
        let document = PDFDocument()
        let image = NSImage(size: CGSize(width: 180, height: 240), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        let widget = PDFAnnotation(
            bounds: CGRect(x: 30, y: 170, width: 100, height: 28),
            forType: .widget,
            withProperties: nil
        )
        widget.widgetFieldType = .text
        widget.fieldName = "comparison-protected-field"
        page.addAnnotation(widget)
        document.insert(page, at: 0)

        let pdfView = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 360, height: 480))
        pdfView.viewportContext = .comparison
        pdfView.displayBox = .cropBox
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.layoutDocumentView()

        let widgetPoint = pdfView.convert(
            CGPoint(x: widget.bounds.midX, y: widget.bounds.midY),
            from: page
        )
        let ordinaryPoint = pdfView.convert(CGPoint(x: 150, y: 40), from: page)
        XCTAssertTrue(pdfView.comparisonWidget(at: widgetPoint) === widget)
        XCTAssertNil(pdfView.comparisonWidget(at: ordinaryPoint))
    }

    @MainActor
    func testComparisonDocumentResumesHibernatedWorkspaceBeforeDisplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HwattakPDF-Comparison-Resume-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hibernated.pdf")
        let source = PDFDocument()
        let image = NSImage(
            size: CGSize(width: 180, height: 240),
            flipped: false
        ) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        source.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(source.write(to: url))

        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        XCTAssertTrue(workspace.hibernateIfPossible())
        XCTAssertTrue(workspace.isHibernated)
        XCTAssertNil(workspace.document)

        let candidate = ComparisonDocument(id: UUID(), workspace: workspace)
        XCTAssertTrue(candidate.prepareForDisplay())
        XCTAssertNotNil(workspace.document)
        XCTAssertFalse(workspace.isHibernated)
        XCTAssertEqual(workspace.pageCount, 1)
    }

    func testComparisonPanelProviderAdvertisesTheExactAcceptedDropType() {
        let provider = comparisonPanelItemProvider(for: UUID())

        XCTAssertEqual(comparisonPanelDragType, .utf8PlainText)
        XCTAssertTrue(
            provider.hasItemConformingToTypeIdentifier(comparisonPanelDragType.identifier)
        )
    }

    func testComparisonPanelPayloadRejectsTabPayloadRawUUIDAndForeignText() {
        let documentID = UUID()
        let encoded = PDFComparisonPanelDragPayload.encodedValue(for: documentID)

        XCTAssertEqual(PDFComparisonPanelDragPayload.decode(encoded), documentID)
        XCTAssertNil(PDFComparisonPanelDragPayload.decode(documentID.uuidString))
        XCTAssertNil(PDFComparisonPanelDragPayload.decode("foreign plain text"))
        XCTAssertNil(
            PDFComparisonPanelDragPayload.decode(
                PDFTabDragPayload.encodedValue(for: documentID)
            )
        )
    }

    func testSelectionKeepsUserOrderAndCapsAtFourDocuments() {
        let ids = (0..<5).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration()

        ids.forEach { configuration.toggleSelection($0) }

        XCTAssertEqual(configuration.selectedDocumentIDs, Array(ids.prefix(4)))
        XCTAssertTrue(configuration.canBeginComparison)

        configuration.toggleSelection(ids[1])
        XCTAssertEqual(configuration.selectedDocumentIDs, [ids[0], ids[2], ids[3]])

        configuration.toggleSelection(ids[4])
        XCTAssertEqual(configuration.selectedDocumentIDs, [ids[0], ids[2], ids[3], ids[4]])
    }

    func testLockedDocumentIsRemovedFromBothSyncDirectionsWhenDeselected() {
        let first = UUID()
        let second = UUID()
        var configuration = PDFComparisonConfiguration(
            selectedDocumentIDs: [first, second]
        )

        configuration.toggleLock(second)
        XCTAssertTrue(configuration.isLocked(second))

        configuration.toggleSelection(second)
        XCTAssertFalse(configuration.isLocked(second))
        XCTAssertFalse(configuration.canBeginComparison)
    }

    func testReorderAndNormalizePreserveValidPanelOrderAndRemoveStaleLocks() {
        let first = UUID()
        let second = UUID()
        let closed = UUID()
        var configuration = PDFComparisonConfiguration(
            selectedDocumentIDs: [first, second, closed],
            lockedDocumentIDs: [first, closed]
        )

        configuration.moveSelection(second, by: -1)
        XCTAssertEqual(configuration.selectedDocumentIDs, [second, first, closed])

        configuration.normalize(availableDocumentIDs: [first, second])
        XCTAssertEqual(configuration.selectedDocumentIDs, [second, first])
        XCTAssertEqual(configuration.lockedDocumentIDs, [first])
        XCTAssertTrue(configuration.canBeginComparison)
    }

    func testDropReorderSupportsBeforeAndAfterWithoutDroppingInvalidSource() {
        let ids = (0..<4).map { _ in UUID() }
        let missing = UUID()
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids)

        configuration.moveSelection(ids[0], after: ids[2])
        XCTAssertEqual(configuration.selectedDocumentIDs, [ids[1], ids[2], ids[0], ids[3]])

        configuration.moveSelection(ids[3], before: ids[1])
        XCTAssertEqual(configuration.selectedDocumentIDs, [ids[3], ids[1], ids[2], ids[0]])

        configuration.moveSelection(ids[1], before: missing)
        configuration.moveSelection(missing, after: ids[0])
        XCTAssertEqual(configuration.selectedDocumentIDs, [ids[3], ids[1], ids[2], ids[0]])
    }

    func testDividerResizeChangesOnlyAdjacentPanelsAndClampsMinimumLength() {
        let ids = (0..<4).map { _ in UUID() }
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids)
        configuration.normalizePanelWeights()
        let initialFractions = configuration.panelFractions(for: .sideBySide)

        configuration.resizeDivider(
            for: .sideBySide,
            afterPanelAt: 1,
            translation: 100,
            availableLength: 1_000,
            minimumPanelLength: 200,
            initialFractions: initialFractions
        )

        let lengths = configuration.panelLengths(
            for: .sideBySide,
            availableLength: 1_000,
            minimumPanelLength: 200
        )
        XCTAssertEqual(lengths[0], 250, accuracy: 0.001)
        XCTAssertEqual(lengths[1], 300, accuracy: 0.001)
        XCTAssertEqual(lengths[2], 200, accuracy: 0.001)
        XCTAssertEqual(lengths[3], 250, accuracy: 0.001)
        XCTAssertEqual(lengths.reduce(0, +), 1_000, accuracy: 0.001)

        configuration.resizeDivider(
            for: .sideBySide,
            afterPanelAt: 0,
            translation: -10_000,
            availableLength: 1_000,
            minimumPanelLength: 200,
            initialFractions: configuration.panelFractions(for: .sideBySide)
        )
        let clampedLengths = configuration.panelLengths(
            for: .sideBySide,
            availableLength: 1_000,
            minimumPanelLength: 200
        )
        XCTAssertEqual(clampedLengths[0], 200, accuracy: 0.001)
        XCTAssertEqual(clampedLengths.reduce(0, +), 1_000, accuracy: 0.001)
        XCTAssertTrue(clampedLengths.allSatisfy { $0 >= 200 - 0.001 })
    }

    func testNarrowViewportUsesEqualEffectiveMinimumWithoutOverflow() {
        let ids = [UUID(), UUID(), UUID()]
        var configuration = PDFComparisonConfiguration(selectedDocumentIDs: ids)

        configuration.resizeDivider(
            for: .stacked,
            afterPanelAt: 0,
            translation: 500,
            availableLength: 300,
            minimumPanelLength: 150
        )

        let lengths = configuration.panelLengths(
            for: .stacked,
            availableLength: 300,
            minimumPanelLength: 150
        )
        XCTAssertEqual(lengths, [100, 100, 100])
        XCTAssertEqual(lengths.reduce(0, +), 300, accuracy: 0.001)
    }

    func testSplitWeightsAreIndependentByLayoutAndFollowDocumentReorder() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        var configuration = PDFComparisonConfiguration(
            selectedDocumentIDs: [first, second, third]
        )

        configuration.resizeDivider(
            for: .sideBySide,
            afterPanelAt: 0,
            translation: 150,
            availableLength: 900,
            minimumPanelLength: 220
        )
        let horizontalByID = Dictionary(
            uniqueKeysWithValues: zip(
                configuration.selectedDocumentIDs,
                configuration.panelFractions(for: .sideBySide)
            )
        )
        XCTAssertEqual(configuration.panelFractions(for: .stacked), [1.0 / 3, 1.0 / 3, 1.0 / 3])

        configuration.resizeDivider(
            for: .stacked,
            afterPanelAt: 1,
            translation: -80,
            availableLength: 600,
            minimumPanelLength: 150
        )
        XCTAssertNotEqual(
            configuration.panelFractions(for: .sideBySide),
            configuration.panelFractions(for: .stacked)
        )

        configuration.moveSelection(first, after: third)
        XCTAssertEqual(configuration.selectedDocumentIDs, [second, third, first])
        let reorderedFractions = configuration.panelFractions(for: .sideBySide)
        for (index, id) in configuration.selectedDocumentIDs.enumerated() {
            XCTAssertEqual(reorderedFractions[index], horizontalByID[id]!, accuracy: 0.000_001)
        }
    }

    func testPersistedPanelWeightsRestoreBothLayoutsWithoutExposingMutableStorage() {
        let ids = [UUID(), UUID(), UUID()]
        var source = PDFComparisonConfiguration(selectedDocumentIDs: ids)
        source.resizeDivider(
            for: .sideBySide,
            afterPanelAt: 0,
            translation: 120,
            availableLength: 900,
            minimumPanelLength: 220
        )
        source.resizeDivider(
            for: .stacked,
            afterPanelAt: 1,
            translation: -70,
            availableLength: 600,
            minimumPanelLength: 150
        )

        var restored = PDFComparisonConfiguration(selectedDocumentIDs: ids)
        restored.restorePersistedPanelWeights(
            sideBySide: source.persistedPanelWeights(for: .sideBySide),
            stacked: source.persistedPanelWeights(for: .stacked)
        )

        XCTAssertEqual(
            restored.panelFractions(for: .sideBySide),
            source.panelFractions(for: .sideBySide)
        )
        XCTAssertEqual(
            restored.panelFractions(for: .stacked),
            source.panelFractions(for: .stacked)
        )
    }
}

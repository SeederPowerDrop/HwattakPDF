// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit
import XCTest
@testable import HwattakPDF

@MainActor
final class InlineTextEditingTests: XCTestCase {
    func testKeyboardPolicyCommitsReturnAndCommandReturnButProtectsIME() {
        XCTAssertEqual(
            InlineTextEditorKeyIntent.resolve(
                keyCode: 36,
                modifiers: [],
                hasMarkedText: false
            ),
            .commit
        )
        XCTAssertEqual(
            InlineTextEditorKeyIntent.resolve(
                keyCode: 36,
                modifiers: [.command],
                hasMarkedText: false
            ),
            .commit
        )
        XCTAssertEqual(
            InlineTextEditorKeyIntent.resolve(
                keyCode: 36,
                modifiers: [.shift],
                hasMarkedText: false
            ),
            .lineBreak
        )
        XCTAssertEqual(
            InlineTextEditorKeyIntent.resolve(
                keyCode: 53,
                modifiers: [],
                hasMarkedText: false
            ),
            .cancel
        )
        XCTAssertEqual(
            InlineTextEditorKeyIntent.resolve(
                keyCode: 36,
                modifiers: [],
                hasMarkedText: true
            ),
            .passThrough,
            "Return must confirm Korean/Japanese/Chinese marked text before it can close the editor."
        )
    }

    func testDraftLimiterCapsGraphemesAndStopsConsumingDenseFragments() {
        let maximum = InlineTextDraftLimiter.maximumCharacterCount
        let oversized = String(repeating: "👩🏽‍💻", count: maximum + 4_000)
        let limited = InlineTextDraftLimiter.limit(oversized)
        XCTAssertTrue(limited.wasTruncated)
        XCTAssertEqual(limited.text.count, maximum)

        var consumedFragments = 0
        let fragments = AnySequence<String> {
            var finished = false
            return AnyIterator<String> {
                guard !finished else { return nil }
                finished = true
                consumedFragments += 1
                return oversized
            }
        }
        let excerpt = InlineTextDraftLimiter.limit(fragments: fragments)
        XCTAssertTrue(excerpt.wasTruncated)
        XCTAssertEqual(excerpt.text.count, maximum)
        XCTAssertEqual(consumedFragments, 1)

        // One Character can still contain hundreds of thousands of combining
        // scalars. The encoded-size ceiling keeps that adversarial case
        // bounded without first walking the entire grapheme.
        let pathological = "e" + String(
            repeating: "\u{0301}",
            count: InlineTextDraftLimiter.maximumUTF16CodeUnitCount + 1_000
        )
        let encodedLimited = InlineTextDraftLimiter.limit(pathological)
        XCTAssertTrue(encodedLimited.wasTruncated)
        XCTAssertLessThanOrEqual(
            encodedLimited.text.utf16.count,
            InlineTextDraftLimiter.maximumUTF16CodeUnitCount
        )
    }

    func testTextViewPreflightsLargeInsertionBeforeTextKitLayout() {
        let textView = PDFInlineTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100))
        textView.string = String(
            repeating: "A",
            count: InlineTextDraftLimiter.maximumCharacterCount - 2
        )
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        var reportedLimit = false
        textView.onLengthLimitReached = { reportedLimit = true }

        textView.insertText(
            String(repeating: "B", count: 100_000),
            replacementRange: textView.selectedRange()
        )

        XCTAssertTrue(reportedLimit)
        XCTAssertEqual(textView.string.count, InlineTextDraftLimiter.maximumCharacterCount)
        XCTAssertLessThanOrEqual(
            textView.string.utf16.count,
            InlineTextDraftLimiter.maximumUTF16CodeUnitCount
        )
    }

    func testTextViewPreflightsActualPasteboardImport() {
        let pasteboard = NSPasteboard.withUniqueName()
        let textView = PDFInlineTextView(frame: .zero)
        textView.plainTextPasteboardReader = { _ in
            String(
                repeating: "붙여넣기 ",
                count: InlineTextDraftLimiter.maximumCharacterCount
            )
        }
        textView.string = "앞"
        textView.setSelectedRange(
            NSRange(location: textView.string.utf16.count, length: 0)
        )
        var reportedLimit = false
        textView.onLengthLimitReached = { reportedLimit = true }

        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .string))
        XCTAssertTrue(textView.string.hasPrefix("앞"))
        XCTAssertEqual(
            textView.string.count,
            InlineTextDraftLimiter.maximumCharacterCount
        )
        XCTAssertLessThanOrEqual(
            textView.string.utf16.count,
            InlineTextDraftLimiter.maximumUTF16CodeUnitCount
        )
        XCTAssertTrue(reportedLimit)
    }

    func testReviewSheetTextViewPreflightsPasteServicesAndTextDropBeforeLayout() {
        // Use the shared base class rather than PDFInlineTextView: the review
        // sheet deliberately keeps Return as a normal multi-line edit, while
        // both editors must share exactly the same Paste/Services/drop guard.
        let pasteboard = NSPasteboard.withUniqueName()
        let textView = PDFBoundedPlainTextView(frame: .zero)
        textView.plainTextPasteboardReader = { _ in
            String(
                repeating: "검토 주석 ",
                count: InlineTextDraftLimiter.maximumCharacterCount
            )
        }
        textView.string = "앞부분\n"
        textView.setSelectedRange(
            NSRange(location: textView.string.utf16.count, length: 0)
        )
        var reportedLimit = false
        textView.onLengthLimitReached = { reportedLimit = true }

        XCTAssertTrue(textView.readSelection(from: pasteboard, type: .string))
        XCTAssertTrue(textView.string.hasPrefix("앞부분\n"))
        XCTAssertEqual(
            textView.string.count,
            InlineTextDraftLimiter.maximumCharacterCount
        )
        XCTAssertLessThanOrEqual(
            textView.string.utf16.count,
            InlineTextDraftLimiter.maximumUTF16CodeUnitCount
        )
        XCTAssertTrue(reportedLimit)
    }

    func testGeometryClampsTextBoxInsidePage() {
        let page = CGRect(x: 10, y: 20, width: 300, height: 400)
        XCTAssertEqual(
            InlineTextGeometry.defaultBounds(
                at: CGPoint(x: 290, y: 30),
                within: page
            ),
            CGRect(x: 50, y: 20, width: 260, height: 64)
        )
        XCTAssertEqual(
            InlineTextGeometry.clamped(
                CGRect(x: -500, y: 900, width: 2, height: 2),
                within: page
            ),
            CGRect(x: 10, y: 396, width: 48, height: 24)
        )
    }

    func testNarrowViewportPanelStaysHorizontallyReachable() {
        for viewportWidth in [454.0, 320.0, 236.0] {
            let viewport = CGRect(x: 0, y: 0, width: viewportWidth, height: 500)
            let frame = InlineTextGeometry.editorPanelFrame(
                targetRect: CGRect(x: 280, y: 200, width: 80, height: 40),
                viewportBounds: viewport,
                purpose: .freeText
            )
            XCTAssertGreaterThan(frame.width, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX)
            XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX)
        }
    }

    func testOpenPanelRelocalizesActionsHintsAndAlignmentSegments() throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: AppPreferences.languageDefaultsKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppPreferences.languageDefaultsKey)
            } else {
                defaults.removeObject(forKey: AppPreferences.languageDefaultsKey)
            }
            NotificationCenter.default.post(
                name: .appLanguageDidChange,
                object: AppPreferences.savedLanguage
            )
        }

        defaults.set(AppLanguage.korean.rawValue, forKey: AppPreferences.languageDefaultsKey)
        let panel = PDFInlineTextEditorPanel(
            frame: CGRect(x: 0, y: 0, width: 620, height: 216)
        )
        let alignment = try XCTUnwrap(
            descendants(of: NSSegmentedControl.self, in: panel).first
        )

        XCTAssertEqual(
            (0..<3).map { alignment.image(forSegment: $0)?.accessibilityDescription },
            ["왼쪽 정렬", "가운데 정렬", "오른쪽 정렬"]
        )
        XCTAssertTrue(descendants(of: NSButton.self, in: panel).contains { $0.title == "적용" })
        XCTAssertTrue(descendants(of: NSTextField.self, in: panel).contains {
            $0.stringValue.contains("Shift-Return 줄 바꿈")
        })

        defaults.set(AppLanguage.english.rawValue, forKey: AppPreferences.languageDefaultsKey)
        NotificationCenter.default.post(name: .appLanguageDidChange, object: AppLanguage.english)

        XCTAssertEqual(
            (0..<3).map { alignment.image(forSegment: $0)?.accessibilityDescription },
            ["Align left", "Align center", "Align right"]
        )
        let buttonTitles = Set(descendants(of: NSButton.self, in: panel).map(\.title))
        XCTAssertTrue(buttonTitles.contains("Cancel"))
        XCTAssertTrue(buttonTitles.contains("Apply"))
        XCTAssertTrue(descendants(of: NSTextField.self, in: panel).contains {
            $0.stringValue.contains("Shift-Return Line Break")
        })
    }

    func testLanguageObserverDoesNotRetainReleasedInlinePanel() {
        weak var releasedPanel: PDFInlineTextEditorPanel?
        autoreleasepool {
            let panel = PDFInlineTextEditorPanel(frame: .zero)
            releasedPanel = panel
            XCTAssertNotNil(releasedPanel)
        }
        XCTAssertNil(releasedPanel)
    }

    func testViewerAndStudyModesCannotStartDirectBodyEditing() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        XCTAssertEqual(fixture.workspace.mode, .viewer)
        XCTAssertFalse(
            fixture.workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 40, y: 300),
                annotation: nil
            )
        )
        fixture.workspace.setMode(.study)
        XCTAssertFalse(
            fixture.workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 40, y: 300),
                annotation: nil
            )
        )
        XCTAssertNil(fixture.workspace.pendingInlineTextEdit)
        XCTAssertFalse(fixture.workspace.isDirty)
    }

    func testNewInlineTextIsTransactionalStyledAndOneUndoCommand() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)

        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 42, y: 310),
                annotation: nil
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(
            workspace.canHibernate,
            "A clean tab must not release PDFKit while an unsaved inline draft is open."
        )
        XCTAssertTrue(try XCTUnwrap(workspace.document?.page(at: 0)).annotations.isEmpty)

        let style = InlineTextStyle(
            fontName: NSFont.monospacedSystemFont(ofSize: 19, weight: .regular).fontName,
            fontSize: 19,
            textColor: PDFTextColor(.systemBlue),
            backgroundColor: PDFTextColor(.systemYellow.withAlphaComponent(0.55)),
            alignment: .center
        )
        workspace.commitPendingInlineText(
            id: pending.id,
            text: "Inline contract text",
            style: style,
            bounds: CGRect(x: 42, y: 246, width: 220, height: 64)
        )

        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = try XCTUnwrap(page.annotations.first)
        XCTAssertEqual(annotation.contents, "Inline contract text")
        XCTAssertEqual(annotation.bounds, CGRect(x: 42, y: 246, width: 220, height: 64))
        XCTAssertEqual(annotation.font?.fontName, style.font.fontName)
        XCTAssertEqual(annotation.font?.pointSize, 19)
        XCTAssertTrue(PDFTextColor(annotation.fontColor).visuallyEquals(style.textColor))
        XCTAssertTrue(PDFTextColor(annotation.color).visuallyEquals(style.backgroundColor))
        XCTAssertEqual(annotation.alignment, .center)
        XCTAssertEqual(EditableAnnotationIdentity.kind(of: annotation), .freeText)
        XCTAssertFalse(InlineTextAnnotationIdentity.isVisualReplacement(annotation))
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)
        XCTAssertNil(workspace.pendingInlineTextEdit)

        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
        workspace.redo()
        XCTAssertTrue(page.annotations.contains(where: { $0 === annotation }))
    }

    func testCancelLeavesPDFAndHistoryUntouched() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 40, y: 300),
                annotation: nil
            )
        )
        workspace.cancelPendingInlineText()

        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertTrue(try XCTUnwrap(workspace.document?.page(at: 0)).annotations.isEmpty)
    }

    func testExistingAppFreeTextRestoresEveryAppearanceFieldOnUndo() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let originalBounds = CGRect(x: 30, y: 200, width: 150, height: 44)
        let annotation = PDFAnnotation(
            bounds: originalBounds,
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "Before"
        annotation.font = NSFont.systemFont(ofSize: 12)
        annotation.fontColor = .systemRed
        annotation.color = .clear
        annotation.alignment = .left
        annotation.setValue("HwattakPDF-Annotation-test", forAnnotationKey: .name)
        EditableAnnotationIdentity.assign(.freeText, to: annotation)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_000)
        annotation.modificationDate = originalDate
        page.addAnnotation(annotation)

        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: originalBounds.origin,
                annotation: annotation
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        let editedStyle = InlineTextStyle(
            fontName: NSFont.boldSystemFont(ofSize: 24).fontName,
            fontSize: 24,
            textColor: PDFTextColor(.white),
            backgroundColor: PDFTextColor(.black),
            alignment: .right
        )
        workspace.commitPendingInlineText(
            id: pending.id,
            text: "After",
            style: editedStyle,
            bounds: CGRect(x: 60, y: 180, width: 190, height: 70)
        )
        XCTAssertEqual(annotation.contents, "After")
        XCTAssertEqual(annotation.alignment, .right)

        workspace.undo()
        XCTAssertEqual(annotation.contents, "Before")
        XCTAssertEqual(annotation.bounds, originalBounds)
        XCTAssertEqual(annotation.font?.pointSize, 12)
        XCTAssertTrue(PDFTextColor(annotation.fontColor).visuallyEquals(PDFTextColor(.systemRed)))
        XCTAssertTrue(PDFTextColor(annotation.color).visuallyEquals(.clear))
        XCTAssertEqual(annotation.alignment, .left)
        XCTAssertEqual(annotation.modificationDate, originalDate)

        workspace.redo()
        XCTAssertEqual(annotation.contents, "After")
        XCTAssertEqual(annotation.bounds, CGRect(x: 60, y: 180, width: 190, height: 70))
        XCTAssertEqual(annotation.font?.pointSize, 24)
        XCTAssertEqual(annotation.alignment, .right)
    }

    func testExistingFreeTextExactNoOpRestoresSnapshotWithoutDirtyOrUndo() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 30, y: 200, width: 150, height: 44),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "No change"
        annotation.font = NSFont.systemFont(ofSize: 15)
        annotation.fontColor = .black
        annotation.color = .clear
        annotation.alignment = .left
        annotation.setValue("HwattakPDF-Annotation-noop", forAnnotationKey: .name)
        EditableAnnotationIdentity.assign(.freeText, to: annotation)
        let originalDate = Date(timeIntervalSince1970: 1_700_000_123)
        annotation.modificationDate = originalDate
        page.addAnnotation(annotation)

        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: annotation.bounds.origin,
                annotation: annotation
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.commitPendingInlineText(
            id: pending.id,
            text: pending.text,
            style: pending.style,
            bounds: pending.bounds
        )

        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertEqual(annotation.modificationDate, originalDate)
        XCTAssertEqual(annotation.contents, "No change")
        XCTAssertEqual(annotation.bounds, CGRect(x: 30, y: 200, width: 150, height: 44))
    }

    func testEditorPanelPreservesExistingFontFaceAndAlignment() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 30, y: 200, width: 180, height: 60),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "Preserve my face"
        annotation.font = NSFont.boldSystemFont(ofSize: 17)
        annotation.fontColor = .black
        annotation.color = .clear
        annotation.alignment = .right
        EditableAnnotationIdentity.assign(.freeText, to: annotation)
        page.addAnnotation(annotation)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: annotation.bounds.origin,
                annotation: annotation
            )
        )
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)

        let panel = PDFInlineTextEditorPanel(frame: CGRect(x: 0, y: 0, width: 620, height: 216))
        panel.configure(with: draft)

        XCTAssertEqual(panel.currentStyle.fontName, draft.style.fontName)
        XCTAssertEqual(panel.currentStyle.fontSize, 17)
        XCTAssertEqual(panel.currentStyle.alignment, .right)
    }

    func testVisualReplacementIsMarkedAsNonRedactionAndOriginalObjectIsNotRemoved() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))

        // This harmless Text annotation stands in for unrelated page content.
        // The replacement workflow must add one FreeText object, never remove
        // source objects or create a Redact annotation.
        let sourceObject = PDFAnnotation(
            bounds: CGRect(x: 50, y: 250, width: 120, height: 20),
            forType: .text,
            withProperties: nil
        )
        sourceObject.contents = "Original remains"
        page.addAnnotation(sourceObject)

        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 50, y: 270),
                annotation: nil,
                visualReplacementText: "Original remains",
                visualReplacementBounds: sourceObject.bounds
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        XCTAssertEqual(pending.purpose, .visualReplacement)
        XCTAssertEqual(pending.style.backgroundColor, .white)
        workspace.commitPendingInlineText(
            id: pending.id,
            text: "Replacement shown",
            style: pending.style,
            bounds: pending.bounds
        )

        XCTAssertTrue(page.annotations.contains(where: { $0 === sourceObject }))
        let replacement = try XCTUnwrap(page.annotations.first(where: {
            InlineTextAnnotationIdentity.isVisualReplacement($0)
        }))
        XCTAssertEqual(replacement.contents, "Replacement shown")
        XCTAssertEqual(
            replacement.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            "FreeText"
        )
        XCTAssertFalse(page.annotations.contains(where: {
            $0.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Redact"
        }))
        XCTAssertEqual(
            workspace.statusMessage,
            L10n.string(
                "status.visual_text_replacement_added",
                defaultValue: "A visual text replacement was added; the original text remains underneath."
            )
        )

        // The marker drives the warning when this annotation is edited after
        // save/reopen, so verify PDFKit keeps the custom annotation key.
        let data = try XCTUnwrap(workspace.document?.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        let reopenedReplacement = try XCTUnwrap(
            reopened.page(at: 0)?.annotations.first(where: {
                InlineTextAnnotationIdentity.isVisualReplacement($0)
            })
        )
        XCTAssertEqual(reopenedReplacement.contents, "Replacement shown")
    }

    func testTruncatedVisualReplacementNeverHidesNonRedactionWarning() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let oversized = String(
            repeating: "A",
            count: InlineTextDraftLimiter.maximumCharacterCount + 1_000
        )

        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 30, y: 300),
                annotation: nil,
                visualReplacementText: oversized,
                visualReplacementBounds: CGRect(x: 30, y: 260, width: 200, height: 40)
            )
        )

        XCTAssertEqual(
            workspace.pendingInlineTextEdit?.text.count,
            InlineTextDraftLimiter.maximumCharacterCount
        )
        let status = workspace.statusMessage
        XCTAssertTrue(status.contains(L10n.string("inline_text.visual_replacement_warning")))
        XCTAssertTrue(
            status.contains(
                L10n.format(
                    "inline_text.length_limit",
                    InlineTextDraftLimiter.maximumCharacterCount
                )
            )
        )
    }

    func testToolbarMutationCommitsTextFirstSoUndoReversesToolbarActionFirst() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 30, y: 300),
                annotation: nil
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(
            id: pending.id,
            text: "Typed before using the toolbar",
            style: pending.style,
            bounds: pending.bounds
        )

        workspace.rotateSelectedPages(clockwise: true)

        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertEqual(page.rotation, 90)
        XCTAssertEqual(page.annotations.first?.contents, "Typed before using the toolbar")
        XCTAssertEqual(workspace.undoActionName, L10n.string("status.rotated_pages"))

        workspace.undo()
        XCTAssertEqual(page.rotation, 0)
        XCTAssertEqual(
            page.annotations.first?.contents,
            "Typed before using the toolbar",
            "The first undo must keep the older text transaction intact."
        )
        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testPageDeletionCommitsDraftOnOriginalPageBeforeRemovingIt() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let document = try XCTUnwrap(workspace.document)
        let originalPage = try XCTUnwrap(document.page(at: 0))
        // Deleting every page is intentionally forbidden, so add a harmless
        // second page outside the history under test.
        let spareImage = NSImage(size: CGSize(width: 320, height: 420), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        document.insert(try XCTUnwrap(PDFPage(image: spareImage)), at: 1)

        workspace.setMode(.editing)
        workspace.selectedPages = [0]
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 30, y: 300),
                annotation: nil
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(
            id: pending.id,
            text: "Belongs to the page being deleted",
            style: pending.style,
            bounds: pending.bounds
        )

        workspace.deleteSelectedPages()

        XCTAssertEqual(document.pageCount, 1)
        XCTAssertEqual(document.index(for: originalPage), NSNotFound)
        XCTAssertNil(workspace.pendingInlineTextEdit)

        workspace.undo()
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0) === originalPage)
        XCTAssertEqual(
            originalPage.annotations.first?.contents,
            "Belongs to the page being deleted"
        )
        workspace.undo()
        XCTAssertTrue(originalPage.annotations.isEmpty)
    }

    func testDirectSaveCommitsDraftBeforeSerializing() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 30, y: 300),
                annotation: nil
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(
            id: pending.id,
            text: "Persisted by direct model save",
            style: pending.style,
            bounds: pending.bounds
        )

        XCTAssertTrue(workspace.saveSynchronously())
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertFalse(workspace.isDirty)

        let savedURL = try XCTUnwrap(workspace.documentURL)
        let reopened = try XCTUnwrap(PDFDocument(url: savedURL))
        XCTAssertEqual(
            reopened.page(at: 0)?.annotations.first?.contents,
            "Persisted by direct model save"
        )
    }

    func testDirectCloseCannotDiscardACleanLookingDraft() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 30, y: 300),
                annotation: nil
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(
            id: pending.id,
            text: "Do not lose me",
            style: pending.style,
            bounds: pending.bounds
        )
        XCTAssertFalse(workspace.isDirty)

        workspace.close()

        XCTAssertNotNil(workspace.document)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertEqual(
            workspace.document?.page(at: 0)?.annotations.first?.contents,
            "Do not lose me"
        )
        XCTAssertEqual(workspace.presentedError, L10n.string("error.unsaved_close"))
    }

    func testDirectOpenCannotMoveACleanLookingDraftOntoAnotherPDF() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let originalURL = try XCTUnwrap(workspace.documentURL)
        let replacementURL = fixture.directory.appendingPathComponent("replacement.pdf")
        let replacementData = try XCTUnwrap(workspace.document?.dataRepresentation())
        try replacementData.write(to: replacementURL, options: .atomic)

        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 30, y: 300),
                annotation: nil
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(
            id: pending.id,
            text: "This belongs to the original PDF",
            style: pending.style,
            bounds: pending.bounds
        )
        XCTAssertFalse(workspace.isDirty)

        XCTAssertFalse(workspace.open(url: replacementURL))
        XCTAssertEqual(workspace.documentURL, originalURL)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertEqual(
            workspace.document?.page(at: 0)?.annotations.first?.contents,
            "This belongs to the original PDF"
        )
        XCTAssertEqual(workspace.presentedError, L10n.string("error.unsaved_open"))
    }

    func testPrepareForDeactivationCommitsLatestSynchronizedDraft() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 30, y: 300),
                annotation: nil
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)
        workspace.updatePendingInlineTextDraft(
            id: pending.id,
            text: "Preserved while switching tabs",
            style: pending.style,
            bounds: pending.bounds
        )

        workspace.prepareForDeactivation()

        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertTrue(workspace.isDirty)
        XCTAssertEqual(
            try XCTUnwrap(workspace.document?.page(at: 0)?.annotations.first).contents,
            "Preserved while switching tabs"
        )
    }

    func testOutgoingOverlayCannotCommitNewerDraftAndRemovesObservers() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 30, y: 300),
                annotation: nil
            )
        )
        let oldID = try XCTUnwrap(workspace.pendingInlineTextEdit?.id)

        let owner = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        owner.workspaceState = workspace
        owner.document = workspace.document
        let outgoing = PDFInlineTextEditingOverlayView(frame: owner.bounds)
        outgoing.owner = owner
        outgoing.synchronizeWithWorkspace()
        XCTAssertTrue(outgoing.hasInstalledObservers)

        workspace.cancelPendingInlineText()
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 80, y: 260),
                annotation: nil
            )
        )
        let newerID = try XCTUnwrap(workspace.pendingInlineTextEdit?.id)
        XCTAssertNotEqual(oldID, newerID)

        outgoing.prepareForRemoval()

        XCTAssertFalse(outgoing.hasInstalledObservers)
        XCTAssertEqual(workspace.pendingInlineTextEdit?.id, newerID)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertTrue(try XCTUnwrap(workspace.document?.page(at: 0)).annotations.isEmpty)
    }

    func testOutgoingOverlayCannotOverwriteNewOwnerOfTheSameDraft() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 30, y: 300),
                annotation: nil
            )
        )
        let draft = try XCTUnwrap(workspace.pendingInlineTextEdit)
        let owner = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        owner.workspaceState = workspace
        owner.document = workspace.document

        // The outgoing view first captures the empty draft. The model then
        // receives newer text and an incoming view claims that same UUID.
        let outgoing = PDFInlineTextEditingOverlayView(frame: owner.bounds)
        outgoing.owner = owner
        outgoing.synchronizeWithWorkspace()
        workspace.updatePendingInlineTextDraft(
            id: draft.id,
            text: "Latest text owned by the replacement view",
            style: draft.style,
            bounds: draft.bounds
        )
        let incoming = PDFInlineTextEditingOverlayView(frame: owner.bounds)
        incoming.owner = owner
        incoming.synchronizeWithWorkspace()

        outgoing.prepareForRemoval()

        XCTAssertEqual(
            workspace.pendingInlineTextEdit?.text,
            "Latest text owned by the replacement view"
        )
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(outgoing.hasInstalledObservers)

        incoming.prepareForRemoval()
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertEqual(
            workspace.document?.page(at: 0)?.annotations.first?.contents,
            "Latest text owned by the replacement view"
        )
    }

    func testThirdPartyFreeTextIsNotSilentlyAdoptedByInlinePath() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let external = PDFAnnotation(
            bounds: CGRect(x: 40, y: 200, width: 100, height: 40),
            forType: .freeText,
            withProperties: nil
        )
        external.contents = "External"
        page.addAnnotation(external)

        XCTAssertFalse(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: CGPoint(x: 50, y: 210),
                annotation: external
            )
        )
        XCTAssertNil(EditableAnnotationIdentity.storedKind(of: external))
        XCTAssertNil(workspace.pendingInlineTextEdit)
        XCTAssertFalse(workspace.isDirty)
    }

    func testOversizedExistingFreeTextIsRefusedWithoutTruncatingItsTail() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let original = String(
            repeating: "Tail must survive. ",
            count: InlineTextDraftLimiter.maximumCharacterCount / 8
        )
        XCTAssertGreaterThan(original.count, InlineTextDraftLimiter.maximumCharacterCount)
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 30, y: 200, width: 200, height: 80),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = original
        annotation.font = NSFont.systemFont(ofSize: 12)
        EditableAnnotationIdentity.assign(.freeText, to: annotation)
        InlineTextAnnotationIdentity.setVisualReplacement(true, on: annotation)
        page.addAnnotation(annotation)

        XCTAssertFalse(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: annotation.bounds.origin,
                annotation: annotation
            )
        )
        XCTAssertEqual(
            workspace.inlineTextEditRejectionReason,
            .existingTextExceedsSafetyLimit
        )
        XCTAssertNil(workspace.pendingInlineTextEdit)

        // Save/tab/mode preparation must remain a no-op after the refusal.
        workspace.prepareForDeactivation()
        XCTAssertEqual(annotation.contents, original)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertTrue(
            workspace.statusMessage.contains(
                L10n.format(
                    "inline_text.existing_length_limit",
                    InlineTextDraftLimiter.maximumCharacterCount
                )
            )
        )
        XCTAssertTrue(
            workspace.statusMessage.contains(
                L10n.string("inline_text.visual_replacement_warning")
            ),
            "Even an oversized replacement must retain the non-redaction warning."
        )
    }

    func testDirectOversizedInlineCommitKeepsExistingTextAndDraftAtomically() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        workspace.setMode(.editing)
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 30, y: 200, width: 200, height: 70),
            forType: .freeText,
            withProperties: nil
        )
        annotation.contents = "Original complete text"
        EditableAnnotationIdentity.assign(.freeText, to: annotation)
        page.addAnnotation(annotation)
        XCTAssertTrue(
            workspace.requestInlineTextEdit(
                pageIndex: 0,
                point: annotation.bounds.origin,
                annotation: annotation
            )
        )
        let pending = try XCTUnwrap(workspace.pendingInlineTextEdit)

        workspace.commitPendingInlineText(
            id: pending.id,
            text: String(
                repeating: "X",
                count: InlineTextDraftLimiter.maximumCharacterCount + 1
            ),
            style: pending.style,
            bounds: pending.bounds
        )

        XCTAssertEqual(annotation.contents, "Original complete text")
        XCTAssertEqual(workspace.pendingInlineTextEdit?.id, pending.id)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
    }

    func testLegacyReviewSheetRefusesOversizedThirdPartyTextWithoutOpeningOrDirtying() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let original = String(
            repeating: "Third-party tail must survive. ",
            count: InlineTextDraftLimiter.maximumCharacterCount / 10
        )
        XCTAssertGreaterThan(original.count, InlineTextDraftLimiter.maximumCharacterCount)
        let external = PDFAnnotation(
            bounds: CGRect(x: 20, y: 180, width: 220, height: 80),
            forType: .freeText,
            withProperties: nil
        )
        external.contents = original
        page.addAnnotation(external)

        workspace.requestTextEdit(
            pageIndex: 0,
            point: external.bounds.origin,
            annotation: external
        )

        XCTAssertNil(workspace.pendingTextEdit)
        XCTAssertEqual(external.contents, original)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertEqual(
            workspace.presentedError,
            L10n.format(
                "inline_text.existing_length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
        )
    }

    func testLegacyReviewSheetNeverAdoptsWidgetOrStampAsFreeText() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))

        for subtype in [PDFAnnotationSubtype.widget, .stamp] {
            let foreign = PDFAnnotation(
                bounds: CGRect(x: 20, y: 80, width: 120, height: 40),
                forType: subtype,
                withProperties: nil
            )
            foreign.contents = "must remain (subtype.rawValue)"
            page.addAnnotation(foreign)

            workspace.requestTextEdit(
                pageIndex: 0,
                point: foreign.bounds.origin,
                annotation: foreign
            )
            workspace.commitPendingText("attempted replacement")

            XCTAssertNil(workspace.pendingTextEdit)
            XCTAssertEqual(foreign.contents, "must remain (subtype.rawValue)")
            XCTAssertNil(EditableAnnotationIdentity.storedKind(of: foreign))
        }
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
    }

    func testLegacyReviewSheetModelRejectsOversizedDirectCommitAtomically() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        let external = PDFAnnotation(
            bounds: CGRect(x: 20, y: 180, width: 220, height: 80),
            forType: .freeText,
            withProperties: nil
        )
        external.contents = "Original external comment"
        page.addAnnotation(external)
        workspace.requestTextEdit(
            pageIndex: 0,
            point: external.bounds.origin,
            annotation: external
        )
        XCTAssertNotNil(workspace.pendingTextEdit)

        workspace.commitPendingText(
            String(
                repeating: "X",
                count: InlineTextDraftLimiter.maximumCharacterCount + 1
            )
        )

        XCTAssertEqual(external.contents, "Original external comment")
        XCTAssertNotNil(
            workspace.pendingTextEdit,
            "A rejected direct call keeps the safe draft available instead of silently discarding it."
        )
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
        XCTAssertEqual(
            workspace.presentedError,
            L10n.format(
                "inline_text.length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
        )
    }

    func testLegacyReviewDraftSurvivesDeactivationUntilExplicitApply() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        workspace.requestTextEdit(
            pageIndex: 0,
            point: CGPoint(x: 30, y: 220),
            annotation: nil
        )
        let draft = try XCTUnwrap(workspace.pendingTextEdit)

        workspace.updatePendingTextDraft(
            id: draft.id,
            text: "탭을 바꾸기 직전에 입력한 최신 메모"
        )
        workspace.prepareForDeactivation()

        XCTAssertEqual(
            workspace.pendingTextEdit?.initialText,
            "탭을 바꾸기 직전에 입력한 최신 메모"
        )
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)

        // A destructive close is refused while the unapplied sheet exists.
        workspace.close()
        XCTAssertNotNil(workspace.document)
        XCTAssertNotNil(workspace.pendingTextEdit)

        workspace.commitPendingText(
            try XCTUnwrap(workspace.pendingTextEdit?.initialText)
        )
        XCTAssertNil(workspace.pendingTextEdit)
        XCTAssertEqual(
            page.annotations.first?.contents,
            "탭을 바꾸기 직전에 입력한 최신 메모"
        )
        XCTAssertTrue(workspace.isDirty)
        XCTAssertTrue(workspace.canUndo)

        workspace.undo()
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testDiscardingLegacyDraftClearsIdentityBeforeAnotherPDFOpens() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let originalURL = try XCTUnwrap(workspace.documentURL)
        workspace.requestTextEdit(
            pageIndex: 0,
            point: CGPoint(x: 30, y: 220),
            annotation: nil
        )
        let draft = try XCTUnwrap(workspace.pendingTextEdit)
        workspace.updatePendingTextDraft(id: draft.id, text: "discard me")

        workspace.closeDiscardingChanges()
        XCTAssertNil(workspace.pendingTextEdit)
        XCTAssertTrue(workspace.open(url: originalURL))

        // A late callback from the discarded sheet has no matching draft and
        // therefore cannot place text onto the newly opened document.
        workspace.updatePendingTextDraft(id: draft.id, text: "late callback")
        workspace.commitPendingText("late callback")
        XCTAssertTrue(workspace.document?.page(at: 0)?.annotations.isEmpty == true)
        XCTAssertFalse(workspace.isDirty)
    }

    func testLazyRestoreRefusesToDiscardAnUnappliedReviewDraft() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let originalURL = try XCTUnwrap(workspace.documentURL)
        workspace.requestTextEdit(pageIndex: 0, point: .zero, annotation: nil)
        let draft = try XCTUnwrap(workspace.pendingTextEdit)
        workspace.updatePendingTextDraft(id: draft.id, text: "preserve across restore attempt")

        workspace.restoreHibernated(
            url: fixture.directory.appendingPathComponent("other.pdf"),
            pageCount: 99,
            currentPageIndex: 80
        )

        XCTAssertEqual(workspace.documentURL, originalURL)
        XCTAssertNotNil(workspace.document)
        XCTAssertEqual(workspace.pendingTextEdit?.id, draft.id)
        XCTAssertEqual(
            workspace.pendingTextEdit?.initialText,
            "preserve across restore attempt"
        )
    }

    func testOversizedLegacyRequestDoesNotDiscardAnEarlierSafeDraft() throws {
        let fixture = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let workspace = fixture.workspace
        let page = try XCTUnwrap(workspace.document?.page(at: 0))
        workspace.requestTextEdit(pageIndex: 0, point: .zero, annotation: nil)
        let safeDraft = try XCTUnwrap(workspace.pendingTextEdit)
        workspace.updatePendingTextDraft(id: safeDraft.id, text: "keep this draft")

        let oversized = PDFAnnotation(
            bounds: CGRect(x: 10, y: 10, width: 100, height: 40),
            forType: .freeText,
            withProperties: nil
        )
        oversized.contents = String(
            repeating: "Z",
            count: InlineTextDraftLimiter.maximumCharacterCount + 1
        )
        page.addAnnotation(oversized)
        workspace.requestTextEdit(pageIndex: 0, point: .zero, annotation: oversized)

        XCTAssertEqual(workspace.pendingTextEdit?.id, safeDraft.id)
        XCTAssertEqual(workspace.pendingTextEdit?.initialText, "keep this draft")
        XCTAssertEqual(
            oversized.contents?.count,
            InlineTextDraftLimiter.maximumCharacterCount + 1
        )
        XCTAssertFalse(workspace.isDirty)
        XCTAssertFalse(workspace.canUndo)
    }

    private func makeWorkspace() throws -> (
        workspace: PDFWorkspaceState,
        directory: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HwattakPDF-InlineText-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("inline.pdf")
        let image = NSImage(size: CGSize(width: 320, height: 420), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let document = PDFDocument()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(document.write(to: url))
        let workspace = PDFWorkspaceState()
        XCTAssertTrue(workspace.open(url: url))
        return (workspace, directory)
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { subview -> [T] in
            let current = (subview as? T).map { [$0] } ?? []
            return current + descendants(of: type, in: subview)
        }
    }
}

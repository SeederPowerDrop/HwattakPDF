// SPDX-License-Identifier: MPL-2.0

import AppKit
import PDFKit

/// Shared plain-text editor used by both the on-page editor and the older
/// review/comment sheet.
///
/// The important part is *where* the length limit is applied. A SwiftUI
/// `onChange` handler runs only after TextKit has accepted and laid out pasted
/// content. A hostile PDF annotation or paste can therefore allocate a very
/// large text graph before the handler gets a chance to shorten it. This
/// AppKit boundary limits every insertion before calling `super.insertText`,
/// and routes Paste, Services, and text-drop imports through that same path.
@MainActor
class PDFBoundedPlainTextView: NSTextView {
    /// Default budget shared by both PDF FreeText editors. UTF-8 is already
    /// bounded indirectly by the grapheme and UTF-16 ceilings; `Int.max`
    /// preserves the existing 32K/1M policy while allowing another caller
    /// (such as the AI composer) to install a stricter three-axis budget.
    static let freeTextBudget = EncodedTextBudget(
        maximumCharacters: InlineTextDraftLimiter.maximumCharacterCount,
        maximumUTF8Bytes: Int.max,
        maximumUTF16CodeUnits: InlineTextDraftLimiter.maximumUTF16CodeUnitCount
    )

    var encodedTextBudget = PDFBoundedPlainTextView.freeTextBudget
    var onLengthLimitReached: (() -> Void)?
    /// Injectable only so headless XCTest can exercise the real
    /// `readSelection(from:type:)` override without depending on the macOS
    /// pasteboard XPC service. Production keeps the system-backed default.
    var plainTextPasteboardReader: (NSPasteboard) -> String? = {
        $0.string(forType: .string)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        // FreeText stores plain text. Advertising only that representation
        // also prevents a rich RTF/HTML attachment graph from bypassing the
        // bounded insertion path below.
        [.string]
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let replacement: String
        if let attributed = insertString as? NSAttributedString {
            replacement = attributed.string
        } else if let string = insertString as? String {
            replacement = string
        } else {
            replacement = String(describing: insertString)
        }

        // AppKit normally supplies a valid UTF-16 range. Clamp defensively so
        // drag-and-drop, Services, and input methods share the same safe path.
        let current = string as NSString
        let requested = replacementRange.location == NSNotFound
            ? selectedRange()
            : replacementRange
        let location = min(max(0, requested.location), current.length)
        let length = min(max(0, requested.length), current.length - location)
        let safeRange = NSRange(location: location, length: length)
        let prefix = current.substring(with: NSRange(location: 0, length: location))
        let suffixStart = NSMaxRange(safeRange)
        let suffix = current.substring(
            with: NSRange(location: suffixStart, length: current.length - suffixStart)
        )
        let remainingCharacters = max(
            0,
            encodedTextBudget.maximumCharacters - prefix.count - suffix.count
        )
        let remainingUTF8 = max(
            0,
            encodedTextBudget.maximumUTF8Bytes
                - prefix.utf8.count
                - suffix.utf8.count
        )
        let remainingUTF16 = max(
            0,
            encodedTextBudget.maximumUTF16CodeUnits
                - prefix.utf16.count
                - suffix.utf16.count
        )
        let limited = EncodedTextLimiter.limit(
            replacement,
            budget: EncodedTextBudget(
                maximumCharacters: remainingCharacters,
                maximumUTF8Bytes: remainingUTF8,
                maximumUTF16CodeUnits: remainingUTF16
            )
        )

        // Crucially, only the bounded replacement reaches NSTextView. The
        // delegate's post-change limiter remains defense in depth, but a huge
        // paste can no longer trigger an equally huge TextKit layout first.
        super.insertText(limited.text, replacementRange: safeRange)
        if limited.wasTruncated {
            onLengthLimitReached?()
        }
    }

    override func readSelection(
        from pasteboard: NSPasteboard,
        type: NSPasteboard.PasteboardType
    ) -> Bool {
        // Paste, Services, and text-drop operations may ask NSTextView to read
        // a pasteboard representation directly, without first calling
        // `insertText`. Calling `super` would let TextKit decode and lay out
        // a huge rich payload before the delegate can enforce the draft cap.
        //
        // Route the plain representation through our preflighted insertion.
        // Refuse every other type: the editor intentionally persists plain PDF
        // FreeText, so importing an unbounded object graph has no useful result.
        guard
            type == .string,
            let plainText = plainTextPasteboardReader(pasteboard)
        else {
            return false
        }
        insertText(plainText, replacementRange: rangeForUserTextChange)
        return true
    }
}

/// NSTextView subclass that gives the on-page editor predictable transaction
/// keys while preserving native selection, copy/paste, spelling, and undo.
/// The review sheet uses the bounded base class without these Return/Escape
/// transaction shortcuts because Return must remain an ordinary line break
/// in its larger multi-line editor.
@MainActor
final class PDFInlineTextView: PDFBoundedPlainTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // During Korean/Japanese/Chinese composition Return confirms a marked
        // syllable. Closing the editor at that moment would truncate input, so
        // AppKit must finish composition before Return becomes our commit key.
        switch InlineTextEditorKeyIntent.resolve(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            hasMarkedText: hasMarkedText()
        ) {
        case .cancel:
            onCancel?()
        case .commit:
            onCommit?()
        case .lineBreak, .passThrough:
            // Shift-Return is the documented escape hatch for a line break;
            // marked-text Return remains owned by the input method.
            super.keyDown(with: event)
        }
    }
}

/// A compact AppKit inspector attached to the selected PDF rectangle.
///
/// It intentionally uses an ordinary NSTextView rather than a custom canvas.
/// That preserves macOS text services, native copy/paste, VoiceOver, spelling,
/// input methods, and the responder-chain undo manager inside the draft.
@MainActor
final class PDFInlineTextEditorPanel: NSVisualEffectView, NSTextViewDelegate {
    var onDraftChanged: ((String, InlineTextStyle) -> Void)?
    var onLengthLimitReached: (() -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private(set) var draftID: UUID?
    private(set) var purpose: InlineTextEditPurpose = .freeText
    private let textView = PDFInlineTextView(frame: .zero)
    private let fontMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeField = NSTextField(frame: .zero)
    private let sizeStepper = NSStepper(frame: .zero)
    private let textColorWell = NSColorWell(frame: .zero)
    private let backgroundColorWell = NSColorWell(frame: .zero)
    private let transparentBackgroundButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let alignmentControl = NSSegmentedControl(frame: .zero)
    private let toolbarScrollView = NSScrollView(frame: .zero)
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    private let foregroundLabel = NSTextField(labelWithString: "")
    private let backgroundLabel = NSTextField(labelWithString: "")
    private let shortcutHint = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let applyButton = NSButton(title: "", target: nil, action: nil)
    private var suppressCallbacks = false
    private var fontMenuConfigured = false
    private var languageObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildInterface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildInterface()
    }

    deinit {
        // NotificationCenter owns its block token. Explicitly removing it
        // keeps repeated PDFView creation/destruction from accumulating idle
        // observers, even though the callback also captures this panel weakly.
        if let languageObserver {
            NotificationCenter.default.removeObserver(languageObserver)
        }
    }

    func configure(with draft: PendingInlineTextEdit) {
        suppressCallbacks = true
        defer { suppressCallbacks = false }
        // Enumerating every installed font can be noticeable on systems with
        // large font libraries. Do it only when a person actually opens this
        // editor, not for every resident/viewer/comparison PDFView.
        if !fontMenuConfigured {
            configureFontMenu()
            fontMenuConfigured = true
        }
        draftID = draft.id
        purpose = draft.purpose
        textView.string = draft.text
        selectFont(named: draft.style.fontName)
        sizeField.doubleValue = Double(draft.style.fontSize)
        sizeStepper.doubleValue = Double(draft.style.fontSize)
        textColorWell.color = draft.style.textColor.nsColor
        backgroundColorWell.color = draft.style.backgroundColor.nsColor
        transparentBackgroundButton.state = draft.style.backgroundColor.alpha <= 0.001 ? .on : .off
        backgroundColorWell.isEnabled = transparentBackgroundButton.state == .off
        alignmentControl.selectedSegment = segment(for: draft.style.alignment)
        warningLabel.isHidden = draft.purpose != .visualReplacement
        applyPreview(style: draft.style)
    }

    var currentText: String { textView.string }

    var currentStyle: InlineTextStyle {
        let requestedName = fontMenu.selectedItem?.representedObject as? String
            ?? NSFont.systemFont(ofSize: 15).fontName
        let background = transparentBackgroundButton.state == .on
            ? PDFTextColor.clear
            : PDFTextColor(backgroundColorWell.color)
        return InlineTextStyle(
            fontName: requestedName,
            fontSize: CGFloat(sizeField.doubleValue),
            textColor: PDFTextColor(textColorWell.color),
            backgroundColor: background,
            alignment: alignment(for: alignmentControl.selectedSegment)
        )
    }

    func focusText() {
        window?.makeFirstResponder(textView)
    }

    func textDidChange(_ notification: Notification) {
        let limited = InlineTextDraftLimiter.limit(textView.string)
        if limited.wasTruncated {
            let selection = textView.selectedRange()
            suppressCallbacks = true
            textView.string = limited.text
            textView.setSelectedRange(
                NSRange(
                    location: min(selection.location, limited.text.utf16.count),
                    length: 0
                )
            )
            suppressCallbacks = false
            onLengthLimitReached?()
        }
        notifyDraftChanged()
    }

    @objc private func styleChanged(_ sender: Any?) {
        // Keep the text field and stepper in lockstep and enforce the same
        // limits used by the model even for pasted/non-numeric values.
        if sender as AnyObject? === sizeStepper {
            sizeField.doubleValue = sizeStepper.doubleValue
        }
        var style = currentStyle
        style.normalize()
        sizeField.doubleValue = Double(style.fontSize)
        sizeStepper.doubleValue = Double(style.fontSize)
        backgroundColorWell.isEnabled = transparentBackgroundButton.state == .off
        applyPreview(style: style)
        notifyDraftChanged(style: style)
    }

    @objc private func commitPressed(_ sender: Any?) {
        onCommit?()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onCancel?()
    }

    private func buildInterface() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.72).cgColor
        shadow = NSShadow()
        shadow?.shadowBlurRadius = 12
        shadow?.shadowOffset = CGSize(width: 0, height: -3)
        shadow?.shadowColor = NSColor.black.withAlphaComponent(0.28)

        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = CGSize(width: 7, height: 7)
        textView.delegate = self
        textView.onCommit = { [weak self] in self?.onCommit?() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        textView.onLengthLimitReached = { [weak self] in self?.onLengthLimitReached?() }
        scrollView.documentView = textView

        fontMenu.target = self
        fontMenu.action = #selector(styleChanged(_:))
        fontMenu.widthAnchor.constraint(equalToConstant: 128).isActive = true

        sizeField.alignment = .right
        sizeField.formatter = numberFormatter
        sizeField.target = self
        sizeField.action = #selector(styleChanged(_:))
        sizeField.widthAnchor.constraint(equalToConstant: 42).isActive = true

        sizeStepper.minValue = Double(InlineTextStyle.minimumFontSize)
        sizeStepper.maxValue = Double(InlineTextStyle.maximumFontSize)
        sizeStepper.increment = 1
        sizeStepper.target = self
        sizeStepper.action = #selector(styleChanged(_:))
        configureColorWell(textColorWell)
        configureColorWell(backgroundColorWell)
        transparentBackgroundButton.target = self
        transparentBackgroundButton.action = #selector(styleChanged(_:))

        alignmentControl.segmentCount = 3
        alignmentControl.trackingMode = .selectOne
        alignmentControl.target = self
        alignmentControl.action = #selector(styleChanged(_:))

        configureCompactLabel(foregroundLabel)
        configureCompactLabel(backgroundLabel)
        // Two rows are substantially easier to scan than one very long row.
        // The containing horizontal scroller is important for narrow HSplitView
        // panes: every control stays keyboard/mouse reachable instead of being
        // clipped beyond the right edge.
        let typographyRow = NSStackView(views: [
            fontMenu, sizeField, sizeStepper, alignmentControl,
        ])
        typographyRow.orientation = .horizontal
        typographyRow.alignment = .centerY
        typographyRow.spacing = 7
        let colorRow = NSStackView(views: [
            foregroundLabel,
            textColorWell,
            backgroundLabel,
            backgroundColorWell,
            transparentBackgroundButton,
        ])
        colorRow.orientation = .horizontal
        colorRow.alignment = .centerY
        colorRow.spacing = 7
        let toolbar = NSStackView(views: [typographyRow, colorRow])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 5
        toolbar.frame = CGRect(x: 0, y: 0, width: 430, height: 58)

        toolbarScrollView.translatesAutoresizingMaskIntoConstraints = false
        toolbarScrollView.drawsBackground = false
        toolbarScrollView.borderType = .noBorder
        toolbarScrollView.hasHorizontalScroller = true
        toolbarScrollView.hasVerticalScroller = false
        toolbarScrollView.autohidesScrollers = true
        toolbarScrollView.documentView = toolbar
        warningLabel.font = .systemFont(ofSize: 11, weight: .medium)
        warningLabel.textColor = .systemOrange
        warningLabel.maximumNumberOfLines = 2

        shortcutHint.font = .systemFont(ofSize: 10)
        shortcutHint.textColor = .secondaryLabelColor
        shortcutHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        applyButton.target = self
        applyButton.action = #selector(commitPressed(_:))
        applyButton.keyEquivalent = "\r"
        applyButton.bezelStyle = .rounded
        let actionRow = NSStackView(views: [shortcutHint, NSView(), cancelButton, applyButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let root = NSStackView(views: [toolbarScrollView, scrollView, warningLabel, actionRow])
        root.translatesAutoresizingMaskIntoConstraints = false
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            toolbarScrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            toolbarScrollView.heightAnchor.constraint(equalToConstant: 62),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
            warningLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])

        refreshLocalization()
        installLanguageObserver()
    }

    /// Refreshes every string owned by this long-lived AppKit panel.
    /// SwiftUI recreates its labels when the app language changes, but this
    /// overlay can remain open over the same PDFView and therefore must update
    /// the concrete controls in place.
    func refreshLocalization() {
        textView.setAccessibilityLabel(
            L10n.string("inline_text.editor", defaultValue: "PDF inline text editor")
        )
        fontMenu.setAccessibilityLabel(L10n.string("inline_text.font", defaultValue: "Font"))
        sizeField.setAccessibilityLabel(
            L10n.string("inline_text.font_size", defaultValue: "Font size")
        )
        sizeStepper.setAccessibilityLabel(
            L10n.string("inline_text.font_size", defaultValue: "Font size")
        )
        textColorWell.setAccessibilityLabel(
            L10n.string("inline_text.text_color", defaultValue: "Text color")
        )
        backgroundColorWell.setAccessibilityLabel(
            L10n.string("inline_text.background_color", defaultValue: "Background color")
        )
        transparentBackgroundButton.title = L10n.string(
            "inline_text.transparent_background",
            defaultValue: "Transparent"
        )
        transparentBackgroundButton.setAccessibilityLabel(transparentBackgroundButton.title)

        let alignmentSegments = [
            ("text.alignleft", "inline_text.alignment.left", "Align left"),
            ("text.aligncenter", "inline_text.alignment.center", "Align center"),
            ("text.alignright", "inline_text.alignment.right", "Align right"),
        ]
        for (index, segment) in alignmentSegments.enumerated() {
            let label = L10n.string(segment.1, defaultValue: segment.2)
            let image = NSImage(
                systemSymbolName: segment.0,
                accessibilityDescription: label
            ) ?? NSImage()
            image.accessibilityDescription = label
            alignmentControl.setImage(image, forSegment: index)
            alignmentControl.setToolTip(label, forSegment: index)
        }
        alignmentControl.setAccessibilityLabel(
            L10n.string("inline_text.alignment", defaultValue: "Text alignment")
        )

        toolbarScrollView.setAccessibilityLabel(
            L10n.string("inline_text.appearance_controls", defaultValue: "Text appearance controls")
        )
        foregroundLabel.stringValue = L10n.string(
            "inline_text.text_color.short",
            defaultValue: "Text"
        )
        backgroundLabel.stringValue = L10n.string(
            "inline_text.background_color.short",
            defaultValue: "Background"
        )
        if fontMenuConfigured, let systemItem = fontMenu.item(at: 0) {
            systemItem.title = L10n.string("inline_text.system_font", defaultValue: "System")
        }

        warningLabel.stringValue = L10n.string(
            "inline_text.visual_replacement_warning",
            defaultValue: "Visual replacement only. The original text remains available to search and copy; this is not secure redaction."
        )
        warningLabel.setAccessibilityLabel(warningLabel.stringValue)
        shortcutHint.stringValue = L10n.string(
            "inline_text.shortcuts",
            defaultValue: "Return/⌘Return Apply · Shift-Return Line Break · Esc Cancel"
        )
        shortcutHint.setAccessibilityLabel(shortcutHint.stringValue)
        cancelButton.title = L10n.string("action.cancel", defaultValue: "Cancel")
        applyButton.title = L10n.string("action.apply", defaultValue: "Apply")
    }

    private func installLanguageObserver() {
        guard languageObserver == nil else { return }
        languageObserver = NotificationCenter.default.addObserver(
            forName: .appLanguageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLocalization()
            }
        }
    }

    private var numberFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: Double(InlineTextStyle.minimumFontSize))
        formatter.maximum = NSNumber(value: Double(InlineTextStyle.maximumFontSize))
        formatter.allowsFloats = true
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private func configureFontMenu() {
        fontMenu.removeAllItems()
        let system = NSFont.systemFont(ofSize: 15)
        fontMenu.addItem(withTitle: L10n.string("inline_text.system_font", defaultValue: "System"))
        fontMenu.lastItem?.representedObject = system.fontName
        let manager = NSFontManager.shared
        for family in manager.availableFontFamilies.sorted() {
            let converted = manager.convert(system, toFamily: family)
            fontMenu.addItem(withTitle: family)
            fontMenu.lastItem?.representedObject = converted.fontName
        }
    }

    private func selectFont(named name: String) {
        if let item = fontMenu.itemArray.first(where: { ($0.representedObject as? String) == name }) {
            fontMenu.select(item)
            return
        }
        // A PDF may use a bold/italic face or embedded PostScript name that is
        // not the regular face returned by NSFontManager's family list. Keep
        // that exact face as an explicit menu item; otherwise merely opening
        // and applying the editor would silently replace it with System.
        let displayName = NSFont(name: name, size: 15)?.displayName ?? name
        fontMenu.addItem(withTitle: displayName)
        fontMenu.lastItem?.representedObject = name
        fontMenu.select(fontMenu.lastItem)
    }

    private func configureColorWell(_ well: NSColorWell) {
        well.target = self
        well.action = #selector(styleChanged(_:))
        well.widthAnchor.constraint(equalToConstant: 28).isActive = true
        well.heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    private func configureCompactLabel(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
    }

    private func applyPreview(style: InlineTextStyle) {
        textView.font = style.font
        textView.textColor = style.textColor.nsColor
        textView.backgroundColor = style.backgroundColor.nsColor
        textView.drawsBackground = style.backgroundColor.alpha > 0.001
        textView.alignment = style.alignment
    }

    private func notifyDraftChanged(style: InlineTextStyle? = nil) {
        guard !suppressCallbacks else { return }
        onDraftChanged?(textView.string, style ?? currentStyle)
    }

    private func segment(for alignment: NSTextAlignment) -> Int {
        switch alignment {
        case .center: 1
        case .right: 2
        default: 0
        }
    }

    private func alignment(for segment: Int) -> NSTextAlignment {
        switch segment {
        case 1: .center
        case 2: .right
        default: .left
        }
    }
}

/// Transparent sibling overlay that hosts the editor and paints an unsaved
/// target rectangle. Editor chrome is never attached to `PDFPage`, so it can
/// never leak into saved or printed output.
@MainActor
final class PDFInlineTextEditingOverlayView: NSView {
    weak var owner: InteractivePDFView?

    /// View-instance identity is separate from the draft UUID. During a
    /// SwiftUI replacement, outgoing and incoming overlays can display the
    /// same draft; only the incoming owner may write it back.
    private let ownershipID = UUID()
    private let panel = PDFInlineTextEditorPanel(frame: .zero)
    private var activeDraftID: UUID?
    private var targetRect = CGRect.zero
    private var boundsObserver: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?
    private weak var observedClipView: NSClipView?
    private(set) var superviewAttachmentCount = 0

    /// Narrow test seam for lifecycle verification. Production callers should
    /// use `prepareForRemoval()` rather than manipulating observers directly.
    var hasInstalledObservers: Bool {
        boundsObserver != nil || scaleObserver != nil
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil {
            superviewAttachmentCount += 1
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupPanel()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPanel()
    }

    /// Only the floating panel owns mouse input. Returning nil elsewhere keeps
    /// PDFKit form widgets, selection, links, and gestures fully native.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !panel.isHidden, panel.frame.contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        positionPanel()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !targetRect.isEmpty, !panel.isHidden else { return }
        NSGraphicsContext.saveGraphicsState()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(roundedRect: targetRect, xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    func synchronizeWithWorkspace() {
        let wasPresenting = activeDraftID != nil || !panel.isHidden || !targetRect.isEmpty
        guard
            let owner,
            owner.viewportContext == .normal,
            owner.workspaceState?.allowsInlineTextEditing == true,
            let draft = owner.workspaceState?.pendingInlineTextEdit,
            let document = owner.document,
            draft.pageIndex >= 0,
            draft.pageIndex < document.pageCount
        else {
            removeObservations()
            panel.isHidden = true
            isHidden = true
            targetRect = .zero
            activeDraftID = nil
            if wasPresenting {
                needsDisplay = true
            }
            return
        }

        if activeDraftID != draft.id {
            guard owner.workspaceState?.claimPendingInlineTextEditor(
                ownerID: ownershipID,
                draftID: draft.id
            ) == true else {
                removeObservations()
                panel.isHidden = true
                isHidden = true
                targetRect = .zero
                activeDraftID = nil
                return
            }
            activeDraftID = draft.id
            panel.configure(with: draft)
            panel.isHidden = false
            DispatchQueue.main.async { [weak self] in self?.panel.focusText() }
        }
        isHidden = false
        refreshScrollObservation()
        positionPanel()
        needsDisplay = true
    }

    /// Called before PDFView interprets a click outside the editor. A valid
    /// draft becomes one semantic PDF edit before the next pointer tool starts.
    func commitBeforePointerAction() {
        guard ownsActiveDraft else { return }
        commit()
    }

    func prepareForRemoval() {
        // A replacement PDFView may already own a newer draft for this same
        // workspace. The outgoing overlay must never synchronize or commit a
        // transaction whose UUID it does not own.
        if ownsActiveDraft {
            synchronizeDraft()
            owner?.workspaceState?.commitPendingInlineTextDraftIfNeeded()
        }
        if let activeDraftID {
            owner?.workspaceState?.releasePendingInlineTextEditor(
                ownerID: ownershipID,
                draftID: activeDraftID
            )
        }
        removeObservations()
        owner = nil
    }

    private func setupPanel() {
        isHidden = true
        panel.isHidden = true
        addSubview(panel)
        panel.onDraftChanged = { [weak self] _, _ in self?.synchronizeDraft() }
        panel.onLengthLimitReached = { [weak self] in
            guard let self else { return }
            guard self.ownsActiveDraft else { return }
            let limit = L10n.format(
                "inline_text.length_limit",
                InlineTextDraftLimiter.maximumCharacterCount
            )
            self.owner?.workspaceState?.statusMessage = self.panel.purpose == .visualReplacement
                ? [L10n.string("inline_text.visual_replacement_warning"), limit]
                    .joined(separator: " ")
                : limit
        }
        panel.onCommit = { [weak self] in self?.commit() }
        panel.onCancel = { [weak self] in self?.cancel() }
    }

    private func synchronizeDraft() {
        guard let owner, let id = activeDraftID, ownsActiveDraft else { return }
        owner.workspaceState?.updatePendingInlineTextDraft(
            id: id,
            text: panel.currentText,
            style: panel.currentStyle,
            bounds: owner.workspaceState?.pendingInlineTextEdit?.bounds ?? .zero
        )
    }

    private func commit() {
        guard
            let state = owner?.workspaceState,
            let id = activeDraftID,
            ownsActiveDraft
        else {
            finishPresentation()
            return
        }
        let bounds = state.pendingInlineTextEdit?.bounds ?? .zero
        state.commitPendingInlineText(
            id: id,
            text: panel.currentText,
            style: panel.currentStyle,
            bounds: bounds
        )
        finishPresentation()
    }

    private func cancel() {
        if ownsActiveDraft {
            owner?.workspaceState?.cancelPendingInlineText()
        }
        finishPresentation()
    }

    private var ownsActiveDraft: Bool {
        guard let state = owner?.workspaceState, let activeDraftID else { return false }
        return state.ownsPendingInlineTextEditor(
            ownerID: ownershipID,
            draftID: activeDraftID
        )
    }

    private func finishPresentation() {
        activeDraftID = nil
        targetRect = .zero
        panel.isHidden = true
        isHidden = true
        removeObservations()
        owner?.needsDisplay = true
        owner?.window?.makeFirstResponder(owner)
    }

    private func positionPanel() {
        guard
            let owner,
            let draft = owner.workspaceState?.pendingInlineTextEdit,
            draft.id == activeDraftID,
            let page = owner.document?.page(at: draft.pageIndex)
        else { return }

        targetRect = convertedRect(draft.bounds, from: page, owner: owner)
        panel.frame = InlineTextGeometry.editorPanelFrame(
            targetRect: targetRect,
            viewportBounds: bounds,
            purpose: draft.purpose
        )
    }

    private func convertedRect(
        _ pageRect: CGRect,
        from page: PDFPage,
        owner: InteractivePDFView
    ) -> CGRect {
        let pageCorners = [
            CGPoint(x: pageRect.minX, y: pageRect.minY),
            CGPoint(x: pageRect.maxX, y: pageRect.minY),
            CGPoint(x: pageRect.minX, y: pageRect.maxY),
            CGPoint(x: pageRect.maxX, y: pageRect.maxY),
        ]
        let points = pageCorners.map { point -> CGPoint in
            let ownerPoint = owner.convert(point, from: page)
            return convert(ownerPoint, from: owner)
        }
        guard
            let minX = points.map(\.x).min(),
            let maxX = points.map(\.x).max(),
            let minY = points.map(\.y).min(),
            let maxY = points.map(\.y).max()
        else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func refreshScrollObservation() {
        guard let owner else { return }
        let clipView = firstScrollView(in: owner)?.contentView ?? owner.enclosingScrollView?.contentView
        if observedClipView !== clipView {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            observedClipView = clipView
            if let clipView {
                clipView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.positionPanel()
                        self?.needsDisplay = true
                    }
                }
            }
        }
        if scaleObserver == nil {
            scaleObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewScaleChanged,
                object: owner,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.positionPanel()
                    self?.needsDisplay = true
                }
            }
        }
    }

    private func removeObservations() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let scaleObserver { NotificationCenter.default.removeObserver(scaleObserver) }
        boundsObserver = nil
        scaleObserver = nil
        observedClipView = nil
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let result = firstScrollView(in: subview) { return result }
        }
        return nil
    }
}

@MainActor
extension InteractivePDFView {
    func configureInlineTextEditingOverlay() {
        let overlay: PDFInlineTextEditingOverlayView
        if let installed = subviews.compactMap({ $0 as? PDFInlineTextEditingOverlayView }).last {
            overlay = installed
        } else {
            overlay = PDFInlineTextEditingOverlayView(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        overlay.owner = self
        overlay.synchronizeWithWorkspace()
    }

    func commitInlineTextEditorBeforePointerAction() {
        subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }
            .forEach { $0.commitBeforePointerAction() }
    }

    func prepareInlineTextEditingOverlayForRemoval() {
        subviews.compactMap { $0 as? PDFInlineTextEditingOverlayView }
            .forEach { $0.prepareForRemoval() }
    }
}

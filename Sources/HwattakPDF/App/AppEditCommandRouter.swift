// SPDX-License-Identifier: MPL-2.0

import AppKit
import Combine
import Foundation

/// Chooses the owner of the standard Edit > Undo / Redo commands.
///
/// Editable text keeps native AppKit undo behavior. A presented sheet without
/// an active editor blocks document history so a sheet-local shortcut (for
/// example the signature canvas' Command-Z button) remains in charge. Only the
/// normal document surface falls back to `PDFWorkspaceState`'s edit history.
enum AppEditCommandDestination: Equatable {
    case textEditing
    case document
    case blockedBySheet

    static func resolve(
        hasEditableTextResponder: Bool,
        hasPresentedSheet: Bool
    ) -> AppEditCommandDestination {
        if hasEditableTextResponder {
            return .textEditing
        }
        if hasPresentedSheet {
            return .blockedBySheet
        }
        return .document
    }
}

@MainActor
final class AppEditCommandRouter: ObservableObject {
    static let shared = AppEditCommandRouter()

    /// Commands are value views. Publishing a lightweight revision makes their
    /// titles and disabled state follow first-responder and native undo changes.
    @Published private(set) var revision: UInt = 0

    private let notificationCenter: NotificationCenter
    private var observationTokens: [NSObjectProtocol] = []
    private var mouseEventMonitor: Any?
    private var trackingMenus: Set<ObjectIdentifier> = []
    private var hasDeferredInvalidation = false

    init(
        notificationCenter: NotificationCenter = .default,
        observesMouseEvents: Bool = true
    ) {
        self.notificationCenter = notificationCenter
        let names: [Notification.Name] = [
            NSText.didBeginEditingNotification,
            NSText.didChangeNotification,
            NSText.didEndEditingNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.willBeginSheetNotification,
            NSWindow.didEndSheetNotification
        ]

        observationTokens = names.map { name in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.invalidate()
                }
            }
        }

        // A menu-bar click also reaches the local mouse monitor. Its deferred
        // focus refresh must not rebuild SwiftUI Commands while AppKit is
        // tracking a submenu; doing so can dismiss the submenu under the
        // pointer. Register tracking synchronously, before that task resumes.
        observationTokens.append(notificationCenter.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                self?.trackingMenus.insert(ObjectIdentifier(menu))
            }
        })
        observationTokens.append(notificationCenter.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                guard let self,
                      self.trackingMenus.remove(ObjectIdentifier(menu)) != nil else { return }
                self.publishDeferredInvalidationIfReady()
            }
        })
        observationTokens.append(notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // App switching cancels menus. Do not retain a tracking gate
                // if AppKit tears down a menu without its normal end event.
                self?.trackingMenus.removeAll()
                self?.publishDeferredInvalidationIfReady()
            }
        })

        guard observesMouseEvents else { return }
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                // Run after AppKit has assigned the click's first responder.
                await Task.yield()
                self?.invalidate()
            }
            return event
        }
    }

    deinit {
        observationTokens.forEach(notificationCenter.removeObserver)
        if let mouseEventMonitor {
            NSEvent.removeMonitor(mouseEventMonitor)
        }
    }

    /// Explicit focus seam for PDFKit views. AppKit does not publish a general
    /// first-responder-change notification when comparison panels are clicked.
    func invalidate() {
        guard trackingMenus.isEmpty else {
            hasDeferredInvalidation = true
            return
        }
        revision &+= 1
    }

    private func publishDeferredInvalidationIfReady() {
        guard trackingMenus.isEmpty, hasDeferredInvalidation else { return }
        hasDeferredInvalidation = false
        revision &+= 1
    }

    var destination: AppEditCommandDestination {
        AppEditCommandDestination.resolve(
            hasEditableTextResponder: editableTextView != nil,
            hasPresentedSheet: hasPresentedSheet
        )
    }

    /// Comparison mode can focus a PDF that is not the active tab. Resolve the
    /// concrete PDF view first. Comparison panels are strictly read-only, so a
    /// focused comparison hierarchy deliberately returns no document history
    /// target instead of undoing/redoing the source workspace underneath it.
    func documentWorkspace(fallback: PDFWorkspaceState?) -> PDFWorkspaceState? {
        Self.documentWorkspace(
            startingAt: activeWindow?.firstResponder,
            fallback: fallback
        )
    }

    static func documentWorkspace(
        startingAt responder: NSResponder?,
        fallback: PDFWorkspaceState?
    ) -> PDFWorkspaceState? {
        guard !isComparisonViewport(startingAt: responder) else { return nil }
        return workspaceState(startingAt: responder) ?? fallback
    }

    /// Testable responder-level half of comparison command protection.
    ///
    /// The scene-focused value used by `HwattakPDFCommands` also covers toolbar
    /// focus. This seam independently protects Command-Z when the comparison
    /// PDFView (or one of PDFKit's private descendants) is first responder.
    static func isComparisonViewport(startingAt responder: NSResponder?) -> Bool {
        guard let responderView = responder as? NSView else { return false }

        if
            let fieldEditor = responderView as? NSTextView,
            fieldEditor.isFieldEditor,
            let delegateView = fieldEditor.delegate as? NSView
        {
            return pdfView(in: delegateView)?.viewportContext == .comparison
        }
        return pdfView(in: responderView)?.viewportContext == .comparison
    }

    static func workspaceState(startingAt responder: NSResponder?) -> PDFWorkspaceState? {
        guard let responderView = responder as? NSView else { return nil }

        if
            let fieldEditor = responderView as? NSTextView,
            fieldEditor.isFieldEditor,
            let delegateView = fieldEditor.delegate as? NSView,
            let state = workspaceState(in: delegateView)
        {
            return state
        }
        return workspaceState(in: responderView)
    }

    func canUndo(documentCanUndo: Bool) -> Bool {
        switch destination {
        case .textEditing:
            return Self.canNativeUndo(in: editableTextView)
        case .document:
            return documentCanUndo
        case .blockedBySheet:
            return false
        }
    }

    func canRedo(documentCanRedo: Bool) -> Bool {
        switch destination {
        case .textEditing:
            return Self.canNativeRedo(in: editableTextView)
        case .document:
            return documentCanRedo
        case .blockedBySheet:
            return false
        }
    }

    func undoMenuTitle(documentTitle: String) -> String {
        guard
            destination == .textEditing,
            let title = editableTextView?.undoManager?.undoMenuItemTitle,
            !title.isEmpty
        else { return documentTitle }
        return title
    }

    func redoMenuTitle(documentTitle: String) -> String {
        guard
            destination == .textEditing,
            let title = editableTextView?.undoManager?.redoMenuItemTitle,
            !title.isEmpty
        else { return documentTitle }
        return title
    }

    func performUndo(documentAction: () -> Void) {
        switch destination {
        case .textEditing:
            guard Self.performNativeUndo(in: editableTextView) else { return }
        case .document:
            documentAction()
        case .blockedBySheet:
            break
        }
        invalidate()
    }

    func performRedo(documentAction: () -> Void) {
        switch destination {
        case .textEditing:
            guard Self.performNativeRedo(in: editableTextView) else { return }
        case .document:
            documentAction()
        case .blockedBySheet:
            break
        }
        invalidate()
    }

    private var editableTextView: NSTextView? {
        Self.editableTextView(startingAt: activeWindow?.firstResponder)
    }

    static func editableTextView(startingAt responder: NSResponder?) -> NSTextView? {
        guard
            let responder = responder as? NSTextView,
            responder.isEditable
        else { return nil }
        return responder
    }

    static func canNativeUndo(in textView: NSTextView?) -> Bool {
        textView?.undoManager?.canUndo ?? false
    }

    static func canNativeRedo(in textView: NSTextView?) -> Bool {
        textView?.undoManager?.canRedo ?? false
    }

    @discardableResult
    static func performNativeUndo(in textView: NSTextView?) -> Bool {
        guard let manager = textView?.undoManager, manager.canUndo else { return false }
        manager.undo()
        return true
    }

    @discardableResult
    static func performNativeRedo(in textView: NSTextView?) -> Bool {
        guard let manager = textView?.undoManager, manager.canRedo else { return false }
        manager.redo()
        return true
    }

    private var hasPresentedSheet: Bool {
        Self.hasPresentedSheet(in: activeWindow)
    }

    static func hasPresentedSheet(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.sheetParent != nil
            || window.attachedSheet != nil
    }

    private var activeWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
    }

    private static func workspaceState(in view: NSView) -> PDFWorkspaceState? {
        var candidate: NSView? = view
        while let current = candidate {
            if let overlay = current as? PDFAnnotationEditingOverlayView,
               let state = overlay.owner?.workspaceState {
                return state
            }
            if let pdfView = current as? InteractivePDFView,
               let state = pdfView.workspaceState {
                return state
            }
            candidate = current.superview
        }
        return nil
    }

    /// Finds the concrete PDFView without assuming that every editing overlay
    /// is physically attached as its child. Some overlays retain an explicit
    /// weak owner while AppKit temporarily reparents the field editor.
    private static func pdfView(in view: NSView) -> InteractivePDFView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let overlay = current as? PDFAnnotationEditingOverlayView,
               let owner = overlay.owner {
                return owner
            }
            if let pdfView = current as? InteractivePDFView {
                return pdfView
            }
            candidate = current.superview
        }
        return nil
    }
}

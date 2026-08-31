// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

@MainActor
final class VibePDFAppDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: MultiDocumentWorkspaceState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconManager.shared.applySavedSelection()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sender.keyWindow?.makeFirstResponder(nil)
        guard let workspace else { return .terminateNow }
        let windowWorkspaces = PDFTabTearOutStore.shared.allWindowWorkspaces
        let documents = workspace.allTabs.map(\.workspace)
            + windowWorkspaces.flatMap { $0.allTabs.map(\.workspace) }
        let accepted = UnsavedChangesGuard.confirmAndClose(
            workspaces: documents,
            beforeClosing: {
                // Capture the main and detached window topology before scene
                // teardown so relaunch can rebuild the same workspace split.
                workspace.freezeSessionPersistenceAfterFlushing(
                    including: windowWorkspaces
                )
                windowWorkspaces.forEach { $0.freezeSessionPersistenceAfterFlushing() }
            }
        )
        return accepted ? .terminateNow : .terminateCancel
    }
}

@MainActor
enum WorkspaceSaveCoordinator {
    enum Purpose {
        case explicitSave
        case closing
    }

    enum Choice: Equatable {
        case overwriteOriginal
        case saveCopy
        case dontSave
        case cancel
    }

    enum Outcome: Equatable {
        case saved
        case discarded
        case cancelled
    }

    /// Presents one consistent save decision for the toolbar and Command-S.
    /// A clean document does not need another PDFKit serialization pass.
    @discardableResult
    static func requestSave(workspace: PDFWorkspaceState) -> Bool {
        workspace.prepareForDeactivation()
        guard workspace.document != nil else {
            workspace.save()
            return false
        }
        guard workspace.isDirty else {
            workspace.statusMessage = L10n.string("status.no_changes_to_save")
            return true
        }

        let choice = decision(for: workspace, purpose: .explicitSave)
        return apply(choice, to: workspace) == .saved
    }

    /// Command-Shift-S enters the copy flow directly, while using the same
    /// destination validation as the save confirmation dialog.
    @discardableResult
    static func requestSaveCopy(workspace: PDFWorkspaceState) -> Bool {
        workspace.prepareForDeactivation()
        guard workspace.document != nil else {
            workspace.save()
            return false
        }
        return apply(.saveCopy, to: workspace) == .saved
    }

    /// Performs a previously chosen action. Keeping this operation separate
    /// from the AppKit alert makes overwrite/copy/cancel behavior testable.
    static func apply(
        _ choice: Choice,
        to workspace: PDFWorkspaceState,
        copyDestination: (() -> URL?)? = nil
    ) -> Outcome {
        switch choice {
        case .overwriteOriginal:
            guard workspace.documentURL != nil else { return .cancelled }
            return workspace.saveSynchronously() ? .saved : .cancelled
        case .saveCopy:
            let destination: URL?
            if let copyDestination {
                destination = copyDestination()
            } else {
                destination = chooseCopyDestination(for: workspace)
            }
            guard let destination else { return .cancelled }
            // NSSavePanel grants a security-scoped destination. Keep that
            // grant alive while the shared resolver reads device/inode metadata
            // so aliases, symlinks, and hard links cannot bypass copy safety.
            let destinationAccess = SecurityScopedAccess(url: destination)
            let isOriginal = withExtendedLifetime(destinationAccess) {
                guard let original = workspace.documentURL else { return false }
                return PDFSourceFileVersion.refersToSameLocation(original, destination)
            }
            if isOriginal {
                workspace.presentedError = L10n.string("error.save_copy_same_as_original")
                return .cancelled
            }
            return workspace.saveSynchronously(as: destination) ? .saved : .cancelled
        case .dontSave:
            return .discarded
        case .cancel:
            return .cancelled
        }
    }

    static func decision(for workspace: PDFWorkspaceState, purpose: Purpose) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("alert.save_changes.title", workspace.displayName)
        alert.informativeText = purpose == .closing
            ? L10n.string("alert.save_changes.message")
            : L10n.string("alert.save_options.message")

        var choices: [Choice] = []
        if workspace.documentURL != nil {
            add(
                .overwriteOriginal,
                title: L10n.string("action.overwrite_original"),
                to: alert,
                choices: &choices
            )
        }
        add(
            .saveCopy,
            title: L10n.string("action.save_copy"),
            to: alert,
            choices: &choices
        )
        add(
            .cancel,
            title: L10n.string("action.cancel"),
            to: alert,
            choices: &choices
        )
        if purpose == .closing {
            add(
                .dontSave,
                title: L10n.string("action.dont_save"),
                to: alert,
                choices: &choices
            )
        }

        for (index, choice) in choices.enumerated() {
            let button = alert.buttons[index]
            switch choice {
            case .overwriteOriginal:
                button.keyEquivalent = "\r"
            case .cancel:
                button.keyEquivalent = "\u{1b}"
            case .dontSave:
                button.hasDestructiveAction = true
            case .saveCopy:
                break
            }
        }

        let choiceIndex = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(choiceIndex) else { return .cancel }
        return choices[choiceIndex]
    }

    private static func add(
        _ choice: Choice,
        title: String,
        to alert: NSAlert,
        choices: inout [Choice]
    ) {
        alert.addButton(withTitle: title)
        choices.append(choice)
    }

    private static func chooseCopyDestination(for workspace: PDFWorkspaceState) -> URL? {
        let baseName = workspace.documentURL?.deletingPathExtension().lastPathComponent
            ?? "HwattakPDF"
        return WorkspaceFilePanels.chooseSavePDF(suggestedName: "\(baseName)-copy.pdf")
    }

}

@MainActor
enum UnsavedChangesGuard {
    private enum PendingAction {
        case keepSaved(PDFWorkspaceState)
        case discard(PDFWorkspaceState)

        var workspace: PDFWorkspaceState {
            switch self {
            case let .keepSaved(workspace), let .discard(workspace):
                return workspace
            }
        }
    }

    /// Resolves dirty documents one at a time. Discard choices are only
    /// committed after every tab has been accepted, so cancelling a later
    /// alert never destroys changes from an earlier tab.
    static func confirmAndClose(
        workspaces: [PDFWorkspaceState],
        beforeClosing: (() -> Void)? = nil,
        closeDocuments: Bool = true
    ) -> Bool {
        confirmAndClose(
            workspaces: workspaces,
            decisionProvider: {
                WorkspaceSaveCoordinator.decision(for: $0, purpose: .closing)
            },
            beforeClosing: beforeClosing,
            closeDocuments: closeDocuments
        )
    }

    /// Injectable variant used by safety tests to exercise multi-document
    /// cancellation without displaying a modal NSAlert.
    static func confirmAndClose(
        workspaces: [PDFWorkspaceState],
        decisionProvider: (PDFWorkspaceState) -> WorkspaceSaveCoordinator.Choice,
        copyDestinationProvider: ((PDFWorkspaceState) -> URL?)? = nil,
        beforeClosing: (() -> Void)? = nil,
        closeDocuments: Bool = true
    ) -> Bool {
        let uniqueWorkspaces = unique(workspaces)
        // A PDFKit form control can still hold its newest text in AppKit's
        // field editor. Commit that responder before looking at `isDirty`, or
        // a tab-X/Cmd-W close could incorrectly classify it as clean.
        uniqueWorkspaces.forEach { $0.prepareForDeactivation() }

        // A review/AI draft has not been applied to the PDF and must not be
        // silently promoted merely because the app/window is closing. Cancel
        // the close so the existing sheet can return to the front and the user
        // can explicitly Apply or Cancel it.
        if let workspace = uniqueWorkspaces.first(where: \.hasPendingReviewTextDraft) {
            workspace.presentedError = L10n.string("error.unsaved_close")
            return false
        }

        var pendingActions: [PendingAction] = []
        pendingActions.reserveCapacity(uniqueWorkspaces.count)

        for workspace in uniqueWorkspaces where workspace.document != nil {
            guard workspace.isDirty else {
                pendingActions.append(.discard(workspace))
                continue
            }

            let choice = decisionProvider(workspace)
            let outcome: WorkspaceSaveCoordinator.Outcome
            if let copyDestinationProvider, choice == .saveCopy {
                outcome = WorkspaceSaveCoordinator.apply(
                    choice,
                    to: workspace,
                    copyDestination: { copyDestinationProvider(workspace) }
                )
            } else {
                outcome = WorkspaceSaveCoordinator.apply(choice, to: workspace)
            }
            switch outcome {
            case .saved:
                pendingActions.append(.keepSaved(workspace))
            case .discarded:
                pendingActions.append(.discard(workspace))
            case .cancelled:
                return false
            }
        }

        // Saving has already committed durable bytes, but all document state
        // remains live until this point. This makes a later Cancel lossless.
        beforeClosing?()
        if closeDocuments {
            pendingActions.forEach { $0.workspace.closeDiscardingChanges() }
        }
        return true
    }

    static func confirmAndClose(workspace: PDFWorkspaceState) -> Bool {
        confirmAndClose(workspaces: [workspace])
    }

    private static func unique(_ workspaces: [PDFWorkspaceState]) -> [PDFWorkspaceState] {
        var seen: Set<ObjectIdentifier> = []
        return workspaces.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}

/// A zero-sized bridge that guards the native red close button while
/// forwarding SwiftUI's other NSWindowDelegate callbacks unchanged.
@MainActor
struct WindowCloseGuard: NSViewRepresentable {
    let workspace: MultiDocumentWorkspaceState

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace: workspace)
    }

    func makeNSView(context: Context) -> GuardView {
        let view = GuardView(frame: .zero)
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: GuardView, context: Context) {
        context.coordinator.workspace = workspace
        view.coordinator = context.coordinator
        if let window = view.window {
            context.coordinator.attach(to: window)
        }
    }

    static func dismantleNSView(_ view: GuardView, coordinator: Coordinator) {
        coordinator.detach()
        view.coordinator = nil
    }

    final class GuardView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                coordinator?.attach(to: window)
            } else {
                coordinator?.detach()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        weak var workspace: MultiDocumentWorkspaceState?
        private weak var guardedWindow: NSWindow?
        private weak var forwardedDelegate: (any NSWindowDelegate)?

        init(workspace: MultiDocumentWorkspaceState) {
            self.workspace = workspace
        }

        func attach(to window: NSWindow) {
            guard guardedWindow !== window else { return }
            detach()
            guardedWindow = window
            forwardedDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            if guardedWindow?.delegate === self {
                guardedWindow?.delegate = forwardedDelegate
            }
            guardedWindow = nil
            forwardedDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.makeFirstResponder(nil)
            if forwardedDelegate?.windowShouldClose?(sender) == false {
                return false
            }
            guard let workspace else { return true }
            let detachedWindowWorkspaces = PDFTabTearOutStore.shared
                .allWindowWorkspaces
                .filter { $0 !== workspace }
            return UnsavedChangesGuard.confirmAndClose(
                workspaces: workspace.allTabs.map(\.workspace),
                beforeClosing: {
                    workspace.freezeSessionPersistenceAfterFlushing(
                        including: detachedWindowWorkspaces
                    )
                }
            )
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (forwardedDelegate?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if forwardedDelegate?.responds(to: selector) == true {
                return forwardedDelegate
            }
            return super.forwardingTarget(for: selector)
        }
    }
}

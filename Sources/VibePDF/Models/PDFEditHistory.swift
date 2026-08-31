// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The small piece of workspace UI state that belongs to a reversible PDF
/// edit. Keeping it beside the command makes page operations feel natural
/// when they are undone without retaining the workspace itself.
struct PDFEditNavigationSnapshot: Equatable {
    let currentPageIndex: Int
    let selectedPages: Set<Int>
}

/// A single already-performed PDF mutation and its inverse.
///
/// The closures intentionally capture only the changed PDF pages or
/// annotations. They must never capture `PDFWorkspaceState`, because the
/// history is owned by that state and doing so would create a retain cycle.
@MainActor
final class PDFEditCommand {
    let actionName: String
    let beforeNavigation: PDFEditNavigationSnapshot
    let afterNavigation: PDFEditNavigationSnapshot
    let invalidatesDocumentSelections: Bool
    /// Number of detached/removed pages kept alive solely for this command.
    /// Pages still present in the open document use a cost of zero.
    let retainedPageCost: Int

    fileprivate let beforeStateID: UUID
    fileprivate let afterStateID: UUID
    fileprivate let undoMutation: () throws -> Void
    fileprivate let redoMutation: () throws -> Void

    fileprivate init(
        actionName: String,
        beforeNavigation: PDFEditNavigationSnapshot,
        afterNavigation: PDFEditNavigationSnapshot,
        invalidatesDocumentSelections: Bool,
        retainedPageCost: Int,
        beforeStateID: UUID,
        afterStateID: UUID,
        undoMutation: @escaping () throws -> Void,
        redoMutation: @escaping () throws -> Void
    ) {
        self.actionName = actionName
        self.beforeNavigation = beforeNavigation
        self.afterNavigation = afterNavigation
        self.invalidatesDocumentSelections = invalidatesDocumentSelections
        self.retainedPageCost = max(0, retainedPageCost)
        self.beforeStateID = beforeStateID
        self.afterStateID = afterStateID
        self.undoMutation = undoMutation
        self.redoMutation = redoMutation
    }
}

/// A document-scoped, bounded command history.
///
/// State IDs provide saved-checkpoint semantics without serializing the PDF:
/// undoing back to the exact state last written to disk becomes clean, while
/// redoing away from it becomes dirty again. Commands keep only reversible
/// deltas (annotation/page references or scalar values), never a full copy of
/// the open document.
@MainActor
final class PDFEditHistory {
    nonisolated static let defaultLimit = 22
    /// Bounds the normal case to roughly a few dozen retained page graphs.
    /// A single larger operation remains undoable, but it becomes the sole
    /// history entry and is evicted when a later edit is registered.
    nonisolated static let defaultRetainedPageLimit = 64

    let limit: Int
    let retainedPageLimit: Int

    private(set) var undoStack: [PDFEditCommand] = []
    private(set) var redoStack: [PDFEditCommand] = []
    private(set) var isApplyingCommand = false

    private var currentStateID = UUID()
    private var savedStateID: UUID

    init(
        limit: Int = PDFEditHistory.defaultLimit,
        retainedPageLimit: Int = PDFEditHistory.defaultRetainedPageLimit
    ) {
        self.limit = max(1, limit)
        self.retainedPageLimit = max(1, retainedPageLimit)
        savedStateID = currentStateID
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoActionName: String? { undoStack.last?.actionName }
    var redoActionName: String? { redoStack.last?.actionName }
    var isAtSavedState: Bool { currentStateID == savedStateID }
    var undoCount: Int { undoStack.count }
    var redoCount: Int { redoStack.count }

    /// Starts a new document history and makes that initial state the saved
    /// baseline. Existing commands are released immediately.
    func reset() {
        undoStack.removeAll(keepingCapacity: false)
        redoStack.removeAll(keepingCapacity: false)
        currentStateID = UUID()
        savedStateID = currentStateID
        isApplyingCommand = false
    }

    /// Marks the current position after a successful file write. History is
    /// deliberately retained, matching standard macOS document behaviour.
    func markSaved() {
        savedStateID = currentStateID
    }

    @discardableResult
    func register(
        actionName: String,
        beforeNavigation: PDFEditNavigationSnapshot,
        afterNavigation: PDFEditNavigationSnapshot,
        invalidatesDocumentSelections: Bool = false,
        retainedPageCost: Int = 0,
        undo: @escaping () throws -> Void,
        redo: @escaping () throws -> Void
    ) -> Bool {
        guard !isApplyingCommand else { return false }

        let nextStateID = UUID()
        let command = PDFEditCommand(
            actionName: actionName,
            beforeNavigation: beforeNavigation,
            afterNavigation: afterNavigation,
            invalidatesDocumentSelections: invalidatesDocumentSelections,
            retainedPageCost: retainedPageCost,
            beforeStateID: currentStateID,
            afterStateID: nextStateID,
            undoMutation: undo,
            redoMutation: redo
        )
        redoStack.removeAll(keepingCapacity: false)
        if retainedPageCost >= retainedPageLimit {
            // Preserve one oversized explicit page operation without also
            // retaining any older page graphs.
            undoStack.removeAll(keepingCapacity: false)
        }
        undoStack.append(command)
        while undoStack.count > limit || retainedPageCostTotal > retainedPageLimit {
            guard undoStack.count > 1 else { break }
            undoStack.removeFirst()
        }
        currentStateID = nextStateID
        return true
    }

    /// Records a PDFKit-side mutation for which no safe inverse is available
    /// (for example, an externally changed widget structure). Older commands cannot
    /// cross that mutation without lying about the saved checkpoint, so it is
    /// an explicit history barrier rather than a no-op undo entry.
    func noteUntrackedMutation() {
        guard !isApplyingCommand else { return }
        undoStack.removeAll(keepingCapacity: false)
        redoStack.removeAll(keepingCapacity: false)
        currentStateID = UUID()
    }

    @discardableResult
    func undo() throws -> PDFEditCommand? {
        guard !isApplyingCommand, let command = undoStack.last else { return nil }
        isApplyingCommand = true
        defer { isApplyingCommand = false }
        try command.undoMutation()
        undoStack.removeLast()
        redoStack.append(command)
        currentStateID = command.beforeStateID
        return command
    }

    @discardableResult
    func redo() throws -> PDFEditCommand? {
        guard !isApplyingCommand, let command = redoStack.last else { return nil }
        isApplyingCommand = true
        defer { isApplyingCommand = false }
        try command.redoMutation()
        redoStack.removeLast()
        undoStack.append(command)
        currentStateID = command.afterStateID
        return command
    }

    private var retainedPageCostTotal: Int {
        undoStack.reduce(into: 0) { $0 += $1.retainedPageCost }
            + redoStack.reduce(into: 0) { $0 += $1.retainedPageCost }
    }
}

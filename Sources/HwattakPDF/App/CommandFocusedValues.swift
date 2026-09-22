// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Publishes whether the focused PDF window is currently showing its
/// comparison-only surface.
///
/// First-responder inspection protects shortcuts while a comparison PDFView is
/// focused, but a user can also focus the comparison toolbar before opening an
/// app menu. A scene-focused value covers that second route and prevents menu
/// commands from mutating the hidden normal workspace underneath comparison.
private struct ComparisonReadOnlyActiveFocusedValueKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var comparisonReadOnlyActive: Bool? {
        get { self[ComparisonReadOnlyActiveFocusedValueKey.self] }
        set { self[ComparisonReadOnlyActiveFocusedValueKey.self] = newValue }
    }
}

/// Window-scoped presentation commands that cannot safely live on the PDF
/// document model. In particular, focus mode hides the tab bar owned by
/// `TabbedWorkspaceView`, so the app menu reaches it through the focused scene
/// instead of accidentally changing a hidden main window.
struct WorkspacePresentationCommandContext {
    let isFocusMode: Bool
    let setFocusMode: (Bool) -> Void
}

enum WorkspaceChromePreferences {
    static let modeToolsVisibleKey = "workspace.modeToolsVisible"
}

private struct WorkspacePresentationCommandsFocusedValueKey: FocusedValueKey {
    typealias Value = WorkspacePresentationCommandContext
}

extension FocusedValues {
    var workspacePresentationCommands: WorkspacePresentationCommandContext? {
        get { self[WorkspacePresentationCommandsFocusedValueKey.self] }
        set { self[WorkspacePresentationCommandsFocusedValueKey.self] = newValue }
    }
}

// SPDX-License-Identifier: MPL-2.0

import AppKit

/// An app-wide override; nil lets AppKit keep following macOS automatically.
enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String { L10n.string("appearance.\(rawValue)") }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        // Applying at the application level also updates PDFKit, detached
        // windows and native panels, not just the current SwiftUI scene.
        NSApplication.shared.appearance = nativeAppearance
    }
}

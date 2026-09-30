// SPDX-License-Identifier: MPL-2.0

import Foundation

enum PDFKeyboardNavigationSpeed: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast

    static let defaultsKey = "pdf.keyboardNavigationSpeed"
    static let defaultValue: Self = .normal

    static var savedValue: Self {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(Self.init(rawValue:)) ?? defaultValue
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slow:
            L10n.string("settings.pdf_input.keyboard_speed.slow", defaultValue: "느리게")
        case .normal:
            L10n.string("settings.pdf_input.keyboard_speed.normal", defaultValue: "보통")
        case .fast:
            L10n.string("settings.pdf_input.keyboard_speed.fast", defaultValue: "빠르게")
        }
    }

    var repeatInterval: TimeInterval {
        switch self {
        case .slow: 0.10
        case .normal: 0.05
        case .fast: 0.025
        }
    }

    var initialDelay: TimeInterval {
        switch self {
        case .slow: 0.30 / 1.8
        case .normal: 0.24 / 1.8
        case .fast: 0.18 / 1.8
        }
    }
}

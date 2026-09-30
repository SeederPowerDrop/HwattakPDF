// SPDX-License-Identifier: MPL-2.0

import Foundation
import SwiftUI

/// Quiet neutral surfaces keep the document in front.
/// Brand colors are reserved for small action and status accents.
struct HwattakPDFTheme {
    let colorScheme: ColorScheme

    init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    var canvas: Color {
        colorScheme == .dark
            ? Color(white: 0.105)
            : Color(white: 0.945)
    }

    var sidebar: Color {
        colorScheme == .dark
            ? Color(white: 0.135)
            : Color(white: 0.970)
    }

    var panel: Color {
        colorScheme == .dark
            ? Color(white: 0.155)
            : Color(white: 0.980)
    }

    var card: Color {
        colorScheme == .dark
            ? Color(white: 0.190)
            : Color.white
    }

    var border: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.085)
            : Color.black.opacity(0.075)
    }

    var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.435, green: 0.557, blue: 0.682)
            : brandNavy
    }

    var primaryText: Color {
        colorScheme == .dark
            ? Color(white: 0.91)
            : Color(white: 0.16)
    }

    var secondaryText: Color {
        colorScheme == .dark
            ? Color(white: 0.64)
            : Color(white: 0.43)
    }

    var dropHighlight: Color {
        accent.opacity(colorScheme == .dark ? 0.20 : 0.10)
    }

    var elevatedShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08)
    }

    var success: Color {
        colorScheme == .dark
            ? Color(red: 0.365, green: 0.730, blue: 0.570)
            : Color(red: 0.140, green: 0.455, blue: 0.335)
    }

    var warning: Color {
        colorScheme == .dark
            ? Color(red: 0.930, green: 0.675, blue: 0.330)
            : Color(red: 0.690, green: 0.390, blue: 0.090)
    }

    // MARK: Freed Page brand roles

    var brandNavy: Color {
        Color(red: 0.078, green: 0.149, blue: 0.231)
    }

    var ink: Color {
        Color(red: 0.149, green: 0.204, blue: 0.259)
    }

    var steel: Color {
        Color(red: 0.435, green: 0.557, blue: 0.682)
    }

    var ribbon: Color {
        colorScheme == .dark
            ? Color(red: 0.976, green: 0.365, blue: 0.329)
            : Color(red: 0.910, green: 0.310, blue: 0.278)
    }

    var ribbonSoft: Color {
        ribbon.opacity(colorScheme == .dark ? 0.20 : 0.12)
    }

    /// Darker coral reserved for small labels that need cream text contrast.
    var ribbonLabel: Color {
        Color(red: 0.650, green: 0.145, blue: 0.125)
    }

    var paperIvory: Color {
        Color(white: 0.980)
    }

    var cream: Color {
        Color(red: 1.000, green: 0.957, blue: 0.875)
    }

    var chrome: Color {
        colorScheme == .dark
            ? Color(white: 0.125)
            : Color(white: 0.945)
    }

    var chromeRaised: Color {
        colorScheme == .dark
            ? Color(white: 0.190)
            : Color(white: 0.995)
    }

    var chromeText: Color { primaryText }

    var chromeSecondaryText: Color {
        chromeText.opacity(0.66)
    }
}

enum HwattakPDFRelease {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.0"
    }

    static var badge: String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }
}

private struct HwattakPDFCardModifier: ViewModifier {
    let theme: HwattakPDFTheme
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(theme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }

    }
}

extension View {
    func hwattakPDFCard(_ theme: HwattakPDFTheme, cornerRadius: CGFloat = 14) -> some View {
        modifier(HwattakPDFCardModifier(theme: theme, cornerRadius: cornerRadius))
    }
}

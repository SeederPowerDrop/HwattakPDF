// SPDX-License-Identifier: MPL-2.0

import Foundation
import SwiftUI

/// HwattakPDF 0.5's adaptive palette, sampled from the Freed Page app icon.
/// Navy carries the app chrome, ivory represents paper, and coral is kept as
/// a small brand/status accent so documents remain the visual focus.
struct VibePDFTheme {
    let colorScheme: ColorScheme

    init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    var canvas: Color {
        colorScheme == .dark
            ? Color(red: 0.051, green: 0.090, blue: 0.137)
            : Color(red: 0.933, green: 0.914, blue: 0.871)
    }

    var sidebar: Color {
        colorScheme == .dark
            ? Color(red: 0.078, green: 0.145, blue: 0.220)
            : Color(red: 0.973, green: 0.949, blue: 0.902)
    }

    var panel: Color {
        colorScheme == .dark
            ? Color(red: 0.106, green: 0.188, blue: 0.278)
            : Color(red: 0.980, green: 0.953, blue: 0.898)
    }

    var card: Color {
        colorScheme == .dark
            ? Color(red: 0.122, green: 0.216, blue: 0.318)
            : Color(red: 1.000, green: 0.976, blue: 0.933)
    }

    var border: Color {
        colorScheme == .dark
            ? cream.opacity(0.17)
            : brandNavy.opacity(0.20)
    }

    var accent: Color {
        colorScheme == .dark
            ? Color(red: 0.435, green: 0.557, blue: 0.682)
            : brandNavy
    }

    var primaryText: Color {
        colorScheme == .dark
            ? cream
            : ink
    }

    var secondaryText: Color {
        colorScheme == .dark
            ? Color(red: 0.620, green: 0.704, blue: 0.790)
            : Color(red: 0.318, green: 0.392, blue: 0.463)
    }

    var dropHighlight: Color {
        steel.opacity(colorScheme == .dark ? 0.28 : 0.18)
    }

    var elevatedShadow: Color {
        Color.black.opacity(colorScheme == .dark ? 0.38 : 0.15)
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
        Color(red: 0.980, green: 0.953, blue: 0.898)
    }

    var cream: Color {
        Color(red: 1.000, green: 0.957, blue: 0.875)
    }

    var chrome: Color {
        colorScheme == .dark
            ? Color(red: 0.035, green: 0.075, blue: 0.122)
            : brandNavy
    }

    var chromeRaised: Color {
        colorScheme == .dark
            ? Color(red: 0.078, green: 0.149, blue: 0.231)
            : Color(red: 0.102, green: 0.212, blue: 0.333)
    }

    var chromeText: Color { cream }

    var chromeSecondaryText: Color {
        cream.opacity(0.66)
    }
}

enum VibePDFRelease {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.8.0"
    }

    static var badge: String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }
}

private struct VibePDFCardModifier: ViewModifier {
    let theme: VibePDFTheme
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(theme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(theme.border, lineWidth: 1)
            }
            .shadow(color: theme.elevatedShadow.opacity(0.22), radius: 5, y: 2)
    }
}

extension View {
    func vibePDFCard(_ theme: VibePDFTheme, cornerRadius: CGFloat = 14) -> some View {
        modifier(VibePDFCardModifier(theme: theme, cornerRadius: cornerRadius))
    }
}

// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// A focused page surface owns its held arrows. Header fields and sliders sit
/// outside this modifier, so their text/caret and adjustment keys stay native.
struct PDFArrowKeyNavigationModifier: ViewModifier {
    var isFocused: FocusState<Bool>.Binding
    let contextID: String
    let onArrow: (KeyEquivalent) -> KeyPress.Result
    @StateObject private var repeater = PDFArrowKeyRepeater()

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused(isFocused)
            .onKeyPress(
                keys: [.upArrow, .downArrow, .leftArrow, .rightArrow],
                phases: [.down, .repeat, .up]
            ) { press in
                guard let code = Self.keyCode(for: press.key) else { return .ignored }
                if press.phase == .up {
                    repeater.handleKeyUp(keyCode: code)
                    return .ignored
                }
                let focus = isFocused
                let navigate = onArrow
                let key = press.key
                let handled = repeater.handleKeyDown(
                    keyCode: code,
                    modifiers: Self.nativeModifiers(press.modifiers),
                    isRepeat: press.phase == .repeat,
                    window: NSApp.keyWindow
                ) {
                    guard focus.wrappedValue else { return false }
                    return navigate(key) == .handled
                }
                return handled ? .handled : .ignored
            }
            .onChange(of: isFocused.wrappedValue) { _, focused in
                if !focused { repeater.stop() }
            }
            .onChange(of: contextID) { _, _ in repeater.stop() }
            .onDisappear { repeater.stop() }
    }

    static func keyCode(for key: KeyEquivalent) -> UInt16? {
        switch key {
        case .leftArrow: 123
        case .rightArrow: 124
        case .downArrow: 125
        case .upArrow: 126
        default: nil
        }
    }

    static func nativeModifiers(_ modifiers: EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}

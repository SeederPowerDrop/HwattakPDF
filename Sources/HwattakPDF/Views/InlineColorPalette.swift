// SPDX-License-Identifier: MPL-2.0

import AppKit
import SwiftUI

/// Keeps quick colors and arbitrary RGB colors inside the invoking popover.
/// A native ColorPicker opens the shared, independently positioned color panel.
struct InlineColorPalette: View {
    @Binding var selection: NSColor
    let title: String

    @State private var hexInput = ""
    @FocusState private var isHexFocused: Bool

    private static let swatches = [
        "FFD60A", "FF9500", "FF3B30", "FF2D55", "AF52DE", "007AFF",
        "32ADE6", "30B0C7", "34C759", "A2845E", "000000", "FFFFFF"
    ]

    private var rgbColor: NSColor {
        selection.usingColorSpace(.sRGB) ?? .black
    }

    private var currentHex: String { Self.hexString(for: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.callout.weight(.medium))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 6), spacing: 9) {
                ForEach(Self.swatches, id: \.self) { hex in
                    swatch(hex)
                }
            }

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: selection))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                    }
                    .frame(width: 28, height: 24)
                    .accessibilityHidden(true)

                Text("HEX")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("#RRGGBB", text: $hexInput)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($isHexFocused)
                    .onSubmit(commitHexInput)
                    .onChange(of: isHexFocused) { _, focused in
                        if !focused { commitHexInput() }
                    }
                    .accessibilityLabel("\(title), HEX")
                    .accessibilityIdentifier("inline-color-hex")
            }

            DisclosureGroup("RGB") {
                VStack(spacing: 7) {
                    colorChannel("R", index: 0, tint: .red)
                    colorChannel("G", index: 1, tint: .green)
                    colorChannel("B", index: 2, tint: .blue)
                }
                .padding(.top, 7)
            }
            .font(.caption)
        }
        .onAppear { hexInput = currentHex }
        .onChange(of: currentHex) { _, value in hexInput = value }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("inline-color-palette")
    }

    private func swatch(_ hex: String) -> some View {
        let color = Self.color(forHex: hex) ?? .black
        let isSelected = currentHex == "#\(hex)"
        let luminance = color.redComponent * 0.2126
            + color.greenComponent * 0.7152
            + color.blueComponent * 0.0722

        return Button {
            isHexFocused = false
            selection = color
            hexInput = currentHex
        } label: {
            Circle()
                .fill(Color(nsColor: color))
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.25), lineWidth: 1)
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(luminance > 0.5 ? Color.black : Color.white)
                    }
                }
                .frame(width: 28, height: 28)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("#\(hex)")
        .accessibilityLabel("\(title), #\(hex)")
        .accessibilityValue(isSelected ? L10n.string("선택됨") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("inline-color-\(hex)")
    }

    private func colorChannel(_ name: String, index: Int, tint: Color) -> some View {
        let value = channelBinding(index)
        return HStack(spacing: 7) {
            Text(name)
                .font(.caption.monospaced())
                .frame(width: 12, alignment: .leading)
            Slider(value: value, in: 0...255, step: 1)
                .tint(tint)
                .accessibilityLabel("\(title), \(name)")
                .accessibilityValue("\(Int(value.wrappedValue.rounded()))")
            Text("\(Int(value.wrappedValue.rounded()))")
                .font(.caption.monospacedDigit())
                .frame(width: 25, alignment: .trailing)
        }
    }

    private func channelBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: {
                let components = [rgbColor.redComponent, rgbColor.greenComponent, rgbColor.blueComponent]
                return Double(components[index] * 255)
            },
            set: { value in
                var components = [rgbColor.redComponent, rgbColor.greenComponent, rgbColor.blueComponent]
                components[index] = CGFloat(value / 255)
                selection = NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: 1)
            }
        )
    }

    private func commitHexInput() {
        if let color = Self.color(forHex: hexInput) {
            selection = color
        }
        hexInput = currentHex
    }

    static func color(forHex input: String) -> NSColor? {
        var hex = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 3 || hex.count == 6,
              hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0) })
        else { return nil }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }

    static func hexString(for color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
            .map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", components[0], components[1], components[2])
    }
}

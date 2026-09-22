// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Produces a compact, human-readable Unicode fallback for a LaTeX expression.
///
/// This is not a full TeX engine. It covers the notation commonly returned by
/// PDF-assistant providers so formulas remain understandable when a dedicated
/// math renderer is unavailable. The original LaTeX remains available on
/// `AIAssistantMarkupSegment` and is never mutated by this formatter.
enum AIAssistantMathFormatter {
    static func format(_ latex: String) -> String {
        var parser = Parser(latex)
        return normalizeSpacing(parser.parse())
    }

    private static func normalizeSpacing(_ value: String) -> String {
        var result = ""
        var pendingSpace = false

        for character in value {
            if character.isNewline {
                while result.last == " " {
                    result.removeLast()
                }
                if result.last != "\n" {
                    result.append("\n")
                }
                pendingSpace = false
                continue
            }

            if character.isWhitespace {
                pendingSpace = !result.isEmpty && result.last != "\n"
                continue
            }

            if isBinaryOperator(character) {
                while result.last == " " {
                    result.removeLast()
                }
                if !result.isEmpty, result.last != "\n", result.last != "(" {
                    result.append(" ")
                }
                result.append(character == "-" ? "−" : character)
                result.append(" ")
                pendingSpace = false
                continue
            }

            if pendingSpace,
               result.last != "(",
               result.last != "[",
               result.last != "{",
               result.last != " " {
                result.append(" ")
            }
            pendingSpace = false

            if isClosingPunctuation(character) {
                while result.last == " " {
                    result.removeLast()
                }
            }
            result.append(character)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isBinaryOperator(_ character: Character) -> Bool {
        [
            "=", "+", "-", "×", "·", "±", "≤", "≥", "≠", "≈",
            "≡", "∝", "∼", "≃", "≅", "⊂", "⊆", "⊃", "⊇",
            "∈", "∉", "∋", "→", "←", "↔", "⇒", "⇐", "⇔",
            "↦", "∧", "∨", "∪", "∩"
        ].contains(character)
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        [")", "]", "}", ",", ";", ":"].contains(character)
    }

    private struct Parser {
        /// Commands can take commands as unbraced arguments (`\sqrt\sqrt…`).
        /// Keep that descent bounded independently of brace nesting so hostile or
        /// malformed provider output cannot grow the native call stack with the
        /// length of the response.
        private static let maximumNestingDepth = 32

        private static let namedSymbols: [String: String] = [
            "times": "×",
            "cdot": "·",
            "pm": "±",
            "le": "≤",
            "leq": "≤",
            "ge": "≥",
            "geq": "≥",
            "neq": "≠",
            "ne": "≠",
            "approx": "≈",
            "equiv": "≡",
            "propto": "∝",
            "sim": "∼",
            "simeq": "≃",
            "cong": "≅",
            "infty": "∞",
            "sum": "∑",
            "prod": "∏",
            "coprod": "∐",
            "int": "∫",
            "iint": "∬",
            "iiint": "∭",
            "oint": "∮",
            "partial": "∂",
            "nabla": "∇",
            "forall": "∀",
            "exists": "∃",
            "neg": "¬",
            "land": "∧",
            "wedge": "∧",
            "lor": "∨",
            "vee": "∨",
            "cup": "∪",
            "cap": "∩",
            "in": "∈",
            "notin": "∉",
            "ni": "∋",
            "subset": "⊂",
            "subseteq": "⊆",
            "supset": "⊃",
            "supseteq": "⊇",
            "to": "→",
            "rightarrow": "→",
            "leftarrow": "←",
            "leftrightarrow": "↔",
            "Rightarrow": "⇒",
            "Leftarrow": "⇐",
            "Leftrightarrow": "⇔",
            "mapsto": "↦",
            "implies": "⇒",
            "iff": "⇔",
            "langle": "⟨",
            "rangle": "⟩",
            "lceil": "⌈",
            "rceil": "⌉",
            "lfloor": "⌊",
            "rfloor": "⌋"
        ]

        private static let greekLetters: [String: String] = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
            "epsilon": "ε", "varepsilon": "ϵ", "zeta": "ζ", "eta": "η",
            "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
            "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
            "omicron": "ο", "pi": "π", "varpi": "ϖ", "rho": "ρ",
            "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ",
            "upsilon": "υ", "phi": "φ", "varphi": "ϕ", "chi": "χ",
            "psi": "ψ", "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
            "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ",
            "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω"
        ]

        private static let superscripts: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ",
            "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ",
            "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ",
            "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
            "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
            "A": "ᴬ", "B": "ᴮ", "D": "ᴰ", "E": "ᴱ", "G": "ᴳ",
            "H": "ᴴ", "I": "ᴵ", "J": "ᴶ", "K": "ᴷ", "L": "ᴸ",
            "M": "ᴹ", "N": "ᴺ", "O": "ᴼ", "P": "ᴾ", "R": "ᴿ",
            "T": "ᵀ", "U": "ᵁ", "V": "ⱽ", "W": "ᵂ"
        ]

        private static let subscripts: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
            "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
            "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
            "v": "ᵥ", "x": "ₓ", "y": "ᵧ", "β": "ᵦ", "γ": "ᵧ",
            "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ"
        ]

        private let characters: [Character]
        private var index = 0
        private var environments: [Environment] = []

        private struct Environment {
            let name: String
            let usesColumns: Bool
        }

        init(_ source: String) {
            characters = Array(source)
        }

        mutating func parse() -> String {
            parseSequence(until: nil, depth: 0)
        }

        private mutating func parseSequence(
            until closingCharacter: Character?,
            depth: Int
        ) -> String {
            var result = ""

            while index < characters.count {
                let character = characters[index]
                if let closingCharacter, character == closingCharacter {
                    index += 1
                    break
                }

                switch character {
                case "\\":
                    result += parseCommand(depth: depth)
                case "^":
                    index += 1
                    while result.last?.isWhitespace == true {
                        result.removeLast()
                    }
                    result += renderScript(
                        parseArgument(depth: depth + 1),
                        using: Self.superscripts,
                        fallbackMarker: "^"
                    )
                case "_":
                    index += 1
                    while result.last?.isWhitespace == true {
                        result.removeLast()
                    }
                    result += renderScript(
                        parseArgument(depth: depth + 1),
                        using: Self.subscripts,
                        fallbackMarker: "_"
                    )
                case "{":
                    index += 1
                    if depth < Self.maximumNestingDepth {
                        result += parseSequence(until: "}", depth: depth + 1)
                    } else {
                        result += readBalancedGroupLiterally()
                    }
                case "}":
                    // An unmatched closing brace is content, not a reason to
                    // discard the remainder of an AI response.
                    result.append(character)
                    index += 1
                case "~":
                    result.append(" ")
                    index += 1
                case "&":
                    // `&` is an alignment token, not visible equation text.
                    // A light column divider keeps a matrix understandable in
                    // plain text while aligned equations only need whitespace.
                    result += environments.last?.usesColumns == true ? " │ " : " "
                    index += 1
                default:
                    result.append(character)
                    index += 1
                }
            }
            return result
        }

        private mutating func parseCommand(depth: Int) -> String {
            index += 1
            guard index < characters.count else { return "" }

            if characters[index] == "\\" {
                index += 1
                return "\n"
            }

            guard characters[index].isLetter else {
                let escapedCharacter = characters[index]
                index += 1
                switch escapedCharacter {
                case ",", ";", ":", " ": return " "
                case "!": return ""
                case "|": return "‖"
                default: return String(escapedCharacter)
                }
            }

            let command = readCommandName()
            if let greek = Self.greekLetters[command] {
                return greek
            }
            if let symbol = Self.namedSymbols[command] {
                return symbol
            }

            // This guard is deliberately after leaf symbols and before every
            // branch that may parse another command argument. The current
            // command has already been consumed, so parsing always advances
            // even after the descent budget is exhausted.
            guard depth < Self.maximumNestingDepth else {
                return depthLimitedFallback(for: command)
            }

            switch command {
            case "frac", "dfrac", "tfrac":
                let numerator = parseArgument(depth: depth + 1)
                let denominator = parseArgument(depth: depth + 1)
                guard !numerator.isEmpty || !denominator.isEmpty else {
                    return "frac"
                }
                return fraction(numerator: numerator, denominator: denominator)

            case "sqrt":
                let rootIndex = parseOptionalBracketArgument(depth: depth + 1)
                let radicand = parseArgument(depth: depth + 1)
                return squareRoot(radicand: radicand, rootIndex: rootIndex)

            case "vec", "overrightarrow":
                return decorate(
                    parseArgument(depth: depth + 1),
                    combiningMark: "\u{20D7}",
                    emptyFallback: "⃗?"
                )

            case "hat", "widehat":
                return decorate(
                    parseArgument(depth: depth + 1),
                    combiningMark: "\u{0302}",
                    emptyFallback: "^?"
                )

            case "bar", "overline":
                return decorate(
                    parseArgument(depth: depth + 1),
                    combiningMark: "\u{0304}",
                    emptyFallback: "¯?"
                )

            case "begin":
                let name = parseArgument(depth: depth + 1)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let environment = Environment(
                    name: name,
                    usesColumns: isMatrixEnvironment(name)
                )
                environments.append(environment)
                if name == "array" {
                    // The mandatory array column specification is layout, not
                    // equation content (for example `{cc}`).
                    _ = parseArgument(depth: depth + 1)
                }
                return openingDelimiter(for: name)

            case "end":
                let name = parseArgument(depth: depth + 1)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if environments.last?.name == name {
                    environments.removeLast()
                } else if !environments.isEmpty {
                    // Recover locally from malformed nesting in model output.
                    environments.removeLast()
                }
                return closingDelimiter(for: name)

            case "left", "right":
                return ""

            case "limits", "nolimits", "displaystyle", "textstyle",
                 "scriptstyle", "scriptscriptstyle":
                return ""

            case "quad":
                return "\u{2003}"
            case "qquad":
                return "\u{2003}\u{2003}"

            case "sin", "cos", "tan", "arcsin", "arccos", "arctan",
                 "sinh", "cosh", "tanh", "log", "ln", "exp", "lim",
                 "sup", "inf", "min", "max", "det", "gcd", "argmin",
                 "argmax":
                return " \(command) "

            case "linebreak", "newline", "cr":
                return "\n"

            case "text", "textrm", "textnormal", "mathrm", "mathbf",
                 "mathit", "mathsf", "mathtt", "operatorname":
                return parseArgument(depth: depth + 1)

            default:
                let argument = peek == "{" ? parseArgument(depth: depth + 1) : ""
                return argument.isEmpty ? command : "\(command)(\(argument))"
            }
        }

        private func depthLimitedFallback(for command: String) -> String {
            switch command {
            case "frac", "dfrac", "tfrac": return "?⁄?"
            case "sqrt": return "√?"
            case "vec", "overrightarrow": return "?⃗"
            case "hat", "widehat": return "^?"
            case "bar", "overline": return "¯?"
            case "left", "right", "limits", "nolimits", "displaystyle",
                 "textstyle", "scriptstyle", "scriptscriptstyle", "begin", "end":
                return ""
            case "sin", "cos", "tan", "arcsin", "arccos", "arctan",
                 "sinh", "cosh", "tanh", "log", "ln", "exp", "lim",
                 "sup", "inf", "min", "max", "det", "gcd", "argmin",
                 "argmax":
                return " \(command) "
            default:
                return command
            }
        }

        private mutating func parseArgument(depth: Int) -> String {
            skipWhitespace()
            guard index < characters.count else { return "" }

            if characters[index] == "{" {
                index += 1
                if depth < Self.maximumNestingDepth {
                    return parseSequence(until: "}", depth: depth + 1)
                }
                return readBalancedGroupLiterally()
            }

            if characters[index] == "\\" {
                return parseCommand(depth: depth)
            }

            let atom = characters[index]
            index += 1
            return String(atom)
        }

        private mutating func parseOptionalBracketArgument(depth: Int) -> String? {
            skipWhitespace()
            guard peek == "[" else { return nil }
            index += 1
            return parseSequence(until: "]", depth: depth)
        }

        private mutating func readCommandName() -> String {
            let start = index
            while index < characters.count, characters[index].isLetter {
                index += 1
            }
            return String(characters[start ..< index])
        }

        private mutating func skipWhitespace() {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
        }

        private mutating func readBalancedGroupLiterally() -> String {
            let start = index
            var nesting = 1
            while index < characters.count, nesting > 0 {
                switch characters[index] {
                case "{": nesting += 1
                case "}": nesting -= 1
                default: break
                }
                index += 1
            }
            let end = nesting == 0 ? index - 1 : index
            return String(characters[start ..< end])
        }

        private func renderScript(
            _ value: String,
            using mapping: [Character: Character],
            fallbackMarker: Character
        ) -> String {
            guard !value.isEmpty else { return String(fallbackMarker) }
            var rendered = ""
            for character in value {
                guard let replacement = mapping[character] else {
                    return "\(fallbackMarker)(\(value))"
                }
                rendered.append(replacement)
            }
            return rendered
        }

        private func fraction(numerator: String, denominator: String) -> String {
            let top = wrapFractionPartIfNeeded(numerator)
            let bottom = wrapFractionPartIfNeeded(denominator)
            return "\(top)⁄\(bottom)"
        }

        private func wrapFractionPartIfNeeded(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "?" }
            let requiresGrouping = trimmed.contains { character in
                character.isWhitespace
                    || ["+", "-", "=", "×", "·", "±", "≤", "≥", "≠", "≈", "⁄"].contains(character)
            }
            return requiresGrouping ? "(\(trimmed))" : trimmed
        }

        private func squareRoot(radicand: String, rootIndex: String?) -> String {
            let trimmed = radicand.trimmingCharacters(in: .whitespacesAndNewlines)
            let grouped = wrapRadicandIfNeeded(trimmed)
            guard let rootIndex, !rootIndex.isEmpty else {
                return "√\(grouped)"
            }
            if rootIndex == "3" { return "∛\(grouped)" }
            if rootIndex == "4" { return "∜\(grouped)" }
            let renderedIndex = renderScript(
                rootIndex,
                using: Self.superscripts,
                fallbackMarker: "^"
            )
            return "\(renderedIndex)√\(grouped)"
        }

        private func decorate(
            _ value: String,
            combiningMark: Character,
            emptyFallback: String
        ) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return emptyFallback }
            let grouped = trimmed.count == 1 ? trimmed : "(\(trimmed))"
            return grouped + String(combiningMark)
        }

        private func isMatrixEnvironment(_ name: String) -> Bool {
            [
                "matrix", "smallmatrix", "pmatrix", "bmatrix", "Bmatrix",
                "vmatrix", "Vmatrix", "array"
            ].contains(name)
        }

        private func openingDelimiter(for environment: String) -> String {
            switch environment {
            case "matrix", "smallmatrix", "bmatrix", "array": return "["
            case "pmatrix": return "("
            case "Bmatrix", "cases": return "{"
            case "vmatrix": return "|"
            case "Vmatrix": return "‖"
            default: return ""
            }
        }

        private func closingDelimiter(for environment: String) -> String {
            switch environment {
            case "matrix", "smallmatrix", "bmatrix", "array": return "]"
            case "pmatrix": return ")"
            case "Bmatrix": return "}"
            case "vmatrix": return "|"
            case "Vmatrix": return "‖"
            default: return ""
            }
        }

        private func wrapRadicandIfNeeded(_ value: String) -> String {
            guard !value.isEmpty else { return "?" }
            let isSimple = value.allSatisfy { character in
                character.isLetter || character.isNumber || character == "."
                    || Self.superscripts.values.contains(character)
                    || Self.subscripts.values.contains(character)
            }
            return isSimple ? value : "(\(value))"
        }

        private var peek: Character? {
            index < characters.count ? characters[index] : nil
        }
    }
}

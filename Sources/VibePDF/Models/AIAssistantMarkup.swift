// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A lossless, presentation-neutral representation of an assistant response.
///
/// Markdown remains untouched so the view layer can hand it to a Markdown
/// renderer. Math delimiters are separated from their expressions so a native
/// or WebKit-based LaTeX renderer can display them without showing raw markup.
struct AIAssistantMarkupDocument: Equatable, Sendable {
    let segments: [AIAssistantMarkupSegment]

    init(source: String) {
        segments = AIAssistantMarkupParser.parseSegments(source)
    }

    /// The exact provider response, including the original math delimiters.
    var source: String {
        segments.map(\.source).joined()
    }

    var containsMath: Bool {
        segments.contains { $0.isMath }
    }
}

enum AIAssistantMarkupSegment: Equatable, Sendable {
    case markdown(String)
    case inlineMath(expression: String, source: String)
    case blockMath(expression: String, source: String)

    var source: String {
        switch self {
        case let .markdown(source),
             let .inlineMath(_, source),
             let .blockMath(_, source):
            source
        }
    }

    var mathExpression: String? {
        switch self {
        case .markdown:
            nil
        case let .inlineMath(expression, _),
             let .blockMath(expression, _):
            expression
        }
    }

    var isMath: Bool {
        mathExpression != nil
    }

    var isBlockMath: Bool {
        if case .blockMath = self {
            return true
        }
        return false
    }
}

enum AIAssistantDisplayBlock: Equatable, Sendable {
    case markdown(String)
    case displayMath(String)
}

/// Combines inline math back into the surrounding Markdown while keeping
/// display equations as dedicated blocks. The view can therefore preserve
/// emphasis, headings, and lists without exposing raw TeX commands.
enum AIAssistantDisplayFormatter {
    static func blocks(from source: String) -> [AIAssistantDisplayBlock] {
        let document = AIAssistantMarkupParser.parse(source)
        var blocks: [AIAssistantDisplayBlock] = []
        var markdown = ""

        func flushMarkdown() {
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                markdown = ""
                return
            }
            blocks.append(.markdown(markdown))
            markdown = ""
        }

        for segment in document.segments {
            switch segment {
            case let .markdown(source):
                markdown += source
            case let .inlineMath(expression, _):
                markdown += escapeForMarkdown(AIAssistantMathFormatter.format(expression))
            case let .blockMath(expression, _):
                flushMarkdown()
                let formatted = AIAssistantMathFormatter.format(expression)
                if !formatted.isEmpty {
                    blocks.append(.displayMath(formatted))
                }
            }
        }
        flushMarkdown()

        if blocks.isEmpty, !source.isEmpty {
            return [.markdown(source)]
        }
        return blocks
    }

    private static func escapeForMarkdown(_ source: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(source.count)
        for character in source {
            if ["\\", "`", "*", "_", "[", "]"].contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}

enum AIAssistantMarkdownFormatter {
    static func attributedString(from source: String) -> AttributedString {
        guard var attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full)
        ) else {
            return AttributedString(source)
        }

        // Rendering Markdown must not turn provider-controlled file, custom
        // scheme, localhost, or private-network links into clickable targets.
        // The same bounded public-web policy used by citations applies here.
        var unsafeLinkRanges: [Range<AttributedString.Index>] = []
        for run in attributed.runs {
            if let link = run.link,
               !AIEndpointPolicy.isValidExternalWebURL(link) {
                unsafeLinkRanges.append(run.range)
            }
        }
        for range in unsafeLinkRanges {
            attributed[range].link = nil
        }
        return attributed
    }
}

/// Splits Markdown and common TeX math delimiters without interpreting either
/// language. The parser is deliberately conservative: malformed or ambiguous
/// delimiters stay in the Markdown segment instead of swallowing surrounding
/// text.
enum AIAssistantMarkupParser {
    static func parse(_ source: String) -> AIAssistantMarkupDocument {
        AIAssistantMarkupDocument(source: source)
    }

    fileprivate static func parseSegments(_ source: String) -> [AIAssistantMarkupSegment] {
        guard !source.isEmpty else { return [] }

        let characters = Array(source)
        let escapedCharacters = escapedCharacterMap(in: characters)
        var segments: [AIAssistantMarkupSegment] = []
        var markdownStart = 0
        var cursor = 0
        var exhaustedClosers: Set<DelimiterKind> = []
        var lineBoundedExhaustion: [DelimiterKind: Int] = [:]

        while cursor < characters.count {
            if let codeEnd = endOfMarkdownCodeSpan(
                in: characters,
                escapedCharacters: escapedCharacters,
                at: cursor
            ) {
                cursor = codeEnd
                continue
            }

            guard let delimiter = openingDelimiter(
                in: characters,
                at: cursor,
                escapedCharacters: escapedCharacters,
                exhaustedClosers: exhaustedClosers,
                lineBoundedExhaustion: lineBoundedExhaustion
            ) else {
                cursor += 1
                continue
            }

            guard let closingStart = closingDelimiterStart(
                for: delimiter,
                in: characters,
                escapedCharacters: escapedCharacters,
                after: cursor + delimiter.opening.count
            ) else {
                // If this closer does not exist anywhere in the remainder, a
                // later opener of the same kind cannot succeed either. Caching
                // that fact keeps malformed input linear rather than quadratic.
                if delimiter.kind.isLineBounded {
                    lineBoundedExhaustion[delimiter.kind] = nextLineStart(
                        in: characters,
                        after: cursor
                    )
                } else {
                    exhaustedClosers.insert(delimiter.kind)
                }
                cursor += delimiter.opening.count
                continue
            }

            let contentStart = cursor + delimiter.opening.count
            let expression = String(characters[contentStart ..< closingStart])
            guard !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                cursor = closingStart + delimiter.closing.count
                continue
            }

            appendMarkdown(
                String(characters[markdownStart ..< cursor]),
                to: &segments
            )

            let segmentEnd = closingStart + delimiter.closing.count
            let originalSource = String(characters[cursor ..< segmentEnd])
            switch delimiter.kind {
            case .backslashParentheses, .singleDollar:
                segments.append(
                    .inlineMath(expression: expression, source: originalSource)
                )
            case .backslashBrackets, .doubleDollar:
                segments.append(
                    .blockMath(expression: expression, source: originalSource)
                )
            }

            cursor = segmentEnd
            markdownStart = segmentEnd
        }

        appendMarkdown(
            String(characters[markdownStart ..< characters.count]),
            to: &segments
        )
        return segments
    }

    private enum DelimiterKind: Hashable {
        case backslashParentheses
        case backslashBrackets
        case singleDollar
        case doubleDollar

        var isLineBounded: Bool {
            self == .backslashParentheses || self == .singleDollar
        }
    }

    private struct Delimiter {
        let kind: DelimiterKind
        let opening: [Character]
        let closing: [Character]
    }

    private static func openingDelimiter(
        in characters: [Character],
        at index: Int,
        escapedCharacters: [Bool],
        exhaustedClosers: Set<DelimiterKind>,
        lineBoundedExhaustion: [DelimiterKind: Int]
    ) -> Delimiter? {
        if characters[index] == "\\" {
            guard !escapedCharacters[index] else { return nil }

            if matches(["\\", "["], in: characters, at: index),
               !exhaustedClosers.contains(.backslashBrackets) {
                return Delimiter(
                    kind: .backslashBrackets,
                    opening: ["\\", "["],
                    closing: ["\\", "]"]
                )
            }

            if matches(["\\", "("], in: characters, at: index),
               index >= lineBoundedExhaustion[.backslashParentheses, default: 0],
               !exhaustedClosers.contains(.backslashParentheses) {
                return Delimiter(
                    kind: .backslashParentheses,
                    opening: ["\\", "("],
                    closing: ["\\", ")"]
                )
            }
            return nil
        }

        guard characters[index] == "$", !escapedCharacters[index] else {
            return nil
        }

        if matches(["$", "$"], in: characters, at: index),
           !exhaustedClosers.contains(.doubleDollar) {
            return Delimiter(
                kind: .doubleDollar,
                opening: ["$", "$"],
                closing: ["$", "$"]
            )
        }

        guard index >= lineBoundedExhaustion[.singleDollar, default: 0],
              !exhaustedClosers.contains(.singleDollar),
              canOpenSingleDollar(in: characters, at: index) else {
            return nil
        }
        return Delimiter(
            kind: .singleDollar,
            opening: ["$"],
            closing: ["$"]
        )
    }

    private static func closingDelimiterStart(
        for delimiter: Delimiter,
        in characters: [Character],
        escapedCharacters: [Bool],
        after start: Int
    ) -> Int? {
        var cursor = start
        while cursor < characters.count {
            if delimiter.kind.isLineBounded,
               characters[cursor].isNewline {
                return nil
            }

            if matches(delimiter.closing, in: characters, at: cursor),
               !escapedCharacters[cursor] {
                if delimiter.kind != .singleDollar
                    || canCloseSingleDollar(in: characters, at: cursor) {
                    return cursor
                }
            }
            cursor += 1
        }
        return nil
    }

    private static func canOpenSingleDollar(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        let next = index + 1
        guard next < characters.count,
              characters[next] != "$",
              !characters[next].isWhitespace else {
            return false
        }

        // A dollar sign between digits is overwhelmingly likely to be a price
        // or amount, not an inline equation delimiter.
        if index > 0,
           characters[index - 1].isNumber,
           characters[next].isNumber {
            return false
        }
        return true
    }

    private static func canCloseSingleDollar(
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard index > 0,
              characters[index - 1] != "$",
              !characters[index - 1].isWhitespace else {
            return false
        }

        let next = index + 1
        if next < characters.count, characters[next] == "$" {
            return false
        }
        return true
    }

    /// Returns the first character after a Markdown code span/fence beginning
    /// at `index`. Keeping code opaque prevents `$PATH` and TeX examples from
    /// unexpectedly turning into live math.
    private static func endOfMarkdownCodeSpan(
        in characters: [Character],
        escapedCharacters: [Bool],
        at index: Int
    ) -> Int? {
        let marker = characters[index]
        guard (marker == "`" || marker == "~"),
              !escapedCharacters[index] else {
            return nil
        }

        let runLength = countRun(of: marker, in: characters, at: index)
        if marker == "~" {
            guard runLength >= 3, isFenceLinePosition(characters, at: index) else {
                return nil
            }
        }

        let isFence = runLength >= 3 && isFenceLinePosition(characters, at: index)
        var cursor = index + runLength
        while cursor < characters.count {
            guard characters[cursor] == marker else {
                cursor += 1
                continue
            }

            let closingRunLength = countRun(of: marker, in: characters, at: cursor)
            let isValidClosure = isFence
                ? closingRunLength >= runLength && isFenceLinePosition(characters, at: cursor)
                : closingRunLength == runLength
            if isValidClosure {
                return cursor + closingRunLength
            }
            cursor += closingRunLength
        }

        // Conservatively treat an unmatched code marker as code through EOF.
        return characters.count
    }

    private static func isFenceLinePosition(
        _ characters: [Character],
        at index: Int
    ) -> Bool {
        var cursor = index
        var spaces = 0
        while cursor > 0, characters[cursor - 1] != "\n" {
            cursor -= 1
            guard characters[cursor] == " " else { return false }
            spaces += 1
            if spaces > 3 { return false }
        }
        return true
    }

    private static func countRun(
        of character: Character,
        in characters: [Character],
        at index: Int
    ) -> Int {
        var cursor = index
        while cursor < characters.count, characters[cursor] == character {
            cursor += 1
        }
        return cursor - index
    }

    private static func nextLineStart(
        in characters: [Character],
        after index: Int
    ) -> Int {
        var cursor = index
        while cursor < characters.count {
            if characters[cursor].isNewline {
                return cursor + 1
            }
            cursor += 1
        }
        return characters.count
    }

    private static func matches(
        _ token: [Character],
        in characters: [Character],
        at index: Int
    ) -> Bool {
        guard index + token.count <= characters.count else { return false }
        for offset in token.indices where characters[index + offset] != token[offset] {
            return false
        }
        return true
    }

    /// Records whether each character is escaped by the immediately preceding
    /// run of backslashes. Computing the parity once keeps every later lookup
    /// constant-time, including adversarial input made of one very long run.
    private static func escapedCharacterMap(in characters: [Character]) -> [Bool] {
        var result = Array(repeating: false, count: characters.count)
        var nextCharacterIsEscaped = false

        for index in characters.indices {
            result[index] = nextCharacterIsEscaped
            if characters[index] == "\\" {
                nextCharacterIsEscaped.toggle()
            } else {
                nextCharacterIsEscaped = false
            }
        }
        return result
    }

    private static func appendMarkdown(
        _ source: String,
        to segments: inout [AIAssistantMarkupSegment]
    ) {
        guard !source.isEmpty else { return }
        if case let .markdown(previous)? = segments.last {
            segments[segments.count - 1] = .markdown(previous + source)
        } else {
            segments.append(.markdown(source))
        }
    }
}

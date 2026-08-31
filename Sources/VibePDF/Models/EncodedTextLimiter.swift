// SPDX-License-Identifier: MPL-2.0

import Foundation

/// A three-dimensional safety budget for text that can come from a PDF,
/// pasteboard, user prompt, or remote AI provider.
///
/// `String.count` measures extended grapheme clusters (roughly what a person
/// sees as characters). That is the right number for a friendly UI counter, but
/// it is not a memory or transmission limit: one grapheme can contain an
/// arbitrary number of combining Unicode scalars. Every externally sourced text
/// value therefore needs encoded-size ceilings as well as a grapheme ceiling.
struct EncodedTextBudget: Equatable, Sendable {
    /// These ratios preserve ordinary Korean, English, Japanese, Chinese,
    /// Arabic, and common multi-scalar emoji (including family/skin-tone ZWJ
    /// sequences) without allowing a pathological grapheme to grow forever.
    static let defaultUTF8BytesPerCharacter = 32
    static let defaultUTF16CodeUnitsPerCharacter = 16

    let maximumCharacters: Int
    let maximumUTF8Bytes: Int
    let maximumUTF16CodeUnits: Int

    init(
        maximumCharacters: Int,
        maximumUTF8Bytes: Int? = nil,
        maximumUTF16CodeUnits: Int? = nil
    ) {
        let characters = max(0, maximumCharacters)
        self.maximumCharacters = characters
        self.maximumUTF8Bytes = max(
            0,
            maximumUTF8Bytes
                ?? Self.saturatingProduct(
                    characters,
                    Self.defaultUTF8BytesPerCharacter
                )
        )
        self.maximumUTF16CodeUnits = max(
            0,
            maximumUTF16CodeUnits
                ?? Self.saturatingProduct(
                    characters,
                    Self.defaultUTF16CodeUnitsPerCharacter
                )
        )
    }

    /// Returns the unused portion of this budget after a bounded string has
    /// already been accepted. The counts are cheap because accepted text is
    /// itself bounded.
    func remaining(after text: String) -> EncodedTextBudget {
        EncodedTextBudget(
            maximumCharacters: max(0, maximumCharacters - text.count),
            maximumUTF8Bytes: max(0, maximumUTF8Bytes - text.utf8.count),
            maximumUTF16CodeUnits: max(
                0,
                maximumUTF16CodeUnits - text.utf16.count
            )
        )
    }

    private static func saturatingProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : value
    }
}

struct EncodedTextLimitResult: Equatable, Sendable {
    let text: String
    let wasTruncated: Bool

    var characterCount: Int { text.count }
    var utf8ByteCount: Int { text.utf8.count }
    var utf16CodeUnitCount: Int { text.utf16.count }
}

/// Limits encoded representations *before* Swift segments grapheme clusters.
///
/// The ordering is important. Calling `prefix(_:)` on `String` first would ask
/// Swift to find grapheme boundaries and could traverse a megabyte-sized single
/// character. UTF-8 and UTF-16 views have bounded code-unit traversal instead.
enum EncodedTextLimiter {
    static func limit(
        _ value: String,
        budget: EncodedTextBudget
    ) -> EncodedTextLimitResult {
        guard !value.isEmpty else {
            return EncodedTextLimitResult(text: "", wasTruncated: false)
        }
        guard
            budget.maximumCharacters > 0,
            budget.maximumUTF8Bytes > 0,
            budget.maximumUTF16CodeUnits > 0
        else {
            return EncodedTextLimitResult(text: "", wasTruncated: true)
        }

        // Step 1: cap bytes without creating invalid UTF-8. A Unicode scalar is
        // at most four bytes, so at most three bytes need to be backed off when
        // the byte ceiling lands in the middle of a scalar.
        let utf8Probe = value.utf8.prefix(
            incrementedProbeLimit(budget.maximumUTF8Bytes)
        )
        let didTruncateUTF8 = utf8Probe.count > budget.maximumUTF8Bytes
        let utf8Bounded: String
        if didTruncateUTF8 {
            var bytes = Array(utf8Probe.prefix(budget.maximumUTF8Bytes))
            while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
                bytes.removeLast()
            }
            utf8Bounded = String(decoding: bytes, as: UTF8.self)
        } else {
            utf8Bounded = value
        }

        // Step 2: cap UTF-16 before grapheme work as well. If the boundary falls
        // after a high surrogate, remove it so decoding cannot manufacture a
        // replacement character from half of a supplementary-plane scalar.
        let utf16Probe = utf8Bounded.utf16.prefix(
            incrementedProbeLimit(budget.maximumUTF16CodeUnits)
        )
        let didTruncateUTF16 = utf16Probe.count
            > budget.maximumUTF16CodeUnits
        let encodedBounded: String
        if didTruncateUTF16 {
            var codeUnits = Array(
                utf16Probe.prefix(budget.maximumUTF16CodeUnits)
            )
            if
                let last = codeUnits.last,
                (0xD800...0xDBFF).contains(last)
            {
                codeUnits.removeLast()
            }
            encodedBounded = String(decoding: codeUnits, as: UTF16.self)
        } else {
            encodedBounded = utf8Bounded
        }

        // Step 3: with encoded memory now finite, apply the user-facing
        // grapheme limit without risking an unbounded segmentation pass.
        let characterPrefix = encodedBounded.prefix(budget.maximumCharacters)
        let didTruncateCharacters = characterPrefix.endIndex
            != encodedBounded.endIndex
        let finalText = didTruncateCharacters
            ? String(characterPrefix)
            : encodedBounded
        return EncodedTextLimitResult(
            text: finalText,
            wasTruncated: didTruncateUTF8
                || didTruncateUTF16
                || didTruncateCharacters
        )
    }

    /// Joins fragments without first constructing an unbounded intermediate
    /// string. This is used for PDF line selections and consent prompt sections.
    static func joined<S: Sequence>(
        fragments: S,
        separator: String,
        budget: EncodedTextBudget
    ) -> EncodedTextLimitResult where S.Element == String {
        var accumulator = EncodedTextAccumulator(budget: budget)
        for fragment in fragments {
            if !accumulator.append(fragment, separator: separator) { break }
        }
        return accumulator.result
    }

    private static func incrementedProbeLimit(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }
}

/// Incremental counterpart to `EncodedTextLimiter.limit`.
///
/// The accumulator remembers all three counts, so appending many PDF lines is
/// linear in the accepted text instead of repeatedly recounting an ever-growing
/// string. `append` returns `false` when any part of the requested separator or
/// value could not fit.
struct EncodedTextAccumulator {
    let budget: EncodedTextBudget

    private(set) var text = ""
    private(set) var characterCount = 0
    private(set) var utf8ByteCount = 0
    private(set) var utf16CodeUnitCount = 0
    private(set) var wasTruncated = false

    var isEmpty: Bool { text.isEmpty }
    var isSaturated: Bool {
        characterCount >= budget.maximumCharacters
            || utf8ByteCount >= budget.maximumUTF8Bytes
            || utf16CodeUnitCount >= budget.maximumUTF16CodeUnits
    }

    var result: EncodedTextLimitResult {
        EncodedTextLimitResult(text: text, wasTruncated: wasTruncated)
    }

    @discardableResult
    mutating func append(
        _ value: String,
        separator: String? = nil
    ) -> Bool {
        if !isEmpty, let separator, !appendPiece(separator) { return false }
        return appendPiece(value)
    }

    private mutating func appendPiece(_ value: String) -> Bool {
        let remaining = EncodedTextBudget(
            maximumCharacters: max(
                0,
                budget.maximumCharacters - characterCount
            ),
            maximumUTF8Bytes: max(
                0,
                budget.maximumUTF8Bytes - utf8ByteCount
            ),
            maximumUTF16CodeUnits: max(
                0,
                budget.maximumUTF16CodeUnits - utf16CodeUnitCount
            )
        )
        let limited = EncodedTextLimiter.limit(value, budget: remaining)
        text.append(contentsOf: limited.text)
        characterCount += limited.characterCount
        utf8ByteCount += limited.utf8ByteCount
        utf16CodeUnitCount += limited.utf16CodeUnitCount
        wasTruncated = wasTruncated || limited.wasTruncated
        return !limited.wasTruncated
    }
}

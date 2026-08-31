// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import VibePDF

final class AIAssistantMarkupTests: XCTestCase {
    func testMarkdownWithoutMathIsPreservedVerbatim() {
        let source = """
        ### 편광의 원리

        **중요한 설명**입니다.

        - 첫 번째 항목
        - 두 번째 항목

        1. 관찰
        2. 계산

        > PDF의 근거 문장
        """

        let document = AIAssistantMarkupParser.parse(source)

        XCTAssertEqual(document.segments, [.markdown(source)])
        XCTAssertEqual(document.source, source)
        XCTAssertFalse(document.containsMath)
    }

    func testAllSupportedMathDelimitersAreClassifiedAndSourceIsLossless() {
        let source = #"""
        인라인 \(E_x=E_0\), $c+d$.

        \[
        \alpha = \frac{1}{2}\tan^{-1}(r)
        \]

        $$f(x)=x^2$$ 끝
        """#

        let document = AIAssistantMarkupParser.parse(source)

        XCTAssertEqual(
            document.segments,
            [
                .markdown("인라인 "),
                .inlineMath(expression: "E_x=E_0", source: #"\(E_x=E_0\)"#),
                .markdown(", "),
                .inlineMath(expression: "c+d", source: "$c+d$"),
                .markdown(".\n\n"),
                .blockMath(
                    expression: "\n\\alpha = \\frac{1}{2}\\tan^{-1}(r)\n",
                    source: #"""
                    \[
                    \alpha = \frac{1}{2}\tan^{-1}(r)
                    \]
                    """#
                ),
                .markdown("\n\n"),
                .blockMath(expression: "f(x)=x^2", source: "$$f(x)=x^2$$"),
                .markdown(" 끝")
            ]
        )
        XCTAssertEqual(document.source, source)
        XCTAssertTrue(document.containsMath)
        XCTAssertEqual(document.segments.filter(\.isBlockMath).count, 2)
    }

    func testMarkdownCodeSpansAndFencesRemainOpaque() {
        let source = #"""
        `$PATH`와 `\(x\)`는 코드입니다.

        ```tex
        \[ y = mx + b \]
        $$z = 3$$
        ```

        실제 수식은 \(a+b\)입니다.
        """#

        let document = AIAssistantMarkupParser.parse(source)

        XCTAssertEqual(document.segments.count, 3)
        guard case let .markdown(markdown) = document.segments[0] else {
            return XCTFail("Expected the code examples to remain Markdown")
        }
        XCTAssertTrue(markdown.contains("`$PATH`"))
        XCTAssertTrue(markdown.contains("$$z = 3$$"))
        XCTAssertEqual(
            document.segments[1],
            .inlineMath(expression: "a+b", source: #"\(a+b\)"#)
        )
        XCTAssertEqual(document.segments[2], .markdown("입니다."))
        XCTAssertEqual(document.source, source)
    }

    func testEscapedAndCurrencyDollarSignsAreNotConsumedAsMath() {
        let source = #"""
        가격은 \$5이고 합계는 $5 and $10입니다.
        수식은 $x+1$입니다.
        """#

        let document = AIAssistantMarkupParser.parse(source)

        XCTAssertEqual(document.segments.count, 3)
        XCTAssertEqual(
            document.segments[0],
            .markdown("가격은 \\$5이고 합계는 $5 and $10입니다.\n수식은 ")
        )
        XCTAssertEqual(
            document.segments[1],
            .inlineMath(expression: "x+1", source: "$x+1$")
        )
        XCTAssertEqual(document.segments[2], .markdown("입니다."))
        XCTAssertEqual(document.source, source)
    }

    func testMalformedInlineDelimiterDoesNotSwallowTheFollowingLine() {
        let source = #"""
        첫 줄은 \(닫히지 않음
        다음 줄은 \(x+y\) 정상
        """#

        let document = AIAssistantMarkupParser.parse(source)

        XCTAssertEqual(
            document.segments,
            [
                .markdown("첫 줄은 \\(닫히지 않음\n다음 줄은 "),
                .inlineMath(expression: "x+y", source: #"\(x+y\)"#),
                .markdown(" 정상")
            ]
        )
        XCTAssertEqual(document.source, source)
    }

    func testEmptyAndUnclosedDelimitersRemainMarkdown() {
        let source = #"빈 수식 \(\), $$$$, 그리고 미완성 \[x+y"#

        let document = AIAssistantMarkupParser.parse(source)

        XCTAssertEqual(document.segments, [.markdown(source)])
        XCTAssertEqual(document.source, source)
        XCTAssertFalse(document.containsMath)
    }

    func testUnicodeContentAndEscapedMathCharactersRemainLossless() {
        let source = #"한글·日本語·🙂 \(\text{빛의 세기}=E_0\$\) 완료"#

        let document = AIAssistantMarkupParser.parse(source)

        XCTAssertEqual(
            document.segments,
            [
                .markdown("한글·日本語·🙂 "),
                .inlineMath(
                    expression: #"\text{빛의 세기}=E_0\$"#,
                    source: #"\(\text{빛의 세기}=E_0\$\)"#
                ),
                .markdown(" 완료")
            ]
        )
        XCTAssertEqual(document.source, source)
    }

    func testVeryLongBackslashRunIsScannedLosslessly() {
        let source = String(repeating: "\\", count: 100_000)

        let document = AIAssistantMarkupParser.parse(source)

        XCTAssertEqual(document.segments, [.markdown(source)])
        XCTAssertEqual(document.source, source)
        XCTAssertFalse(document.containsMath)
    }

    func testDelimiterEscapeParityIsPreservedAfterAdversarialBackslashRuns() {
        let evenPrefix = String(repeating: "\\", count: 100_000)
        let parsedSource = evenPrefix + #"\(x+y\)"#
        let parsed = AIAssistantMarkupParser.parse(parsedSource)

        XCTAssertEqual(
            parsed.segments,
            [
                .markdown(evenPrefix),
                .inlineMath(expression: "x+y", source: #"\(x+y\)"#)
            ]
        )
        XCTAssertEqual(parsed.source, parsedSource)

        let oddPrefix = evenPrefix + "\\"
        let escapedSource = oddPrefix + #"\(x+y\)"#
        let escaped = AIAssistantMarkupParser.parse(escapedSource)

        XCTAssertEqual(escaped.segments, [.markdown(escapedSource)])
        XCTAssertEqual(escaped.source, escapedSource)
        XCTAssertFalse(escaped.containsMath)
    }

    func testDisplayFormatterPreservesMarkdownAndReplacesInlineAndBlockLatex() {
        let source = #"""
        ### 2. 타원의 기울기

        **핵심 식**은 \(E_{0x}=E_{0y}\)입니다.

        \[
        \alpha = \frac12 \tan^{-1}\left(\frac{2E_{0x}E_{0y}\cos\phi}{E_{0x}^2-E_{0y}^2}\right)
        \]
        """#

        XCTAssertEqual(
            AIAssistantDisplayFormatter.blocks(from: source),
            [
                .markdown(#"""
                ### 2. 타원의 기울기

                **핵심 식**은 E₀ₓ = E₀ᵧ입니다.


                """#),
                .displayMath("α = 1⁄2 tan⁻¹((2E₀ₓE₀ᵧ cos φ)⁄(E₀ₓ² − E₀ᵧ²))")
            ]
        )
    }

    func testDisplayFormatterEscapesMarkdownSyntaxProducedByMathFallback() {
        let source = #"**식:** \(A_{word} + x^q\)"#

        XCTAssertEqual(
            AIAssistantDisplayFormatter.blocks(from: source),
            [.markdown(#"**식:** A\_(word) + x^(q)"#)]
        )
    }

    func testMarkdownFormatterAppliesFormattingAndKeepsOnlySafePublicLinks() {
        let source = """
        ### 결과

        **강조** [공개 자료](https://example.com/paper)
        [로컬 파일](file:///tmp/private.pdf)
        [로컬 서버](https://127.0.0.1/secret)
        """

        let attributed = AIAssistantMarkdownFormatter.attributedString(from: source)
        let plainText = String(attributed.characters)
        XCTAssertFalse(plainText.contains("###"))
        XCTAssertFalse(plainText.contains("**"))
        XCTAssertTrue(plainText.contains("결과"))
        XCTAssertTrue(plainText.contains("강조"))

        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links, [URL(string: "https://example.com/paper")!])
    }
}

// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import HwattakPDF

final class AIAssistantMathFormatterTests: XCTestCase {
    func testGreekLettersAndNamedSymbolsBecomeUnicode() {
        let latex = #"\alpha \beta \gamma \delta \theta \lambda \mu \pi \rho \sigma \phi \omega \Gamma \Delta \Theta \Lambda \Pi \Sigma \Phi \Omega \times \cdot \pm \le \ge \neq \approx \infty"#

        XCTAssertEqual(
            AIAssistantMathFormatter.format(latex),
            "α β γ δ θ λ μ π ρ σ φ ω Γ Δ Θ Λ Π Σ Φ Ω × · ± ≤ ≥ ≠ ≈ ∞"
        )
    }

    func testFractionsSupportBracedAndCompactArguments() {
        XCTAssertEqual(
            AIAssistantMathFormatter.format(#"\frac{1}{2} + \frac12"#),
            "1⁄2 + 1⁄2"
        )
        XCTAssertEqual(
            AIAssistantMathFormatter.format(#"\frac{a+b}{c-d}"#),
            "(a + b)⁄(c − d)"
        )
    }

    func testSquareRootsAndScriptsUseReadableUnicode() {
        XCTAssertEqual(
            AIAssistantMathFormatter.format(#"x^2 + E_{0x} + \sqrt{x} + \sqrt{x+y}"#),
            "x² + E₀ₓ + √x + √(x + y)"
        )
        XCTAssertEqual(
            AIAssistantMathFormatter.format(#"\sqrt[3]{x} + \sqrt[4]{y}"#),
            "∛x + ∜y"
        )
        XCTAssertEqual(
            AIAssistantMathFormatter.format(#"A_{word} + B^{\phi}"#),
            "A_(word) + B^(φ)"
        )
    }

    func testScreenshotStylePolarizationFormulaIsHumanReadable() {
        let latex = #"\alpha = \frac12 \tan^{-1}\left(\frac{2E_{0x}E_{0y}\cos\phi}{E_{0x}^2-E_{0y}^2}\right)"#

        XCTAssertEqual(
            AIAssistantMathFormatter.format(latex),
            "α = 1⁄2 tan⁻¹((2E₀ₓE₀ᵧ cos φ)⁄(E₀ₓ² − E₀ᵧ²))"
        )
    }

    func testTrigSpacingLeftRightAndQuadCommandsAreRemovedCleanly() {
        let latex = #"\left(\sin\theta + \cos\phi\right)\quad\neq\quad\tan x"#

        XCTAssertEqual(
            AIAssistantMathFormatter.format(latex),
            "(sin θ + cos φ) ≠ tan x"
        )
        XCTAssertFalse(AIAssistantMathFormatter.format(latex).contains("\\"))
    }

    func testUnknownCommandsRemainReadableWithoutRawBackslashes() {
        XCTAssertEqual(
            AIAssistantMathFormatter.format(#"\vec{E} + \custom{x+y}"#),
            "E⃗ + custom(x + y)"
        )
    }

    func testCalculusOperatorsLimitsAndCommonFunctionsAreReadable() {
        let latex = #"\sum\limits_{i=1}^{n} i + \int_a^b f(x)\,dx + \partial_x u + \nabla^2u"#

        XCTAssertEqual(
            AIAssistantMathFormatter.format(latex),
            "∑ᵢ₌₁ⁿ i + ∫ₐᵇ f(x) dx + ∂ₓ u + ∇²u"
        )
        XCTAssertEqual(
            AIAssistantMathFormatter.format(#"\lim_{x\to0} f(x) = L"#),
            "lim_(x → 0) f(x) = L"
        )
    }

    func testAccentsRenderAsUnicodeDecorations() {
        XCTAssertEqual(
            AIAssistantMathFormatter.format(#"\vec{E} + \hat{x} + \bar{v} + \vec{x+y}"#),
            "E⃗ + x̂ + v̄ + (x + y)⃗"
        )
    }

    func testRelationsSetsAndArrowsRenderAsSymbols() {
        let latex = #"\forall x\in A,\quad x\notin B \implies x\to\infty,\quad A\subseteq B \iff B\supseteq A"#

        XCTAssertEqual(
            AIAssistantMathFormatter.format(latex),
            "∀ x ∈ A, x ∉ B ⇒ x → ∞, A ⊆ B ⇔ B ⊇ A"
        )
    }

    func testAlignedAndMatrixEnvironmentsBecomeCompactPlainTextLayouts() {
        XCTAssertEqual(
            AIAssistantMathFormatter.format(
                #"\begin{aligned} E &= mc^2 \\ p &= mv \end{aligned}"#
            ),
            "E = mc²\np = mv"
        )
        XCTAssertEqual(
            AIAssistantMathFormatter.format(
                #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#
            ),
            "(a │ b\nc │ d)"
        )
    }

    func testUnbracedCommandChainsHaveBoundedDescent() {
        // These inputs used to make parser recursion proportional to the
        // provider response and could exhaust the native stack.
        for command in [#"\sqrt"#, #"\text"#] {
            let repetitions = 20_000
            let latex = String(repeating: command, count: repetitions) + "x"
            let rendered = AIAssistantMathFormatter.format(latex)

            XCTAssertFalse(rendered.isEmpty)
            XCTAssertFalse(rendered.contains("\\"))
            XCTAssertTrue(rendered.contains("x"))
            XCTAssertLessThan(rendered.count, latex.count * 4)
        }
    }

    func testFormattingDoesNotChangeTheLosslessMarkupModel() {
        let source = #"설명: \(\frac12\pi r^2\)"#
        let document = AIAssistantMarkupParser.parse(source)

        guard case let .inlineMath(expression, originalMathSource) = document.segments[1] else {
            return XCTFail("Expected an inline math segment")
        }
        XCTAssertEqual(AIAssistantMathFormatter.format(expression), "1⁄2π r²")
        XCTAssertEqual(originalMathSource, #"\(\frac12\pi r^2\)"#)
        XCTAssertEqual(document.source, source)
    }
}

import Foundation
import XCTest
@testable import PdfVocab

final class MathReadingTests: XCTestCase {
    func testLexiconKeepsAmbiguousLookingLettersAndGreekDistinct() {
        XCTAssertEqual(MathSymbolLexicon.chineseName(for: "×"), "乘号")
        XCTAssertEqual(MathSymbolLexicon.latex(for: "×"), "\\times")
        XCTAssertEqual(MathSymbolLexicon.latex(for: "x"), "x")
        XCTAssertNotEqual(MathSymbolLexicon.chineseName(for: "x"), MathSymbolLexicon.chineseName(for: "×"))

        XCTAssertEqual(MathSymbolLexicon.chineseName(for: "l"), "拉丁小写 l（字母，不是数字 1）")
        XCTAssertEqual(MathSymbolLexicon.chineseName(for: "1"), "数字 1（不是字母 l）")
        XCTAssertNotEqual(MathSymbolLexicon.chineseName(for: "l"), MathSymbolLexicon.chineseName(for: "1"))

        XCTAssertEqual(MathSymbolLexicon.latex(for: "ν"), "\\nu")
        XCTAssertNotEqual(MathSymbolLexicon.chineseName(for: "ν"), MathSymbolLexicon.chineseName(for: "v"))
        XCTAssertEqual(MathSymbolLexicon.latex(for: "ψ"), "\\psi")
        XCTAssertEqual(MathSymbolLexicon.latex(for: "Ψ"), "\\Psi")
        XCTAssertNotEqual(MathSymbolLexicon.chineseName(for: "ψ"), MathSymbolLexicon.chineseName(for: "Ψ"))

        XCTAssertEqual(MathSymbolLexicon.latex(for: "ε"), "\\varepsilon")
        XCTAssertEqual(MathSymbolLexicon.latex(for: "ϵ"), "\\epsilon")
        XCTAssertEqual(MathSymbolLexicon.latex(for: "φ"), "\\varphi")
        XCTAssertEqual(MathSymbolLexicon.latex(for: "ϕ"), "\\phi")

        for symbol in ["ℏ", "ℓ", "±", "∓", "<", ">"] {
            let parsed = MathReadingService.resolve(symbol)
            XCTAssertEqual(parsed?.status, .parsedText, "Known non-letter symbol \(symbol) is a strong standalone signal")
            XCTAssertTrue(parsed?.explanation.contains(MathSymbolLexicon.chineseName(for: symbol) ?? "") ?? false)
        }
    }

    func testPlainTextEquationsAndUnicodeScriptsBecomeStructuredLatex() throws {
        let alpha = try parsed("α")
        XCTAssertTrue(alpha.explanation.contains("希腊小写 alpha"))
        XCTAssertTrue(alpha.explanation.contains("依上下文"))

        let greekWithLatin = try parsed("αx")
        XCTAssertTrue(try XCTUnwrap(greekWithLatin.latex).contains("\\alpha"))
        XCTAssertEqual(try XCTUnwrap(greekWithLatin.ast).children.count, 2)
        XCTAssertEqual(try XCTUnwrap(greekWithLatin.ast).children.last?.value, "x")

        let partialWithLatin = try parsed("∂x")
        XCTAssertTrue(try XCTUnwrap(partialWithLatin.latex).contains("\\partial"))
        XCTAssertEqual(try XCTUnwrap(partialWithLatin.ast).children.count, 2)

        let epsilon = try parsed("ε")
        let epsilonSymbol = try parsed("ϵ")
        XCTAssertNotEqual(try XCTUnwrap(epsilon.ast).children.first?.value,
                          try XCTUnwrap(epsilonSymbol.ast).children.first?.value)
        let phi = try parsed("φ")
        let phiSymbol = try parsed("ϕ")
        XCTAssertNotEqual(try XCTUnwrap(phi.ast).children.first?.value,
                          try XCTUnwrap(phiSymbol.ast).children.first?.value)

        let massEnergy = try parsed("E=mc²")
        XCTAssertTrue(try XCTUnwrap(massEnergy.latex).contains("mc^{2}"))
        let massEnergyScript = try XCTUnwrap(findNodes(in: try XCTUnwrap(massEnergy.ast), kind: .scripts).first)
        XCTAssertEqual(massEnergyScript.base?.kind, .symbol)
        XCTAssertEqual(massEnergyScript.base?.value, "c")
        XCTAssertEqual(massEnergyScript.superscriptExpression?.children.first?.value, "2")
        XCTAssertEqual(massEnergy.unicode, "E=mc²")

        let scaled = try parsed("3.2×10⁸")
        let scaledLatex = try XCTUnwrap(scaled.latex)
        XCTAssertTrue(scaledLatex.contains("3.2\\times"))
        XCTAssertTrue(scaledLatex.contains("10^{8}"))
        let scaledScript = try XCTUnwrap(findNodes(in: try XCTUnwrap(scaled.ast), kind: .scripts).first)
        XCTAssertEqual(scaledScript.base?.kind, .sequence, "The exponent binds to the complete numeric base 10")
        XCTAssertEqual(scaledScript.base?.children.compactMap(\.value).joined(), "10")
        XCTAssertEqual(scaledScript.superscriptExpression?.children.compactMap(\.value).joined(), "8")

        let negativePower = try parsed("10⁻³")
        let power = try XCTUnwrap(findNodes(in: try XCTUnwrap(negativePower.ast), kind: .scripts).first)
        XCTAssertEqual(power.base?.kind, .sequence)
        XCTAssertEqual(power.base?.children.compactMap(\.value).joined(), "10")
        XCTAssertEqual(power.superscriptExpression?.children.compactMap(\.value).joined(), "−3")

        let partial = try parsed("∂²ψ/∂x²")
        let partialLatex = try XCTUnwrap(partial.latex)
        XCTAssertTrue(partialLatex.contains("\\partial"))
        XCTAssertTrue(partialLatex.contains("\\psi"))
        XCTAssertTrue(partialLatex.contains("^{2}"))
        XCTAssertFalse(findNodes(in: try XCTUnwrap(partial.ast), kind: .fraction).count > 0,
                       "A slash stays linear and is not guessed to be a fraction")
        XCTAssertEqual(findNodes(in: try XCTUnwrap(partial.ast), kind: .scripts).count, 2)
    }

    func testExplicitLatexBuildsFractionScriptsOperatorsAndRoots() throws {
        let fraction = try parsed("\\frac12")
        XCTAssertTrue(try XCTUnwrap(fraction.latex).contains("\\frac"))
        let fractionNode = try XCTUnwrap(findNodes(in: try XCTUnwrap(fraction.ast), kind: .fraction).first)
        XCTAssertEqual(fractionNode.numerator?.children.compactMap(\.value).joined(), "1")
        XCTAssertEqual(fractionNode.denominator?.children.compactMap(\.value).joined(), "2")
        XCTAssertNil(fraction.unicode, "A two dimensional fraction is not flattened to a Unicode string")

        let scripted = try parsed("x_i^2")
        let xScripts = try XCTUnwrap(findNodes(in: try XCTUnwrap(scripted.ast), kind: .scripts).first)
        XCTAssertEqual(xScripts.base?.value, "x")
        XCTAssertEqual(xScripts.subscriptExpression?.children.compactMap(\.value).joined(), "i")
        XCTAssertEqual(xScripts.superscriptExpression?.children.compactMap(\.value).joined(), "2")

        let summation = try parsed("\\sum_{i=1}^n")
        let sumScripts = try XCTUnwrap(findNodes(in: try XCTUnwrap(summation.ast), kind: .scripts).first)
        XCTAssertEqual(sumScripts.base?.kind, .largeOperator)
        XCTAssertEqual(sumScripts.base?.value, "∑")
        XCTAssertNotNil(sumScripts.subscriptExpression)
        XCTAssertEqual(sumScripts.superscriptExpression?.children.compactMap(\.value).joined(), "n")

        let integral = try parsed("\\int_0^1")
        let integralScripts = try XCTUnwrap(findNodes(in: try XCTUnwrap(integral.ast), kind: .scripts).first)
        XCTAssertEqual(integralScripts.base?.kind, .largeOperator)
        XCTAssertEqual(integralScripts.base?.value, "∫")

        let root = try parsed("√(x+1)")
        XCTAssertTrue(try XCTUnwrap(root.latex).contains("\\sqrt"))
        XCTAssertEqual(findNodes(in: try XCTUnwrap(root.ast), kind: .root).count, 1)
    }

    func testMatrixAndSchrodingerExpressionKeepTheirStructure() throws {
        let matrix = try parsed("\\begin{matrix}a&b\\\\c&d\\end{matrix}")
        let matrixNode = try XCTUnwrap(findNodes(in: try XCTUnwrap(matrix.ast), kind: .matrix).first)
        XCTAssertEqual(matrixNode.rows?.count, 2)
        XCTAssertEqual(matrixNode.rows?.first?.count, 2)
        XCTAssertNil(matrix.unicode, "A matrix is not flattened into a linear Unicode string")

        let schrodinger = try parsed("iℏ∂ψ/∂t = −(ℏ²/2m)∇²ψ + Vψ")
        XCTAssertTrue(try XCTUnwrap(schrodinger.latex).contains("\\hbar"))
        XCTAssertTrue(try XCTUnwrap(schrodinger.latex).contains("\\partial"))
        XCTAssertTrue(try XCTUnwrap(schrodinger.latex).contains("\\nabla"))
        XCTAssertTrue(findNodes(in: try XCTUnwrap(schrodinger.ast), kind: .scripts).count >= 2)
        XCTAssertTrue(try XCTUnwrap(schrodinger.ast).isComplete)
    }

    func testOrdinaryWordsSingleLettersCurrencyAndProseAreNotIntercepted() {
        XCTAssertNil(MathReadingService.resolve("Schrödinger"))
        XCTAssertNil(MathReadingService.resolve("x"))
        XCTAssertNil(MathReadingService.resolve("l"))
        XCTAssertNil(MathReadingService.resolve("x-ray"))
        XCTAssertNil(MathReadingService.resolve("co-op"))
        XCTAssertNil(MathReadingService.resolve("and/or"))
        XCTAssertNil(MathReadingService.resolve("https://example.com/path"))
        XCTAssertNil(MathReadingService.resolve("src/file.swift"))
        XCTAssertEqual(MathReadingService.resolve("a-b")?.status, .parsedText)
        XCTAssertEqual(MathReadingService.resolve("x-y")?.status, .parsedText)
        XCTAssertNil(MathReadingService.resolve("€12.50"))
        XCTAssertNil(MathReadingService.resolve("A normal sentence with number 12."))
        XCTAssertNil(MathReadingService.resolve("The answer is x=1"), "English prose with an incidental relation stays prose")
        XCTAssertNil(MathReadingService.resolve("the angle α is small"), "A Greek letter inside prose does not turn the sentence into a formula")

        let equation = MathReadingService.resolve("F = ma")
        XCTAssertEqual(equation?.status, .parsedText)
        XCTAssertNotNil(equation?.ast)
    }

    func testSuspiciousLinearizedOrLabelledSourceNeedsReviewWithoutLatex() throws {
        let suspiciousInputs = [
            "x = 1 / (y+1) / 2 - 3/3",
            "f(2) = 3(2)2 + 1",
            "b. f(2) = 3(2)2 + 1"
        ]

        for source in suspiciousInputs {
            let result = try XCTUnwrap(MathReadingService.resolve(source), "Expected ambiguous math source to route for review: \(source)")
            XCTAssertEqual(result.status, .needsReview, source)
            XCTAssertEqual(result.sourceText, source, "Review keeps the extracted text verbatim")
            XCTAssertNil(result.latex, "Ambiguous source must not be re-typeset as a confirmed formula")
            XCTAssertNil(result.unicode)
        }
    }

    func testUnambiguousLinearAndSeparateSlashExpressionsRemainParsed() throws {
        _ = try parsed("E=mc²")
        _ = try parsed("F = ma")
        _ = try parsed("x = 1/2 + 3/4")
    }

    func testMalformedUnknownAndOverLimitMathIsReturnedForReview() throws {
        let unknownCommand = try XCTUnwrap(MathReadingService.resolve("x\\unknown=1"))
        XCTAssertEqual(unknownCommand.status, .needsReview)
        XCTAssertEqual(unknownCommand.sourceText, "x\\unknown=1")
        XCTAssertNil(unknownCommand.latex)

        let unknownLatexOnly = try XCTUnwrap(MathReadingService.resolve("\\unknown{x}"))
        XCTAssertEqual(unknownLatexOnly.status, .needsReview)
        XCTAssertEqual(unknownLatexOnly.sourceText, "\\unknown{x}")

        let malformed = try XCTUnwrap(MathReadingService.resolve("x^{"))
        XCTAssertEqual(malformed.status, .needsReview)
        XCTAssertEqual(malformed.sourceText, "x^{")

        let tooDeepLatex = String(repeating: "\\sqrt{", count: 33) + "x" + String(repeating: "}", count: 33)
        let tooDeep = try XCTUnwrap(MathReadingService.resolve(tooDeepLatex))
        XCTAssertEqual(tooDeep.status, .needsReview)
        XCTAssertNil(tooDeep.latex)

        let tooLong = "x=" + String(repeating: "1", count: MathReadingService.maximumUTF16Length)
        let lengthReview = try XCTUnwrap(MathReadingService.resolve(tooLong))
        XCTAssertEqual(lengthReview.status, .needsReview)
        XCTAssertEqual(lengthReview.sourceText, tooLong)
        XCTAssertNil(lengthReview.latex)

        let unsupportedNode = try XCTUnwrap(MathReadingService.resolve("\\overline{x}"))
        XCTAssertEqual(unsupportedNode.status, .needsReview)
        XCTAssertFalse(try XCTUnwrap(unsupportedNode.ast).isComplete)
        XCTAssertFalse(findNodes(in: try XCTUnwrap(unsupportedNode.ast), kind: .unknown).isEmpty)

        for emptyStructure in ["\\frac{}{}", "\\sqrt{}", "\\begin{matrix}\\end{matrix}"] {
            let empty = try XCTUnwrap(MathReadingService.resolve(emptyStructure))
            XCTAssertEqual(empty.status, .needsReview, "Empty structure must not be marked complete: \(emptyStructure)")
            if let ast = empty.ast {
                XCTAssertFalse(ast.isComplete)
            }
        }

        let excessiveScriptChain = "x+" + String(repeating: "^", count: 100) + "2"
        let chainReview = try XCTUnwrap(MathReadingService.resolve(excessiveScriptChain))
        XCTAssertEqual(chainReview.status, .needsReview)
        XCTAssertNil(chainReview.latex, "Script depth is rejected before SwiftMath's recursive parser is called")
    }

    func testAstCodableRoundTripPreservesNestedStructure() throws {
        let result = try parsed("\\begin{matrix}x_i^2&\\frac12\\\\\\sum_{k=1}^n&√2\\end{matrix}")
        let ast = try XCTUnwrap(result.ast)
        let data = try JSONEncoder().encode(ast)
        let decoded = try JSONDecoder().decode(MathExpressionNode.self, from: data)
        XCTAssertEqual(decoded, ast)
        XCTAssertTrue(decoded.isComplete)
        XCTAssertEqual(findNodes(in: decoded, kind: .matrix).first?.rows?.count, 2)
    }

    private func parsed(_ source: String, file: StaticString = #filePath, line: UInt = #line) throws -> MathReadingResult {
        let result = try XCTUnwrap(MathReadingService.resolve(source), file: file, line: line)
        XCTAssertEqual(result.status, .parsedText, file: file, line: line)
        XCTAssertTrue(try XCTUnwrap(result.ast, file: file, line: line).isComplete, file: file, line: line)
        XCTAssertNotNil(result.latex, file: file, line: line)
        return result
    }

    private func findNodes(in node: MathExpressionNode, kind: MathExpressionNode.Kind) -> [MathExpressionNode] {
        var matches: [MathExpressionNode] = node.kind == kind ? [node] : []
        switch node {
        case .sequence(let children):
            matches += children.flatMap { findNodes(in: $0, kind: kind) }
        case .scripts(let base, let subscriptExpression, let superscriptExpression):
            matches += findNodes(in: base, kind: kind)
            if let subscriptExpression { matches += findNodes(in: subscriptExpression, kind: kind) }
            if let superscriptExpression { matches += findNodes(in: superscriptExpression, kind: kind) }
        case .fraction(let numerator, let denominator, _):
            matches += findNodes(in: numerator, kind: kind)
            matches += findNodes(in: denominator, kind: kind)
        case .root(let radicand, let degree):
            matches += findNodes(in: radicand, kind: kind)
            if let degree { matches += findNodes(in: degree, kind: kind) }
        case .matrix(_, let rows):
            matches += rows.joined().flatMap { findNodes(in: $0, kind: kind) }
        case .symbol, .number, .largeOperator, .unknown:
            break
        }
        return matches
    }
}

import Foundation
import SwiftMath

public enum MathReadingService {
    public static let maximumUTF16Length = 2_048

    private static let maximumLatexUTF16Length = 4_096
    private static let maximumInputGroupDepth = 32
    private static let maximumASTDepth = 32
    private static let maximumASTNodes = 512
    private static let maximumScriptMarkers = 32
    private static let maximumLatexCommands = 128
    private static let maximumLatexCommandLength = 32

    private static let currencySymbols = Set("$€£¥₹¢")
    private static let greekSignals = Set("αβγδεζηθικλμνξοπρσςτυφχψωϵϑϖϱϕ𝜖𝜙ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ")
    private static let explicitMathSignals = Set("=+−-×⋅·÷*/^_≤≥≠≈≡∞∑∏∫∮∂∇√∈∉⊂⊆∪∩∧∨→←↔⇒⇔∀∃±∓<>")
    private static let latexMathCommands: Set<String> = [
        "frac", "binom", "sqrt", "sum", "prod", "int", "oint", "partial", "nabla", "infty",
        "alpha", "beta", "gamma", "delta", "epsilon", "theta", "lambda", "mu", "nu", "pi",
        "rho", "sigma", "tau", "phi", "psi", "omega", "Gamma", "Delta", "Theta", "Lambda",
        "Xi", "Pi", "Sigma", "Phi", "Psi", "Omega", "times", "cdot", "div", "pm", "mp",
        "le", "leq", "ge", "geq", "ne", "neq", "approx", "equiv", "in", "notin", "subset",
        "subseteq", "cup", "cap", "wedge", "vee", "rightarrow", "leftarrow", "leftrightarrow",
        "Rightarrow", "Leftrightarrow", "forall", "exists", "hbar", "ell", "begin", "overline", "underline"
    ]

    private enum ScriptKind: Equatable {
        case superscript
        case subscript
    }

    private struct ASTBudget {
        var nodeCount = 0
        var exceeded = false
    }

    /// Parses only the mathematical syntax present in the supplied text. This does not inspect a PDF or
    /// verify the accuracy of text previously recognized by OCR.
    public static func resolve(_ sourceText: String) -> MathReadingResult? {
        guard !sourceText.isEmpty else { return nil }
        guard sourceText.utf16.count <= maximumUTF16Length else {
            let prefix = prefixWithinUTF16Units(sourceText, maximumUTF16Units: maximumUTF16Length)
            guard hasStrongMathSignal(prefix) else { return nil }
            return needsReview(sourceText)
        }
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hasStrongMathSignal(sourceText) else { return nil }
        guard !sourceText.unicodeScalars.contains(where: { currencySymbols.contains(Character($0)) }) else {
            return nil
        }

        let containsRawLatex = sourceText.contains("\\")
        guard preflight(sourceText, maximumUTF16Units: maximumUTF16Length),
              let latexInput = latexInput(for: sourceText),
              preflight(latexInput, maximumUTF16Units: maximumLatexUTF16Length) else {
            return needsReview(sourceText)
        }

        var parseError: NSError?
        guard let parsedList = MTMathListBuilder.build(fromString: latexInput, error: &parseError) else {
            return needsReview(sourceText)
        }

        var sourceBudget = ASTBudget()
        guard let sourceAST = makeSequence(from: parsedList, depth: 0, budget: &sourceBudget),
              !sourceBudget.exceeded else {
            return needsReview(sourceText)
        }
        guard sourceAST.isComplete else {
            return needsReview(sourceText, ast: sourceAST)
        }

        let canonicalLatex = MTMathListBuilder.mathListToString(parsedList)
        guard !canonicalLatex.isEmpty,
              preflight(canonicalLatex, maximumUTF16Units: maximumLatexUTF16Length) else {
            return needsReview(sourceText, ast: sourceAST)
        }

        var roundTripError: NSError?
        guard let verifiedList = MTMathListBuilder.build(fromString: canonicalLatex, error: &roundTripError) else {
            return needsReview(sourceText, ast: sourceAST)
        }

        var verificationBudget = ASTBudget()
        guard let verifiedAST = makeSequence(from: verifiedList, depth: 0, budget: &verificationBudget),
              !verificationBudget.exceeded,
              verifiedAST.isComplete,
              verifiedAST == sourceAST else {
            return needsReview(sourceText, ast: sourceAST)
        }

        let unicode = losslessUnicode(for: sourceText, ast: verifiedAST, containsRawLatex: containsRawLatex)
        return MathReadingResult(
            sourceText: sourceText,
            latex: canonicalLatex,
            unicode: unicode,
            explanation: parsedExplanation(for: sourceText),
            status: .parsedText,
            ast: verifiedAST
        )
    }

    private static func needsReview(_ sourceText: String, ast: MathExpressionNode? = nil) -> MathReadingResult {
        MathReadingResult(
            sourceText: sourceText,
            latex: nil,
            unicode: nil,
            explanation: "检测到数学信号，但文本语法或复杂度无法安全确认；保留原文供复核。该结果不验证原 PDF/OCR 的识别准确性。",
            status: .needsReview,
            ast: ast
        )
    }

    private static func prefixWithinUTF16Units(_ text: String, maximumUTF16Units: Int) -> String {
        var result = ""
        var usedUnits = 0
        for scalar in text.unicodeScalars {
            let scalarUnits = scalar.value > 0xFFFF ? 2 : 1
            guard usedUnits + scalarUnits <= maximumUTF16Units else { break }
            result.unicodeScalars.append(scalar)
            usedUnits += scalarUnits
        }
        return result
    }

    private static func hasStrongMathSignal(_ source: String) -> Bool {
        if looksLikeSingleWordConnectorOrPath(source) {
            return false
        }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.unicodeScalars.count == 1,
           MathSymbolLexicon.entry(for: trimmed) != nil,
           let scalar = trimmed.unicodeScalars.first,
           !isASCIIWordLetter(scalar),
           !CharacterSet.decimalDigits.contains(scalar) {
            return true
        }

        let scalars = Array(source.unicodeScalars)
        var hasSignal = false
        var hasGreek = false
        var hasUnicodeScript = false
        var hasKnownLatexCommand = false
        var hasLatexControlWord = false
        var hasRelationOrBinary = false
        var longWordCount = 0
        var currentWordLength = 0

        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            let character = Character(scalar)
            if currencySymbols.contains(character) {
                return false
            }

            if greekSignals.contains(character) {
                hasGreek = true
            }
            if superscriptValue(for: scalar) != nil || subscriptValue(for: scalar) != nil {
                hasUnicodeScript = true
            }
            if explicitMathSignals.contains(character) {
                hasSignal = true
                if "=+−-×⋅·÷≤≥≠≈≡∈∉⊂⊆∪∩∧∨→←↔⇒⇔".contains(character) {
                    hasRelationOrBinary = true
                }
            }

            if scalar == "\\" {
                var command = ""
                var cursor = index + 1
                while cursor < scalars.count && isASCIICommandLetter(scalars[cursor]) {
                    command.unicodeScalars.append(scalars[cursor])
                    cursor += 1
                }
                if !command.isEmpty {
                    hasLatexControlWord = true
                }
                if latexMathCommands.contains(command) {
                    hasKnownLatexCommand = true
                }
                if !command.isEmpty && latexMathCommands.contains(command) {
                    hasSignal = true
                }
            }

            if scalar == "^" || scalar == "_" {
                let hasPreviousOperand = index > 0 && !CharacterSet.whitespacesAndNewlines.contains(scalars[index - 1])
                let hasNextOperand = index + 1 < scalars.count && !CharacterSet.whitespacesAndNewlines.contains(scalars[index + 1])
                if hasPreviousOperand && hasNextOperand {
                    hasSignal = true
                }
            }

            if isASCIIWordLetter(scalar) {
                currentWordLength += 1
            } else if currentWordLength > 0 {
                if currentWordLength >= 2 { longWordCount += 1 }
                currentWordLength = 0
            }

            index += 1
        }
        if currentWordLength >= 2 { longWordCount += 1 }

        // Greek letters in a sentence do not make the whole sentence a formula. Explicit LaTeX remains opt-in.
        if longWordCount >= 2 && !hasKnownLatexCommand {
            return false
        }
        if hasGreek || hasUnicodeScript || hasKnownLatexCommand {
            return true
        }
        if hasRelationOrBinary {
            return true
        }
        return hasSignal || hasLatexControlWord
    }

    private static func latexInput(for source: String) -> String? {
        latexInput(for: source, conversionDepth: 0)
    }

    private static func latexInput(for source: String, conversionDepth: Int) -> String? {
        if source.contains("\\") {
            return source
        }

        let characters = Array(source)
        var output = ""
        var index = 0
        var hasScriptableBase = false
        while index < characters.count {
            let character = characters[index]
            if let scriptKind = scriptKind(for: character) {
                guard hasScriptableBase else { return nil }
                var script = ""
                while index < characters.count, scriptKind(for: characters[index]) == scriptKind {
                    guard let scalar = characters[index].unicodeScalars.first,
                          let value = scriptValue(for: scalar, kind: scriptKind) else { return nil }
                    script += latexAtom(value)
                    index += 1
                }
                switch scriptKind {
                case .superscript: output += "^{\(script)}"
                case .subscript: output += "_{\(script)}"
                }
                continue
            }

            if character == "√" {
                guard conversionDepth < maximumInputGroupDepth,
                      let (operand, nextIndex) = rootOperand(in: characters, from: index + 1) else {
                    return nil
                }
                guard let convertedOperand = latexInput(for: operand, conversionDepth: conversionDepth + 1) else { return nil }
                output += "\\sqrt{\(convertedOperand)}"
                index = nextIndex
                hasScriptableBase = true
                continue
            }

            let text = String(character)
            if let entry = MathSymbolLexicon.entry(for: text) {
                let followingCharacter = index + 1 < characters.count ? characters[index + 1] : nil
                output += terminatedLatexCommand(entry.latex, followedBy: followingCharacter)
            } else {
                output += text
            }

            if character.isWhitespace {
                // Whitespace does not change which math atom a following script belongs to.
            } else if isBinaryOrRelation(character) || "=<>+−-×⋅·÷*/".contains(character) {
                hasScriptableBase = false
            } else if character == "(" || character == "[" || character == "{" {
                hasScriptableBase = false
            } else if character == ")" || character == "]" || character == "}" {
                hasScriptableBase = true
            } else {
                hasScriptableBase = true
            }
            index += 1
        }
        return output
    }

    private static func rootOperand(in characters: [Character], from start: Int) -> (String, Int)? {
        var index = start
        while index < characters.count && characters[index].isWhitespace { index += 1 }
        guard index < characters.count else { return nil }

        let opener = characters[index]
        if opener == "(" || opener == "{" || opener == "[" {
            let matching: Character = opener == "(" ? ")" : (opener == "{" ? "}" : "]")
            var depth = 0
            var cursor = index
            while cursor < characters.count {
                if characters[cursor] == opener { depth += 1 }
                if characters[cursor] == matching {
                    depth -= 1
                    if depth == 0 {
                        return (String(characters[index...cursor]), cursor + 1)
                    }
                }
                cursor += 1
            }
            return nil
        }

        if characters[index].isNumber {
            let first = index
            while index < characters.count && (characters[index].isNumber || characters[index] == ".") {
                index += 1
            }
            return (String(characters[first..<index]), index)
        }

        let first = index
        guard characters[index].isLetter else { return nil }
        index += 1
        while index < characters.count, scriptKind(for: characters[index]) != nil {
            index += 1
        }
        if index < characters.count && characters[index].isLetter {
            // A bare multi-letter radicand has ambiguous scope. Require explicit grouping.
            return nil
        }
        return (String(characters[first..<index]), index)
    }

    private static func latexAtom(_ value: String) -> String {
        if let entry = MathSymbolLexicon.entry(for: value) {
            return terminatedLatexCommand(entry.latex)
        }
        return value
    }

    private static func terminatedLatexCommand(_ latex: String, followedBy character: Character? = nil) -> String {
        guard latex.first == "\\" else { return latex }
        let command = latex.dropFirst()
        guard !command.isEmpty, command.unicodeScalars.allSatisfy(isASCIICommandLetter) else { return latex }
        guard let character, character.isLetter else { return latex }
        if let nextEntry = MathSymbolLexicon.entry(for: String(character)), nextEntry.latex.first == "\\" {
            return latex
        }
        return latex + " "
    }

    private static func parsedExplanation(for sourceText: String) -> String {
        let trimmed = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let entry = MathSymbolLexicon.entry(for: trimmed) {
            return "\(entry.chineseName)；符号或变量含义依上下文。仅解析输入文本，不验证原 PDF/OCR 的识别准确性。"
        }
        return "已解析输入中的数学文本；变量含义依上下文，不做语义臆断，也不验证原 PDF/OCR 的识别准确性。"
    }

    private static func looksLikeSingleWordConnectorOrPath(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") || trimmed.hasPrefix("/") { return true }
        if trimmed.count >= 3 {
            let characters = Array(trimmed)
            if characters[1] == ":" && (characters[2] == "/" || characters[2] == "\\") {
                return true
            }
        }
        guard !trimmed.contains(where: \.isWhitespace) else { return false }
        let separators = trimmed.filter { $0 == "-" || $0 == "/" }
        guard separators.count == 1 else { return false }
        let parts = trimmed.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 2 else { return false }
        let tokens = parts.map(String.init)
        guard tokens.allSatisfy({ token in
            token.unicodeScalars.allSatisfy { isASCIICommandLetter($0) }
        }) else { return false }
        let totalLength = tokens.reduce(0) { $0 + $1.count }
        return totalLength >= 4
    }

    private static func scriptKind(for character: Character) -> ScriptKind? {
        guard let scalar = character.unicodeScalars.first else { return nil }
        if superscriptValue(for: scalar) != nil { return .superscript }
        if subscriptValue(for: scalar) != nil { return .subscript }
        return nil
    }

    private static func scriptValue(for scalar: Unicode.Scalar, kind: ScriptKind) -> String? {
        switch kind {
        case .superscript: return superscriptValue(for: scalar)
        case .subscript: return subscriptValue(for: scalar)
        }
    }

    private static func superscriptValue(for scalar: Unicode.Scalar) -> String? {
        switch scalar {
        case "⁰": return "0"; case "¹": return "1"; case "²": return "2"; case "³": return "3"
        case "⁴": return "4"; case "⁵": return "5"; case "⁶": return "6"; case "⁷": return "7"
        case "⁸": return "8"; case "⁹": return "9"; case "⁺": return "+"; case "⁻": return "-"
        case "⁼": return "="; case "⁽": return "("; case "⁾": return ")"; case "ⁱ": return "i"
        case "ⁿ": return "n"; case "ᵃ": return "a"; case "ᵇ": return "b"; case "ᶜ": return "c"
        case "ᵈ": return "d"; case "ᵉ": return "e"; case "ᶠ": return "f"; case "ᵍ": return "g"
        case "ʰ": return "h"; case "ʲ": return "j"; case "ᵏ": return "k"; case "ˡ": return "l"
        case "ᵐ": return "m"; case "ᵒ": return "o"; case "ᵖ": return "p"; case "ʳ": return "r"
        case "ˢ": return "s"; case "ᵗ": return "t"; case "ᵘ": return "u"; case "ᵛ": return "v"
        case "ʷ": return "w"; case "ˣ": return "x"; case "ʸ": return "y"; case "ᶻ": return "z"
        default: return nil
        }
    }

    private static func subscriptValue(for scalar: Unicode.Scalar) -> String? {
        switch scalar {
        case "₀": return "0"; case "₁": return "1"; case "₂": return "2"; case "₃": return "3"
        case "₄": return "4"; case "₅": return "5"; case "₆": return "6"; case "₇": return "7"
        case "₈": return "8"; case "₉": return "9"; case "₊": return "+"; case "₋": return "-"
        case "₌": return "="; case "₍": return "("; case "₎": return ")"; case "ₐ": return "a"
        case "ₑ": return "e"; case "ₕ": return "h"; case "ᵢ": return "i"; case "ⱼ": return "j"
        case "ₖ": return "k"; case "ₗ": return "l"; case "ₘ": return "m"; case "ₙ": return "n"
        case "ₒ": return "o"; case "ₚ": return "p"; case "ᵣ": return "r"; case "ₛ": return "s"
        case "ₜ": return "t"; case "ᵤ": return "u"; case "ᵥ": return "v"; case "ₓ": return "x"
        case "ᵦ": return "β"; case "ᵧ": return "γ"; case "ᵨ": return "ρ"; case "ᵩ": return "φ"
        case "ᵪ": return "χ"
        default: return nil
        }
    }

    private static func isBinaryOrRelation(_ character: Character) -> Bool {
        "=<>≤≥≠≈≡∈∉⊂⊆∪∩∧∨→←↔⇒⇔".contains(character)
    }

    private static func isASCIICommandLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isASCIIWordLetter(_ scalar: Unicode.Scalar) -> Bool {
        isASCIICommandLetter(scalar)
    }

    private static func preflight(_ text: String, maximumUTF16Units: Int) -> Bool {
        guard text.utf16.count <= maximumUTF16Units else { return false }

        let scalars = Array(text.unicodeScalars)
        var groupStack: [Unicode.Scalar] = []
        var commandCount = 0
        var estimatedNodes = 0
        var scriptMarkerCount = 0
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\" {
                index += 1
                guard index < scalars.count else { return false }
                if isASCIICommandLetter(scalars[index]) {
                    commandCount += 1
                    var commandLength = 0
                    while index < scalars.count && isASCIICommandLetter(scalars[index]) {
                        commandLength += 1
                        index += 1
                    }
                    guard commandCount <= maximumLatexCommands,
                          commandLength <= maximumLatexCommandLength else { return false }
                } else {
                    // Escaped punctuation such as \{ is not a grouping delimiter.
                    index += 1
                }
                estimatedNodes += 1
                if estimatedNodes > maximumASTNodes { return false }
                continue
            }

            if scalar == "^" || scalar == "_" {
                scriptMarkerCount += 1
                guard scriptMarkerCount <= maximumScriptMarkers else { return false }
            }

            if scalar == "{" || scalar == "(" || scalar == "[" {
                groupStack.append(scalar)
                guard groupStack.count <= maximumInputGroupDepth else { return false }
            } else if scalar == "}" || scalar == ")" || scalar == "]" {
                guard let opener = groupStack.popLast() else { return false }
                let expected: Unicode.Scalar = opener == "{" ? "}" : (opener == "(" ? ")" : "]")
                guard scalar == expected else { return false }
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar), scalar != "&", scalar != "\\" {
                estimatedNodes += 1
                if estimatedNodes > maximumASTNodes { return false }
            }
            index += 1
        }
        return groupStack.isEmpty
    }

    private static func makeSequence(from list: MTMathList,
                                     depth: Int,
                                     budget: inout ASTBudget) -> MathExpressionNode? {
        guard reserveNode(depth: depth, budget: &budget) else { return nil }
        var children: [MathExpressionNode] = []

        for atom in list.atoms {
            if atom.type == .style {
                continue
            }
            guard let node = makeAtom(atom, depth: depth + 1, budget: &budget) else { return nil }
            if node.kind == .number {
                children.append(node)
                continue
            }

            if node.kind == .scripts,
               let base = node.base,
               base.kind == .number,
               let last = children.last,
               last.kind == .number {
                var numericRun: [MathExpressionNode] = []
                while children.last?.kind == .number {
                    numericRun.insert(children.removeLast(), at: 0)
                }
                numericRun.append(base)
                guard reserveNode(depth: depth + 1, budget: &budget) else { return nil }
                let combinedBase = MathExpressionNode(kind: .sequence, children: numericRun)
                children.append(MathExpressionNode(
                    kind: .scripts,
                    base: combinedBase,
                    subscriptExpression: node.subscriptExpression,
                    superscriptExpression: node.superscriptExpression,
                    isComplete: node.isComplete && combinedBase.isComplete
                ))
            } else {
                children.append(node)
            }
        }

        return MathExpressionNode(kind: .sequence, children: children, isComplete: children.allSatisfy(\.isComplete))
    }

    private static func makeAtom(_ atom: MTMathAtom,
                                 depth: Int,
                                 budget: inout ASTBudget) -> MathExpressionNode? {
        guard reserveNode(depth: depth, budget: &budget) else { return nil }

        let base: MathExpressionNode
        switch atom.type {
        case .number:
            base = MathExpressionNode(kind: .number, value: atom.nucleus)
        case .largeOperator:
            base = MathExpressionNode(kind: .largeOperator, value: atom.nucleus)
        case .fraction:
            guard let fraction = atom as? MTFraction,
                  let numeratorList = fraction.numerator,
                  let denominatorList = fraction.denominator,
                  let numerator = makeSequence(from: numeratorList, depth: depth + 1, budget: &budget),
                  let denominator = makeSequence(from: denominatorList, depth: depth + 1, budget: &budget) else {
                return unknownNode(for: atom)
            }
            base = MathExpressionNode(kind: .fraction,
                                      value: fraction.hasRule ? nil : "noRule",
                                      numerator: numerator,
                                      denominator: denominator,
                                      isComplete: numerator.isComplete && denominator.isComplete)
        case .radical:
            guard let radical = atom as? MTRadical,
                  let radicandList = radical.radicand,
                  let radicand = makeSequence(from: radicandList, depth: depth + 1, budget: &budget) else {
                return unknownNode(for: atom)
            }
            let degree = radical.degree.flatMap { makeSequence(from: $0, depth: depth + 1, budget: &budget) }
            base = MathExpressionNode(kind: .root,
                                      radicand: radicand,
                                      degree: degree,
                                      isComplete: radicand.isComplete && (degree?.isComplete ?? true))
        case .table:
            guard let table = atom as? MTMathTable else { return unknownNode(for: atom) }
            var rows: [[MathExpressionNode]] = []
            for row in table.cells {
                var cells: [MathExpressionNode] = []
                for cell in row {
                    guard let cellNode = makeSequence(from: cell, depth: depth + 1, budget: &budget) else { return nil }
                    cells.append(cellNode)
                }
                rows.append(cells)
            }
            base = MathExpressionNode(kind: .matrix,
                                      value: table.environment,
                                      rows: rows,
                                      isComplete: rows.joined().allSatisfy(\.isComplete))
        case .inner:
            guard let inner = atom as? MTInner,
                  let innerList = inner.innerList,
                  let content = makeSequence(from: innerList, depth: depth + 1, budget: &budget) else {
                return unknownNode(for: atom)
            }
            guard content.isComplete else { return unknownNode(for: atom) }
            var children: [MathExpressionNode] = []
            if let left = inner.leftBoundary {
                children.append(MathExpressionNode(kind: .symbol, value: left.nucleus))
            }
            children.append(contentsOf: content.children)
            if let right = inner.rightBoundary {
                children.append(MathExpressionNode(kind: .symbol, value: right.nucleus))
            }
            base = MathExpressionNode(kind: .sequence, children: children, isComplete: content.isComplete)
        case .ordinary, .variable, .binaryOperator, .unaryOperator, .relation, .open, .close, .punctuation, .boundary:
            base = MathExpressionNode(kind: .symbol, value: atom.nucleus)
        default:
            return unknownNode(for: atom)
        }

        guard atom.subScript != nil || atom.superScript != nil else { return base }
        let subscriptExpression = atom.subScript.flatMap { makeSequence(from: $0, depth: depth + 1, budget: &budget) }
        let superscriptExpression = atom.superScript.flatMap { makeSequence(from: $0, depth: depth + 1, budget: &budget) }
        return MathExpressionNode(kind: .scripts,
                                  base: base,
                                  subscriptExpression: subscriptExpression,
                                  superscriptExpression: superscriptExpression,
                                  isComplete: base.isComplete &&
                                    (subscriptExpression?.isComplete ?? true) &&
                                    (superscriptExpression?.isComplete ?? true))
    }

    private static func unknownNode(for atom: MTMathAtom) -> MathExpressionNode {
        let latex = MTMathListBuilder.mathListToString(MTMathList(atom: atom))
        let preservedValue = latex.isEmpty || latex == "{}" ? "\(atom.type.description):\(atom.nucleus)" : latex
        return MathExpressionNode(kind: .unknown, value: preservedValue, isComplete: false)
    }

    private static func reserveNode(depth: Int, budget: inout ASTBudget) -> Bool {
        guard depth <= maximumASTDepth else {
            budget.exceeded = true
            return false
        }
        budget.nodeCount += 1
        guard budget.nodeCount <= maximumASTNodes else {
            budget.exceeded = true
            return false
        }
        return true
    }

    private static func losslessUnicode(for sourceText: String,
                                        ast: MathExpressionNode,
                                        containsRawLatex: Bool) -> String? {
        guard !containsRawLatex,
              !sourceText.contains("^") && !sourceText.contains("_"),
              !containsTwoDimensionalStructure(ast) else {
            return nil
        }
        return sourceText
    }

    private static func containsTwoDimensionalStructure(_ node: MathExpressionNode) -> Bool {
        if node.kind == .fraction || node.kind == .matrix { return true }
        if let base = node.base, containsTwoDimensionalStructure(base) { return true }
        if let numerator = node.numerator, containsTwoDimensionalStructure(numerator) { return true }
        if let denominator = node.denominator, containsTwoDimensionalStructure(denominator) { return true }
        if let radicand = node.radicand, containsTwoDimensionalStructure(radicand) { return true }
        if let degree = node.degree, containsTwoDimensionalStructure(degree) { return true }
        if let subscriptExpression = node.subscriptExpression,
           containsTwoDimensionalStructure(subscriptExpression) { return true }
        if let superscriptExpression = node.superscriptExpression,
           containsTwoDimensionalStructure(superscriptExpression) { return true }
        if node.children.contains(where: containsTwoDimensionalStructure) { return true }
        if let rows = node.rows, rows.joined().contains(where: containsTwoDimensionalStructure) { return true }
        return false
    }
}

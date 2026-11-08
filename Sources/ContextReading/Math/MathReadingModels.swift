import Foundation

public enum MathReadingStatus: String, Codable, Sendable {
    case parsedText
    case needsReview
}

public struct MathReadingResult: Equatable, Codable, Sendable {
    public let sourceText: String
    public let latex: String?
    public let unicode: String?
    public let explanation: String
    public let status: MathReadingStatus
    public let ast: MathExpressionNode?

    public init(sourceText: String,
                latex: String?,
                unicode: String?,
                explanation: String,
                status: MathReadingStatus,
                ast: MathExpressionNode?) {
        self.sourceText = sourceText
        self.latex = latex
        self.unicode = unicode
        self.explanation = explanation
        self.status = status
        self.ast = ast
    }
}

public indirect enum MathExpressionNode: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case symbol
        case number
        case sequence
        case scripts
        case fraction
        case root
        case matrix
        case largeOperator
        case unknown
    }

    case symbol(String)
    case number(String)
    case sequence([MathExpressionNode])
    case scripts(base: MathExpressionNode,
                 subscriptExpression: MathExpressionNode?,
                 superscriptExpression: MathExpressionNode?)
    case fraction(numerator: MathExpressionNode, denominator: MathExpressionNode, value: String?)
    case root(radicand: MathExpressionNode, degree: MathExpressionNode?)
    case matrix(value: String?, rows: [[MathExpressionNode]])
    case largeOperator(String)
    case unknown(String?)

    public var kind: Kind {
        switch self {
        case .symbol: return .symbol
        case .number: return .number
        case .sequence: return .sequence
        case .scripts: return .scripts
        case .fraction: return .fraction
        case .root: return .root
        case .matrix: return .matrix
        case .largeOperator: return .largeOperator
        case .unknown: return .unknown
        }
    }

    public var value: String? {
        switch self {
        case .symbol(let value), .number(let value), .largeOperator(let value): return value
        case .fraction(_, _, let value), .matrix(let value, _), .unknown(let value): return value
        default: return nil
        }
    }

    public var children: [MathExpressionNode] {
        switch self {
        case .sequence(let children): return children
        case .scripts(let base, _, _): return [base]
        case .fraction(let numerator, let denominator, _): return [numerator, denominator]
        case .root(let radicand, let degree): return [radicand] + (degree.map { [$0] } ?? [])
        default: return []
        }
    }

    public var base: MathExpressionNode? {
        guard case .scripts(let base, _, _) = self else { return nil }
        return base
    }

    public var subscriptExpression: MathExpressionNode? {
        guard case .scripts(_, let expression, _) = self else { return nil }
        return expression
    }

    public var superscriptExpression: MathExpressionNode? {
        guard case .scripts(_, _, let expression) = self else { return nil }
        return expression
    }

    public var numerator: MathExpressionNode? {
        guard case .fraction(let numerator, _, _) = self else { return nil }
        return numerator
    }

    public var denominator: MathExpressionNode? {
        guard case .fraction(_, let denominator, _) = self else { return nil }
        return denominator
    }

    public var radicand: MathExpressionNode? {
        guard case .root(let radicand, _) = self else { return nil }
        return radicand
    }

    public var degree: MathExpressionNode? {
        guard case .root(_, let degree) = self else { return nil }
        return degree
    }

    public var rows: [[MathExpressionNode]]? {
        guard case .matrix(_, let rows) = self else { return nil }
        return rows
    }

    public var isComplete: Bool {
        switch self {
        case .unknown:
            return false
        case .symbol(let value), .number(let value), .largeOperator(let value):
            return !value.isEmpty
        case .sequence(let children):
            return !children.isEmpty && children.allSatisfy(\.isComplete)
        case .scripts(let base, let subscriptExpression, let superscriptExpression):
            return base.isComplete && (subscriptExpression?.isComplete ?? true) && (superscriptExpression?.isComplete ?? true)
        case .fraction(let numerator, let denominator, _):
            return numerator.isComplete && denominator.isComplete
        case .root(let radicand, let degree):
            return radicand.isComplete && (degree?.isComplete ?? true)
        case .matrix(_, let rows):
            return !rows.isEmpty && rows.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isComplete) }
        }
    }

    public init(kind: Kind,
                value: String? = nil,
                children: [MathExpressionNode] = [],
                base: MathExpressionNode? = nil,
                subscriptExpression: MathExpressionNode? = nil,
                superscriptExpression: MathExpressionNode? = nil,
                numerator: MathExpressionNode? = nil,
                denominator: MathExpressionNode? = nil,
                radicand: MathExpressionNode? = nil,
                degree: MathExpressionNode? = nil,
                rows: [[MathExpressionNode]]? = nil,
                isComplete: Bool = true) {
        _ = isComplete
        switch kind {
        case .symbol: self = .symbol(value ?? "")
        case .number: self = .number(value ?? "")
        case .sequence: self = .sequence(children)
        case .scripts:
            if let base {
                self = .scripts(base: base,
                                subscriptExpression: subscriptExpression,
                                superscriptExpression: superscriptExpression)
            } else {
                self = .unknown(value)
            }
        case .fraction:
            if let numerator, let denominator {
                self = .fraction(numerator: numerator, denominator: denominator, value: value)
            } else {
                self = .unknown(value)
            }
        case .root:
            if let radicand {
                self = .root(radicand: radicand, degree: degree)
            } else {
                self = .unknown(value)
            }
        case .matrix: self = .matrix(value: value, rows: rows ?? [])
        case .largeOperator: self = .largeOperator(value ?? "")
        case .unknown: self = .unknown(value)
        }
    }
}

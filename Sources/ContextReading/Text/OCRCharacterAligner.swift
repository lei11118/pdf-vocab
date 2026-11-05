import Foundation

struct OCRCharacterAlignmentMatch: Equatable, Sendable {
    let sourceSpan: UTF16Span
    let fastSpan: UTF16Span
}

struct OCRCharacterAlignment: Equatable, Sendable {
    let distance: Int
    let matches: [OCRCharacterAlignmentMatch]
}

enum OCRCharacterAlignmentRejection: Error, Equatable, Sendable {
    case sourceUTF16LimitExceeded
    case fastUTF16LimitExceeded
    case sourceGraphemeLimitExceeded
    case fastGraphemeLimitExceeded
    case invalidSourceSegmentation
    case invalidFastSegmentation
    case inconsistentOptimalAlignment
}

enum OCRCharacterAlignmentOutcome: Equatable, Sendable {
    case aligned(OCRCharacterAlignment)
    case rejected(OCRCharacterAlignmentRejection)
}

/// Maps raw-exact composed characters from an accurate OCR line to a fast OCR
/// line. Ambiguous or changed characters are deliberately left unmapped.
enum OCRCharacterAligner {
    static let maximumGraphemes = 256
    static let maximumUTF16Units = 4096

    private struct Grapheme {
        let span: UTF16Span
        let rawUTF16: [UInt16]
    }

    static func align(source: String, fast: String) -> OCRCharacterAlignmentOutcome {
        let sourceGraphemes: [Grapheme]
        switch graphemes(in: source, side: .source) {
        case .success(let value): sourceGraphemes = value
        case .failure(let error): return .rejected(error)
        }

        let fastGraphemes: [Grapheme]
        switch graphemes(in: fast, side: .fast) {
        case .success(let value): fastGraphemes = value
        case .failure(let error): return .rejected(error)
        }

        let sourceCount = sourceGraphemes.count
        let fastCount = fastGraphemes.count
        var forward = Array(repeating: Array(repeating: 0, count: fastCount + 1),
                            count: sourceCount + 1)
        for sourceIndex in 0...sourceCount { forward[sourceIndex][0] = sourceIndex }
        for fastIndex in 0...fastCount { forward[0][fastIndex] = fastIndex }

        for sourceIndex in 1..<(sourceCount + 1) {
            for fastIndex in 1..<(fastCount + 1) {
                let substitutionCost = rawEqual(sourceGraphemes[sourceIndex - 1],
                                                fastGraphemes[fastIndex - 1]) ? 0 : 1
                forward[sourceIndex][fastIndex] = min(
                    min(forward[sourceIndex - 1][fastIndex] + 1,
                        forward[sourceIndex][fastIndex - 1] + 1),
                    forward[sourceIndex - 1][fastIndex - 1] + substitutionCost
                )
            }
        }

        var backward = Array(repeating: Array(repeating: 0, count: fastCount + 1),
                             count: sourceCount + 1)
        for sourceIndex in stride(from: sourceCount, through: 0, by: -1) {
            for fastIndex in stride(from: fastCount, through: 0, by: -1) {
                if sourceIndex == sourceCount && fastIndex == fastCount { continue }
                var best = Int.max
                if sourceIndex < sourceCount {
                    best = min(best, 1 + backward[sourceIndex + 1][fastIndex])
                }
                if fastIndex < fastCount {
                    best = min(best, 1 + backward[sourceIndex][fastIndex + 1])
                }
                if sourceIndex < sourceCount && fastIndex < fastCount {
                    let substitutionCost = rawEqual(sourceGraphemes[sourceIndex],
                                                    fastGraphemes[fastIndex]) ? 0 : 1
                    best = min(best, substitutionCost + backward[sourceIndex + 1][fastIndex + 1])
                }
                backward[sourceIndex][fastIndex] = best
            }
        }

        let distance = forward[sourceCount][fastCount]
        var sourceHasNonExactOptimalEdge = Array(repeating: false, count: sourceCount)
        var fastHasNonExactOptimalEdge = Array(repeating: false, count: fastCount)
        var sourceExactMatchCount = Array(repeating: 0, count: sourceCount)
        var sourceExactFastIndex = Array<Int?>(repeating: nil, count: sourceCount)
        var fastExactMatchCount = Array(repeating: 0, count: fastCount)
        var fastExactSourceIndex = Array<Int?>(repeating: nil, count: fastCount)

        for sourceIndex in 0..<sourceCount {
            for fastIndex in 0...fastCount {
                if forward[sourceIndex][fastIndex] + 1 + backward[sourceIndex + 1][fastIndex] == distance {
                    sourceHasNonExactOptimalEdge[sourceIndex] = true // deletion
                }
            }
        }
        for fastIndex in 0..<fastCount {
            for sourceIndex in 0...sourceCount {
                if forward[sourceIndex][fastIndex] + 1 + backward[sourceIndex][fastIndex + 1] == distance {
                    fastHasNonExactOptimalEdge[fastIndex] = true // insertion
                }
            }
        }
        for sourceIndex in 0..<sourceCount {
            for fastIndex in 0..<fastCount {
                let isExact = rawEqual(sourceGraphemes[sourceIndex], fastGraphemes[fastIndex])
                let edgeCost = isExact ? 0 : 1
                guard forward[sourceIndex][fastIndex] + edgeCost
                        + backward[sourceIndex + 1][fastIndex + 1] == distance else { continue }
                if isExact {
                    sourceExactMatchCount[sourceIndex] += 1
                    sourceExactFastIndex[sourceIndex] = fastIndex
                    fastExactMatchCount[fastIndex] += 1
                    fastExactSourceIndex[fastIndex] = sourceIndex
                } else {
                    sourceHasNonExactOptimalEdge[sourceIndex] = true // substitution
                    fastHasNonExactOptimalEdge[fastIndex] = true
                }
            }
        }

        var matches: [OCRCharacterAlignmentMatch] = []
        var previousFastIndex = -1
        for sourceIndex in 0..<sourceCount {
            guard !sourceHasNonExactOptimalEdge[sourceIndex],
                  sourceExactMatchCount[sourceIndex] == 1,
                  let fastIndex = sourceExactFastIndex[sourceIndex],
                  !fastHasNonExactOptimalEdge[fastIndex],
                  fastExactMatchCount[fastIndex] == 1,
                  fastExactSourceIndex[fastIndex] == sourceIndex else { continue }
            guard fastIndex > previousFastIndex else {
                return .rejected(.inconsistentOptimalAlignment)
            }
            previousFastIndex = fastIndex
            matches.append(OCRCharacterAlignmentMatch(sourceSpan: sourceGraphemes[sourceIndex].span,
                                                      fastSpan: fastGraphemes[fastIndex].span))
        }

        return .aligned(OCRCharacterAlignment(distance: distance, matches: matches))
    }

    private enum Side: Equatable {
        case source
        case fast
    }

    private static func graphemes(in text: String,
                                  side: Side) -> Swift.Result<[Grapheme], OCRCharacterAlignmentRejection> {
        let nsText = text as NSString
        guard nsText.length <= maximumUTF16Units else {
            return .failure(side == .source ? .sourceUTF16LimitExceeded : .fastUTF16LimitExceeded)
        }

        var output: [Grapheme] = []
        var offset = 0
        while offset < nsText.length {
            let range = nsText.rangeOfComposedCharacterSequence(at: offset)
            guard range.location == offset,
                  range.length > 0,
                  range.length <= nsText.length - offset else {
                return .failure(side == .source ? .invalidSourceSegmentation : .invalidFastSegmentation)
            }
            output.append(Grapheme(span: UTF16Span(location: offset, length: range.length),
                                   rawUTF16: (0..<range.length).map { nsText.character(at: offset + $0) }))
            guard output.count <= maximumGraphemes else {
                return .failure(side == .source ? .sourceGraphemeLimitExceeded : .fastGraphemeLimitExceeded)
            }
            offset += range.length
        }
        return .success(output)
    }

    private static func rawEqual(_ lhs: Grapheme, _ rhs: Grapheme) -> Bool {
        lhs.rawUTF16.elementsEqual(rhs.rawUTF16)
    }
}

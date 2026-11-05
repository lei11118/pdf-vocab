import Foundation
import XCTest
@testable import PdfVocab

final class OCRCharacterAlignmentTests: XCTestCase {
    func testExactHelloMapsEveryRawGraphemeDespiteRepeatedLetters() {
        let result = aligned(source: "hello", fast: "hello")

        XCTAssertEqual(result.distance, 0)
        XCTAssertEqual(result.matches.map(\.sourceSpan), (0..<5).map { UTF16Span(location: $0, length: 1) })
        XCTAssertEqual(result.matches.map(\.fastSpan), (0..<5).map { UTF16Span(location: $0, length: 1) })
    }

    func testRepeatedSourceGraphemeAgainstSingleTargetIsAmbiguous() {
        let result = aligned(source: "aa", fast: "a")

        XCTAssertEqual(result.distance, 1)
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testCrossingExactCandidatesAreNotAccepted() {
        let result = aligned(source: "ab", fast: "ba")

        XCTAssertEqual(result.distance, 2)
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testDeletionAndSubstitutionKeepOnlyMandatoryExactMatches() {
        let deletion = aligned(source: "abc", fast: "ac")
        XCTAssertEqual(deletion.distance, 1)
        XCTAssertEqual(deletion.matches.map(\.sourceSpan), [UTF16Span(location: 0, length: 1),
                                                              UTF16Span(location: 2, length: 1)])
        XCTAssertEqual(deletion.matches.map(\.fastSpan), [UTF16Span(location: 0, length: 1),
                                                            UTF16Span(location: 1, length: 1)])

        let substitution = aligned(source: "abc", fast: "axc")
        XCTAssertEqual(substitution.distance, 1)
        XCTAssertEqual(substitution.matches.map(\.sourceSpan), [UTF16Span(location: 0, length: 1),
                                                                  UTF16Span(location: 2, length: 1)])
        XCTAssertEqual(substitution.matches.map(\.fastSpan), [UTF16Span(location: 0, length: 1),
                                                               UTF16Span(location: 2, length: 1)])
    }

    func testInsertionShiftsFastUTF16SpansWithoutChangingSourceSpans() {
        let result = aligned(source: "abc", fast: "aXbc")

        XCTAssertEqual(result.distance, 1)
        XCTAssertEqual(result.matches.map(\.sourceSpan), (0..<3).map { UTF16Span(location: $0, length: 1) })
        XCTAssertEqual(result.matches.map(\.fastSpan), [UTF16Span(location: 0, length: 1),
                                                         UTF16Span(location: 2, length: 1),
                                                         UTF16Span(location: 3, length: 1)])
    }

    func testRawUnicodeGraphemesKeepExactUTF16RangesAndRejectNormalizationEquivalence() {
        let scientist = "\u{1F469}\u{200D}\u{1F52C}"
        let decomposed = "e\u{0301}\(scientist)x"
        let exact = aligned(source: decomposed, fast: decomposed)

        XCTAssertEqual(exact.distance, 0)
        XCTAssertEqual(exact.matches.map(\.sourceSpan), [UTF16Span(location: 0, length: 2),
                                                           UTF16Span(location: 2, length: 5),
                                                           UTF16Span(location: 7, length: 1)])
        XCTAssertEqual(exact.matches.map(\.fastSpan), exact.matches.map(\.sourceSpan))

        let normalizedPair = aligned(source: "e\u{0301}", fast: "\u{00E9}")
        XCTAssertEqual(normalizedPair.distance, 1)
        XCTAssertTrue(normalizedPair.matches.isEmpty,
                      "Canonically equivalent strings with different UTF-16 must not source-map")
    }

    func testLookalikesAreNotNormalizedOrMapped() {
        let multiplication = aligned(source: "x", fast: "\u{00D7}")
        XCTAssertEqual(multiplication.distance, 1)
        XCTAssertTrue(multiplication.matches.isEmpty)

        let greekNu = aligned(source: "\u{03BD}", fast: "v")
        XCTAssertEqual(greekNu.distance, 1)
        XCTAssertTrue(greekNu.matches.isEmpty)
    }

    func testEmptyInputsReturnExactDistanceAndNoMatches() {
        let bothEmpty = aligned(source: "", fast: "")
        XCTAssertEqual(bothEmpty.distance, 0)
        XCTAssertTrue(bothEmpty.matches.isEmpty)

        let emptyFast = aligned(source: "a", fast: "")
        XCTAssertEqual(emptyFast.distance, 1)
        XCTAssertTrue(emptyFast.matches.isEmpty)

        let emptySource = aligned(source: "", fast: "b")
        XCTAssertEqual(emptySource.distance, 1)
        XCTAssertTrue(emptySource.matches.isEmpty)
    }

    func testInputLimitsRejectInsteadOfSilentlyTruncating() {
        XCTAssertEqual(OCRCharacterAligner.align(source: String(repeating: "a", count: 257), fast: ""),
                       .rejected(.sourceGraphemeLimitExceeded))
        XCTAssertEqual(OCRCharacterAligner.align(source: String(repeating: "c", count: 4097), fast: ""),
                       .rejected(.sourceUTF16LimitExceeded))
        XCTAssertEqual(OCRCharacterAligner.align(source: "", fast: String(repeating: "b", count: 257)),
                       .rejected(.fastGraphemeLimitExceeded))
        XCTAssertEqual(OCRCharacterAligner.align(source: "", fast: String(repeating: "c", count: 4097)),
                       .rejected(.fastUTF16LimitExceeded))
    }

    func testAlignmentMatchesExhaustiveOptimalPathOracleForShortBinaryStrings() {
        let candidates = shortStrings(alphabet: ["a", "b"], maximumLength: 3)
        XCTAssertEqual(candidates.count, 15)

        var comparisons = 0
        for source in candidates {
            for fast in candidates {
                let oracle = exhaustiveOracle(source: source, fast: fast)
                let actual = OCRCharacterAligner.align(source: source, fast: fast)
                guard case .aligned(let alignment) = actual else {
                    XCTFail("Unexpected rejection for source=\(source.debugDescription), fast=\(fast.debugDescription): \(actual)")
                    continue
                }

                XCTAssertEqual(alignment.distance, oracle.distance,
                               "Distance mismatch for source=\(source.debugDescription), fast=\(fast.debugDescription)")
                let actualPairs = Set(alignment.matches.map {
                    OracleMatch(sourceIndex: $0.sourceSpan.location, fastIndex: $0.fastSpan.location)
                })
                XCTAssertEqual(actualPairs, oracle.mandatoryMatches,
                               "Mandatory exact-match mismatch for source=\(source.debugDescription), fast=\(fast.debugDescription)")
                comparisons += 1
            }
        }
        XCTAssertEqual(comparisons, 225)
    }

    private func aligned(source: String,
                         fast: String,
                         file: StaticString = #filePath,
                         line: UInt = #line) -> OCRCharacterAlignment {
        switch OCRCharacterAligner.align(source: source, fast: fast) {
        case .aligned(let alignment): return alignment
        case .rejected(let rejection):
            XCTFail("Unexpected OCR character alignment rejection: \(rejection)", file: file, line: line)
            return OCRCharacterAlignment(distance: -1, matches: [])
        }
    }

    private struct OracleMatch: Hashable {
        let sourceIndex: Int
        let fastIndex: Int
    }

    private struct OraclePath {
        let cost: Int
        let exactMatches: Set<OracleMatch>
    }

    private struct OracleResult {
        let distance: Int
        let mandatoryMatches: Set<OracleMatch>
    }

    private func shortStrings(alphabet: [Character], maximumLength: Int) -> [String] {
        var result: [String] = []
        func append(prefix: String, remaining: Int) {
            result.append(prefix)
            guard remaining > 0 else { return }
            for character in alphabet {
                append(prefix: prefix + String(character), remaining: remaining - 1)
            }
        }
        append(prefix: "", remaining: maximumLength)
        return result
    }

    private func exhaustiveOracle(source: String, fast: String) -> OracleResult {
        let sourceCharacters = Array(source)
        let fastCharacters = Array(fast)

        func enumerate(sourceIndex: Int,
                       fastIndex: Int,
                       cost: Int,
                       exactMatches: Set<OracleMatch>) -> [OraclePath] {
            if sourceIndex == sourceCharacters.count && fastIndex == fastCharacters.count {
                return [OraclePath(cost: cost, exactMatches: exactMatches)]
            }

            var paths: [OraclePath] = []
            if sourceIndex < sourceCharacters.count {
                paths += enumerate(sourceIndex: sourceIndex + 1,
                                   fastIndex: fastIndex,
                                   cost: cost + 1,
                                   exactMatches: exactMatches)
            }
            if fastIndex < fastCharacters.count {
                paths += enumerate(sourceIndex: sourceIndex,
                                   fastIndex: fastIndex + 1,
                                   cost: cost + 1,
                                   exactMatches: exactMatches)
            }
            if sourceIndex < sourceCharacters.count && fastIndex < fastCharacters.count {
                let isExact = sourceCharacters[sourceIndex] == fastCharacters[fastIndex]
                var nextMatches = exactMatches
                if isExact {
                    nextMatches.insert(OracleMatch(sourceIndex: sourceIndex, fastIndex: fastIndex))
                }
                paths += enumerate(sourceIndex: sourceIndex + 1,
                                   fastIndex: fastIndex + 1,
                                   cost: cost + (isExact ? 0 : 1),
                                   exactMatches: nextMatches)
            }
            return paths
        }

        let paths = enumerate(sourceIndex: 0, fastIndex: 0, cost: 0, exactMatches: [])
        let distance = paths.map(\.cost).min() ?? 0
        let optimalPaths = paths.filter { $0.cost == distance }
        let mandatoryMatches = optimalPaths.dropFirst().reduce(optimalPaths[0].exactMatches) {
            $0.intersection($1.exactMatches)
        }
        return OracleResult(distance: distance, mandatoryMatches: mandatoryMatches)
    }
}

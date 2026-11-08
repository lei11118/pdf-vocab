import XCTest
@testable import PdfVocab

final class AlignmentEvaluationTests: XCTestCase {
    func testMultiSourcePhraseToOneTargetCanBeScoredAsExactLinks() {
        let read = UTF16Span(location: 4, length: 4)
        let books = UTF16Span(location: 9, length: 5)
        let phraseTarget = UTF16Span(location: 2, length: 4)
        let reference: Set<AlignmentEvaluationLink> = [
            .init(sourceOccurrence: read, targetSpan: phraseTarget),
            .init(sourceOccurrence: books, targetSpan: phraseTarget)
        ]

        let metrics = AlignmentEvaluationMetrics.evaluate(predictedLinks: reference,
                                                          referenceLinks: reference,
                                                          sourceOccurrences: [read, books])

        XCTAssertEqual(metrics.precision, 1.0)
        XCTAssertEqual(metrics.recall, 1.0)
        XCTAssertEqual(metrics.f1, 1.0)
        XCTAssertEqual(metrics.coverage, 1.0)
        XCTAssertEqual(metrics.rejectionRate, 0.0)
    }

    func testRepeatedSpellingsRemainSeparateBySourceOccurrenceSpan() {
        let firstRead = UTF16Span(location: 4, length: 4)
        let secondRead = UTF16Span(location: 15, length: 4)
        let firstTarget = UTF16Span(location: 0, length: 2)
        let secondTarget = UTF16Span(location: 4, length: 2)
        let reference: Set<AlignmentEvaluationLink> = [
            .init(sourceOccurrence: firstRead, targetSpan: firstTarget),
            .init(sourceOccurrence: secondRead, targetSpan: secondTarget)
        ]
        let prediction: Set<AlignmentEvaluationLink> = [
            .init(sourceOccurrence: firstRead, targetSpan: firstTarget),
            .init(sourceOccurrence: secondRead, targetSpan: firstTarget)
        ]

        let metrics = AlignmentEvaluationMetrics.evaluate(predictedLinks: prediction,
                                                          referenceLinks: reference,
                                                          sourceOccurrences: [firstRead, secondRead])

        XCTAssertEqual(metrics.truePositiveLinks, 1)
        XCTAssertEqual(metrics.precision, 0.5)
        XCTAssertEqual(metrics.recall, 0.5)
        XCTAssertEqual(metrics.f1, 0.5)
        XCTAssertEqual(metrics.coverage, 1.0)
        XCTAssertEqual(metrics.rejectionRate, 0.0)
    }

    func testUnmappedOccurrenceContributesToCoverageAndRejectionRate() throws {
        let first = UTF16Span(location: 0, length: 3)
        let second = UTF16Span(location: 5, length: 3)
        let third = UTF16Span(location: 10, length: 4)
        let firstTarget = UTF16Span(location: 0, length: 2)
        let secondTarget = UTF16Span(location: 4, length: 2)
        let incorrectTarget = UTF16Span(location: 7, length: 2)
        let reference: Set<AlignmentEvaluationLink> = [
            .init(sourceOccurrence: first, targetSpan: firstTarget),
            .init(sourceOccurrence: second, targetSpan: secondTarget)
        ]
        let prediction: Set<AlignmentEvaluationLink> = [
            .init(sourceOccurrence: first, targetSpan: firstTarget),
            .init(sourceOccurrence: second, targetSpan: incorrectTarget)
        ]

        let metrics = AlignmentEvaluationMetrics.evaluate(predictedLinks: prediction,
                                                          referenceLinks: reference,
                                                          sourceOccurrences: [first, second, third])

        XCTAssertEqual(metrics.precision, 0.5)
        XCTAssertEqual(metrics.recall, 0.5)
        XCTAssertEqual(metrics.f1, 0.5)
        XCTAssertEqual(try XCTUnwrap(metrics.coverage), 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(metrics.rejectionRate), 1.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(metrics.alignedSourceOccurrenceCount, 2)
    }

    func testEmptyDenominatorsAreNilAndNonemptyReferenceWithNoPredictionScoresZero() {
        let empty = AlignmentEvaluationMetrics.evaluate(predictedLinks: [],
                                                        referenceLinks: [],
                                                        sourceOccurrences: [])
        XCTAssertNil(empty.precision)
        XCTAssertNil(empty.recall)
        XCTAssertNil(empty.f1)
        XCTAssertNil(empty.coverage)
        XCTAssertNil(empty.rejectionRate)

        let source = UTF16Span(location: 2, length: 3)
        let reference: Set<AlignmentEvaluationLink> = [
            .init(sourceOccurrence: source, targetSpan: UTF16Span(location: 0, length: 2))
        ]
        let noPrediction = AlignmentEvaluationMetrics.evaluate(predictedLinks: [],
                                                               referenceLinks: reference,
                                                               sourceOccurrences: [source])
        XCTAssertNil(noPrediction.precision)
        XCTAssertEqual(noPrediction.recall, 0.0)
        XCTAssertEqual(noPrediction.f1, 0.0)
        XCTAssertEqual(noPrediction.coverage, 0.0)
        XCTAssertEqual(noPrediction.rejectionRate, 1.0)
    }
}

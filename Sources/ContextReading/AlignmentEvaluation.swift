import Foundation

/// One exact occurrence-to-target alignment. Source spans distinguish repeated
/// spellings, and target spans distinguish separate translated occurrences.
struct AlignmentEvaluationLink: Hashable, Sendable {
    let sourceOccurrence: UTF16Span
    let targetSpan: UTF16Span

    init(sourceOccurrence: UTF16Span, targetSpan: UTF16Span) {
        self.sourceOccurrence = sourceOccurrence
        self.targetSpan = targetSpan
    }
}

struct AlignmentEvaluationMetrics: Equatable, Sendable {
    let precision: Double?
    let recall: Double?
    let f1: Double?
    let coverage: Double?
    let rejectionRate: Double?
    let truePositiveLinks: Int
    let predictedLinkCount: Int
    let referenceLinkCount: Int
    let sourceOccurrenceCount: Int
    let alignedSourceOccurrenceCount: Int

    /// Precision and recall are nil when their own denominator is empty. F1
    /// is nil only when both link sets are empty; otherwise it is 0...1. Coverage
    /// counts source occurrences with at least one predicted link, regardless
    /// of correctness. Rejection rate is its complement over supplied source
    /// occurrences. Coverage and rejection are nil when that set is empty.
    static func evaluate(predictedLinks: Set<AlignmentEvaluationLink>,
                         referenceLinks: Set<AlignmentEvaluationLink>,
                         sourceOccurrences: Set<UTF16Span>) -> AlignmentEvaluationMetrics {
        let truePositives = predictedLinks.intersection(referenceLinks).count
        let precision = predictedLinks.isEmpty
            ? nil
            : Double(truePositives) / Double(predictedLinks.count)
        let recall = referenceLinks.isEmpty
            ? nil
            : Double(truePositives) / Double(referenceLinks.count)
        let combinedLinkCount = predictedLinks.count + referenceLinks.count
        let f1 = combinedLinkCount == 0
            ? nil
            : Double(2 * truePositives) / Double(combinedLinkCount)
        let alignedOccurrences = Set(predictedLinks.map(\.sourceOccurrence))
            .intersection(sourceOccurrences)
        let coverage = sourceOccurrences.isEmpty
            ? nil
            : Double(alignedOccurrences.count) / Double(sourceOccurrences.count)
        let rejectionRate = sourceOccurrences.isEmpty
            ? nil
            : Double(sourceOccurrences.count - alignedOccurrences.count) / Double(sourceOccurrences.count)

        return AlignmentEvaluationMetrics(precision: precision,
                                          recall: recall,
                                          f1: f1,
                                          coverage: coverage,
                                          rejectionRate: rejectionRate,
                                          truePositiveLinks: truePositives,
                                          predictedLinkCount: predictedLinks.count,
                                          referenceLinkCount: referenceLinks.count,
                                          sourceOccurrenceCount: sourceOccurrences.count,
                                          alignedSourceOccurrenceCount: alignedOccurrences.count)
    }
}

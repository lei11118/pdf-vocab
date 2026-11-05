import Foundation
import PDFKit
import Vision

struct OCRCharacterFastSpanEvidence: Equatable, Sendable {
    let fastSpan: UTF16Span
    let pageRect: SourceRect?
}

struct OCRCharacterFastObservationEvidence: Equatable, Sendable {
    let ordinal: Int
    let text: String
    let confidence: Double
    let pageRect: SourceRect?
    let characters: [OCRCharacterFastSpanEvidence]
}

enum OCRCharacterRefinementSource: String, Equatable, Sendable {
    case visionFast
    case mandatoryExactMapping
}

struct OCRCharacterRefinedBox: Equatable, Sendable {
    let sourceSpan: UTF16Span
    let actualRect: SourceRect
    let geometrySource: OCRCharacterRefinementSource
    let mappingSource: OCRCharacterRefinementSource
}

enum OCRCharacterRefinementFallback: Equatable, Sendable {
    case invalidSourceGeometry
    case invalidRegion
    case textLimitExceeded
    case noSpatialCandidate
    case tooManyCandidates(Int)
    case alignmentRejected
    case ambiguousBestObservation
    case noMandatoryExactMatches
    case noTrustedCharacterBoxes
}

struct OCRCharacterRefinementResult: Equatable, Sendable {
    let sourceText: String
    let mediaBox: SourceRect
    let roi: SourceRect
    let observations: [OCRCharacterFastObservationEvidence]
    let selectedObservationOrdinal: Int?
    let boxes: [OCRCharacterRefinedBox]
    let fallback: OCRCharacterRefinementFallback?
}

enum OCRCharacterRefinementError: LocalizedError {
    case invalidMediaBox
    case invalidSourceLine
    case invalidROI
    case renderFailed
    case visionFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidMediaBox: return "PDF page has invalid media bounds"
        case .invalidSourceLine: return "OCR source line has no valid page bounds"
        case .invalidROI: return "OCR character refinement region is invalid"
        case .renderFailed: return "Could not render the OCR line region"
        case .visionFailed(let message): return "Fast Vision OCR failed: \(message)"
        case .cancelled: return "OCR character refinement was cancelled"
        }
    }
}

/// Collects fast Vision character geometry and conservatively maps only exact,
/// mandatory raw-character matches back to the accurate OCR source line.
/// Call synchronously while the owning worker holds the PDFPage; this type
/// never stores or returns PDFKit or Vision objects.
enum OCRCharacterRefiner {
    static let maximumSpatialCandidates = 16

    /// Runs one fast Vision pass over a padded line ROI in canonical media space.
    static func refine(line: OCRLine, on page: PDFPage) throws -> OCRCharacterRefinementResult {
        try Task.checkCancellation()
        guard let sourceRect = line.pageRect?.cgRect,
              isFinitePositive(sourceRect) else {
            throw OCRCharacterRefinementError.invalidSourceLine
        }
        let mediaBounds = page.bounds(for: .mediaBox)
        guard let mediaBox = SourceRect(rect: mediaBounds) else {
            throw OCRCharacterRefinementError.invalidMediaBox
        }
        guard contains(sourceRect, in: mediaBox.cgRect, tolerance: 0.000001) else {
            throw OCRCharacterRefinementError.invalidSourceLine
        }

        let padding = max(2, sourceRect.height * 0.3)
        let roiBounds = sourceRect.insetBy(dx: -padding, dy: -padding).intersection(mediaBox.cgRect)
        guard let roi = SourceRect(rect: roiBounds), roi.width > 1, roi.height > 1 else {
            throw OCRCharacterRefinementError.invalidROI
        }
        guard isWithinAlignmentLimits(line.sourceText) else {
            return result(sourceText: line.sourceText,
                          roi: roi,
                          mediaBox: mediaBox,
                          evidence: [],
                          fallback: .textLimitExceeded)
        }
        let maximumSide = max(roi.width, roi.height)
        let area = roi.width * roi.height
        guard maximumSide.isFinite, maximumSide > 1, area.isFinite, area > 1 else {
            throw OCRCharacterRefinementError.invalidROI
        }
        let factor = min(6, min(5120 / maximumSide, sqrt(10_000_000 / area)))
        let targetSize = CGSize(width: floor(roi.width * factor), height: floor(roi.height * factor))
        guard targetSize.width.isFinite, targetSize.height.isFinite,
              targetSize.width > 1, targetSize.height > 1,
              let image = OCRService.recognitionImage(page: page, size: targetSize, region: roi.cgRect) else {
            throw OCRCharacterRefinementError.renderFailed
        }
        try Task.checkCancellation()

        let evidence = try autoreleasepool {
            try fastEvidence(in: image, roi: roi.cgRect)
        }
        try Task.checkCancellation()
        return validate(line: line, roi: roi, mediaBox: mediaBox, evidence: evidence)
    }

    /// Pure filtering and source mapping. Vision observations and geometry are
    /// immutable values so this path can be tested without running Vision.
    static func validate(line: OCRLine,
                         roi: SourceRect,
                         mediaBox: SourceRect,
                         evidence: [OCRCharacterFastObservationEvidence]) -> OCRCharacterRefinementResult {
        let sourceText = line.sourceText
        guard let sourceLine = line.pageRect?.cgRect, isFinitePositive(sourceLine) else {
            return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                          evidence: evidence, fallback: .invalidSourceGeometry)
        }
        guard isFinitePositive(roi.cgRect), roi.width > 1, roi.height > 1,
              isFinitePositive(mediaBox.cgRect), contains(roi.cgRect, in: mediaBox.cgRect),
              contains(sourceLine, in: mediaBox.cgRect, tolerance: 0.000001),
              contains(sourceLine, in: roi.cgRect, tolerance: 0.000001) else {
            return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                          evidence: evidence, fallback: .invalidRegion)
        }
        guard isWithinAlignmentLimits(sourceText) else {
            return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                          evidence: evidence, fallback: .textLimitExceeded)
        }

        let spatialCandidates = evidence.filter {
            isSameLine($0, sourceLine: sourceLine, roi: roi.cgRect, mediaBox: mediaBox.cgRect)
        }
        guard !spatialCandidates.isEmpty else {
            return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                          evidence: evidence, fallback: .noSpatialCandidate)
        }
        guard spatialCandidates.count <= maximumSpatialCandidates else {
            return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                          evidence: evidence,
                          fallback: .tooManyCandidates(spatialCandidates.count))
        }
        guard spatialCandidates.allSatisfy({ isWithinAlignmentLimits($0.text) }) else {
            return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                          evidence: evidence, fallback: .textLimitExceeded)
        }

        var aligned: [(observation: OCRCharacterFastObservationEvidence, alignment: OCRCharacterAlignment)] = []
        aligned.reserveCapacity(spatialCandidates.count)
        for observation in spatialCandidates {
            switch OCRCharacterAligner.align(source: sourceText, fast: observation.text) {
            case .aligned(let alignment):
                aligned.append((observation, alignment))
            case .rejected:
                return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                              evidence: evidence, fallback: .alignmentRejected)
            }
        }
        guard let bestDistance = aligned.map({ $0.alignment.distance }).min() else {
            return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                          evidence: evidence, fallback: .noSpatialCandidate)
        }
        let bestCandidates = aligned.filter { $0.alignment.distance == bestDistance }
        guard bestCandidates.count == 1, let best = bestCandidates.first else {
            return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                          evidence: evidence, fallback: .ambiguousBestObservation)
        }
        guard !best.alignment.matches.isEmpty else {
            return result(sourceText: sourceText, roi: roi, mediaBox: mediaBox,
                          evidence: evidence,
                          selectedObservationOrdinal: best.observation.ordinal,
                          fallback: .noMandatoryExactMatches)
        }

        let sourceExpanded = expanded(sourceLine, fractionOfHeight: 0.25)
        var provisional: [(span: UTF16Span, rect: SourceRect)] = []
        for match in best.alignment.matches {
            guard best.alignment.matches.filter({ $0.sourceSpan == match.sourceSpan }).count == 1,
                  best.alignment.matches.filter({ $0.fastSpan == match.fastSpan }).count == 1,
                  let sourceRange = match.sourceSpan.composedCharacterRange(in: sourceText),
                  sourceRange.length == match.sourceSpan.length,
                  let fastRange = match.fastSpan.composedCharacterRange(in: best.observation.text),
                  fastRange.length == match.fastSpan.length else { continue }
            let sourceCharacter = (sourceText as NSString).substring(with: sourceRange)
            guard !sourceCharacter.unicodeScalars.allSatisfy({
                CharacterSet.whitespacesAndNewlines.contains($0)
            }) else { continue }

            let mappedCharacters = best.observation.characters.filter { $0.fastSpan == match.fastSpan }
            guard mappedCharacters.count == 1,
                  let rect = mappedCharacters[0].pageRect,
                  contains(rect.cgRect, in: roi.cgRect),
                  contains(rect.cgRect, in: mediaBox.cgRect),
                  contains(rect.cgRect, in: sourceExpanded),
                  passesAccurateWordFrames(for: match.sourceSpan,
                                           line: line,
                                           characterRect: rect.cgRect,
                                           mediaBox: mediaBox.cgRect) else { continue }
            provisional.append((match.sourceSpan, rect))
        }

        let duplicatedSpans = sharedGeometrySpans(provisional)
        let boxes = provisional.compactMap { item -> OCRCharacterRefinedBox? in
            guard !duplicatedSpans.contains(item.span) else { return nil }
            return OCRCharacterRefinedBox(sourceSpan: item.span,
                                          actualRect: item.rect,
                                          geometrySource: .visionFast,
                                          mappingSource: .mandatoryExactMapping)
        }
        return OCRCharacterRefinementResult(sourceText: sourceText,
                                            mediaBox: mediaBox,
                                            roi: roi,
                                            observations: evidence,
                                            selectedObservationOrdinal: best.observation.ordinal,
                                            boxes: boxes,
                                            fallback: boxes.isEmpty ? .noTrustedCharacterBoxes : nil)
    }

    private static func fastEvidence(in image: CGImage,
                                     roi: CGRect) throws -> [OCRCharacterFastObservationEvidence] {
        if Task.isCancelled { throw OCRCharacterRefinementError.cancelled }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if Task.isCancelled { throw OCRCharacterRefinementError.cancelled }
            throw OCRCharacterRefinementError.visionFailed(error.localizedDescription)
        }
        if Task.isCancelled { throw OCRCharacterRefinementError.cancelled }

        var output: [OCRCharacterFastObservationEvidence] = []
        for (ordinal, observation) in (request.results ?? []).enumerated() {
            if Task.isCancelled { throw OCRCharacterRefinementError.cancelled }
            guard let candidate = observation.topCandidates(1).first else { continue }
            let pageRect = ContextOCRGeometry.pageRect(fromVisionNormalized: observation.boundingBox, in: roi)
            let characterEvidence = fastCharacterEvidence(from: candidate, in: roi)
            output.append(OCRCharacterFastObservationEvidence(ordinal: ordinal,
                                                             text: candidate.string,
                                                             confidence: Double(candidate.confidence),
                                                             pageRect: pageRect,
                                                             characters: characterEvidence))
        }
        return output
    }

    private static func fastCharacterEvidence(from candidate: VNRecognizedText,
                                              in roi: CGRect) -> [OCRCharacterFastSpanEvidence] {
        let text = candidate.string
        guard isWithinAlignmentLimits(text) else { return [] }
        let nsText = text as NSString
        var output: [OCRCharacterFastSpanEvidence] = []
        var offset = 0
        while offset < nsText.length {
            let range = nsText.rangeOfComposedCharacterSequence(at: offset)
            guard let span = UTF16Span(composedRange: range, in: text), range.length > 0 else {
                offset += max(1, range.length)
                continue
            }
            let pageRect: SourceRect?
            if let swiftRange = Range(range, in: text),
               let rectangle = try? candidate.boundingBox(for: swiftRange) {
                pageRect = ContextOCRGeometry.pageRect(fromVisionNormalized: rectangle.boundingBox, in: roi)
            } else {
                pageRect = nil
            }
            output.append(OCRCharacterFastSpanEvidence(fastSpan: span, pageRect: pageRect))
            offset += range.length
        }
        return output
    }

    private static func isSameLine(_ observation: OCRCharacterFastObservationEvidence,
                                   sourceLine: CGRect,
                                   roi: CGRect,
                                   mediaBox: CGRect) -> Bool {
        guard let candidate = observation.pageRect?.cgRect,
              isFinitePositive(candidate),
              contains(candidate, in: roi), contains(candidate, in: mediaBox) else { return false }
        let expandedSource = expanded(sourceLine, fractionOfHeight: 0.25)
        let intersection = candidate.intersection(expandedSource)
        guard !intersection.isNull, !intersection.isInfinite,
              intersection.width > 0, intersection.height > 0,
              expandedSource.contains(CGPoint(x: candidate.midX, y: candidate.midY)) else { return false }
        let verticalOverlap = min(candidate.maxY, sourceLine.maxY) - max(candidate.minY, sourceLine.minY)
        return verticalOverlap >= min(candidate.height, sourceLine.height) * 0.5
    }

    private static func passesAccurateWordFrames(for sourceSpan: UTF16Span,
                                                 line: OCRLine,
                                                 characterRect: CGRect,
                                                 mediaBox: CGRect) -> Bool {
        guard let sourceEnd = sourceSpan.endExclusive else { return false }
        let coveringTokens = line.tokens.indices.filter { index in
            let token = line.tokens[index]
            guard let tokenEnd = token.span.endExclusive else { return false }
            return token.span.location <= sourceSpan.location && tokenEnd >= sourceEnd
        }
        guard !coveringTokens.isEmpty else { return true }

        for index in coveringTokens {
            let token = line.tokens[index]
            guard token.span.length > 0,
                  token.span.composedCharacterRange(in: line.sourceText) != nil,
                  let sourceSurface = token.span.substring(in: line.sourceText),
                  sourceSurface.utf16.elementsEqual(token.sourceSurface.utf16),
                  token.blockID == line.blockID else { return false }

            let geometry = index < line.tokenGeometry.count ? line.tokenGeometry[index] : nil
            let tokenClaimsWordFrame = token.geometryQuality == .word
            let geometryClaimsWordFrame = geometry?.quality == .word
            guard tokenClaimsWordFrame == geometryClaimsWordFrame else { return false }
            guard tokenClaimsWordFrame else { continue }
            guard let geometry,
                  geometry.tokenID == token.id, geometry.span == token.span,
                  let wordRect = geometry.rect?.cgRect,
                  isFinitePositive(wordRect), contains(wordRect, in: mediaBox) else { return false }
            let expandedWord = expanded(wordRect, fractionOfHeight: 0.2)
            guard contains(characterRect, in: expandedWord) else { return false }
        }
        return true
    }

    private static func sharedGeometrySpans(_ boxes: [(span: UTF16Span, rect: SourceRect)]) -> Set<UTF16Span> {
        var duplicated = Set<UTF16Span>()
        guard boxes.count > 1 else { return duplicated }
        for firstIndex in 0..<(boxes.count - 1) {
            for secondIndex in (firstIndex + 1)..<boxes.count {
                guard boxes[firstIndex].span != boxes[secondIndex].span,
                      intersectionOverUnion(boxes[firstIndex].rect.cgRect,
                                            boxes[secondIndex].rect.cgRect) >= 0.9 else { continue }
                duplicated.insert(boxes[firstIndex].span)
                duplicated.insert(boxes[secondIndex].span)
            }
        }
        return duplicated
    }

    private static func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> Double {
        let intersection = first.intersection(second)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = first.width * first.height + second.width * second.height - intersectionArea
        guard intersectionArea.isFinite, unionArea.isFinite, unionArea > 0 else { return 0 }
        return Double(intersectionArea / unionArea)
    }

    private static func expanded(_ rect: CGRect, fractionOfHeight: CGFloat) -> CGRect {
        let margin = max(2, rect.height * fractionOfHeight)
        return rect.insetBy(dx: -margin, dy: -margin)
    }

    private static func contains(_ rect: CGRect, in bounds: CGRect) -> Bool {
        isFinitePositive(rect) && isFinitePositive(bounds)
            && rect.minX >= bounds.minX && rect.minY >= bounds.minY
            && rect.maxX <= bounds.maxX && rect.maxY <= bounds.maxY
    }

    private static func contains(_ rect: CGRect, in bounds: CGRect, tolerance: CGFloat) -> Bool {
        isFinitePositive(rect) && isFinitePositive(bounds)
            && rect.minX >= bounds.minX - tolerance && rect.minY >= bounds.minY - tolerance
            && rect.maxX <= bounds.maxX + tolerance && rect.maxY <= bounds.maxY + tolerance
    }

    private static func isWithinAlignmentLimits(_ text: String) -> Bool {
        let nsText = text as NSString
        guard nsText.length <= OCRCharacterAligner.maximumUTF16Units else { return false }
        var count = 0
        var offset = 0
        while offset < nsText.length {
            let range = nsText.rangeOfComposedCharacterSequence(at: offset)
            guard range.location == offset, range.length > 0,
                  range.length <= nsText.length - offset else { return false }
            count += 1
            guard count <= OCRCharacterAligner.maximumGraphemes else { return false }
            offset += range.length
        }
        return true
    }

    private static func isFinitePositive(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
            && !rect.isNull && !rect.isInfinite
    }

    private static func result(sourceText: String,
                               roi: SourceRect,
                               mediaBox: SourceRect,
                               evidence: [OCRCharacterFastObservationEvidence],
                               selectedObservationOrdinal: Int? = nil,
                               fallback: OCRCharacterRefinementFallback) -> OCRCharacterRefinementResult {
        OCRCharacterRefinementResult(sourceText: sourceText,
                                     mediaBox: mediaBox,
                                     roi: roi,
                                     observations: evidence,
                                     selectedObservationOrdinal: selectedObservationOrdinal,
                                     boxes: [],
                                     fallback: fallback)
    }
}

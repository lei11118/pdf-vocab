import Foundation
import XCTest
@testable import PdfVocab

final class ContextReadingModelTests: XCTestCase {
    func testUTF16SpanSeparatesSafeRawRangesFromComposedTokenRanges() throws {
        let combining = "e\u{0301}"
        let rawPart = UTF16Span(location: 0, length: 1)
        XCTAssertNotNil(rawPart.nsRange(in: combining), "A scalar boundary may split a grapheme in a raw source range")
        XCTAssertNil(rawPart.composedCharacterRange(in: combining), "A semantic token must keep the base and combining mark together")
        XCTAssertEqual(try XCTUnwrap(UTF16Span(location: 0, length: 2).composedCharacterRange(in: combining)),
                       NSRange(location: 0, length: 2))

        let scientist = "👩‍🔬"
        let womanOnly = UTF16Span(location: 0, length: 2)
        XCTAssertNotNil(womanOnly.nsRange(in: scientist), "The range does not split a UTF-16 surrogate pair")
        XCTAssertNil(womanOnly.composedCharacterRange(in: scientist), "A token must not split a ZWJ emoji")
        XCTAssertEqual(try XCTUnwrap(UTF16Span(location: 0, length: (scientist as NSString).length)
            .substring(in: scientist)), scientist)

        XCTAssertNil(UTF16Span(location: 1, length: 1).nsRange(in: "😀"), "A raw range must not split a surrogate pair")
        XCTAssertNil(UTF16Span(location: Int.max, length: 2).endExclusive)
        XCTAssertNil(UTF16Span(location: -1, length: 1).nsRange(in: "safe"))
    }

    func testTokenizerPreservesSourceRangesAndStableDuplicateIdentity() throws {
        let source = "Don't electron-positron 3.2 e\u{0301} 👩‍🔬 charge charge, 42!"
        let first = SemanticTokenizer.canonicalize(source, documentSHA256: "fixture-doc", pageIndex: 4)
        let second = SemanticTokenizer.canonicalize(source, documentSHA256: "fixture-doc", pageIndex: 4)

        XCTAssertEqual(first.sourceText, source)
        let surfaces = first.tokens.map(\.sourceSurface)
        XCTAssertTrue(surfaces.contains("Don't"), "An internal apostrophe stays in one reading token")
        XCTAssertTrue(surfaces.contains("electron-positron"), "An internal hyphen stays in one reading token")
        XCTAssertTrue(surfaces.contains("👩‍🔬"), "A ZWJ emoji stays intact")

        for token in first.tokens {
            XCTAssertEqual(token.span.substring(in: source), token.sourceSurface)
            XCTAssertNotNil(token.span.composedCharacterRange(in: source), "Token \(token.sourceSurface) must end on composed-character boundaries")
        }

        let ns = source as NSString
        let decimalSpan = try XCTUnwrap(UTF16Span(range: ns.range(of: "3.2"), in: source))
        let decimalTokens = first.tokens.filter { $0.span.intersects(decimalSpan) }
        XCTAssertEqual(decimalTokens.map(\.sourceSurface).joined(), "3.2", "Digits and punctuation must not be dropped")
        XCTAssertTrue(decimalTokens.allSatisfy { $0.kind == .number || $0.kind == .punctuation })
        XCTAssertEqual(SemanticTokenizer.kind(of: "3.2"), .number)
        XCTAssertEqual(SemanticTokenizer.kind(of: "1.2e-3"), .number)

        let duplicates = first.tokens.filter { $0.sourceSurface == "charge" }
        XCTAssertEqual(duplicates.count, 2)
        XCTAssertNotEqual(duplicates[0].id, duplicates[1].id, "Repeated words at distinct offsets need distinct IDs")
        XCTAssertEqual(duplicates.map(\.id), second.tokens.filter { $0.sourceSurface == "charge" }.map(\.id))
        let otherPage = SemanticTokenizer.canonicalize(source, documentSHA256: "fixture-doc", pageIndex: 5)
        let otherDocument = SemanticTokenizer.canonicalize(source, documentSHA256: "other-doc", pageIndex: 4)
        XCTAssertNotEqual(duplicates[0].id, otherPage.tokens.first { $0.sourceSurface == "charge" }?.id)
        XCTAssertNotEqual(duplicates[0].id, otherDocument.tokens.first { $0.sourceSurface == "charge" }?.id)

        let covered = Set(first.tokens.flatMap { token -> [Int] in
            guard let end = token.span.endExclusive else { return [] }
            return Array(token.span.location..<end)
        })
        for index in 0..<ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: index)
            let unit = ns.substring(with: range)
            let isWhitespace = unit.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
            if !isWhitespace {
                XCTAssertTrue((range.location..<NSMaxRange(range)).allSatisfy(covered.contains),
                              "Non-whitespace source text at \(range) must remain represented")
            }
        }
    }

    func testAllExperimentalFeatureFlagsDefaultOff() {
        let suite = "ContextReadingFeatureFlags-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(FeatureFlags.contextReadingEnabled(in: defaults))
        XCTAssertFalse(FeatureFlags.mathEnabled(in: defaults))
        XCTAssertFalse(FeatureFlags.prefetchEnabled(in: defaults))

        defaults.set(true, forKey: FeatureFlags.contextReadingEnabledKey)
        XCTAssertTrue(FeatureFlags.contextReadingEnabled(in: defaults))
        XCTAssertFalse(FeatureFlags.mathEnabled(in: defaults))
        XCTAssertFalse(FeatureFlags.prefetchEnabled(in: defaults))

        defaults.set(true, forKey: FeatureFlags.mathEnabledKey)
        defaults.set(true, forKey: FeatureFlags.prefetchEnabledKey)
        defaults.set(false, forKey: FeatureFlags.contextReadingEnabledKey)
        XCTAssertFalse(FeatureFlags.mathEnabled(in: defaults), "Subfeatures stay ineffective when the master switch is off")
        XCTAssertFalse(FeatureFlags.prefetchEnabled(in: defaults), "Subfeatures stay ineffective when the master switch is off")
        defaults.set(true, forKey: FeatureFlags.contextReadingEnabledKey)
        XCTAssertTrue(FeatureFlags.mathEnabled(in: defaults))
        XCTAssertTrue(FeatureFlags.prefetchEnabled(in: defaults))
    }

    func testInvalidSelectionRangeRejectsWholeSourceMapping() {
        let source = "charge phrase"
        let valid = NSRange(location: 0, length: 6)
        XCTAssertEqual(SelectionGeometry.validatedSourceRanges([valid], in: source), [valid])
        XCTAssertNil(SelectionGeometry.validatedSourceRanges([
            valid,
            NSRange(location: 8, length: 0)
        ], in: source), "A zero-length range cannot be silently dropped")
        XCTAssertNil(SelectionGeometry.validatedSourceRanges([
            valid,
            NSRange(location: 100, length: 2)
        ], in: source), "An out-of-bounds range rejects the entire selection")
        XCTAssertNil(SelectionGeometry.validatedSourceRanges([
            valid,
            NSRange(location: NSNotFound, length: 1)
        ], in: source), "NSNotFound rejects the entire selection")
    }

    func testVisualSeedKeepsCanonicalSourceAndDisplaySurfaceSeparate() throws {
        let source = "c h a r g e next"
        let canonical = SemanticTokenizer.canonicalize(source, documentSHA256: "fixture-doc", pageIndex: 2)
        let seedRange = try XCTUnwrap((source as NSString).range(of: "c h a r g e").asValidRange(in: source))
        let seed = try XCTUnwrap(UTF16Span(range: seedRange, in: source))

        let routed = try XCTUnwrap(ContextSelectionRouter.resolve(canonical: canonical,
                                                                  sourceSpans: [seed],
                                                                  displaySurface: "charge",
                                                                  geometryQuality: .word,
                                                                  generation: 9))

        XCTAssertEqual(routed.sourceSpans, [seed])
        XCTAssertEqual(routed.displaySurface, "charge")
        XCTAssertEqual(routed.tokens.count, 1)
        XCTAssertEqual(routed.tokens[0].span, seed)
        XCTAssertEqual(routed.tokens[0].sourceSurface, "c h a r g e")
        XCTAssertEqual(routed.tokens[0].geometryQuality, .word)
        XCTAssertFalse(routed.tokens.contains { $0.sourceSurface == "next" })
    }

    func testSelectionDisplayMismatchRetainsSelectionWithoutSentenceContext() throws {
        let source = "Charge first sentence."
        let canonical = SemanticTokenizer.canonicalize(source, documentSHA256: "display-mismatch", pageIndex: 0)
        let selected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "Charge"), in: source))

        let routed = try XCTUnwrap(ContextSelectionRouter.resolve(canonical: canonical,
                                                                  sourceSpans: [selected],
                                                                  displaySurface: "Change",
                                                                  geometryQuality: .word,
                                                                  generation: 1))

        XCTAssertEqual(routed.displaySurface, "Change")
        XCTAssertEqual(routed.sourceSpans, [selected])
        XCTAssertNil(routed.sentenceContext,
                     "A display correction that changes selected non-whitespace characters cannot seed translation")
    }

    func testRouterRejectsMultilineSentenceAcrossPDFColumns() throws {
        let source = "A sentence continues\non the next line."
        let selected = try XCTUnwrap(UTF16Span(range: (source as NSString).range(of: "continues"), in: source))
        let candidate = try XCTUnwrap(NativeSentenceContextBuilder.build(sourceText: source,
                                                                          selectedSourceSpans: [selected],
                                                                          displaySurface: "continues",
                                                                          documentSHA256: "native-columns",
                                                                          pageIndex: 0,
                                                                          allowsLineBreaks: true))

        XCTAssertTrue(ContextSelectionRouter.isTrustedMultilineLayout(sourceText: source,
                                                                       candidate: candidate,
                                                                       lineBounds: [
                                                                           CGRect(x: 40, y: 200, width: 180, height: 16),
                                                                           CGRect(x: 42, y: 180, width: 140, height: 16)
                                                                       ]))
        XCTAssertFalse(ContextSelectionRouter.isTrustedMultilineLayout(sourceText: source,
                                                                        candidate: candidate,
                                                                        lineBounds: [
                                                                            CGRect(x: 35, y: 200, width: 180, height: 16),
                                                                            CGRect(x: 430, y: 180, width: 160, height: 16)
                                                                        ]))
    }
}

private extension NSRange {
    func asValidRange(in source: String) -> NSRange? {
        UTF16Span(range: self, in: source)?.nsRange(in: source)
    }
}

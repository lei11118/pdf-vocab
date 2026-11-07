import XCTest
import PDFKit
import UIKit
@testable import PdfVocab

@MainActor
final class GlyphSelectionTests: XCTestCase {
    func testOriginalOpenStaxWordHits() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OpenStax-selection", withExtension: "pdf"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let cases: [(Int, String, CGPoint)] = [
            (0, "Functions", CGPoint(x: 123.5795, y: 762.7960)),
            (0, "Functions", CGPoint(x: 167.4803, y: 409.7785)),
            (0, "Functions", CGPoint(x: 195.9708, y: 393.6285)),
            (0, "Trigonometric", CGPoint(x: 131.4312, y: 377.4785)),
            (0, "Functions", CGPoint(x: 183.4946, y: 377.4785)),
            (0, "Functions", CGPoint(x: 156.9352, y: 361.3285)),
            (0, "Functions", CGPoint(x: 245.6082, y: 345.1785)),
            (0, "magnitude", CGPoint(x: 146.9284, y: 281.0690)),
            (0, "magnitude", CGPoint(x: 250.4516, y: 281.0690)),
            (0, "magnitude", CGPoint(x: 119.8101, y: 269.6690)),
            (0, "magnitude", CGPoint(x: 120.7306, y: 258.2690)),
            (0, "magnitude", CGPoint(x: 343.6717, y: 258.2690)),
            (0, "magnitude", CGPoint(x: 488.5164, y: 246.8690)),
            (1, "functions", CGPoint(x: 459.7125, y: 655.3395)),
            (1, "functions", CGPoint(x: 365.2445, y: 627.7895)),
            (1, "functions", CGPoint(x: 147.8987, y: 590.0300)),
            (1, "motion", CGPoint(x: 184.6852, y: 578.6300)),
            (1, "motion", CGPoint(x: 429.8185, y: 578.6300)),
            (1, "electrical", CGPoint(x: 89.3660, y: 578.6300)),
            (1, "functions", CGPoint(x: 203.8964, y: 567.2300)),
            (1, "functions", CGPoint(x: 445.0150, y: 567.2300)),
            (1, "functions", CGPoint(x: 222.7602, y: 555.8300)),
            (1, "functions", CGPoint(x: 171.0259, y: 517.8300))
        ]
        for (index, expected, point) in cases {
            let page = try XCTUnwrap(document.page(at: index))
            let picked = SelectionGeometry.initialWord(on: page, at: point)
            let actual = picked.map { SelectionGeometry.lookupText(for: $0) } ?? "<nil>"
            let hint = page.characterIndex(at: point)
            print("REALPDF page=\(index) word=\(expected) actual=\(actual) count=\(page.numberOfCharacters) string=\((page.string as NSString?)?.length ?? 0) hint=\(hint)")
            if actual != expected, hint != NSNotFound {
                for i in max(0,hint-12)..<min(page.numberOfCharacters,hint+13) {
                    print("GLYPH \(i) native=\(page.characterBounds(at:i)) selection=\(page.selection(for:NSRange(location:i,length:1))?.bounds(for:page) ?? .null) text=\(page.selection(for:NSRange(location:i,length:1))?.string ?? "nil")")
                }
            }
            XCTAssertEqual(actual, expected, "page \(index) at \(point)")
        }
    }

    func testOpenStaxSeedRoutesToExactCanonicalTokenWithoutNeighborExpansion() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OpenStax-selection", withExtension: "pdf"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let pageIndex = 0
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let point = CGPoint(x: 183.4946, y: 377.4785)
        let seed = try XCTUnwrap(SelectionGeometry.initialWord(on: page, at: point))
        let displaySurface = SelectionGeometry.lookupText(for: seed)
        let source = try XCTUnwrap(page.string)
        let sourceRanges = SelectionGeometry.sourceRanges(of: seed, on: page)
        XCTAssertFalse(sourceRanges.isEmpty)
        XCTAssertTrue(sourceRanges.allSatisfy { UTF16Span(range: $0, in: source) != nil })

        let routed = try XCTUnwrap(ContextSelectionRouter.route(selection: seed,
                                                                page: page,
                                                                documentSHA256: "openstax-selection-fixture",
                                                                pageIndex: pageIndex,
                                                                displaySurface: displaySurface,
                                                                geometryQuality: .word,
                                                                generation: 3))

        XCTAssertEqual(displaySurface, "Functions")
        XCTAssertEqual(routed.displaySurface, "Functions")
        XCTAssertEqual(routed.sourceSpans, sourceRanges.compactMap { UTF16Span(range: $0, in: source) })
        XCTAssertEqual(routed.tokens.map(\.sourceSurface), ["Functions"], "A trusted word seed must not absorb either neighboring word")
        XCTAssertTrue(routed.tokens.allSatisfy { $0.span.substring(in: source) == $0.sourceSurface })
    }

    func testVerifiedPhraseGroupRoutesThroughExactPDFKitRange() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OpenStax-selection", withExtension: "pdf"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let pageIndex = 0
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let source = try XCTUnwrap(page.string)
        let canonical = SemanticTokenizer.canonicalize(source,
                                                       documentSHA256: "openstax-phrase-fixture",
                                                       pageIndex: pageIndex)
        var didRoutePhrase = false
        var diagnostics: [String: Int] = [:]
        var rowRangeMismatchSamples: [String] = []
        func record(_ stage: String) {
            diagnostics[stage, default: 0] += 1
        }

        func contextResultBucket(_ context: SentenceContext?) -> String {
            guard let context else { return "nil" }
            let kind: String
            switch context.kind {
            case .completeSentence: kind = "complete"
            case .fragment: kind = "fragment"
            case .layoutBlock: kind = "layout-block"
            }
            let length = context.text.utf16.count >= 32 ? "32plus" : "under32"
            return "\(kind)_\(length)"
        }

        func diagnoseSeedContextPath(selection: PDFSelection, displaySurface: String) {
            let ranges = SelectionGeometry.sourceRanges(of: selection, on: page)
            let sourceSpans = ranges.compactMap { UTF16Span(range: $0, in: source) }
            guard !ranges.isEmpty, sourceSpans.count == ranges.count else {
                record("native_diagnostic.source_spans_invalid")
                return
            }

            let directContext = NativeSentenceContextBuilder.build(sourceText: source,
                                                                    selectedSourceSpans: sourceSpans,
                                                                    displaySurface: displaySurface,
                                                                    documentSHA256: "openstax-phrase-fixture",
                                                                    pageIndex: pageIndex,
                                                                    allowsLineBreaks: true)
            record("native_builder.direct.\(contextResultBucket(directContext))")

            let sourceRows = NativeSentenceContextBuilder.physicalLineSpans(in: source)
            let selectedRowIndices = sourceSpans.compactMap { selected -> Int? in
                guard let selectedEnd = selected.endExclusive else { return nil }
                return sourceRows.firstIndex { row in
                    guard let rowEnd = row.endExclusive else { return false }
                    return row.length > 0 && selected.location >= row.location && selectedEnd <= rowEnd
                }
            }
            guard selectedRowIndices.count == sourceSpans.count,
                  let seedRowIndex = selectedRowIndices.first,
                  selectedRowIndices.allSatisfy({ $0 == seedRowIndex }) else {
                record("native_trusted_block.seed_row_unmapped")
                record("native_builder.trusted.not_attempted")
                return
            }

            var rowBoundsCache: [Int: (bounds: CGRect?, reason: String)] = [:]
            func rowBounds(for rowIndex: Int) -> (bounds: CGRect?, reason: String) {
                if let cached = rowBoundsCache[rowIndex] { return cached }
                let result: (bounds: CGRect?, reason: String)
                guard sourceRows.indices.contains(rowIndex),
                      let range = sourceRows[rowIndex].nsRange(in: source) else {
                    result = (nil, "source_range_invalid")
                    rowBoundsCache[rowIndex] = result
                    record("native_row_bounds.\(result.reason)")
                    return result
                }
                guard range.length > 0 else {
                    result = (nil, "empty_source_row")
                    rowBoundsCache[rowIndex] = result
                    record("native_row_bounds.\(result.reason)")
                    return result
                }
                guard let lineSelection = page.selection(for: range) else {
                    result = (nil, "selection_missing")
                    rowBoundsCache[rowIndex] = result
                    record("native_row_bounds.\(result.reason)")
                    return result
                }
                guard lineSelection.pages.count == 1,
                      lineSelection.pages.first === page else {
                    result = (nil, "page_mismatch")
                    rowBoundsCache[rowIndex] = result
                    record("native_row_bounds.\(result.reason)")
                    return result
                }
                let returnedRanges = SelectionGeometry.sourceRanges(of: lineSelection, on: page)
                let rangeMatch = ContextSelectionRouter.classifySourceRowRanges(requested: range,
                                                                                 returned: returnedRanges,
                                                                                 sourceText: source)
                if rangeMatch != .exact, rowRangeMismatchSamples.count < 3 {
                    let returnedSummary = returnedRanges.prefix(3).map {
                        "\($0.location):\($0.length)"
                    }.joined(separator: ",")
                    let remainder = returnedRanges.count > 3 ? ",more=\(returnedRanges.count - 3)" : ""
                    rowRangeMismatchSamples.append("kind=\(rangeMatch.rawValue) requested=\(range.location):\(range.length) returned=[\(returnedSummary)]\(remainder)")
                }
                guard rangeMatch == .exact || rangeMatch == .whitespaceOnly else {
                    result = (nil, rangeMatch.rawValue)
                    rowBoundsCache[rowIndex] = result
                    record("native_row_bounds.\(result.reason)")
                    return result
                }
                record("native_row_bounds.\(rangeMatch.rawValue)")
                let lineSelections = lineSelection.selectionsByLine()
                guard lineSelections.count == 1 else {
                    result = (nil, "visual_line_count_\(lineSelections.count)")
                    rowBoundsCache[rowIndex] = result
                    record("native_row_bounds.\(result.reason)")
                    return result
                }
                let bounds = lineSelections[0].bounds(for: page)
                guard SelectionGeometry.isValid(bounds) else {
                    result = (nil, "bounds_invalid")
                    rowBoundsCache[rowIndex] = result
                    record("native_row_bounds.\(result.reason)")
                    return result
                }
                result = (bounds, "accepted")
                rowBoundsCache[rowIndex] = result
                record("native_row_bounds.\(result.reason)")
                return result
            }

            func candidateGeometryResult(_ candidate: SentenceContext) -> String {
                guard let candidateEnd = candidate.sourceSpan.endExclusive else {
                    return "candidate_range_invalid"
                }
                let candidateRows = sourceRows.indices.filter { rowIndex in
                    guard let rowEnd = sourceRows[rowIndex].endExclusive else { return false }
                    return sourceRows[rowIndex].length > 0 &&
                        sourceRows[rowIndex].location < candidateEnd && rowEnd > candidate.sourceSpan.location
                }
                guard candidateRows.count >= 2 else { return "candidate_has_fewer_than_two_rows" }
                guard candidateRows.allSatisfy({ abs($0 - seedRowIndex) <= 9 }) else {
                    return "candidate_outside_nine_rows"
                }
                let lineBoxes = candidateRows.compactMap { rowBounds(for: $0).bounds }
                guard lineBoxes.count == candidateRows.count else { return "candidate_row_bounds_rejected" }
                guard ContextSelectionRouter.isTrustedMultilineLayout(sourceText: source,
                                                                       candidate: candidate,
                                                                       lineBounds: lineBoxes) else {
                    return "candidate_layout_untrusted"
                }
                return "accepted"
            }

            if let directContext,
               let rawCandidate = directContext.sourceSpan.substring(in: source),
               rawCandidate.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) {
                record("native_candidate_geometry.\(candidateGeometryResult(directContext))")
            } else if directContext != nil {
                record("native_candidate_geometry.not_multiline")
            } else {
                record("native_candidate_geometry.not_applicable")
            }

            guard !sourceRows.isEmpty else {
                record("native_trusted_block.no_source_rows")
                record("native_builder.trusted.not_attempted")
                return
            }
            var nearbyBounds = [CGRect?](repeating: nil, count: sourceRows.count)
            let lower = max(0, seedRowIndex - 9)
            let upper = min(sourceRows.count - 1, seedRowIndex + 9)
            for rowIndex in lower...upper {
                nearbyBounds[rowIndex] = rowBounds(for: rowIndex).bounds
            }

            guard let trustedBlock = NativeSentenceContextBuilder.trustedSourceBlock(sourceText: source,
                                                                                       selectedSourceSpans: sourceSpans,
                                                                                       lineBounds: nearbyBounds) else {
                let seedBounds = rowBounds(for: seedRowIndex).bounds
                record(seedBounds == nil
                       ? "native_trusted_block.nil_seed_bounds_rejected"
                       : "native_trusted_block.nil_with_seed_bounds")
                record("native_builder.trusted.not_attempted")
                return
            }
            record("native_trusted_block.created")
            record("native_trusted_block.leading_truncated_\(trustedBlock.leadingEdgeTruncated)")
            record("native_trusted_block.trailing_truncated_\(trustedBlock.trailingEdgeTruncated)")
            let trustedContext = NativeSentenceContextBuilder.build(sourceText: source,
                                                                    selectedSourceSpans: sourceSpans,
                                                                    displaySurface: displaySurface,
                                                                    documentSHA256: "openstax-phrase-fixture",
                                                                    pageIndex: pageIndex,
                                                                    allowsLineBreaks: true,
                                                                    trustedSourceBlock: trustedBlock)
            record("native_builder.trusted.\(contextResultBucket(trustedContext))")
        }

        for seedToken in canonical.tokens.prefix(100) where seedToken.kind == .word {
            guard let seedRange = seedToken.span.nsRange(in: source),
                  let seedSelection = page.selection(for: seedRange) else {
                record("native_diagnostic.seed_selection_unavailable")
                continue
            }
            diagnoseSeedContextPath(selection: seedSelection,
                                    displaySurface: SelectionGeometry.lookupText(for: seedSelection))
        }

        for seedToken in canonical.tokens.prefix(100) where seedToken.kind == .word {
            record("seed_attempt")
            guard let seedRange = seedToken.span.nsRange(in: source) else {
                record("invalid_seed_range")
                continue
            }
            guard let seedSelection = page.selection(for: seedRange) else {
                record("seed_pdf_selection")
                continue
            }
            let display = SelectionGeometry.lookupText(for: seedSelection)
            guard let seedContext = ContextSelectionRouter.route(selection: seedSelection,
                                                                 page: page,
                                                                 documentSHA256: "openstax-phrase-fixture",
                                                                 pageIndex: pageIndex,
                                                                 displaySurface: display,
                                                                 geometryQuality: .word,
                                                                 generation: 7) else {
                record("seed_route")
                continue
            }
            guard let sentenceContext = seedContext.sentenceContext else {
                record("seed_context_missing")
                continue
            }
            guard let selectedSpan = seedContext.sourceSpans.first else {
                record("seed_source_span_missing")
                continue
            }
            guard let phrase = VerifiedPhraseGroupResolver.resolve(in: sentenceContext,
                                                                   selectedSourceSpans: [selectedSpan],
                                                                   sourceText: source,
                                                                   exactPhraseExists: { _ in true }) else {
                record("resolver_miss")
                continue
            }
            guard let phraseRange = phrase.sourceSpan.nsRange(in: source) else {
                record("invalid_phrase_range")
                continue
            }
            guard let phraseSelection = page.selection(for: phraseRange) else {
                record("phrase_pdf_selection")
                continue
            }
            guard SelectionGeometry.sourceRanges(of: phraseSelection, on: page) == [phraseRange] else {
                record("phrase_source_ranges_mismatch")
                continue
            }
            guard phraseSelection.pages.count == 1,
                  phraseSelection.pages.first === page else {
                record("phrase_page_mismatch")
                continue
            }
            guard phraseSelection.selectionsByLine().count == 1 else {
                record("phrase_multiple_visual_lines")
                continue
            }
            guard SelectionGeometry.isValid(SelectionGeometry.placedBounds(of: phraseSelection, on: page)) else {
                record("phrase_invalid_bounds")
                continue
            }
            guard let routed = ContextSelectionRouter.route(selection: phraseSelection,
                                                            page: page,
                                                            documentSHA256: "openstax-phrase-fixture",
                                                            pageIndex: pageIndex,
                                                            displaySurface: phrase.sourceSurface,
                                                            geometryQuality: .word,
                                                            generation: 7,
                                                            verifiedPhraseGroupSpan: phrase.sourceSpan) else {
                record("group_route")
                guard let groupContextual = ContextSelectionRouter.resolve(canonical: canonical,
                                                                           sourceSpans: [phrase.sourceSpan],
                                                                           displaySurface: phrase.sourceSurface,
                                                                           geometryQuality: .word,
                                                                           generation: 7,
                                                                           allowsMultilineSentenceContext: true,
                                                                           verifiedPhraseGroupSpan: phrase.sourceSpan) else {
                    record("group_resolve")
                    continue
                }
                guard let groupSentenceContext = groupContextual.sentenceContext else {
                    record("group_sentence_context_missing")
                    continue
                }
                guard groupContextual.sourceSpans == [phrase.sourceSpan] else {
                    record("group_route_source_span_mismatch")
                    continue
                }
                guard groupSentenceContext.selectedSourceSpans == [phrase.sourceSpan] else {
                    record("group_context_selection_span_mismatch")
                    continue
                }
                guard groupContextual.tokens.count >= 2 else {
                    record("group_route_token_count")
                    continue
                }
                guard groupContextual.tokens.allSatisfy({ $0.kind == .word }) else {
                    record("group_route_token_kind")
                    continue
                }
                guard let rawSentence = groupSentenceContext.sourceSpan.substring(in: source) else {
                    record("group_context_source_span_invalid")
                    continue
                }
                if rawSentence.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) {
                    guard let lineSpans = NativeSentenceContextBuilder.lineSpans(in: source,
                                                                                 sourceSpan: groupSentenceContext.sourceSpan) else {
                        record("group_line_spans_missing")
                        continue
                    }
                    var lineBounds: [CGRect] = []
                    var lineBoundsFailure: String?
                    for lineSpan in lineSpans {
                        guard let lineRange = lineSpan.nsRange(in: source) else {
                            lineBoundsFailure = "group_line_range_invalid"
                            break
                        }
                        guard let lineSelection = page.selection(for: lineRange) else {
                            lineBoundsFailure = "group_line_selection_missing"
                            break
                        }
                        let lineSelections = lineSelection.selectionsByLine()
                        guard lineSelections.count == 1 else {
                            lineBoundsFailure = "group_line_selection_multiline"
                            break
                        }
                        let bounds = lineSelections[0].bounds(for: page)
                        guard SelectionGeometry.isValid(bounds) else {
                            lineBoundsFailure = "group_line_bounds_invalid"
                            break
                        }
                        lineBounds.append(bounds)
                    }
                    if let lineBoundsFailure {
                        record(lineBoundsFailure)
                        continue
                    }
                    guard ContextSelectionRouter.isTrustedMultilineLayout(sourceText: source,
                                                                          candidate: groupSentenceContext,
                                                                          lineBounds: lineBounds) else {
                        record("group_multiline_geometry_untrusted")
                        continue
                    }
                }
                record("route_rejected_after_resolve_geometry")
                continue
            }

            XCTAssertEqual(routed.verifiedPhraseGroupSpan, phrase.sourceSpan)
            XCTAssertEqual(routed.sourceSpans, [phrase.sourceSpan])
            XCTAssertGreaterThanOrEqual(routed.tokens.count, 2)
            XCTAssertTrue(routed.tokens.allSatisfy { $0.kind == .word && $0.geometryQuality == .word })
            XCTAssertEqual(phrase.sourceSpan.substring(in: source), phrase.sourceSurface)
            didRoutePhrase = true
            break
        }

        let summary = diagnostics.keys.sorted().map { "\($0)=\(diagnostics[$0] ?? 0)" }.joined(separator: " ")
        print("PHRASE_ROUTE_DIAGNOSTICS \(summary)")
        if !rowRangeMismatchSamples.isEmpty {
            print("NATIVE_ROW_RANGE_SAMPLES \(rowRangeMismatchSamples.joined(separator: ";"))")
        }
        XCTAssertTrue(didRoutePhrase, "Expected an exact word-group range to survive PDFKit selection and routing")
    }

    func testOpenStaxWordSeedBuildsExactLayoutBlockTranslationRequest() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OpenStax-selection", withExtension: "pdf"))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let pageIndex = 0
        let page = try XCTUnwrap(document.page(at: pageIndex))
        let source = try XCTUnwrap(page.string)
        let canonical = SemanticTokenizer.canonicalize(source,
                                                       documentSHA256: "openstax-complete-request-fixture",
                                                       pageIndex: pageIndex)
        var didBuildRequest = false

        for seedToken in canonical.tokens.prefix(200) where seedToken.kind == .word {
            guard let seedRange = seedToken.span.nsRange(in: source),
                  let seedSelection = page.selection(for: seedRange) else { continue }
            let displaySurface = SelectionGeometry.lookupText(for: seedSelection)
            guard let routed = ContextSelectionRouter.route(selection: seedSelection,
                                                            page: page,
                                                            documentSHA256: "openstax-complete-request-fixture",
                                                            pageIndex: pageIndex,
                                                            displaySurface: displaySurface,
                                                            geometryQuality: .word,
                                                            generation: 11),
                  let sentenceContext = routed.sentenceContext,
                  sentenceContext.kind == .layoutBlock,
                  sentenceContext.text.utf16.count >= 32 else { continue }
            let wordCount = SemanticTokenizer.canonicalize(sentenceContext.text,
                                                           documentSHA256: sentenceContext.documentSHA256,
                                                           pageIndex: sentenceContext.pageIndex,
                                                           blockID: sentenceContext.blockID)
                .tokens.filter { $0.kind == .word }.count
            guard wordCount >= 5 else { continue }

            XCTAssertEqual(sentenceContext.selectedSourceSpans, routed.sourceSpans)
            XCTAssertEqual(sentenceContext.selectedSourceSpans.first?.substring(in: source), seedToken.sourceSurface)
            let request = try ContextualTranslationRequest.make(from: sentenceContext)
            let globalSeedSpan = try XCTUnwrap(routed.sourceSpans.first)
            let expectedLocalSpan = UTF16Span(location: globalSeedSpan.location - sentenceContext.sourceSpan.location,
                                              length: globalSeedSpan.length)
            XCTAssertEqual(request.selectedSourceSpans, [expectedLocalSpan])
            XCTAssertEqual(request.selectedSourceSpans, sentenceContext.selectedDisplaySpans)
            XCTAssertEqual(request.selectedSourceSpans.first?.substring(in: request.sentenceText),
                           request.selectedSourcePhrase)
            XCTAssertEqual(request.sentenceText, sentenceContext.text)
            didBuildRequest = true
            break
        }

        XCTAssertTrue(didBuildRequest,
                      "Expected an exact word seed to recover a body sentence and form a valid translation request")
    }

    func testEveryVisibleCharacterHasAnAlignedSelection() throws {
        struct Hit: Decodable { let page: Int; let text: String; let point: [Double] }
        let bundle = Bundle(for:Self.self)
        let document = try XCTUnwrap(PDFDocument(url:try XCTUnwrap(bundle.url(forResource:"OpenStax-selection",withExtension:"pdf"))))
        let data = try Data(contentsOf:XCTUnwrap(bundle.url(forResource:"OpenStax-character-hits",withExtension:"json")))
        let hits = try JSONDecoder().decode([Hit].self,from:data)
        var failures: [String] = []
        for hit in hits {
            let page = try XCTUnwrap(document.page(at:hit.page)), point = CGPoint(x:hit.point[0],y:hit.point[1])
            let selection = SelectionGeometry.initialWord(on:page,at:point,tolerance:1)
                ?? SelectionGeometry.initialCharacter(on:page,at:point,tolerance:1)
            let actual = selection?.string?.precomposedStringWithCompatibilityMapping ?? "<nil>"
            let aligned = selection.map { SelectionGeometry.placedBounds(of:$0,on:page).insetBy(dx:-1,dy:-1).contains(point) } ?? false
            if !actual.contains(hit.text.precomposedStringWithCompatibilityMapping) || !aligned {
                failures.append("page=\(hit.page) char=\(hit.text) point=\(point) actual=\(actual) aligned=\(aligned)")
            }
        }
        print("ALL_CHARACTERS total=\(hits.count) failures=\(failures.count)")
        for value in failures.prefix(50) { print("CHARACTER_MISS \(value)") }
        XCTAssertTrue(failures.isEmpty,"\(failures.count)/\(hits.count) character failures: \(failures.prefix(8))")
    }

    func testEveryOriginalTextGlyphIsSelectable() throws {
        struct Hit: Decodable { let page: Int; let text: String; let points: [[Double]] }
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource:"OpenStax-selection",withExtension:"pdf"))
        let document = try XCTUnwrap(PDFDocument(url:url))
        let fixture = try XCTUnwrap(bundle.url(forResource:"OpenStax-glyph-hits",withExtension:"json"))
        let hits = try JSONDecoder().decode([Hit].self,from:Data(contentsOf:fixture))
        var geometry: [[String: Any]] = []
        for pi in 0..<document.pageCount {
            guard let page = document.page(at:pi), let text = page.string else { continue }
            let ns = text as NSString
            let attr = page.attributedString
            for i in 0..<ns.length {
                let r = page.selection(for:NSRange(location:i,length:1))?.bounds(for:page) ?? .null
                guard SelectionGeometry.isValid(r) else { continue }
                let font = i < (attr?.length ?? 0) ? attr?.attribute(.font,at:i,effectiveRange:nil) as? UIFont : nil
                let char = ns.substring(with:NSRange(location:i,length:1))
                geometry.append(["page":pi,"i":i,"ch":char,"rect":[r.minX,r.minY,r.width,r.height],
                    "font":font?.fontName ?? "nil","size":font?.pointSize ?? 0,
                    "advance":font.map { char.size(withAttributes:[.font:$0]).width } ?? 0])
            }
        }
        var placement: [[String:Any]] = []
        for pi in 0..<document.pageCount {
            guard let page = document.page(at:pi) else { continue }
            for glyph in PDFTextLayout.glyphs(on:page) {
                let r = glyph.rect
                placement.append(["page":pi,"ch":glyph.text,"rect":[r.minX,r.minY,r.width,r.height]])
            }
        }
        let placementAttachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:placement),uniformTypeIdentifier:"public.json")
        placementAttachment.name = "PDF-content-stream-placement"; placementAttachment.lifetime = .keepAlways; add(placementAttachment)
        var native: [[String:Any]] = []
        for pi in 0..<document.pageCount {
            guard let page = document.page(at:pi) else { continue }
            for i in 0..<page.numberOfCharacters {
                let r = page.characterBounds(at:i)
                guard SelectionGeometry.isValid(r) else { continue }
                native.append(["page":pi,"i":i,"rect":[r.minX,r.minY,r.width,r.height]])
            }
        }
        let nativeAttachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:native),uniformTypeIdentifier:"public.json")
        nativeAttachment.name = "PDFKit-native-glyph-bounds"; nativeAttachment.lifetime = .keepAlways; add(nativeAttachment)
        let attachment = XCTAttachment(data:try JSONSerialization.data(withJSONObject:geometry),uniformTypeIdentifier:"public.json")
        attachment.name = "OpenStax-PDFKit-glyphs"
        attachment.lifetime = .keepAlways
        add(attachment)
        var failures: [String] = [], total = 0
        for hit in hits {
            let page = try XCTUnwrap(document.page(at:hit.page))
            for (offset, coordinates) in hit.points.enumerated() {
                total += 1
                let point = CGPoint(x:coordinates[0],y:coordinates[1])
                let selection = SelectionGeometry.initialWord(on:page,at:point,tolerance:1)
                let actual = selection.map { SelectionGeometry.lookupText(for:$0) } ?? "<nil>"
                if actual != hit.text {
                    failures.append("page=\(hit.page) word=\(hit.text) glyph=\(offset) at=\(point) actual=\(actual)")
                }
            }
        }
        print("ALL_GLYPHS total=\(total) failures=\(failures.count)")
        for failure in failures.prefix(100) { print("GLYPH_MISS \(failure)") }
        XCTAssertTrue(failures.isEmpty,"\(failures.count)/\(total) glyph failures: \(failures.prefix(12))")
    }
}

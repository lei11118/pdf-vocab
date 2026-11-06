import Foundation
import XCTest
@testable import PdfVocab

final class VerifiedPhraseGroupResolverTests: XCTestCase {
    func testReturnsLongestExactEnabledPhraseAroundSelectedWord() throws {
        let text = "We will take off soon."
        let selected = try span(of: "off", in: text)
        let context = makeContext(text, selected: selected, origin: 120)
        let exactEntries: Set<String> = ["take off", "will take off"]

        let result = VerifiedPhraseGroupResolver.resolve(in: context,
                                                         selectedSourceSpans: context.selectedSourceSpans) {
            exactEntries.contains($0)
        }

        XCTAssertEqual(result?.lookupKey, "will take off")
        XCTAssertEqual(result?.sourceSurface, "will take off")
        XCTAssertEqual(result?.sourceSpan,
                       UTF16Span(location: 120 + (text as NSString).range(of: "will take off").location,
                                 length: ("will take off" as NSString).length))
    }

    func testUsesExactSourceOccurrenceWithUTF16Offsets() throws {
        let text = "😀 Learn machine learning; then apply machine learning."
        let selected = try span(of: "learning", in: text, occurrence: 1)
        let context = makeContext(text, selected: selected, origin: 37)

        let result = VerifiedPhraseGroupResolver.resolve(in: context,
                                                         selectedSourceSpans: context.selectedSourceSpans) {
            $0 == "machine learning"
        }

        let expected = try span(of: "machine learning", in: text, occurrence: 1)
        XCTAssertEqual(result?.sourceSpan,
                       UTF16Span(location: 37 + expected.location, length: expected.length))
        XCTAssertEqual(result?.sourceSurface, "machine learning")
    }

    func testRejectsPunctuationAndUnlistedNgrams() throws {
        let punctuated = "take, off now."
        let punctuatedSelection = try span(of: "off", in: punctuated)
        let punctuatedContext = makeContext(punctuated, selected: punctuatedSelection)
        XCTAssertNil(VerifiedPhraseGroupResolver.resolve(in: punctuatedContext,
                                                         selectedSourceSpans: punctuatedContext.selectedSourceSpans,
                                                         exactPhraseExists: { $0 == "take off" }))

        let unlisted = "take off now."
        let unlistedSelection = try span(of: "off", in: unlisted)
        let unlistedContext = makeContext(unlisted, selected: unlistedSelection)
        XCTAssertNil(VerifiedPhraseGroupResolver.resolve(in: unlistedContext,
                                                         selectedSourceSpans: unlistedContext.selectedSourceSpans,
                                                         exactPhraseExists: { _ in false }))
    }

    func testRejectsNewlineBoundaryEvenWhenDictionaryHasPhrase() throws {
        let text = "take\noff now."
        let selected = try span(of: "off", in: text)
        let context = makeContext(text, selected: selected)

        XCTAssertNil(VerifiedPhraseGroupResolver.resolve(in: context,
                                                         selectedSourceSpans: context.selectedSourceSpans,
                                                         exactPhraseExists: { $0 == "take off" }))
    }

    func testChecksOriginalSourceWhenNativeContextHasNormalizedLineBreaks() throws {
        let sourceText = "take\noff now."
        let normalizedContextText = "take off now."
        let selected = try span(of: "off", in: normalizedContextText)
        let context = makeContext(normalizedContextText, selected: selected)

        XCTAssertNil(VerifiedPhraseGroupResolver.resolve(in: context,
                                                         selectedSourceSpans: context.selectedSourceSpans,
                                                         sourceText: sourceText,
                                                         exactPhraseExists: { $0 == "take off" }))
    }

    func testAllowsVerifiedPhraseInAContextFragment() throws {
        let text = "New York"
        let selected = try span(of: "York", in: text)
        let context = makeContext(text, selected: selected, kind: .fragment)

        let result = VerifiedPhraseGroupResolver.resolve(in: context,
                                                         selectedSourceSpans: context.selectedSourceSpans,
                                                         exactPhraseExists: { $0 == "new york" })

        XCTAssertEqual(result?.sourceSurface, "New York")
    }

    func testLookupMemoizesSameSeedAndInvalidatesOnDictionaryRevisionOrClear() throws {
        let text = "Take off soon."
        let selected = try span(of: "off", in: text)
        let context = makeContext(text, selected: selected)
        var revision = 0
        var lookupCount = 0
        let lookup = VerifiedPhraseGroupLookup(dictionaryRevision: { revision },
                                              exactPhraseExists: { _ in
                                                  lookupCount += 1
                                                  return true
                                              })

        XCTAssertNotNil(lookup.resolve(in: context,
                                       selectedSourceSpans: context.selectedSourceSpans,
                                       sourceText: text))
        let firstLookupCount = lookupCount
        XCTAssertGreaterThan(firstLookupCount, 0)
        _ = lookup.resolve(in: context,
                           selectedSourceSpans: context.selectedSourceSpans,
                           sourceText: text)
        XCTAssertEqual(lookupCount, firstLookupCount, "Repeated hover frames for one seed reuse the result")

        revision += 1
        _ = lookup.resolve(in: context,
                           selectedSourceSpans: context.selectedSourceSpans,
                           sourceText: text)
        XCTAssertGreaterThan(lookupCount, firstLookupCount,
                             "Enabling or disabling a dictionary invalidates the same source seed")

        let revisionLookupCount = lookupCount
        lookup.clear()
        _ = lookup.resolve(in: context,
                           selectedSourceSpans: context.selectedSourceSpans,
                           sourceText: text)
        XCTAssertGreaterThan(lookupCount, revisionLookupCount, "Ending hover clears the seed cache")
    }

    private func makeContext(_ text: String,
                             selected localSpan: UTF16Span,
                             origin: Int = 0,
                             kind: SentenceContextKind = .completeSentence) -> SentenceContext {
        let length = (text as NSString).length
        let sourceSpan = UTF16Span(location: origin, length: length)
        let selected = UTF16Span(location: origin + localSpan.location, length: localSpan.length)
        return SentenceContext(documentSHA256: "phrase-resolver-fixture",
                              pageIndex: 0,
                              blockID: "phrase-resolver-block",
                              text: text,
                              displayLineText: text,
                              displaySentenceText: text,
                              sourceSpan: sourceSpan,
                              displaySpan: UTF16Span(location: 0, length: length),
                              selectedSourceSpans: [selected],
                              selectedDisplaySpans: [localSpan],
                              kind: kind)
    }

    private func span(of surface: String,
                      in text: String,
                      occurrence: Int = 0) throws -> UTF16Span {
        let source = text as NSString
        var searchStart = 0
        for index in 0...occurrence {
            let range = source.range(of: surface,
                                     options: [],
                                     range: NSRange(location: searchStart,
                                                    length: source.length - searchStart))
            guard range.location != NSNotFound else { throw ContextualTranslationError.invalidSelection }
            if index == occurrence {
                return try XCTUnwrap(UTF16Span(range: range, in: text))
            }
            searchStart = NSMaxRange(range)
        }
        throw ContextualTranslationError.invalidSelection
    }
}

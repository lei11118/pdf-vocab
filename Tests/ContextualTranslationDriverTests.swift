import Foundation
import XCTest
import SwiftUI
import UIKit
@testable import PdfVocab

@MainActor
final class ContextualTranslationDriverTests: XCTestCase {
    func testInjectedPrepareAndTranslationCompleteForCurrentIdentity() async throws {
        let driver = ContextualTranslationDriver(availabilityProvider: { .installed },
                                                 translator: { request in
                                                     ContextualTranslationCandidate(sourcePhrase: request.selectedSourcePhrase,
                                                                                    translatedPhrase: "当前结果")
                                                 })
        let identity = try makeIdentity(selected: "read")

        await driver.prepare(identity)
        XCTAssertEqual(driver.state, .translating)
        await driver.translateWithInjectedTranslator()

        XCTAssertEqual(driver.state,
                       .candidate(ContextualTranslationCandidate(sourcePhrase: "read",
                                                                 translatedPhrase: "当前结果")))
    }

    func testOlderTranslationCannotReplaceNewSelectionResult() async throws {
        let firstGate = DriverTranslationGate()
        let driver = ContextualTranslationDriver(availabilityProvider: { .installed },
                                                 translator: { request in
                                                     if request.selectedSourcePhrase == "read" {
                                                         return await firstGate.wait()
                                                     }
                                                     return ContextualTranslationCandidate(sourcePhrase: request.selectedSourcePhrase,
                                                                                           translatedPhrase: "新选区")
                                                 })
        let firstIdentity = try makeIdentity(selected: "read")
        let secondIdentity = try makeIdentity(selected: "books")

        await driver.prepare(firstIdentity)
        let oldTask = Task { await driver.translateWithInjectedTranslator() }
        await firstGate.waitUntilStarted()

        await driver.prepare(secondIdentity)
        await driver.translateWithInjectedTranslator()
        let secondCandidate = ContextualTranslationCandidate(sourcePhrase: "books", translatedPhrase: "新选区")
        XCTAssertEqual(driver.state, .candidate(secondCandidate))

        await firstGate.resume(ContextualTranslationCandidate(sourcePhrase: "read", translatedPhrase: "旧结果"))
        await oldTask.value
        XCTAssertEqual(driver.state, .candidate(secondCandidate),
                       "A response for an older selection must not replace the current candidate")
    }

    func testDeactivationDropsAndCancelsInFlightInjectedTranslation() async throws {
        let gate = DriverTranslationGate()
        let driver = ContextualTranslationDriver(availabilityProvider: { .installed },
                                                 translator: { request in await gate.wait() })
        let identity = try makeIdentity(selected: "read")

        await driver.prepare(identity)
        let task = Task { await driver.translateWithInjectedTranslator() }
        await gate.waitUntilStarted()
        driver.deactivate()
        task.cancel()
        await gate.resume(ContextualTranslationCandidate(sourcePhrase: "read", translatedPhrase: "过期结果"))
        await task.value

        XCTAssertEqual(driver.state, .disabled)
    }

    func testEachWordInVerifiedPhraseRequestsSamePhraseAndKeepsWordSurface() async throws {
        let capturedRequests = DriverTranslationRequests()
        let driver = ContextualTranslationDriver(availabilityProvider: { .installed },
                                                 translator: { request in
                                                     await capturedRequests.append(request)
                                                     return ContextualTranslationCandidate(
                                                        sourcePhrase: request.selectedSourcePhrase,
                                                        translatedPhrase: "语境译义")
                                                 })

        for surface in ["read", "books"] {
            let identity = try makeVerifiedPhraseIdentity(selected: surface)
            XCTAssertEqual(identity.selection.displaySurface, surface)
            XCTAssertEqual(identity.selection.tokens.map(\.sourceSurface), [surface])

            await driver.prepare(identity)
            await driver.translateWithInjectedTranslator()
        }

        let requests = await capturedRequests.values()
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(requests.first)
        let second = try XCTUnwrap(requests.dropFirst().first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.selectedSourcePhrase, "read books")
    }

    func testEmptyHoverHostsTranslationLifecycleTask() async throws {
        let availabilityChecked = expectation(description: "The mounted hover runs prepare")
        let driver = ContextualTranslationDriver(availabilityProvider: {
            availabilityChecked.fulfill()
            return .unsupported
        })
        let identity = try makeIdentity(selected: "read")
        let host = UIHostingController(rootView: ContextualTranslationTaskView(
            selection: identity.selection,
            isEnabled: true,
            presentation: .hover,
            driver: driver
        ))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        await fulfillment(of: [availabilityChecked], timeout: 5)
        XCTAssertEqual(driver.state, .unsupported)
    }

    func testVerifiedPhraseScopeRejectsSameOffsetsFromDifferentOCRLine() throws {
        let text = "read books today"
        let source = text as NSString
        let phraseSpan = try XCTUnwrap(UTF16Span(range: source.range(of: "read books"), in: text))
        let canonical = SemanticTokenizer.canonicalize(text,
                                                       documentSHA256: "driver-fixture",
                                                       pageIndex: 2,
                                                       blockID: "ocr-line-a")
        let phraseTokens = canonical.tokens.filter { token in
            token.span.location >= phraseSpan.location
                && (token.span.endExclusive ?? -1) <= (phraseSpan.endExclusive ?? -1)
        }
        let phraseContext = makeSentenceContext(text: text,
                                                selectedSourceSpans: [phraseSpan],
                                                pageIndex: 2,
                                                blockID: "ocr-line-a")
        let phrase = ContextualSelection(documentSHA256: "driver-fixture",
                                         pageIndex: 2,
                                         sourceSpans: [phraseSpan],
                                         tokens: phraseTokens,
                                         verifiedPhraseGroupSpan: phraseSpan,
                                         displaySurface: "read books",
                                         generation: 4,
                                         sentenceContext: phraseContext)
        let wrongLineToken = SourceToken(documentSHA256: "driver-fixture",
                                         pageIndex: 2,
                                         span: try XCTUnwrap(phraseTokens.first?.span),
                                         sourceSurface: "read",
                                         kind: .word,
                                         blockID: "ocr-line-b")
        let selected = ContextualSelection(documentSHA256: "driver-fixture",
                                           pageIndex: 2,
                                           sourceSpans: [wrongLineToken.span],
                                           tokens: [wrongLineToken],
                                           displaySurface: "read",
                                           generation: 4,
                                           sentenceContext: phraseContext)

        XCTAssertNil(selected.borrowingVerifiedPhraseTranslationScope(from: phrase))
    }

    func testInvalidBorrowedPhraseContextFallsBackToSelectedWordContext() async throws {
        let identity = try makeVerifiedPhraseIdentity(selected: "read", phraseKind: .fragment)
        let driver = ContextualTranslationDriver(availabilityProvider: { .installed },
                                                 translator: { request in
                                                     ContextualTranslationCandidate(
                                                        sourcePhrase: request.selectedSourcePhrase,
                                                        translatedPhrase: "单词语境")
                                                 })

        await driver.prepare(identity)
        await driver.translateWithInjectedTranslator()

        XCTAssertEqual(driver.state,
                       .candidate(ContextualTranslationCandidate(sourcePhrase: "read",
                                                                 translatedPhrase: "单词语境")))
    }

    private func makeIdentity(selected surface: String) throws -> ContextualTranslationDriver.Identity {
        let text = "They read books daily."
        let source = text as NSString
        let range = source.range(of: surface)
        guard range.location != NSNotFound,
              let selectedSpan = UTF16Span(range: range, in: text) else {
            throw ContextualTranslationError.invalidSelection
        }
        let canonical = SemanticTokenizer.canonicalize(text,
                                                       documentSHA256: "driver-fixture",
                                                       pageIndex: 0)
        let token = try XCTUnwrap(canonical.tokens.first { $0.span == selectedSpan })
        let context = makeSentenceContext(text: text, selectedSourceSpans: [selectedSpan])
        let selection = ContextualSelection(documentSHA256: "driver-fixture",
                                            pageIndex: 0,
                                            sourceSpans: [selectedSpan],
                                            tokens: [token.withGeometryQuality(.word)],
                                            displaySurface: surface,
                                            generation: 1,
                                            sentenceContext: context)
        return ContextualTranslationDriver.Identity(selection: selection,
                                                    isEnabled: true,
                                                    presentation: .card,
                                                    retryGeneration: 0)
    }

    private func makeVerifiedPhraseIdentity(selected surface: String,
                                            phraseKind: SentenceContextKind = .completeSentence) throws
        -> ContextualTranslationDriver.Identity {
        let text = "They read books daily."
        let source = text as NSString
        let phraseSpan = try XCTUnwrap(UTF16Span(range: source.range(of: "read books"), in: text))
        let canonical = SemanticTokenizer.canonicalize(text,
                                                       documentSHA256: "driver-fixture",
                                                       pageIndex: 0)
        let phraseTokens = canonical.tokens.filter { token in
            token.span.location >= phraseSpan.location
                && (token.span.endExclusive ?? -1) <= (phraseSpan.endExclusive ?? -1)
        }
        let phraseContext = makeSentenceContext(text: text,
                                                selectedSourceSpans: [phraseSpan],
                                                kind: phraseKind)
        let phrase = ContextualSelection(documentSHA256: "driver-fixture",
                                         pageIndex: 0,
                                         sourceSpans: [phraseSpan],
                                         tokens: phraseTokens,
                                         verifiedPhraseGroupSpan: phraseSpan,
                                         displaySurface: "read books",
                                         generation: 1,
                                         sentenceContext: phraseContext)
        let selection = try makeIdentity(selected: surface).selection
        XCTAssertEqual(selection.tokens.map(\.sourceSurface), [surface])
        let scoped = try XCTUnwrap(selection.borrowingVerifiedPhraseTranslationScope(from: phrase))
        return ContextualTranslationDriver.Identity(selection: scoped,
                                                    isEnabled: true,
                                                    presentation: .card,
                                                    retryGeneration: 0)
    }

    private func makeSentenceContext(text: String,
                                     selectedSourceSpans: [UTF16Span],
                                     documentSHA256: String = "driver-fixture",
                                     pageIndex: Int = 0,
                                     blockID: String = "driver-block",
                                     kind: SentenceContextKind = .completeSentence) -> SentenceContext {
        let fullSpan = UTF16Span(location: 0, length: (text as NSString).length)
        return SentenceContext(documentSHA256: documentSHA256,
                               pageIndex: pageIndex,
                               blockID: blockID,
                               text: text,
                               displayLineText: text,
                               displaySentenceText: text,
                               sourceSpan: fullSpan,
                               displaySpan: fullSpan,
                               selectedSourceSpans: selectedSourceSpans,
                               selectedDisplaySpans: selectedSourceSpans,
                               kind: kind)
    }
}

private actor DriverTranslationGate {
    private var continuation: CheckedContinuation<ContextualTranslationCandidate, Never>?
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?

    func wait() async -> ContextualTranslationCandidate {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func resume(_ candidate: ContextualTranslationCandidate) {
        continuation?.resume(returning: candidate)
        continuation = nil
    }
}

private actor DriverTranslationRequests {
    private var stored: [ContextualTranslationRequest] = []

    func append(_ request: ContextualTranslationRequest) {
        stored.append(request)
    }

    func values() -> [ContextualTranslationRequest] { stored }
}

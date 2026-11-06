import Foundation
import XCTest
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
        let length = source.length
        let context = SentenceContext(documentSHA256: "driver-fixture",
                                      pageIndex: 0,
                                      blockID: "driver-block",
                                      text: text,
                                      displayLineText: text,
                                      displaySentenceText: text,
                                      sourceSpan: UTF16Span(location: 0, length: length),
                                      displaySpan: UTF16Span(location: 0, length: length),
                                      selectedSourceSpans: [selectedSpan],
                                      selectedDisplaySpans: [selectedSpan],
                                      kind: .completeSentence)
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

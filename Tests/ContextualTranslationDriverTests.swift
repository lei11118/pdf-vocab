import Foundation
import XCTest
import SwiftUI
import UIKit
import Vision
@testable import PdfVocab

@MainActor
final class ContextualTranslationDriverTests: XCTestCase {
    func testCachedCandidateSkipsAvailabilityAndTranslationSessionPath() async throws {
        let calls = DriverLifecycleCallCounter()
        let expected = ContextualTranslationCandidate(sourcePhrase: "read", translatedPhrase: "已缓存")
        let driver = ContextualTranslationDriver(availabilityProvider: {
            await calls.recordAvailability()
            return .installed
        }, cacheLookup: { request in
            await calls.recordCacheLookup()
            XCTAssertEqual(request.selectedSourcePhrase, "read")
            return .candidate(expected)
        }, translator: { request in
            await calls.recordTranslation()
            return ContextualTranslationCandidate(sourcePhrase: request.selectedSourcePhrase,
                                                  translatedPhrase: "不应请求")
        })

        await driver.prepare(try makeIdentity(selected: "read"))
        await driver.translateWithInjectedTranslator()

        XCTAssertEqual(driver.state, .candidate(expected))
        XCTAssertNil(driver.configuration)
        let snapshot = await calls.snapshot()
        XCTAssertEqual(snapshot.cacheLookups, 1)
        XCTAssertEqual(snapshot.availabilityChecks, 0)
        XCTAssertEqual(snapshot.translations, 0)
    }

    func testColdCacheKeepsCardPreparationStateAndOnlyBackendNoAlignmentIsFinal() async throws {
        let calls = DriverLifecycleCallCounter()
        let cachedNoAlignmentDriver = ContextualTranslationDriver(availabilityProvider: {
            await calls.recordAvailability()
            return .installed
        }, cacheLookup: { _ in .noAlignedResult }, translator: { request in
            await calls.recordTranslation()
            return ContextualTranslationCandidate(sourcePhrase: request.selectedSourcePhrase,
                                                  translatedPhrase: "不应请求")
        })
        await cachedNoAlignmentDriver.prepare(try makeIdentity(selected: "read"))
        await cachedNoAlignmentDriver.translateWithInjectedTranslator()
        XCTAssertEqual(cachedNoAlignmentDriver.state, .noAlignedResult)
        let negativeHitSnapshot = await calls.snapshot()
        XCTAssertEqual(negativeHitSnapshot.availabilityChecks, 0)
        XCTAssertEqual(negativeHitSnapshot.translations, 0,
                       "A bounded negative hit must skip the availability/session path too")

        let cacheMissDriver = ContextualTranslationDriver(availabilityProvider: { .supported },
                                                         cacheLookup: { _ in nil })
        await cacheMissDriver.prepare(try makeIdentity(selected: "read"))
        XCTAssertEqual(cacheMissDriver.state, .needsPreparation,
                       "A cache miss must continue through availability without claiming no alignment")

        let noAlignmentDriver = ContextualTranslationDriver(availabilityProvider: { .installed },
                                                            cacheLookup: { _ in nil },
                                                            translator: { _ in
                                                                throw ContextualTranslationError.selectedTokenNotAligned
                                                            })
        await noAlignmentDriver.prepare(try makeIdentity(selected: "read"))
        await noAlignmentDriver.translateWithInjectedTranslator()
        XCTAssertEqual(noAlignmentDriver.state, .noAlignedResult)

        let errorDriver = ContextualTranslationDriver(availabilityProvider: { .installed },
                                                      cacheLookup: { _ in nil },
                                                      translator: { _ in
                                                          throw ContextualTranslationError.invalidConfiguration
                                                      })
        await errorDriver.prepare(try makeIdentity(selected: "read"))
        await errorDriver.translateWithInjectedTranslator()
        if case .failed = errorDriver.state {
            // A real configuration error stays distinct from a no-alignment result.
        } else {
            XCTFail("Backend/configuration errors must remain visible as errors")
        }
    }

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

    func testEachWordInVerifiedPhraseRequestsItsOwnMeaning() async throws {
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
        XCTAssertEqual(first.selectedSourcePhrase, "read")
        XCTAssertEqual(second.selectedSourcePhrase, "books")
        XCTAssertNotEqual(first.selectedSourceSpans, second.selectedSourceSpans)
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
        try await Task.sleep(for: .milliseconds(100))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        assertContextualNoResultRendered(in: host.view, testCase: self)
    }

    func testMountedCachedNoAlignmentShowsHoverNoneWithoutAvailabilityCheck() async throws {
        let cacheChecked = expectation(description: "The mounted hover checks the exact cached selection")
        let driver = ContextualTranslationDriver(availabilityProvider: {
            XCTFail("A definitive cached no-alignment result must skip language availability")
            return .unsupported
        }, cacheLookup: { _ in
            cacheChecked.fulfill()
            return .noAlignedResult
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

        await fulfillment(of: [cacheChecked], timeout: 5)
        try await Task.sleep(for: .milliseconds(100))
        host.view.layoutIfNeeded()
        XCTAssertEqual(driver.state, .noAlignedResult)
        assertContextualNoResultRendered(in: host.view, testCase: self)
    }

    func testContextualNoResultVisualOCRRecognizesKnownChineseFixture() {
        let size = CGSize(width: 320, height: 72)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            ("语境：无" as NSString).draw(
                in: CGRect(x: 12, y: 15, width: 296, height: 42),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 20, weight: .semibold),
                    .foregroundColor: UIColor.black
                ]
            )
        }
        assertContextualNoResultRecognized(in: image, testCase: self)
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

@MainActor
func assertContextualNoResultRendered(in root: UIView,
                                      testCase: XCTestCase,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
    let size = root.bounds.size
    guard size.width > 0, size.height > 0 else {
        XCTFail("Cannot capture the contextual no-result view with empty bounds", file: file, line: line)
        return
    }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 4
    format.opaque = true
    var didDrawHierarchy = false
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        context.cgContext.setFillColor(UIColor.white.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: size))
        didDrawHierarchy = root.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
    }
    assertContextualNoResultRecognized(in: image,
                                      drawingSucceeded: didDrawHierarchy,
                                      testCase: testCase,
                                      file: file,
                                      line: line)
}

@MainActor
func assertContextualNoResultRecognized(in image: UIImage,
                                        drawingSucceeded: Bool = true,
                                        testCase: XCTestCase,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) {
    let recognizedLines: [String]
    do {
        guard let cgImage = image.cgImage else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["zh-Hans"]
        try VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:]).perform([request])
        recognizedLines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    } catch {
        attachContextualNoResultFailure(image, to: testCase)
        XCTFail("Vision could not inspect the contextual no-result image: \(error)", file: file, line: line)
        return
    }

    let phraseWasRecognized = recognizedLines.contains(where: containsContextualNoResultMarker)
    let evidenceIsValid = drawingSucceeded && phraseWasRecognized
    if !evidenceIsValid {
        attachContextualNoResultFailure(image, to: testCase)
    }
    XCTAssertTrue(evidenceIsValid,
                  "Expected the contextual no-result marker ‘语境：无’ within an OCR line "
                    + "(internal whitespace and colon width normalized). "
                    + "drawHierarchy=\(drawingSucceeded), OCR lines=\(recognizedLines)",
                  file: file,
                  line: line)
}

private func containsContextualNoResultMarker(_ line: String) -> Bool {
    let pattern = #"(?<![\p{L}\p{N}])语\s*境\s*[:：]\s*无(?=$|[\s\p{P}])"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
    return expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
}

@MainActor
private func attachContextualNoResultFailure(_ image: UIImage, to testCase: XCTestCase) {
    let attachment = XCTAttachment(image: image)
    attachment.name = "contextual-no-result-visual-evidence"
    attachment.lifetime = .keepAlways
    testCase.add(attachment)
}

private actor DriverLifecycleCallCounter {
    private(set) var cacheLookups = 0
    private(set) var availabilityChecks = 0
    private(set) var translations = 0

    func recordCacheLookup() { cacheLookups += 1 }
    func recordAvailability() { availabilityChecks += 1 }
    func recordTranslation() { translations += 1 }
    func snapshot() -> (cacheLookups: Int, availabilityChecks: Int, translations: Int) {
        (cacheLookups, availabilityChecks, translations)
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

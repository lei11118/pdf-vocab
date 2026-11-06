import XCTest
@testable import PdfVocab

@MainActor
final class OfflineTranslationPreparationTests: XCTestCase {
    func testRefreshOnlyReportsAvailabilityAndDoesNotStartPreparation() async {
        var statusChecks = 0
        let model = OfflineTranslationPreparationModel(availabilityProvider: {
            statusChecks += 1
            return .supported
        })

        XCTAssertEqual(model.state, .checking)
        XCTAssertFalse(model.isPreparing)
        await model.refresh()

        XCTAssertEqual(model.state, .supported)
        XCTAssertEqual(statusChecks, 1)
        XCTAssertFalse(model.isPreparing, "Availability checks must not prepare a language pack")
    }

    func testInstalledSupportedAndUnsupportedAvailabilityAreMappedFaithfully() async {
        let installed = OfflineTranslationPreparationModel(availabilityProvider: { .installed })
        let supported = OfflineTranslationPreparationModel(availabilityProvider: { .supported })
        let unsupported = OfflineTranslationPreparationModel(availabilityProvider: { .unsupported })

        await installed.refresh()
        await supported.refresh()
        await unsupported.refresh()

        XCTAssertEqual(installed.state, .installed)
        XCTAssertEqual(supported.state, .supported, "Supported must not be reported as installed")
        XCTAssertEqual(unsupported.state, .unsupported)
    }

    func testCancellationSuppressesStaleFailureAndPreparationCanRetry() async {
        var statusChecks = 0
        let model = OfflineTranslationPreparationModel(availabilityProvider: {
            statusChecks += 1
            return .supported
        })
        await model.refresh()

        let cancelledRequest = try! XCTUnwrap(model.beginPreparation())
        var operationStarted = false
        let cancelledTask = Task { @MainActor in
            operationStarted = true
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await model.cancelPreparation(requestID: cancelledRequest)
        }
        while !operationStarted { await Task.yield() }
        cancelledTask.cancel()
        await cancelledTask.value

        XCTAssertEqual(model.state, .supported)
        XCTAssertFalse(model.isPreparing)

        let failedRequest = try! XCTUnwrap(model.beginPreparation())
        await model.finishPreparation(requestID: failedRequest, failureMessage: PreparationFailure.expected.localizedDescription)
        guard case .failed(let message) = model.state else {
            return XCTFail("A failed prepare attempt should remain visible after rechecking availability")
        }
        XCTAssertEqual(message, PreparationFailure.expected.localizedDescription)
        XCTAssertEqual(model.availabilityAfterFailure, .supported)

        let retryRequest = try! XCTUnwrap(model.beginPreparation())
        await model.finishPreparation(requestID: retryRequest)

        XCTAssertEqual(model.state, .supported, "A successful prepare call must not be treated as proof that the pack is installed")
        XCTAssertFalse(model.isPreparing)
        XCTAssertEqual(statusChecks, 3, "Initial refresh, failed-prepare recheck, and successful-prepare recheck")
    }

    func testViewLeavingDuringFailureRecheckCannotPublishAStaleError() async {
        var statusChecks = 0
        var recheckStarted = false
        let model = OfflineTranslationPreparationModel(availabilityProvider: {
            statusChecks += 1
            if statusChecks == 1 { return .supported }
            recheckStarted = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return .supported
        })
        await model.refresh()
        let request = try! XCTUnwrap(model.beginPreparation())

        let preparationTask = Task { @MainActor in
            await model.finishPreparation(requestID: request, failureMessage: PreparationFailure.expected.localizedDescription)
        }
        while !recheckStarted { await Task.yield() }
        model.cancelPending()
        preparationTask.cancel()
        await preparationTask.value

        XCTAssertEqual(model.state, .checking)
        XCTAssertFalse(model.isPreparing)
    }
}

private enum PreparationFailure: Error, LocalizedError {
    case expected

    var errorDescription: String? { "Expected preparation failure" }
}
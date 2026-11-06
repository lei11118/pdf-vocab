import SwiftUI
import Translation

enum OfflineTranslationAvailability: Equatable {
    case installed
    case supported
    case unsupported
}

@MainActor
final class OfflineTranslationPreparationModel: ObservableObject {
    enum State: Equatable {
        case checking
        case installed
        case supported
        case unsupported
        case failed(String)
    }

    typealias AvailabilityProvider = @MainActor () async throws -> OfflineTranslationAvailability

    @Published private(set) var state: State = .checking
    @Published private(set) var availabilityAfterFailure: OfflineTranslationAvailability?
    @Published private(set) var isPreparing = false

    private let availabilityProvider: AvailabilityProvider
    private var activeCheckID: UUID?
    private var activePreparationID: UUID?

    init(availabilityProvider: AvailabilityProvider? = nil) {
        self.availabilityProvider = availabilityProvider ?? Self.systemAvailability
    }

    func refresh() async {
        guard !isPreparing else { return }
        let checkID = UUID()
        activeCheckID = checkID
        availabilityAfterFailure = nil
        state = .checking

        do {
            let availability = try await availabilityProvider()
            try Task.checkCancellation()
            guard activeCheckID == checkID, activePreparationID == nil else { return }
            activeCheckID = nil
            state = Self.state(for: availability)
        } catch {
            guard activeCheckID == checkID else { return }
            activeCheckID = nil
            guard !(error is CancellationError), !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Starts a request only in response to an explicit user action.
    func beginPreparation() -> UUID? {
        guard !isPreparing else { return nil }
        switch state {
        case .supported, .failed:
            break
        case .checking, .installed, .unsupported:
            return nil
        }

        activeCheckID = nil
        let requestID = UUID()
        activePreparationID = requestID
        isPreparing = true
        return requestID
    }

    /// Records the preparation result, then checks the system status again.
    func finishPreparation(requestID: UUID, failureMessage: String? = nil) async {
        guard isPreparing, activePreparationID == requestID else { return }
        isPreparing = false

        guard let failureMessage else {
            activePreparationID = nil
            await refresh()
            return
        }

        state = .checking
        availabilityAfterFailure = try? await availabilityProvider()
        guard activePreparationID == requestID, !Task.isCancelled else {
            if activePreparationID == requestID {
                state = availabilityAfterFailure.map(Self.state(for:)) ?? .checking
                availabilityAfterFailure = nil
                activePreparationID = nil
            }
            return
        }
        activePreparationID = nil
        state = .failed(failureMessage)
    }

    func cancelPreparation(requestID: UUID) {
        guard activePreparationID == requestID else { return }
        activePreparationID = nil
        isPreparing = false
        if case .failed = state {
            state = availabilityAfterFailure.map(Self.state(for:)) ?? .checking
            availabilityAfterFailure = nil
        }
    }

    /// Invalidates in-flight results when the view disappears or the user cancels.
    func cancelPending() {
        activeCheckID = nil
        activePreparationID = nil
        isPreparing = false
        if case .failed = state {
            state = availabilityAfterFailure.map(Self.state(for:)) ?? .checking
            availabilityAfterFailure = nil
        }
    }

    private static func state(for availability: OfflineTranslationAvailability) -> State {
        switch availability {
        case .installed: .installed
        case .supported: .supported
        case .unsupported: .unsupported
        }
    }

    private static func systemAvailability() async -> OfflineTranslationAvailability {
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier),
            to: Locale.Language(identifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier)
        )
        switch status {
        case .installed:
            return OfflineTranslationAvailability.installed
        case .supported:
            return OfflineTranslationAvailability.supported
        case .unsupported:
            return OfflineTranslationAvailability.unsupported
        @unknown default:
            return OfflineTranslationAvailability.unsupported
        }
    }
}

@MainActor
struct OfflineTranslationPreparationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: OfflineTranslationPreparationModel
    @State private var preparationConfiguration: TranslationSession.Configuration?
    @State private var preparationRequestID: UUID?
    @State private var refreshRequestID = UUID()

    init(model: OfflineTranslationPreparationModel? = nil) {
        _model = StateObject(wrappedValue: model ?? OfflineTranslationPreparationModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3s) {
            HStack(spacing: DS.Space.xs) {
                if model.isPreparing || model.state == .checking {
                    ProgressView().controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(statusText)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(model.state.isFailure ? DS.foreground2 : DS.foreground3)
                    .accessibilityIdentifier("offline-translation-status")
                Spacer(minLength: DS.Space.xs)
                actionButtons
            }

            if case .failed(let message) = model.state {
                Text(failureDetail(message))
                    .font(DS.Fonts.caption2)
                    .foregroundStyle(DS.foreground3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("offline-translation-failure-detail")
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.foreground1.opacity(0.035), in: RoundedRectangle(cornerRadius: DS.Radius.regular))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("offline-translation-preparation")
        .translationTask(preparationConfiguration) { session in
            guard let requestID = preparationRequestID else { return }
            do {
                try Task.checkCancellation()
                try await session.prepareTranslation()
                try Task.checkCancellation()
                await model.finishPreparation(requestID: requestID)
            } catch {
                if error is CancellationError || Task.isCancelled {
                    await model.cancelPreparation(requestID: requestID)
                } else {
                    await model.finishPreparation(requestID: requestID, failureMessage: error.localizedDescription)
                }
            }
        }
        .task(id: OfflineTranslationRefreshTaskID(scenePhase: scenePhase, requestID: refreshRequestID)) {
            guard scenePhase == .active else { return }
            await model.refresh()
        }
        .onDisappear {
            model.cancelPending()
            preparationRequestID = nil
            preparationConfiguration = nil
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if model.isPreparing {
            Button("取消") { cancelPreparation() }
                .font(DS.Fonts.caption)
                .accessibilityIdentifier("offline-translation-cancel")
        } else {
            HStack(spacing: DS.Space.xs) {
                if canPrepare {
                    Button(prepareButtonTitle) { requestPreparation() }
                        .font(DS.Fonts.caption)
                        .accessibilityIdentifier("offline-translation-prepare")
                }
                if model.state != .checking {
                    Button("重新检查") { requestRefresh() }
                        .font(DS.Fonts.caption)
                        .accessibilityIdentifier("offline-translation-refresh")
                }
            }
        }
    }

    private var canPrepare: Bool {
        switch model.state {
        case .supported, .failed: true
        case .checking, .installed, .unsupported: false
        }
    }

    private var prepareButtonTitle: String {
        if case .failed = model.state { return "重试准备" }
        return "准备离线翻译"
    }

    private var statusText: String {
        let pair = "英语 → 简体中文"
        if model.isPreparing { return "\(pair) · 正在准备" }
        switch model.state {
        case .checking: return "\(pair) · 正在检查"
        case .installed: return "\(pair) · 已安装"
        case .supported: return "\(pair) · 可下载"
        case .unsupported: return "\(pair) · 不支持"
        case .failed: return "\(pair) · 准备或检查失败"
        }
    }

    private func failureDetail(_ message: String) -> String {
        if let availability = model.availabilityAfterFailure {
            return "\(availabilityText(availability))；\(message)"
        }
        return message
    }

    private func availabilityText(_ availability: OfflineTranslationAvailability) -> String {
        switch availability {
        case .installed: "当前可用性：已安装"
        case .supported: "当前可用性：可下载"
        case .unsupported: "当前可用性：不支持"
        }
    }

    private func requestRefresh() {
        refreshRequestID = UUID()
    }

    private func requestPreparation() {
        guard let requestID = model.beginPreparation() else { return }
        preparationRequestID = requestID
        var configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier),
            target: Locale.Language(identifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier)
        )
        configuration.invalidate()
        preparationConfiguration = configuration
    }

    private func cancelPreparation() {
        model.cancelPending()
        preparationRequestID = nil
        preparationConfiguration = nil
    }
}

private struct OfflineTranslationRefreshTaskID: Equatable {
    let scenePhase: ScenePhase
    let requestID: UUID
}

private extension OfflineTranslationPreparationModel.State {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

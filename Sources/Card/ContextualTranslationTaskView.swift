import SwiftUI
import Translation
import Combine

enum ContextualTranslationPresentation: Hashable {
    case card
    case hover
}

/// Owns the local identity barrier for one contextual request. A disappearing
/// card or hover cancels only this driver; it never invalidates shared requests.
@MainActor
final class ContextualTranslationDriver: ObservableObject {
    enum Availability: Equatable {
        case systemUnavailable
        case installed
        case supported
        case unsupported
    }

    typealias AvailabilityProvider = () async -> Availability
    typealias Translator = (ContextualTranslationRequest) async throws -> ContextualTranslationCandidate

    enum State: Equatable {
        case disabled
        case checking
        case needsPreparation
        case unsupported
        case unavailable(String)
        case translating
        case candidate(ContextualTranslationCandidate)
        case failed(String)
        case silent
    }

    struct Identity: Equatable {
        let selection: ContextualSelection
        let isEnabled: Bool
        let presentation: ContextualTranslationPresentation
        let retryGeneration: Int
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var configuration: TranslationSession.Configuration?
    private let injectedAvailabilityProvider: AvailabilityProvider?
    private let injectedTranslator: Translator?
    private var generation: UInt64 = 0
    private var activeIdentity: Identity?
    private var activeRequest: ContextualTranslationRequest?
    private var activeRequestID: UUID?

    init(availabilityProvider: AvailabilityProvider? = nil,
         translator: Translator? = nil) {
        injectedAvailabilityProvider = availabilityProvider
        injectedTranslator = translator
    }

    var hasCandidate: Bool {
        if case .candidate = state { return true }
        return false
    }

    @discardableResult
    func activate(_ identity: Identity) -> UInt64 {
        guard activeIdentity != identity else { return generation }
        generation &+= 1
        activeIdentity = identity
        activeRequestID = nil
        activeRequest = nil
        configuration = nil
        state = identity.isEnabled ? .checking : .disabled
        DiagLog.log("context.translation.activate enabled=\(identity.isEnabled ? 1 : 0) surface=\(identity.presentation == .card ? "card" : "hover") generation=\(generation)")
        return generation
    }

    func prepare(_ identity: Identity) async {
        let localGeneration = activate(identity)

        guard isCurrent(identity, generation: localGeneration), !Task.isCancelled,
              identity.isEnabled else { return }
        guard let sentenceContext = identity.selection.sentenceContext else {
            state = .unavailable("当前选区没有可验证的完整句子上下文，可查看词典释义。")
            DiagLog.log("context.translation.prepare=missing-context")
            return
        }

        let request: ContextualTranslationRequest
        do {
            request = try ContextualTranslationRequest.make(
                from: sentenceContext,
                verifiedPhraseGroupSpan: identity.selection.verifiedPhraseGroupSpan
            )
        } catch {
            state = .unavailable(error.localizedDescription)
            let reason = (error as? ContextualTranslationError)?.diagnosticCode ?? "unexpected"
            DiagLog.log("context.translation.prepare=invalid-request reason=\(reason)")
            return
        }

        let availability: Availability
        if let injectedAvailabilityProvider {
            availability = await injectedAvailabilityProvider()
        } else {
            guard #available(iOS 26.4, *) else {
                availability = .systemUnavailable
                state = .unavailable("系统 Token 对齐需要 iPadOS 26.4 或更高版本，当前版本仍可使用词典入口。")
                DiagLog.log("context.translation.availability=system-unavailable")
                return
            }
            switch await LanguageAvailability().status(
                from: Locale.Language(identifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier),
                to: Locale.Language(identifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier)
            ) {
            case .installed: availability = .installed
            case .supported: availability = .supported
            case .unsupported: availability = .unsupported
            @unknown default: availability = .unsupported
            }
        }
        guard isCurrent(identity, generation: localGeneration), !Task.isCancelled else { return }

        switch availability {
        case .installed:
            activeRequest = request
            activeRequestID = UUID()
            state = .translating
            var next = TranslationSession.Configuration(
                source: Locale.Language(identifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier),
                target: Locale.Language(identifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier)
            )
            next.invalidate()
            configuration = next
            DiagLog.log("context.translation.availability=installed group=\(request.selectedPhraseGroup == nil ? 0 : 1)")
        case .supported:
            state = identity.presentation == .card ? .needsPreparation : .silent
            DiagLog.log("context.translation.availability=supported")
        case .unsupported:
            state = .unsupported
            DiagLog.log("context.translation.availability=unsupported")
        case .systemUnavailable:
            state = .unavailable("系统 Token 对齐需要 iPadOS 26.4 或更高版本，当前版本仍可使用词典入口。")
            DiagLog.log("context.translation.availability=system-unavailable")
        }
    }

    func translate(using session: TranslationSession) async {
        guard #available(iOS 26.4, *) else { return }
        await runTranslation { request in
            let translator = AppleContextualTranslationAdapter.makeTranslator(
                using: session,
                sourceLanguageIdentifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier,
                targetLanguageIdentifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier
            )
            return try await ContextualTranslationService.shared.translate(
                request,
                sourceLanguageIdentifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier,
                targetLanguageIdentifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier,
                backendVersion: AppleContextualTranslationAdapter.backendVersion,
                using: translator
            )
        }
    }

    /// Internal injection seam for lifecycle tests; production views use the
    /// system TranslationSession path above.
    func translateWithInjectedTranslator() async {
        guard let injectedTranslator else { return }
        await runTranslation(using: injectedTranslator)
    }

    private func runTranslation(using translator: @escaping Translator) async {
        guard let identity = activeIdentity,
              let request = activeRequest,
              let requestID = activeRequestID,
              identity.isEnabled else { return }
        let localGeneration = generation

        do {
            let candidate = try await translator(request)
            try Task.checkCancellation()
            guard isCurrent(identity, generation: localGeneration),
                  activeRequestID == requestID,
                  activeRequest == request,
                  identity.isEnabled else {
                DiagLog.log("context.translation.result=stale")
                return
            }
            state = .candidate(candidate)
            activeRequestID = nil
            configuration = nil
            DiagLog.log("context.translation.result=accepted")
        } catch {
            guard isCurrent(identity, generation: localGeneration),
                  activeRequestID == requestID,
                  identity.isEnabled,
                  !(error is CancellationError), !Task.isCancelled else {
                if error is CancellationError || Task.isCancelled {
                    DiagLog.log("context.translation.result=cancelled")
                } else {
                    DiagLog.log("context.translation.result=stale-error")
                }
                return
            }
            state = .failed(error.localizedDescription)
            activeRequestID = nil
            configuration = nil
            let reason = (error as? ContextualTranslationError)?.diagnosticCode ?? "unexpected"
            DiagLog.log("context.translation.result=failed reason=\(reason)")
        }
    }

    func deactivate() {
        generation &+= 1
        activeIdentity = nil
        activeRequestID = nil
        activeRequest = nil
        configuration = nil
        state = .disabled
        DiagLog.log("context.translation.deactivate")
    }

    private func isCurrent(_ identity: Identity, generation expected: UInt64) -> Bool {
        generation == expected && activeIdentity == identity
    }
}

/// Shared TranslationSession host for the full contextual card and the compact
/// hover bubble. Only the card offers language preparation UI.
@MainActor
struct ContextualTranslationTaskView: View {
    let selection: ContextualSelection
    let isEnabled: Bool
    var presentation: ContextualTranslationPresentation = .card
    @ObservedObject var driver: ContextualTranslationDriver
    @StateObject private var preparationModel = OfflineTranslationPreparationModel()
    @State private var retryGeneration = 0

    init(selection: ContextualSelection,
         isEnabled: Bool,
         presentation: ContextualTranslationPresentation = .card,
         driver: ContextualTranslationDriver) {
        self.selection = selection
        self.isEnabled = isEnabled
        self.presentation = presentation
        self.driver = driver
    }

    private var identity: ContextualTranslationDriver.Identity {
        ContextualTranslationDriver.Identity(selection: selection,
                                             isEnabled: isEnabled,
                                             presentation: presentation,
                                             retryGeneration: retryGeneration)
    }

    var body: some View {
        Group {
            if presentation == .card {
                cardContent
            } else {
                hoverContent
            }
        }
        .task(id: identity) { await driver.prepare(identity) }
        .translationTask(driver.configuration) { session in await driver.translate(using: session) }
        .onChange(of: identity) { _, newIdentity in _ = driver.activate(newIdentity) }
        .onDisappear { driver.deactivate() }
        .onChange(of: preparationModel.state) { _, newState in
            if case .installed = newState, case .needsPreparation = driver.state {
                retryGeneration &+= 1
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            switch driver.state {
            case .disabled:
                Text("启用语境 Token 阅读后，才会请求 Token 对齐候选。")
                    .font(DS.Fonts.caption).foregroundStyle(DS.foreground3)
            case .checking:
                ProgressView("检查端侧翻译语言…").font(DS.Fonts.caption)
            case .needsPreparation:
                Text("需要先由你准备英语到简体中文的离线翻译语言。准备状态不代表 Token 对齐成功。")
                    .font(DS.Fonts.caption).foregroundStyle(DS.foreground2)
                OfflineTranslationPreparationView(model: preparationModel)
                retryButton
            case .unsupported:
                Text("此设备当前不支持英语到简体中文的端侧翻译，可查看词典释义。")
                    .font(DS.Fonts.caption).foregroundStyle(DS.foreground2)
            case .unavailable(let message), .failed(let message):
                Text(message).font(DS.Fonts.caption).foregroundStyle(DS.foreground2)
                retryButton
            case .translating:
                ProgressView("正在生成选中 Token 的系统对齐候选…").font(DS.Fonts.caption)
            case .candidate(let candidate):
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Label("语境译义候选 · 系统对齐，待校对", systemImage: "text.magnifyingglass")
                        .font(DS.Fonts.caption.weight(.semibold)).foregroundStyle(DS.foreground2)
                    Text(candidate.sourcePhrase).font(DS.Fonts.caption).foregroundStyle(DS.foreground3)
                        .textSelection(.enabled)
                    Text(candidate.translatedPhrase).font(DS.Fonts.wordBody).foregroundStyle(DS.foreground1)
                        .textSelection(.enabled).accessibilityIdentifier("contextual-translation-candidate")
                }
            case .silent:
                EmptyView()
            }
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.background2, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contextual-translation-section")
    }

    @ViewBuilder
    private var hoverContent: some View {
        if case .candidate(let candidate) = driver.state {
            ScrollView(.vertical, showsIndicators: false) {
                Text(candidate.translatedPhrase)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DS.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("contextual-hover-candidate")
            }
            .frame(maxHeight: 64)
        }
    }

    private var retryButton: some View {
        Button("重新检查并尝试语境对齐") { retryGeneration &+= 1 }
            .font(DS.Fonts.caption)
            .buttonStyle(.bordered)
            .accessibilityIdentifier("contextual-translation-retry")
    }
}

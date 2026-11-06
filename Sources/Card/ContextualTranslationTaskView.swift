import SwiftUI
import Translation

/// Starts an automatic token-alignment request only after the feature switch,
/// sentence validation, OS availability, and language installation checks pass.
@MainActor
struct ContextualTranslationTaskView: View {
    let selection: ContextualSelection
    let isEnabled: Bool

    private enum TranslationState: Equatable {
        case disabled
        case checking
        case needsPreparation
        case unsupported
        case unavailable(String)
        case translating
        case candidate(ContextualTranslationCandidate)
        case failed(String)
    }

    @State private var state: TranslationState = .checking
    @State private var configuration: TranslationSession.Configuration?
    @State private var activeRequest: ContextualTranslationRequest?
    @State private var activeSelection: ContextualSelection?
    @State private var activeRequestID: UUID?
    @State private var retryGeneration = 0
    @StateObject private var preparationModel: OfflineTranslationPreparationModel

    init(selection: ContextualSelection, isEnabled: Bool) {
        self.selection = selection
        self.isEnabled = isEnabled
        _preparationModel = StateObject(wrappedValue: OfflineTranslationPreparationModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            stateContent
        }
        .padding(DS.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.background2, in: RoundedRectangle(cornerRadius: DS.Radius.regular, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("contextual-translation-section")
        .task(id: TaskIdentity(selection: selection,
                               isEnabled: isEnabled,
                               retryGeneration: retryGeneration)) {
            await prepare(TaskIdentity(selection: selection,
                                       isEnabled: isEnabled,
                                       retryGeneration: retryGeneration))
        }
        .translationTask(configuration) { session in
            await translate(using: session)
        }
        .onChange(of: selection) { _, _ in
            activeRequestID = nil
            activeRequest = nil
            activeSelection = nil
            configuration = nil
            state = isEnabled ? .checking : .disabled
        }
        .onChange(of: isEnabled) { _, enabled in
            activeRequestID = nil
            activeRequest = nil
            activeSelection = nil
            configuration = nil
            state = enabled ? .checking : .disabled
        }
        .onDisappear {
            activeRequestID = nil
            activeRequest = nil
            activeSelection = nil
            configuration = nil
        }
        .onChange(of: preparationModel.state) { _, newState in
            if case .installed = newState, case .needsPreparation = state {
                retryGeneration &+= 1
            }
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .disabled:
            Text("启用语境 Token 阅读后，才会请求 Token 对齐候选。")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.foreground3)
        case .checking:
            ProgressView("检查端侧翻译语言…")
                .font(DS.Fonts.caption)
        case .needsPreparation:
            Text("需要先由你准备英语到简体中文的离线翻译语言。准备状态不代表 Token 对齐成功。")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.foreground2)
            OfflineTranslationPreparationView(model: preparationModel)
            retryButton
        case .unsupported:
            Text("此设备当前不支持英语到简体中文的端侧翻译，可查看词典释义。")
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.foreground2)
        case .unavailable(let message), .failed(let message):
            Text(message)
                .font(DS.Fonts.caption)
                .foregroundStyle(DS.foreground2)
            retryButton
        case .translating:
            ProgressView("正在生成选中 Token 的系统对齐候选…")
                .font(DS.Fonts.caption)
        case .candidate(let candidate):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label("语境译义候选 · 系统对齐，待校对", systemImage: "text.magnifyingglass")
                    .font(DS.Fonts.caption.weight(.semibold))
                    .foregroundStyle(DS.foreground2)
                Text(candidate.sourcePhrase)
                    .font(DS.Fonts.caption)
                    .foregroundStyle(DS.foreground3)
                    .textSelection(.enabled)
                Text(candidate.translatedPhrase)
                    .font(DS.Fonts.wordBody)
                    .foregroundStyle(DS.foreground1)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("contextual-translation-candidate")
            }
        }
    }

    private var retryButton: some View {
        Button("重新检查并尝试语境对齐") {
            retryGeneration &+= 1
        }
        .font(DS.Fonts.caption)
        .buttonStyle(.bordered)
        .accessibilityIdentifier("contextual-translation-retry")
    }

    private func prepare(_ identity: TaskIdentity) async {
        activeRequestID = nil
        activeRequest = nil
        activeSelection = nil
        configuration = nil
        state = identity.isEnabled ? .checking : .disabled
        guard isCurrent(identity), !Task.isCancelled else { return }
        guard identity.isEnabled else { return }
        guard #available(iOS 26.4, *) else {
            state = .unavailable("系统 Token 对齐需要 iPadOS 26.4 或更高版本，当前版本仍可使用词典入口。")
            return
        }
        guard let sentenceContext = identity.selection.sentenceContext else {
            state = .unavailable("当前选区没有可验证的完整句子上下文，可查看词典释义。")
            return
        }

        let request: ContextualTranslationRequest
        do {
            request = try ContextualTranslationRequest.make(from: sentenceContext)
        } catch {
            state = .unavailable(error.localizedDescription)
            return
        }

        let languageAvailability = LanguageAvailability()
        let availability = await languageAvailability.status(
            from: Locale.Language(identifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier),
            to: Locale.Language(identifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier)
        )
        guard isCurrent(identity), !Task.isCancelled else { return }

        switch availability {
        case .installed:
            activeRequest = request
            activeSelection = identity.selection
            activeRequestID = UUID()
            state = .translating
            var nextConfiguration = TranslationSession.Configuration(
                source: Locale.Language(identifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier),
                target: Locale.Language(identifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier)
            )
            nextConfiguration.invalidate()
            configuration = nextConfiguration
        case .supported:
            state = .needsPreparation
        case .unsupported:
            state = .unsupported
        @unknown default:
            state = .unsupported
        }
    }

    private func translate(using session: TranslationSession) async {
        guard #available(iOS 26.4, *),
              let request = activeRequest,
              let expectedSelection = activeSelection,
              let requestID = activeRequestID,
              isEnabled else { return }

        do {
            let translator = AppleContextualTranslationAdapter.makeTranslator(
                using: session,
                sourceLanguageIdentifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier,
                targetLanguageIdentifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier
            )
            let candidate = try await ContextualTranslationService.shared.translate(
                request,
                sourceLanguageIdentifier: StandaloneSentenceTranslationCache.sourceLanguageIdentifier,
                targetLanguageIdentifier: StandaloneSentenceTranslationCache.targetLanguageIdentifier,
                backendVersion: AppleContextualTranslationAdapter.backendVersion,
                using: translator
            )
            try Task.checkCancellation()
            guard activeRequestID == requestID,
                  activeRequest == request,
                  activeSelection == expectedSelection,
                  selection == expectedSelection,
                  isEnabled,
                  expectedSelection.sentenceContext != nil else { return }
            state = .candidate(candidate)
            activeRequestID = nil
            configuration = nil
        } catch {
            guard activeRequestID == requestID, isEnabled,
                  !(error is CancellationError), !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
            activeRequestID = nil
            configuration = nil
        }
    }

    private func isCurrent(_ identity: TaskIdentity) -> Bool {
        identity == TaskIdentity(selection: selection,
                                 isEnabled: isEnabled,
                                 retryGeneration: retryGeneration)
    }

    private struct TaskIdentity: Equatable {
        let selection: ContextualSelection
        let isEnabled: Bool
        let retryGeneration: Int
    }
}

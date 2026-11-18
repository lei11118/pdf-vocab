import Foundation
import LlamaRuntime

struct TranslationModel: Identifiable, Sendable {
    let id: String
    let name: String
    let repository: String
    let revision: String
    let filename: String
    let bytes: Int64
    let sha256: String
    var promptStyle: MetalTranslationSession.PromptStyle = .hyMT2

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!
    }

    var sourceURL: URL {
        URL(string: "https://huggingface.co/\(repository)/tree/\(revision)")!
    }

    static let preferenceKey = "contextReading.translationModel"
    static let labBackendKey = "contextReading.translationLabBackend"
    static let systemID = "apple"

    enum Backend: String, CaseIterable, Identifiable, Sendable {
        case metal, coreMLAll, coreMLNeural
        var id: String { rawValue }
        var title: String {
            switch self {
            case .metal: return "llama.cpp Metal"
            case .coreMLAll: return "Core ML · 自动分配"
            case .coreMLNeural: return "Core ML · CPU 与 Neural Engine"
            }
        }
    }

    static var coreMLLabModel: URL {
        URL.documentsDirectory.appending(path: "TranslationLab/Hy-MT2-1.8B.mlmodelc", directoryHint: .isDirectory)
    }

    func runtimeBackend(_ requested: Backend) -> Backend {
        #if DEBUG && !targetEnvironment(simulator)
        if id == "hy-mt2-18-q4" { return requested }
        #endif
        return .metal
    }

    static let candidates = [
        TranslationModel(id: "hy-mt2-18-q4", name: "Hy-MT2 1.8B · Q4_K_M",
                         repository: "tencent/Hy-MT2-1.8B-GGUF",
                         revision: "a0c709d9fac510f2c807aa3af52872340dc37a4a",
                         filename: "Hy-MT2-1.8B-Q4_K_M.gguf", bytes: 1_133_080_448,
                         sha256: "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"),
        TranslationModel(id: "hy-mt2-18-2bit", name: "Hy-MT2 1.8B · 2-bit",
                         repository: "tencent/Hy-MT2-1.8B-2Bit-GGUF",
                         revision: "b630487d19ab7f336664a15b07c638d0d1071471",
                         filename: "Hy-MT2-1.8B-2Bit.gguf", bytes: 600_534_880,
                         sha256: "dcc33bbae9b28d923c8c76a64f6157840841d26f8774f3dfd770d5fabeeb1cd7"),
        TranslationModel(id: "hy-mt2-7-q4", name: "Hy-MT2 7B · Q4_K_M",
                         repository: "tencent/Hy-MT2-7B-GGUF",
                         revision: "ab8472660ac61fac25f1af43fac2599d52a8a775",
                         filename: "Hy-MT2-7B-Q4_K_M.gguf", bytes: 4_624_648_896,
                         sha256: "9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b"),
        TranslationModel(id: "qwen35-4-q4", name: "Qwen3.5 4B · Q4_K_M",
                         repository: "unsloth/Qwen3.5-4B-GGUF",
                         revision: "e87f176479d0855a907a41277aca2f8ee7a09523",
                         filename: "Qwen3.5-4B-Q4_K_M.gguf", bytes: 2_740_937_888,
                         sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
                         promptStyle: .qwen35ShortGloss),
    ]

    static var available: [TranslationModel] {
        #if DEBUG && !targetEnvironment(simulator)
        // Physical-device lab builds need access before a configuration can qualify.
        let memory = ProcessInfo.processInfo.physicalMemory
        return candidates.filter { model in
            let minimumGiB: UInt64 = model.id == "hy-mt2-7-q4" || model.promptStyle == .qwen35ShortGloss ? 15 : 7
            return memory >= minimumGiB * 1_073_741_824
        }
        #else
        // Populate per-device entries from the physical-device qualification report.
        return []
        #endif
    }
}

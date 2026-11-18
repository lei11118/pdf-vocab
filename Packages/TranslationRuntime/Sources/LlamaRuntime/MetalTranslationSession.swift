import Foundation
import llama

public final class MetalTranslationSession {
    public enum Failure: Error {
        case model, context, input, inference, output
    }

    private static let initialize: Void = llama_backend_init()
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private let contextLength = 1536

    public init(modelURL: URL) throws {
        _ = Self.initialize
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = -1
        guard let model = modelURL.path.withCString({ llama_model_load_from_file($0, modelParameters) })
        else { throw Failure.model }
        var parameters = llama_context_default_params()
        parameters.n_ctx = UInt32(contextLength)
        parameters.n_batch = UInt32(contextLength)
        parameters.n_ubatch = 256
        parameters.n_threads = 2
        parameters.n_threads_batch = 2
        guard let vocabulary = llama_model_get_vocab(model),
              let context = llama_init_from_model(model, parameters) else {
            llama_model_free(model)
            throw Failure.context
        }
        self.model = model
        self.vocabulary = vocabulary
        self.context = context
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    public func generate(_ instruction: String, maximumOutput: Int) throws -> String {
        try Task.checkCancellation()
        // The single-user-turn form of Tencent's pinned Hy-MT2 chat template.
        let prompt = "<｜hy_begin▁of▁sentence｜><｜hy_User｜>\(instruction)<｜hy_Assistant｜>"
        let capacity = Int32(contextLength)
        var tokens = [llama_token](repeating: 0, count: contextLength)
        let count = prompt.withCString {
            llama_tokenize(vocabulary, $0, Int32(prompt.utf8.count), &tokens,
                           capacity, false, true)
        }
        guard count > 0, maximumOutput > 0, Int(count) + maximumOutput <= contextLength,
              let sampler = llama_sampler_init_greedy() else { throw Failure.input }
        defer { llama_sampler_free(sampler) }
        llama_memory_clear(llama_get_memory(context), false)
        let status = tokens.withUnsafeMutableBufferPointer {
            llama_decode(context, llama_batch_get_one($0.baseAddress, count))
        }
        guard status == 0 else { throw Failure.inference }

        var output: [UInt8] = []
        var buffer = [CChar](repeating: 0, count: 512)
        for _ in 0..<maximumOutput {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) {
                guard let result = String(bytes: output, encoding: .utf8) else { throw Failure.output }
                return result
            }
            let length = llama_token_to_piece(vocabulary, token, &buffer, 512, 0, false)
            guard length >= 0 else { throw Failure.output }
            output.append(contentsOf: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) })
            if output.last(where: { $0 != 10 && $0 != 13 && $0 != 32 }) == 125,
               let object = try? JSONSerialization.jsonObject(with: Data(output)),
               object is [String: Any] {
                guard let result = String(bytes: output, encoding: .utf8) else { throw Failure.output }
                return result
            }
            let nextStatus = withUnsafeMutablePointer(to: &token) {
                llama_decode(context, llama_batch_get_one($0, 1))
            }
            guard nextStatus == 0 else { throw Failure.inference }
        }
        throw Failure.output
    }

}

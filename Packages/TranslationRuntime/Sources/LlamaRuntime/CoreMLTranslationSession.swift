import CoreML
import Foundation
import llama

public final class CoreMLTranslationSession: TranslationInferenceSession {
    private let model: MLModel
    private let tokenizerModel: OpaquePointer
    private let vocabulary: OpaquePointer

    public init(compiledModel: URL, tokenizerGGUF: URL, computeUnits: MLComputeUnits) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: compiledModel, configuration: configuration)
        _ = MetalTranslationSession.initialize
        var parameters = llama_model_default_params()
        parameters.vocab_only = true
        guard let tokenizer = tokenizerGGUF.path.withCString({ llama_model_load_from_file($0, parameters) }) else {
            throw MetalTranslationSession.Failure.model
        }
        guard let vocabulary = llama_model_get_vocab(tokenizer) else {
            llama_model_free(tokenizer)
            throw MetalTranslationSession.Failure.model
        }
        tokenizerModel = tokenizer
        self.vocabulary = vocabulary
    }

    deinit { llama_model_free(tokenizerModel) }

    public func generate(_ instruction: String, maximumOutput: Int) throws -> String {
        let tokens = try MetalTranslationSession.tokenize(instruction, vocabulary: vocabulary,
                                                          maximumOutput: maximumOutput)
        let state = model.makeState()
        var next: llama_token = 0
        var position = 0
        while position < tokens.count {
            try Task.checkCancellation()
            let end = min(position + 128, tokens.count)
            next = try predict(Array(tokens[position..<end]), position: position, state: state)
            position = end
        }

        var output: [UInt8] = []
        for _ in 0..<maximumOutput {
            try Task.checkCancellation()
            if llama_vocab_is_eog(vocabulary, next) {
                guard let result = String(bytes: output, encoding: .utf8) else {
                    throw MetalTranslationSession.Failure.output
                }
                return result
            }
            try MetalTranslationSession.append(next, vocabulary: vocabulary, to: &output)
            if let result = MetalTranslationSession.completeJSON(output) { return result }
            next = try predict([next], position: position, state: state)
            position += 1
        }
        throw MetalTranslationSession.Failure.output
    }

    private func predict(_ ids: [llama_token], position: Int, state: MLState) throws -> llama_token {
        let input = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (index, token) in ids.enumerated() { input[index] = NSNumber(value: token) }
        let start = try MLMultiArray(shape: [1], dataType: .int32)
        start[0] = NSNumber(value: position)
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: input),
            "start_position": MLFeatureValue(multiArray: start),
        ])
        let result = try model.prediction(from: features, using: state)
        guard let output = result.featureValue(for: "next_token")?.multiArrayValue, output.count == 1 else {
            throw MetalTranslationSession.Failure.inference
        }
        return output[0].int32Value
    }
}

//
//  EnglishFallbackNetwork.swift
//  ClawdyVoice
//
//  The out-of-vocabulary fallback of the Misaki G2P: a tiny BART (d_model 128, one
//  encoder layer, one decoder layer, one head, 63-token vocab) that spells an unknown
//  word ("clawdy", a surname, a product name) into phonemes character by character.
//
//  MisakiSwift runs this network on MLX, which is Apple-silicon-only and macOS 15+.
//  Clawdy supports Intel and macOS 14.2, so this is a plain-Swift + Accelerate port of
//  the same forward pass over the same `us_bart.safetensors` weights (Hugging Face BART
//  layout: post-layer-norm blocks, positional embeddings offset by 2, tied input/output
//  embeddings, `final_logits_bias` added to the logits). Greedy decoding, max 50 steps,
//  exactly like the reference. A whole word decodes in well under a millisecond.
//

import Accelerate
import Foundation

/// A row-major float matrix (`rows × columns`), the only tensor shape the network needs.
struct FloatMatrix {
    var rows: Int
    var columns: Int
    var values: [Float]

    init(rows: Int, columns: Int, values: [Float]) {
        precondition(values.count == rows * columns, "FloatMatrix shape mismatch")
        self.rows = rows
        self.columns = columns
        self.values = values
    }

    init(zerosWithRows rows: Int, columns: Int) {
        self.init(rows: rows, columns: columns, values: [Float](repeating: 0, count: rows * columns))
    }

    subscript(row: Int, column: Int) -> Float {
        get { values[row * columns + column] }
        set { values[row * columns + column] = newValue }
    }

    func row(_ index: Int) -> ArraySlice<Float> {
        values[(index * columns)..<((index + 1) * columns)]
    }
}

/// `y = x · Wᵀ + b` with the Hugging Face `[out, in]` weight layout.
struct LinearLayer {
    let weight: FloatMatrix   // [outputSize, inputSize]
    let bias: [Float]?

    func apply(_ input: FloatMatrix) -> FloatMatrix {
        let outputSize = weight.rows
        var output = FloatMatrix(zerosWithRows: input.rows, columns: outputSize)
        // output[rows × out] = input[rows × in] · weightᵀ[in × out]
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(input.rows), Int32(outputSize), Int32(input.columns),
            1.0, input.values, Int32(input.columns),
            weight.values, Int32(weight.columns),
            0.0, &output.values, Int32(outputSize)
        )
        if let bias {
            for rowIndex in 0..<output.rows {
                for columnIndex in 0..<outputSize {
                    output[rowIndex, columnIndex] += bias[columnIndex]
                }
            }
        }
        return output
    }
}

/// Per-row layer normalisation with learned scale/shift (eps 1e-5, as in HF BART).
struct LayerNormLayer {
    let weight: [Float]
    let bias: [Float]
    let epsilon: Float = 1e-5

    func apply(_ input: FloatMatrix) -> FloatMatrix {
        var output = input
        let width = input.columns
        for rowIndex in 0..<input.rows {
            let row = Array(input.row(rowIndex))
            var mean: Float = 0
            vDSP_meanv(row, 1, &mean, vDSP_Length(width))
            var centered = row.map { $0 - mean }
            // Population variance (divide by N), as PyTorch's LayerNorm computes it.
            var sumOfSquares: Float = 0
            vDSP_svesq(centered, 1, &sumOfSquares, vDSP_Length(width))
            let variance = sumOfSquares / Float(width)
            let inverseStandardDeviation = 1 / sqrt(variance + epsilon)
            for columnIndex in 0..<width {
                centered[columnIndex] = centered[columnIndex] * inverseStandardDeviation * weight[columnIndex] + bias[columnIndex]
            }
            output.values.replaceSubrange((rowIndex * width)..<((rowIndex + 1) * width), with: centered)
        }
        return output
    }
}

/// Scaled dot-product attention with `numberOfHeads` heads (1 for this network).
struct MultiHeadAttentionLayer {
    let numberOfHeads: Int
    let queryProjection: LinearLayer
    let keyProjection: LinearLayer
    let valueProjection: LinearLayer
    let outputProjection: LinearLayer

    /// `isCausal` masks each query position from attending to LATER key positions (decoder self-attention).
    func apply(query queryInput: FloatMatrix, keyValue keyValueInput: FloatMatrix, isCausal: Bool) -> FloatMatrix {
        let modelSize = queryInput.columns
        let headSize = modelSize / numberOfHeads
        let queries = queryProjection.apply(queryInput)
        let keys = keyProjection.apply(keyValueInput)
        let values = valueProjection.apply(keyValueInput)
        let scale = 1 / Float(headSize).squareRoot()

        var context = FloatMatrix(zerosWithRows: queryInput.rows, columns: modelSize)
        for headIndex in 0..<numberOfHeads {
            let headColumns = (headIndex * headSize)..<((headIndex + 1) * headSize)
            for queryPosition in 0..<queries.rows {
                var scores = [Float](repeating: -Float.infinity, count: keys.rows)
                for keyPosition in 0..<keys.rows {
                    if isCausal && keyPosition > queryPosition { continue }
                    var dotProduct: Float = 0
                    for column in headColumns {
                        dotProduct += queries[queryPosition, column] * keys[keyPosition, column]
                    }
                    scores[keyPosition] = dotProduct * scale
                }
                let weights = Self.softmax(scores)
                for column in headColumns {
                    var weightedSum: Float = 0
                    for keyPosition in 0..<keys.rows where weights[keyPosition] != 0 {
                        weightedSum += weights[keyPosition] * values[keyPosition, column]
                    }
                    context[queryPosition, column] = weightedSum
                }
            }
        }
        return outputProjection.apply(context)
    }

    private static func softmax(_ scores: [Float]) -> [Float] {
        let maximum = scores.max() ?? 0
        let exponentials = scores.map { $0 == -Float.infinity ? 0 : exp($0 - maximum) }
        let total = exponentials.reduce(0, +)
        return exponentials.map { $0 / total }
    }
}

/// `fc2(gelu(fc1(x)))` with the exact (erf) GELU HF uses for `activation_function: "gelu"`.
struct FeedForwardLayer {
    let firstLinear: LinearLayer
    let secondLinear: LinearLayer

    func apply(_ input: FloatMatrix) -> FloatMatrix {
        var hidden = firstLinear.apply(input)
        for index in hidden.values.indices {
            let value = hidden.values[index]
            hidden.values[index] = 0.5 * value * (1 + erf(value / Float(2).squareRoot()))
        }
        return secondLinear.apply(hidden)
    }
}

struct BARTEncoderLayer {
    let selfAttention: MultiHeadAttentionLayer
    let selfAttentionNorm: LayerNormLayer
    let feedForward: FeedForwardLayer
    let feedForwardNorm: LayerNormLayer

    func apply(_ hidden: FloatMatrix) -> FloatMatrix {
        var output = selfAttentionNorm.apply(Self.sum(hidden, selfAttention.apply(query: hidden, keyValue: hidden, isCausal: false)))
        output = feedForwardNorm.apply(Self.sum(output, feedForward.apply(output)))
        return output
    }

    static func sum(_ left: FloatMatrix, _ right: FloatMatrix) -> FloatMatrix {
        var result = left
        vDSP_vadd(left.values, 1, right.values, 1, &result.values, 1, vDSP_Length(left.values.count))
        return result
    }
}

struct BARTDecoderLayer {
    let selfAttention: MultiHeadAttentionLayer
    let selfAttentionNorm: LayerNormLayer
    let crossAttention: MultiHeadAttentionLayer
    let crossAttentionNorm: LayerNormLayer
    let feedForward: FeedForwardLayer
    let feedForwardNorm: LayerNormLayer

    func apply(_ hidden: FloatMatrix, encoderOutput: FloatMatrix) -> FloatMatrix {
        var output = selfAttentionNorm.apply(BARTEncoderLayer.sum(hidden, selfAttention.apply(query: hidden, keyValue: hidden, isCausal: true)))
        output = crossAttentionNorm.apply(BARTEncoderLayer.sum(output, crossAttention.apply(query: output, keyValue: encoderOutput, isCausal: false)))
        output = feedForwardNorm.apply(BARTEncoderLayer.sum(output, feedForward.apply(output)))
        return output
    }
}

/// The full grapheme→phoneme BART: encoder, decoder, tied language-model head.
struct BARTModel {
    let config: BARTConfig
    let sharedEmbedding: FloatMatrix          // [vocab, dModel] — also the LM head
    let encoderPositionalEmbedding: FloatMatrix
    let decoderPositionalEmbedding: FloatMatrix
    let encoderEmbeddingNorm: LayerNormLayer
    let decoderEmbeddingNorm: LayerNormLayer
    let encoderLayers: [BARTEncoderLayer]
    let decoderLayers: [BARTDecoderLayer]
    let finalLogitsBias: [Float]

    /// HF BART reserves the first two positions, so position embeddings are looked up at `index + 2`.
    private static let positionOffset = 2

    init(config: BARTConfig, weights: [String: SafetensorsTensor]) throws {
        func tensor(_ name: String) throws -> SafetensorsTensor {
            guard let tensor = weights[name] else { throw BARTModelError.missingWeight(name) }
            return tensor
        }
        func matrix(_ name: String) throws -> FloatMatrix {
            let tensor = try tensor(name)
            guard tensor.shape.count == 2 else { throw BARTModelError.missingWeight(name) }
            return FloatMatrix(rows: tensor.shape[0], columns: tensor.shape[1], values: tensor.values)
        }
        func linear(_ prefix: String) throws -> LinearLayer {
            LinearLayer(weight: try matrix(prefix + ".weight"), bias: weights[prefix + ".bias"]?.values)
        }
        func norm(_ prefix: String) throws -> LayerNormLayer {
            LayerNormLayer(weight: try tensor(prefix + ".weight").values, bias: try tensor(prefix + ".bias").values)
        }
        func attention(_ prefix: String, heads: Int) throws -> MultiHeadAttentionLayer {
            MultiHeadAttentionLayer(
                numberOfHeads: heads,
                queryProjection: try linear(prefix + ".q_proj"),
                keyProjection: try linear(prefix + ".k_proj"),
                valueProjection: try linear(prefix + ".v_proj"),
                outputProjection: try linear(prefix + ".out_proj")
            )
        }
        func feedForward(_ prefix: String) throws -> FeedForwardLayer {
            FeedForwardLayer(firstLinear: try linear(prefix + ".fc1"), secondLinear: try linear(prefix + ".fc2"))
        }

        self.config = config
        sharedEmbedding = try matrix("model.shared.weight")
        encoderPositionalEmbedding = try matrix("model.encoder.embed_positions.weight")
        decoderPositionalEmbedding = try matrix("model.decoder.embed_positions.weight")
        encoderEmbeddingNorm = try norm("model.encoder.layernorm_embedding")
        decoderEmbeddingNorm = try norm("model.decoder.layernorm_embedding")
        encoderLayers = try (0..<config.encoderLayers).map { index in
            let prefix = "model.encoder.layers.\(index)"
            return BARTEncoderLayer(
                selfAttention: try attention(prefix + ".self_attn", heads: config.encoderAttentionHeads),
                selfAttentionNorm: try norm(prefix + ".self_attn_layer_norm"),
                feedForward: try feedForward(prefix),
                feedForwardNorm: try norm(prefix + ".final_layer_norm")
            )
        }
        decoderLayers = try (0..<config.decoderLayers).map { index in
            let prefix = "model.decoder.layers.\(index)"
            return BARTDecoderLayer(
                selfAttention: try attention(prefix + ".self_attn", heads: config.decoderAttentionHeads),
                selfAttentionNorm: try norm(prefix + ".self_attn_layer_norm"),
                crossAttention: try attention(prefix + ".encoder_attn", heads: config.decoderAttentionHeads),
                crossAttentionNorm: try norm(prefix + ".encoder_attn_layer_norm"),
                feedForward: try feedForward(prefix),
                feedForwardNorm: try norm(prefix + ".final_layer_norm")
            )
        }
        finalLogitsBias = weights["final_logits_bias"]?.values ?? [Float](repeating: 0, count: config.vocabSize)
    }

    private func embed(tokenIDs: [Int], positionalEmbedding: FloatMatrix, embeddingNorm: LayerNormLayer) -> FloatMatrix {
        let modelSize = sharedEmbedding.columns
        var hidden = FloatMatrix(zerosWithRows: tokenIDs.count, columns: modelSize)
        for (position, tokenID) in tokenIDs.enumerated() {
            for column in 0..<modelSize {
                hidden[position, column] = sharedEmbedding[tokenID, column]
                    + positionalEmbedding[position + Self.positionOffset, column]
            }
        }
        return embeddingNorm.apply(hidden)
    }

    func encode(tokenIDs: [Int]) -> FloatMatrix {
        var hidden = embed(tokenIDs: tokenIDs, positionalEmbedding: encoderPositionalEmbedding, embeddingNorm: encoderEmbeddingNorm)
        for layer in encoderLayers { hidden = layer.apply(hidden) }
        return hidden
    }

    /// Logits for every decoder position (`[decoderTokens.count, vocab]`).
    func decode(decoderTokenIDs: [Int], encoderOutput: FloatMatrix) -> FloatMatrix {
        var hidden = embed(tokenIDs: decoderTokenIDs, positionalEmbedding: decoderPositionalEmbedding, embeddingNorm: decoderEmbeddingNorm)
        for layer in decoderLayers { hidden = layer.apply(hidden, encoderOutput: encoderOutput) }
        var logits = LinearLayer(weight: sharedEmbedding, bias: nil).apply(hidden)
        for rowIndex in 0..<logits.rows {
            for column in 0..<logits.columns { logits[rowIndex, column] += finalLogitsBias[column] }
        }
        return logits
    }

    /// Greedy decoding from BOS until EOS (or `maxLength`, matching the reference's forced EOS).
    func generate(inputTokenIDs: [Int], maxLength: Int = 50) -> [Int] {
        let encoderOutput = encode(tokenIDs: inputTokenIDs)
        var decoderTokenIDs = [config.bosTokenId]
        var generated: [Int] = []
        for step in 0..<maxLength {
            if step == maxLength - 1 {
                generated.append(config.eosTokenId)
                break
            }
            let logits = decode(decoderTokenIDs: decoderTokenIDs, encoderOutput: encoderOutput)
            let lastRow = Array(logits.row(logits.rows - 1))
            var bestToken = 0
            var bestLogit = -Float.infinity
            for (tokenID, logit) in lastRow.enumerated() where logit > bestLogit {
                bestLogit = logit
                bestToken = tokenID
            }
            if bestToken == config.eosTokenId { break }
            generated.append(bestToken)
            decoderTokenIDs.append(bestToken)
        }
        return generated
    }
}

enum BARTModelError: Error {
    case missingWeight(String)
    case missingResource(String)
}

/// Wraps `BARTModel` with the grapheme/phoneme alphabets from the config, exposing the
/// same `(phonemes, rating)` call MisakiSwift's MLX version exposed to `EnglishG2P`.
final class EnglishFallbackNetwork {
    static let unknownTokenId = 3

    private let configuration: BARTConfig
    private let model: BARTModel
    private let graphemeToToken: [Character: Int]
    private let tokenToPhoneme: [Int: Character]

    init(british: Bool) {
        // The bundled fallback is US-English only (the GB weights were dropped to keep the app small).
        precondition(!british, "Only the US fallback network is bundled")
        do {
            configuration = try Self.loadConfig()
            model = try BARTModel(config: configuration, weights: try Self.loadWeights())
        } catch {
            fatalError("ClawdyVoice: cannot load the G2P fallback network: \(error)")
        }
        var graphemeDictionary: [Character: Int] = [:]
        for (index, grapheme) in configuration.graphemeChars.enumerated() { graphemeDictionary[grapheme] = index }
        graphemeToToken = graphemeDictionary
        var phonemeDictionary: [Int: Character] = [:]
        for (index, phoneme) in configuration.phonemeChars.enumerated() { phonemeDictionary[index] = phoneme }
        tokenToPhoneme = phonemeDictionary
    }

    func callAsFunction(_ word: MToken) -> (phoneme: String, rating: Int) {
        // The network predicts far better from lowercase ("Xcode" → "kˈOd" but "xcode" →
        // "ˈɛksˌOd"); only an all-caps token keeps its case (acronyms are spelled letter by
        // letter upstream anyway).
        let isAllCaps = word.text == word.text.uppercased() && word.text.contains(where: { $0.isLetter })
        return (phonemes(forWord: isAllCaps ? word.text : word.text.lowercased()), 1)
    }

    /// Spells `word` into phonemes with the network (public for tests and pronunciation tooling).
    func phonemes(forWord word: String) -> String {
        var tokenIDs = [configuration.bosTokenId]
        for character in word {
            tokenIDs.append(graphemeToToken[character] ?? Self.unknownTokenId)
        }
        tokenIDs.append(configuration.eosTokenId)
        let generated = model.generate(inputTokenIDs: tokenIDs)
        var output = ""
        for tokenID in generated where tokenID > Self.unknownTokenId {
            if let phoneme = tokenToPhoneme[tokenID] { output.append(phoneme) }
        }
        return output
    }

    static func loadConfig() throws -> BARTConfig {
        guard let url = Bundle.module.url(forResource: "us_bart_config", withExtension: "json", subdirectory: "Resources") else {
            throw BARTModelError.missingResource("us_bart_config.json")
        }
        return try JSONDecoder().decode(BARTConfig.self, from: Data(contentsOf: url))
    }

    static func loadWeights() throws -> [String: SafetensorsTensor] {
        guard let url = Bundle.module.url(forResource: "us_bart", withExtension: "safetensors", subdirectory: "Resources") else {
            throw BARTModelError.missingResource("us_bart.safetensors")
        }
        return try SafetensorsFile.load(url: url)
    }
}

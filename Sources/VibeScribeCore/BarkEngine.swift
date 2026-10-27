import Accelerate
import CoreML
import Foundation

/// Underdog Bark 3.0 Plus: a Core ML encoder, with the audio frontend and decoder ported line by line from
/// Underdog's reference `bark_coreml.py`. English only, and it takes no vocabulary hints.
@available(macOS 15, *)
actor BarkEngine: SpeechEngine {
    static let sampleRate = BarkAudio.sampleRate
    /// Encoder windows in seconds. Each piece uses the smallest one that holds it.
    static let windows = [8, 15]
    /// Silence added before each piece, the setting Underdog's scores use.
    static let leadingSilence = sampleRate / 4

    private let modelFolder: URL
    private var parts: Parts?
    private var loadTask: Task<Void, Error>?
    private var lastTranscription: Task<EngineResult, Error>?

    private struct Parts {
        let frontend: BarkFrontend
        let decoder: BarkDecoder
        let encoders: [Int: MLModel]
    }

    init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    func prepare() async throws {
        if parts != nil { return }
        if let loadTask {
            try await loadTask.value
            return
        }
        let task = Task { try await load() }
        loadTask = task
        do {
            try await task.value
            loadTask = nil
        } catch {
            loadTask = nil
            throw error
        }
    }

    func transcribe(segments: [AudioSegment], language: WhisperLanguage, vocabulary: String) async throws -> EngineResult {
        let previous = lastTranscription
        let task = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await performTranscription(segments: segments)
        }
        lastTranscription = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performTranscription(segments: [AudioSegment]) async throws -> EngineResult {
        try await prepare()
        try Task.checkCancellation()
        let audio = try AudioBufferConverter.whisperSamples(from: segments)
        guard !audio.isEmpty, SpeechDetector.containsSpeech(audio, sampleRate: Double(Self.sampleRate)) else {
            return EngineResult(text: "", language: "en")
        }
        guard let parts else { throw WhisperModelError.missing }
        let maxSeconds = Double(Self.windows.last!) - Double(Self.leadingSilence) / Double(Self.sampleRate)
        var texts: [String] = []
        for piece in BarkAudio.pieces(of: audio, maxSeconds: maxSeconds) {
            try Task.checkCancellation()
            texts.append(parts.decoder.text(for: try transcribe(piece: piece, with: parts)))
        }
        return EngineResult(text: texts.joined(separator: " ").trimmed, language: "en")
    }

    private func transcribe(piece: [Float], with parts: Parts) throws -> [Int] {
        let audio = [Float](repeating: 0, count: Self.leadingSilence) + piece
        let features = parts.frontend.features(audio)
        guard let window = Self.windows.first(where: { audio.count <= $0 * Self.sampleRate }),
              let encoder = parts.encoders[window] else {
            throw WhisperModelError.missing
        }
        let frames = window * 100 + 1
        let input = try MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: BarkFrontend.mels)], dataType: .float16)
        input.withUnsafeMutableBytes { raw, strides in
            let halves = raw.bindMemory(to: UInt16.self)
            halves.initialize(repeating: 0)
            features.values.withUnsafeBufferPointer { values in
                for frame in 0..<min(features.frames, frames) {
                    Half.fromFloat(values.baseAddress! + frame * BarkFrontend.mels, halves.baseAddress! + frame * strides[1], count: BarkFrontend.mels)
                }
            }
        }
        let mask = try MLMultiArray(shape: [1, NSNumber(value: frames)], dataType: .int32)
        mask.withUnsafeMutableBytes { raw, strides in
            let flags = raw.bindMemory(to: Int32.self)
            flags.initialize(repeating: 0)
            for frame in 0..<min(features.valid, frames) { flags[frame * strides[1]] = 1 }
        }
        let output = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": input, "mask": mask]))
        guard let encoded = output.featureValue(for: "encoded")?.multiArrayValue else { throw WhisperModelError.missing }
        let length = min(BarkFrontend.encodedLength(features.valid), encoded.shape[1].intValue)
        let rows = try Self.rows(of: encoded, count: length, width: BarkDecoder.hidden)
        guard rows.allSatisfy(\.isFinite) else {
            throw BarkEngineError.nonFinite
        }
        return parts.decoder.decode(rows, frames: length)
    }

    /// The first `count` rows of a `[1, frames, width]` array, whatever its element type and padding.
    private static func rows(of array: MLMultiArray, count: Int, width: Int) throws -> [Float] {
        guard array.dataType == .float16 || array.dataType == .float32 else { throw BarkEngineError.unexpectedOutput }
        var rows = [Float](repeating: 0, count: count * width)
        let strides = array.strides.map(\.intValue)
        array.withUnsafeBytes { raw in
            rows.withUnsafeMutableBufferPointer { destination in
                for row in 0..<count {
                    let target = destination.baseAddress! + row * width
                    if array.dataType == .float16 {
                        let source = raw.bindMemory(to: UInt16.self).baseAddress! + row * strides[1]
                        if strides[2] == 1 {
                            Half.toFloat(source, target, count: width)
                        } else {
                            for column in 0..<width { Half.toFloat(source + column * strides[2], target + column, count: 1) }
                        }
                    } else {
                        let source = raw.bindMemory(to: Float.self).baseAddress! + row * strides[1]
                        for column in 0..<width { target[column] = source[column * strides[2]] }
                    }
                }
            }
        }
        return rows
    }

    private func load() async throws {
        guard WhisperModelLocator.isComplete(modelFolder, for: .barkPlus) else { throw WhisperModelError.missing }
        let weights = try NumpyArchive(contentsOf: modelFolder.appendingPathComponent("decoder.npz"))
        let vocabulary = try JSONDecoder().decode(
            BarkVocabulary.self,
            from: Data(contentsOf: modelFolder.appendingPathComponent("vocab.json"))
        )
        let frontend = try BarkFrontend(melFilters: weights.array("mel_filters"))
        let decoder = try BarkDecoder(weights: weights, vocabulary: vocabulary)
        let compiled = try await compiledEncoder()
        var encoders: [Int: MLModel] = [:]
        for window in Self.windows {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            configuration.functionName = "w\(window)"
            encoders[window] = try await MLModel.load(contentsOf: compiled, configuration: configuration)
        }
        parts = Parts(frontend: frontend, decoder: decoder, encoders: encoders)
    }

    /// The download is a Core ML package, which has to be compiled before it can run. The result is kept.
    private func compiledEncoder() async throws -> URL {
        let compiled = modelFolder.appendingPathComponent("BarkEncoder.mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: compiled.path) { return compiled }
        let temporary = try await MLModel.compileModel(at: modelFolder.appendingPathComponent("BarkEncoder.mlpackage"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staging = modelFolder.appendingPathComponent(".BarkEncoder-\(UUID().uuidString).mlmodelc", isDirectory: true)
        try FileManager.default.copyItem(at: temporary, to: staging)
        try FileManager.default.moveItem(at: staging, to: compiled)
        return compiled
    }
}

enum BarkEngineError: LocalizedError {
    case nonFinite
    case unexpectedOutput
    case badWeights(String)

    var errorDescription: String? {
        switch self {
        case .nonFinite: return "The speech model produced invalid output."
        case .unexpectedOutput: return "The speech model produced output in an unexpected format."
        case .badWeights(let name): return "The speech model's \(name) weights have an unexpected shape."
        }
    }
}

struct BarkVocabulary: Decodable {
    let pieces: [String]
    let specialIDs: [Int]
    let blankID: Int
    let vocabularySize: Int
    let durations: [Int]
    let maxSymbolsPerStep: Int

    enum CodingKeys: String, CodingKey {
        case pieces
        case specialIDs = "special_ids"
        case blankID = "blank_id"
        case vocabularySize = "vocab_size"
        case durations
        case maxSymbolsPerStep = "max_symbols_per_step"
    }
}

/// Log-mel features: pre-emphasis, a centred 512-point STFT with a 400-sample Hann window, 128 mel bands,
/// and per-utterance normalisation. Matches transformers' `ParakeetFeatureExtractor`.
struct BarkFrontend {
    static let fftSize = 512
    static let hop = 160
    static let windowLength = 400
    static let bins = fftSize / 2 + 1
    static let mels = 128

    /// `[mels, bins]`
    private let melFilters: [Float]
    /// Windowed DFT bases, `[fftSize, bins]`. A matrix product is exact and fast enough for 15 seconds of audio.
    private let cosines: [Float]
    private let sines: [Float]

    init(melFilters: NumpyArray) throws {
        guard melFilters.shape == [Self.mels, Self.bins] else { throw BarkEngineError.badWeights("mel filter") }
        self.melFilters = melFilters.values
        let offset = (Self.fftSize - Self.windowLength) / 2
        var cosines = [Float](repeating: 0, count: Self.fftSize * Self.bins)
        var sines = [Float](repeating: 0, count: Self.fftSize * Self.bins)
        for n in 0..<Self.windowLength {
            // Symmetric Hann, like torch.hann_window(periodic=False).
            let weight = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(Self.windowLength - 1))
            let sample = n + offset
            for bin in 0..<Self.bins {
                let angle = 2 * Double.pi * Double(sample * bin % Self.fftSize) / Double(Self.fftSize)
                cosines[sample * Self.bins + bin] = Float(weight * cos(angle))
                sines[sample * Self.bins + bin] = Float(weight * sin(angle))
            }
        }
        self.cosines = cosines
        self.sines = sines
    }

    /// Encoder frames for `frames` input frames: three stride-2 convolutions.
    static func encodedLength(_ frames: Int) -> Int {
        var length = frames
        for _ in 0..<3 { length = (length - 1) / 2 + 1 }
        return length
    }

    /// `values` is `[frames, mels]`. Frames from `valid` on are zero.
    func features(_ audio: [Float]) -> (values: [Float], frames: Int, valid: Int) {
        let half = Self.fftSize / 2
        var padded = [Float](repeating: 0, count: audio.count + Self.fftSize)
        if let first = audio.first { padded[half] = first }
        for index in audio.indices.dropFirst() {
            padded[half + index] = audio[index] - 0.97 * audio[index - 1]
        }
        let frames = 1 + audio.count / Self.hop
        var framed = [Float](repeating: 0, count: frames * Self.fftSize)
        for frame in 0..<frames {
            let start = frame * Self.hop
            framed.replaceSubrange(frame * Self.fftSize ..< (frame + 1) * Self.fftSize, with: padded[start ..< start + Self.fftSize])
        }
        var real = [Float](repeating: 0, count: frames * Self.bins)
        var imaginary = [Float](repeating: 0, count: frames * Self.bins)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(Self.bins), Int32(Self.fftSize),
                    1, framed, Int32(Self.fftSize), cosines, Int32(Self.bins), 0, &real, Int32(Self.bins))
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(frames), Int32(Self.bins), Int32(Self.fftSize),
                    1, framed, Int32(Self.fftSize), sines, Int32(Self.bins), 0, &imaginary, Int32(Self.bins))
        var power = [Float](repeating: 0, count: frames * Self.bins)
        vDSP.add(vDSP.square(real), vDSP.square(imaginary), result: &power)
        var values = [Float](repeating: 0, count: frames * Self.mels)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(frames), Int32(Self.mels), Int32(Self.bins),
                    1, power, Int32(Self.bins), melFilters, Int32(Self.bins), 0, &values, Int32(Self.mels))
        values = values.map { log($0 + 0x1p-24) }

        let valid = audio.count / Self.hop
        for mel in 0..<Self.mels {
            var sum = 0.0
            for frame in 0..<valid { sum += Double(values[frame * Self.mels + mel]) }
            let mean = sum / Double(max(valid, 1))
            var squares = 0.0
            for frame in 0..<valid {
                let difference = Double(values[frame * Self.mels + mel]) - mean
                squares += difference * difference
            }
            let deviation = (squares / Double(max(1, valid - 1))).squareRoot()
            for frame in 0..<frames {
                let index = frame * Self.mels + mel
                values[index] = frame < valid ? Float((Double(values[index]) - mean) / (deviation + 1e-5)) : 0
            }
        }
        return (values, frames, valid)
    }
}

/// Greedy TDT decoding on the CPU: a two-layer LSTM prediction network and a joint head that picks a token
/// and how many encoder frames to skip.
struct BarkDecoder {
    static let hidden = 640

    private let embedding: [Float]
    private let layers: [(input: [Float], recurrent: [Float], bias: [Float])]
    private let projection: [Float]
    private let projectionBias: [Float]
    private let head: [Float]
    private let headBias: [Float]
    private let vocabulary: BarkVocabulary
    private let special: Set<Int>

    init(weights: NumpyArchive, vocabulary: BarkVocabulary) throws {
        /// Int8 weights times per-row scales, or plain floats.
        func weight(_ name: String, rows: Int, columns: Int = 1) throws -> [Float] {
            let values: [Float]
            if weights.contains(name + ".q") {
                let quantized = try weights.array(name + ".q")
                let scales = try weights.array(name + ".s")
                guard quantized.shape == [rows, columns], scales.shape == [rows] else { throw BarkEngineError.badWeights(name) }
                var scaled = quantized.values
                for row in 0..<rows {
                    vDSP.multiply(scales.values[row], scaled[row * columns ..< (row + 1) * columns], result: &scaled[row * columns ..< (row + 1) * columns])
                }
                values = scaled
            } else {
                values = try weights.array(name).values
            }
            guard values.count == rows * columns else { throw BarkEngineError.badWeights(name) }
            return values
        }
        let hidden = Self.hidden
        let gates = 4 * hidden
        embedding = try weight("decoder.embedding.weight", rows: vocabulary.vocabularySize, columns: hidden)
        layers = try (0..<2).map { layer in
            (
                try weight("decoder.lstm.weight_ih_l\(layer)", rows: gates, columns: hidden),
                try weight("decoder.lstm.weight_hh_l\(layer)", rows: gates, columns: hidden),
                vDSP.add(try weight("decoder.lstm.bias_ih_l\(layer)", rows: gates), try weight("decoder.lstm.bias_hh_l\(layer)", rows: gates))
            )
        }
        projection = try weight("decoder.decoder_projector.weight", rows: hidden, columns: hidden)
        projectionBias = try weight("decoder.decoder_projector.bias", rows: hidden)
        let outputs = vocabulary.vocabularySize + vocabulary.durations.count
        head = try weight("joint.head.weight", rows: outputs, columns: hidden)
        headBias = try weight("joint.head.bias", rows: outputs)
        self.vocabulary = vocabulary
        special = Set(vocabulary.specialIDs)
    }

    /// Token ids for `frames` rows of projected encoder output, `[frames, hidden]`.
    func decode(_ encoded: [Float], frames: Int) -> [Int] {
        let hidden = Self.hidden
        let size = vocabulary.vocabularySize
        var state = [(h: [Float], c: [Float])](repeating: ([Float](repeating: 0, count: hidden), [Float](repeating: 0, count: hidden)), count: 2)
        var prediction = step(token: vocabulary.blankID, state: &state)
        var tokens: [Int] = []
        var joint = [Float](repeating: 0, count: hidden)
        var logits = [Float](repeating: 0, count: headBias.count)
        var frame = 0
        var symbols = 0
        while frame < frames {
            encoded.withUnsafeBufferPointer { rows in
                vDSP_vadd(rows.baseAddress! + frame * hidden, 1, prediction, 1, &joint, 1, vDSP_Length(hidden))
            }
            joint = vDSP.threshold(joint, to: 0, with: .clampToThreshold)
            logits = headBias
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(headBias.count), Int32(hidden), 1, head, Int32(hidden), joint, 1, 1, &logits, 1)
            let token = Self.argmax(logits[0..<size])
            var duration = vocabulary.durations[Self.argmax(logits[size...])]
            if token == vocabulary.blankID {
                frame += max(duration, 1)
                symbols = 0
            } else {
                tokens.append(token)
                prediction = step(token: token, state: &state)
                symbols += 1
                if duration == 0, symbols >= vocabulary.maxSymbolsPerStep { duration = 1 }
                if duration > 0 { symbols = 0 }
                frame += duration
            }
        }
        return tokens
    }

    func text(for tokens: [Int]) -> String {
        tokens
            .filter { !special.contains($0) && $0 < vocabulary.pieces.count }
            .map { vocabulary.pieces[$0] }
            .joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmed
    }

    private func step(token: Int, state: inout [(h: [Float], c: [Float])]) -> [Float] {
        let hidden = Self.hidden
        var x = Array(embedding[token * hidden ..< (token + 1) * hidden])
        for (index, layer) in layers.enumerated() {
            var gates = layer.bias
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(4 * hidden), Int32(hidden), 1, layer.input, Int32(hidden), x, 1, 1, &gates, 1)
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(4 * hidden), Int32(hidden), 1, layer.recurrent, Int32(hidden), state[index].h, 1, 1, &gates, 1)
            var h = [Float](repeating: 0, count: hidden)
            var c = state[index].c
            for unit in 0..<hidden {
                let input = Self.sigmoid(gates[unit])
                let forget = Self.sigmoid(gates[hidden + unit])
                let candidate = tanh(gates[2 * hidden + unit])
                let output = Self.sigmoid(gates[3 * hidden + unit])
                c[unit] = forget * c[unit] + input * candidate
                h[unit] = output * tanh(c[unit])
            }
            state[index] = (h, c)
            x = h
        }
        var projected = projectionBias
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(hidden), Int32(hidden), 1, projection, Int32(hidden), x, 1, 1, &projected, 1)
        return projected
    }

    private static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    /// The first index of the largest value, like numpy's argmax.
    private static func argmax(_ values: ArraySlice<Float>) -> Int {
        var best = values.startIndex
        for index in values.indices where values[index] > values[best] { best = index }
        return best - values.startIndex
    }
}

enum BarkAudio {
    static let sampleRate = 16_000

    /// Audio longer than `maxSeconds` cut at pauses: within each 5 to `maxSeconds` stretch, in the middle of the
    /// quietest 200 ms (smoothed 10 ms energy), so no word is split.
    static func pieces(of audio: [Float], maxSeconds: Double, minSeconds: Double = 5) -> [[Float]] {
        let rate = Double(sampleRate)
        guard audio.count > Int(maxSeconds * rate) else { return [audio] }
        let frame = sampleRate / 100
        let energies = (0..<audio.count / frame).map { index in
            vDSP.meanSquare(audio[index * frame ..< (index + 1) * frame])
        }
        // numpy's convolve(mode="same") with 20 equal weights: frames index-10 through index+9.
        let smoothed = energies.indices.map { index in
            energies[max(0, index - 10)...min(energies.count - 1, index + 9)].reduce(0, +) / 20
        }
        var pieces: [[Float]] = []
        var start = 0
        while Double(audio.count - start) > maxSeconds * rate {
            let low = (start + Int(minSeconds * rate)) / frame
            let high = (start + Int(maxSeconds * rate)) / frame
            var quietest = low
            for index in low..<high where smoothed[index] < smoothed[quietest] { quietest = index }
            let cut = quietest * frame + frame / 2
            pieces.append(Array(audio[start..<cut]))
            start = cut
        }
        pieces.append(Array(audio[start...]))
        return pieces
    }
}

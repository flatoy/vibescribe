// whisper-check <model-folder> [--vocab "<custom vocabulary>"] <language>:<file.wav> [...]
// Prints one JSON object per clip: {"file", "language", "text", "words", "seconds"}.
// Mirrors Sources/VibeScribeCore/WhisperKitClient.swift: local model, no download,
// DecodingOptions(language:, detectLanguage: false, withoutTimestamps: true, promptTokens:),
// where the prompt is the custom vocabulary exactly as the app builds it, then the same
// no-speech segment filter and whitespace cleanup. "words" uses the app's whitespace count
// (TranscriptionResult.wordCount), i.e. the number the "Pasted N words" pill would show.
import Foundation
import WhisperKit

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    FileHandle.standardError.write("usage: whisper-check <model-folder> [--vocab words] <lang>:<file.wav> ...\n".data(using: .utf8)!)
    exit(2)
}
let folder = args.removeFirst()
var vocabulary = ""
if let i = args.firstIndex(of: "--vocab"), i + 1 < args.count {
    vocabulary = args[i + 1]
    args.removeSubrange(i...(i + 1))
}

let config = WhisperKitConfig(
    modelFolder: folder,
    tokenizerFolder: URL(fileURLWithPath: folder),
    verbose: false,
    prewarm: false,
    load: true,
    download: false
)
let model = try await WhisperKit(config)

func promptTokens(_ vocabulary: String, tokenizer: WhisperTokenizer?) -> [Int]? {
    let words = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !words.isEmpty, let tokenizer else { return nil }
    let tokens = tokenizer.encode(text: " " + words).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
    return tokens.isEmpty ? nil : tokens
}

for job in args {
    guard let colon = job.firstIndex(of: ":") else { continue }
    let language = String(job[..<colon])
    let file = String(job[job.index(after: colon)...])
    let started = Date()
    let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: file)
    let options = DecodingOptions(
        language: language,
        detectLanguage: false,
        withoutTimestamps: true,
        promptTokens: promptTokens(vocabulary, tokenizer: model.tokenizer)
    )
    let results = try await model.transcribe(audioArray: audio, decodeOptions: options)
    let text = results
        .flatMap(\.segments)
        .filter { !($0.noSpeechProb > 0.6 && $0.avgLogprob < -1) }
        .map(\.text)
        .joined(separator: " ")
        .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    let row: [String: Any] = ["file": file, "language": language, "vocabulary": vocabulary, "text": text, "words": words, "seconds": Date().timeIntervalSince(started)]
    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

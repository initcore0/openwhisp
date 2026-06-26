import Foundation

/// Maps OpenWhisp's Language setting to WhisperKit decoding options. Mirrors
/// `WhisperTask` (used for whisper.cpp): "en" means translate-to-English with the
/// source auto-detected; everything else transcribes in that language. Pure, so
/// it's testable without importing WhisperKit.
enum WhisperKitTaskMapper {
    struct Resolved: Equatable {
        /// nil = let WhisperKit auto-detect the source language.
        var language: String?
        /// true = translate to English; false = transcribe.
        var translate: Bool
    }

    static func map(languageSetting: String) -> Resolved {
        if languageSetting == "en" {
            return Resolved(language: nil, translate: true)
        }
        if languageSetting.isEmpty || languageSetting == "auto" {
            return Resolved(language: nil, translate: false)
        }
        return Resolved(language: languageSetting, translate: false)
    }
}

#if WHISPERKIT
import WhisperKit

/// Concrete handle type so WhisperKitEngine can store/return a typed WhisperKit
/// instance without naming the framework outside the guarded files.
typealias WhisperKitHandle = WhisperKit

/// Thin async bridge over the WhisperKit API. Isolated here so the WhisperKit
/// import lives in exactly one place; all of it is compiled only under WHISPERKIT.
enum WhisperKitBridge {
    /// Load (and auto-download on first use) the given CoreML model.
    static func load(model: String) async throws -> WhisperKit {
        let config = WhisperKitConfig(model: model)
        return try await WhisperKit(config)
    }

    /// Transcribe a WAV file to plain text, honoring the language/translate task.
    /// NOTE: WhisperKit's `DecodingOptions` biases recognition via `promptTokens:
    /// [Int]?` (token IDs), not a plain string, so the vocabulary `prompt` is NOT
    /// wired in this pilot (it would need the WhisperKit tokenizer). The whisper.cpp
    /// backend still honors custom vocabulary; this is a known pilot limitation.
    static func transcribe(
        kit: WhisperKit,
        wavPath: String,
        task: WhisperKitTaskMapper.Resolved,
        prompt: String
    ) async throws -> String {
        let options = DecodingOptions(
            task: task.translate ? .translate : .transcribe,
            language: task.language
        )
        // transcribe(audioPath:decodeOptions:) -> [TranscriptionResult]; one entry
        // per processed window. Concatenate their `.text`.
        let results = try await kit.transcribe(audioPath: wavPath, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

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
import CoreML

/// Locates a locally-prepared compiled WhisperKit model folder.
///
/// WhisperKit's published prebuilt models are problematic for our larger defaults
/// because first load runs a slow, memory-heavy one-time CoreML/ANE specialization
/// pass on-device. We instead stage a folder of `.mlmodelc` under Application
/// Support and load it via `modelFolder` (no Manifest.json is required on this
/// path — `tiny.en` loads with none present). An automated download+stage is the
/// follow-up for additional models.
enum WhisperKitModelInstaller {
    /// Base dir where compiled model folders live.
    static var baseDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("OpenWhisp", isDirectory: true)
            .appendingPathComponent("whisperkit-models", isDirectory: true)
    }

    /// Returns the compiled model folder for `model` iff it exists and contains the
    /// three required compiled sub-models; otherwise nil (caller falls back).
    static func compiledModelFolder(for model: String) -> URL? {
        let folder = baseDir.appendingPathComponent(model, isDirectory: true)
        let fm = FileManager.default
        for sub in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            if !fm.fileExists(atPath: folder.appendingPathComponent(sub).path) { return nil }
        }
        return folder
    }
}

/// Concrete handle type so WhisperKitEngine can store/return a typed WhisperKit
/// instance without naming the framework outside the guarded files.
typealias WhisperKitHandle = WhisperKit

/// Thin async bridge over the WhisperKit API. Isolated here so the WhisperKit
/// import lives in exactly one place; all of it is compiled only under WHISPERKIT.
enum WhisperKitBridge {
    /// Load the given CoreML model. If a locally-prepared compiled model folder
    /// exists (see WhisperKitModelInstaller) load from it via `modelFolder`;
    /// otherwise fall back to WhisperKit's normal auto-download.
    ///
    /// COMPUTE UNITS — the critical bit. WhisperKit defaults the audio encoder to
    /// `.cpuAndNeuralEngine`. On macOS 26 / Apple Silicon, the one-time on-device
    /// ANE specialization of a non-tiny encoder (e.g. `small`'s ~176 MB encoder)
    /// can STALL indefinitely — the load never returns (no `model loaded` ever
    /// logs) and the e5 ANE bundle cache never grows. That was the real cause of
    /// the "WhisperKit gets stuck" hang. We pin the audio encoder to the GPU
    /// (`.cpuAndGPU`) instead: it loads in seconds and sidesteps the wedged ANE
    /// compile. The (small) text decoder keeps its ANE default, which is fine.
    static func load(model: String) async throws -> WhisperKit {
        let compute = ModelComputeOptions(audioEncoderCompute: .cpuAndGPU)
        if let folder = WhisperKitModelInstaller.compiledModelFolder(for: model) {
            let config = WhisperKitConfig(modelFolder: folder.path, computeOptions: compute)
            return try await WhisperKit(config)
        }
        let config = WhisperKitConfig(model: model, computeOptions: compute)
        return try await WhisperKit(config)
    }

    /// Detect the spoken language of a WAV file (Whisper language code, e.g. "ru").
    /// Used for the "auto" setting so we can detect ONCE and then pin the language
    /// for the rest of the session — per-2s-chunk auto-detection is unreliable and
    /// makes Whisper flap between languages (e.g. emit English for Russian speech).
    static func detectLanguage(kit: WhisperKit, wavPath: String) async throws -> String {
        let (language, _) = try await kit.detectLanguage(audioPath: wavPath)
        return language
    }

    /// Transcribe a WAV file to plain text, honoring the language/translate task.
    /// `languageOverride`, when non-nil, forces the source language (used to pin the
    /// detected language across an "auto" session); otherwise `task.language` is used.
    /// NOTE: WhisperKit's `DecodingOptions` biases recognition via `promptTokens:
    /// [Int]?` (token IDs), not a plain string, so the vocabulary `prompt` is NOT
    /// wired in this pilot (it would need the WhisperKit tokenizer). The whisper.cpp
    /// backend still honors custom vocabulary; this is a known pilot limitation.
    static func transcribe(
        kit: WhisperKit,
        wavPath: String,
        task: WhisperKitTaskMapper.Resolved,
        languageOverride: String? = nil,
        prompt: String
    ) async throws -> String {
        let options = DecodingOptions(
            task: task.translate ? .translate : .transcribe,
            language: languageOverride ?? task.language
        )
        // transcribe(audioPath:decodeOptions:) -> [TranscriptionResult]; one entry
        // per processed window. Concatenate their `.text`.
        let results = try await kit.transcribe(audioPath: wavPath, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif

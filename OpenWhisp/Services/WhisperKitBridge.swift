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
    /// Base dir where compiled model folders live (shared with the build-independent
    /// `WhisperKitModelCatalog`, the single source of truth for the path + layout).
    static var baseDir: URL { WhisperKitModelCatalog.baseDir }

    /// Returns the compiled model folder for `model` iff it's staged with all three
    /// required compiled sub-models; otherwise nil (caller falls back).
    static func compiledModelFolder(for model: String) -> URL? {
        guard WhisperKitModelCatalog.isStaged(model) else { return nil }
        return baseDir.appendingPathComponent(model, isDirectory: true)
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
    /// Timeout for loading an ALREADY-STAGED compiled model (no network). Generous
    /// vs. a normal few-second load, but bounded so the documented ANE/CoreML stall
    /// surfaces a retryable error instead of wedging the app forever.
    static let stagedLoadTimeout: Double = 120
    /// Timeout for the auto-download path, which also fetches the model over the
    /// network on first use — so it's allowed much longer before we call it stuck.
    static let downloadLoadTimeout: Double = 600

    static func load(model: String) async throws -> WhisperKit {
        let compute = ModelComputeOptions(audioEncoderCompute: .cpuAndGPU)
        if let folder = WhisperKitModelInstaller.compiledModelFolder(for: model) {
            return try await withTimeout(seconds: stagedLoadTimeout, operation: "Loading model") {
                let config = WhisperKitConfig(modelFolder: folder.path, computeOptions: compute)
                return try await WhisperKit(config)
            }
        }
        return try await withTimeout(seconds: downloadLoadTimeout, operation: "Downloading model") {
            let config = WhisperKitConfig(model: model, computeOptions: compute)
            return try await WhisperKit(config)
        }
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

    /// Construct a streaming handle from an already-loaded WhisperKit. The handle
    /// wraps `AudioStreamTranscriber` (which owns the mic + its own energy VAD so
    /// silence is skipped) and translates its WhisperKit `State` into plain Swift
    /// values via `onState`, so callers never name WhisperKit types.
    ///
    /// Language: when explicit (e.g. "ru") it's pinned via `options.language`. For
    /// "auto" we leave it nil and let WhisperKit detect; because the engine only
    /// surfaces CONFIRMED text as live partials, the per-window detection on the
    /// unconfirmed tail doesn't cause visible flapping.
    static func makeStreamHandle(
        kit: WhisperKit,
        task: WhisperKitTaskMapper.Resolved,
        languageOverride: String?,
        onState: @escaping (WhisperKitStreamState) -> Void
    ) throws -> WhisperKitStreamHandle {
        guard let tokenizer = kit.tokenizer else {
            throw WhisperKitBridgeError.tokenizerUnavailable
        }
        let resolvedLanguage = languageOverride ?? task.language
        // "auto" (no explicit language, not translating): WhisperKit's prefill
        // otherwise FORCES a default language token (English), so Russian speech comes
        // out translated/forced to English. Turning on `detectLanguage` makes it
        // detect the spoken language per window and decode in it. When a language is
        // pinned (e.g. "ru") or we're translating, leave detection off.
        let autoDetect = resolvedLanguage == nil && !task.translate
        let options = DecodingOptions(
            task: task.translate ? .translate : .transcribe,
            language: resolvedLanguage,
            detectLanguage: autoDetect,
            // Streaming segment text is the RAW token stream unless we ask for clean
            // output: strip the special tokens (<|startoftranscript|>, <|en|>, …) and
            // the per-segment timestamp markers. Without this the preview shows token
            // soup instead of words.
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        let handle = WhisperKitStreamHandle()
        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: options,
            useVAD: true,                 // skip silence — don't transcribe dead air
            stateChangeCallback: { _, new in
                let snapshot = WhisperKitStreamState(from: new)
                handle.latest = snapshot      // keep the newest for `fullText()` at stop
                onState(snapshot)
            }
        )
        handle.attach(transcriber)
        return handle
    }
}

/// Plain-Swift snapshot of the streaming state — keeps WhisperKit types out of the
/// engine/AppState. `confirmedText` is the stable, committed transcript; `fullText`
/// also folds in the still-unconfirmed tail.
struct WhisperKitStreamState {
    let confirmedText: String
    let fullText: String
    /// Peak relative mic energy in the latest buffer (0–1), for the waveform.
    let peakEnergy: Float?

    init(from state: AudioStreamTranscriber.State) {
        let confirmed = state.confirmedSegments.map(\.text).joined(separator: " ")
        let unconfirmed = state.unconfirmedSegments.map(\.text).joined(separator: " ")
        self.confirmedText = confirmed
        self.fullText = (confirmed + " " + unconfirmed)
        // `bufferEnergy` is the cumulative per-buffer relative-energy history,
        // refreshed every ~0.1s. Read the RECENT window (not the all-time max, which
        // freezes the bars) and map it with the relative-energy curve (NOT fromRMS,
        // which double-compresses the already-0…1 value). See AudioLevel.
        self.peakEnergy = AudioLevel.liveLevel(fromEnergyHistory: state.bufferEnergy)
    }
}

/// Lifecycle wrapper around `AudioStreamTranscriber` so the engine can start/stop
/// and read the final transcript without importing WhisperKit. The transcriber's
/// `state` is private, so we cache the latest snapshot from the state callback.
final class WhisperKitStreamHandle {
    private var transcriber: AudioStreamTranscriber?
    /// Newest state snapshot, written from the state-change callback.
    fileprivate var latest: WhisperKitStreamState?

    fileprivate func attach(_ transcriber: AudioStreamTranscriber) {
        self.transcriber = transcriber
    }

    /// Starts mic capture + the realtime loop. Returns when the stream stops.
    func start() async throws { try await transcriber?.startStreamTranscription() }
    func stop() async { await transcriber?.stopStreamTranscription() }

    /// The full assembled transcript (confirmed + unconfirmed) as of the last state.
    func fullText() -> String {
        (latest?.fullText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WhisperKitBridgeError: Error, LocalizedError {
    case tokenizerUnavailable
    var errorDescription: String? {
        switch self {
        case .tokenizerUnavailable:
            return "WhisperKit tokenizer not loaded (model may still be loading)."
        }
    }
}
#endif

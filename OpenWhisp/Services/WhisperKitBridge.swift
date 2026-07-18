import Foundation
import CoreAudio   // AudioDeviceID (the input-device id threaded to AudioStreamTranscriber)

/// Maps OpenWhisp's engine-facing language setting to WhisperKit decoding
/// options. Mirrors `WhisperTask` (used for whisper.cpp): the shared
/// translate-to-English sentinel means translate with the source auto-detected;
/// every plain language ("en" included) transcribes in that language. Pure, so
/// it's testable without importing WhisperKit.
public enum WhisperKitTaskMapper {
    public struct Resolved: Equatable {
        /// nil = let WhisperKit auto-detect the source language.
        public var language: String?
        /// true = translate to English; false = transcribe.
        public var translate: Bool

        public init(language: String?, translate: Bool) {
            self.language = language
            self.translate = translate
        }
    }

    public static func map(languageSetting: String) -> Resolved {
        if languageSetting == WhisperTask.translateToEnglishSetting {
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

    /// Hub `downloadBase` passed to every WhisperKitConfig. Without an explicit
    /// base, WhisperKit's bundled Hub library defaults to `~/Documents/huggingface`
    /// — even a staged-model load touches it for the tokenizer fetch/cache
    /// (`tokenizerFolder = config.tokenizerFolder ?? config.downloadBase`), which
    /// is what triggered the macOS "access your Documents folder" prompt. Pinning
    /// it here keeps WhisperKit entirely inside our Application Support dir.
    static func hubDownloadBase() -> URL {
        let dir = WhisperKitModelCatalog.hubBaseDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load(model: String) async throws -> WhisperKit {
        // Honor a stopServer()-issued cancel that landed before the load began;
        // cancellation DURING the load is handled by withTimeout, which forwards
        // caller cancellation to the racing operation/watchdog tasks.
        try Task.checkCancellation()
        let compute = ModelComputeOptions(audioEncoderCompute: .cpuAndGPU)
        if let folder = WhisperKitModelInstaller.compiledModelFolder(for: model) {
            // Timed span (instrumentation builds only): this is where the CoreML
            // specialization/warm-up cost shows up — the cold-vs-warm-launch number.
            return try await Instrumentation.measure("whisperkit.load.staged") {
                try await withTimeout(seconds: stagedLoadTimeout, operation: "Loading model") {
                    let config = WhisperKitConfig(
                        downloadBase: hubDownloadBase(),
                        modelFolder: folder.path,
                        computeOptions: compute
                    )
                    return try await WhisperKit(config)
                }
            }
        }
        return try await Instrumentation.measure("whisperkit.load.download") {
            try await withTimeout(seconds: downloadLoadTimeout, operation: "Downloading model") {
                let config = WhisperKitConfig(
                    model: model,
                    downloadBase: hubDownloadBase(),
                    computeOptions: compute
                )
                return try await WhisperKit(config)
            }
        }
    }

    /// Download `model` from the WhisperKit CoreML repo and STAGE it where the
    /// catalog expects (`baseDir/<model>`), reporting 0…1 progress via `onProgress`.
    ///
    /// WhisperKit's `download(downloadBase:)` lays the model under a nested HF cache
    /// path (`<base>/models/argmaxinc/whisperkit-coreml/<model>`), so we download into
    /// a temp base and then move the finished model folder to `baseDir/<model>` — the
    /// flat layout `WhisperKitModelInstaller.compiledModelFolder` looks for. The
    /// move is atomic-ish (remove any partial, then move), and the catalog's
    /// three-`.mlmodelc` check is the post-download integrity gate.
    static func downloadModel(
        _ model: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let fm = FileManager.default
        let baseDir = WhisperKitModelCatalog.baseDir
        try fm.createDirectory(at: baseDir, withIntermediateDirectories: true)

        // Download into a temp base so a failed/partial download never pollutes the
        // staging dir (and a half-written folder can't read as "staged").
        let tempBase = fm.temporaryDirectory
            .appendingPathComponent("openwhisp-wk-download-\(model)", isDirectory: true)
        try? fm.removeItem(at: tempBase)
        try fm.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempBase) }

        let downloaded = try await WhisperKit.download(
            variant: model,
            downloadBase: tempBase
        ) { progress in
            let total = progress.totalUnitCount
            let fraction = total > 0 ? Double(progress.completedUnitCount) / Double(total) : 0
            onProgress(max(0, min(1, fraction)))
        }

        // Validate the download produced the three compiled sub-models before staging.
        let ok = WhisperKitModelCatalog.requiredSubmodels.allSatisfy {
            fm.fileExists(atPath: downloaded.appendingPathComponent($0).path)
        }
        guard ok else {
            throw WhisperKitBridgeError.incompleteDownload(model)
        }

        // Move into the flat staging location the catalog/installer use.
        let dest = baseDir.appendingPathComponent(model, isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: downloaded, to: dest)
        onProgress(1)
    }

    /// Detect the spoken language of a WAV file (Whisper language code, e.g. "ru").
    /// Used for the "auto" setting so we can detect ONCE and then pin the language
    /// for the rest of the session — per-2s-chunk auto-detection is unreliable and
    /// makes Whisper flap between languages (e.g. emit English for Russian speech).
    static func detectLanguage(kit: WhisperKit, wavPath: String) async throws -> String {
        let (language, _) = try await kit.detectLanguage(audioPath: wavPath)
        return language
    }

    /// Turn a whisper-shaped `prompt` (comma-joined bias terms) into WhisperKit
    /// `promptTokens` (MAK-69). WhisperKit biases the decoder with token IDs, not a
    /// string, so we tokenize with special tokens OFF — the decoder prepends its
    /// own prefill tokens and filters anything `>= specialTokenBegin` out of the
    /// prompt (see TextDecoder), so a bare content-token list is exactly what it
    /// wants. Empty/blank prompt → nil (the plain, unbiased path).
    static func promptTokens(from prompt: String, tokenizer: WhisperTokenizer) -> [Int]? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = tokenizer.encode(text: " " + trimmed).filter {
            $0 < tokenizer.specialTokens.specialTokenBegin
        }
        return tokens.isEmpty ? nil : tokens
    }

    /// Transcribe a WAV file to plain text, honoring the language/translate task.
    /// `languageOverride`, when non-nil, forces the source language (used to pin the
    /// detected language across an "auto" session); otherwise `task.language` is used.
    /// `prompt` (comma-joined bias terms) steers recognition via WhisperKit's
    /// `promptTokens` (MAK-69) — the `.all` vocabulary declaration for whisperKit.
    static func transcribe(
        kit: WhisperKit,
        wavPath: String,
        task: WhisperKitTaskMapper.Resolved,
        languageOverride: String? = nil,
        prompt: String
    ) async throws -> String {
        let options = DecodingOptions(
            task: task.translate ? .translate : .transcribe,
            language: languageOverride ?? task.language,
            usePrefillPrompt: true,
            promptTokens: kit.tokenizer.flatMap { promptTokens(from: prompt, tokenizer: $0) }
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
    /// `inputDeviceID` (a CoreAudio `AudioDeviceID`) pins the input device the stream
    /// captures from; nil = system default input. Threaded straight into
    /// `AudioStreamTranscriber` (our WhisperKit fork backports upstream #503's
    /// `inputDeviceID` passthrough), which forwards it to `startRecordingLive` — so
    /// device routing needs NO system-default swap.
    static func makeStreamHandle(
        kit: WhisperKit,
        task: WhisperKitTaskMapper.Resolved,
        languageOverride: String?,
        inputDeviceID: AudioDeviceHandle? = nil,
        prompt: String = "",
        onState: @escaping (WhisperKitStreamState) -> Void
    ) throws -> WhisperKitStreamHandle {
        guard let tokenizer = kit.tokenizer else {
            throw WhisperKitBridgeError.tokenizerUnavailable
        }
        // Vocabulary biasing on the live path (MAK-69): tokenize the bias terms to
        // WhisperKit's `promptTokens`. Empty prompt → nil (plain path). This is the
        // streaming half of whisperKit's `.all` vocabulary declaration.
        let streamPromptTokens = promptTokens(from: prompt, tokenizer: tokenizer)
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
            usePrefillPrompt: true,
            detectLanguage: autoDetect,
            // Streaming segment text is the RAW token stream unless we ask for clean
            // output: strip the special tokens (<|startoftranscript|>, <|en|>, …) and
            // the per-segment timestamp markers. Without this the preview shows token
            // soup instead of words.
            skipSpecialTokens: true,
            withoutTimestamps: true,
            // Vocabulary bias terms (MAK-69), nil when none.
            promptTokens: streamPromptTokens
        )
        let handle = WhisperKitStreamHandle(kit: kit, decodingOptions: options)
        let transcriber = AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: kit.audioProcessor,
            decodingOptions: options,
            useVAD: true,                 // skip silence — don't transcribe dead air
            inputDeviceID: inputDeviceID, // nil = system default (fork backport of #503)
            stateChangeCallback: { _, new in
                // Absolute-scale level for the silence VAD. `bufferEnergy` is
                // RELATIVE to WhisperKit's rolling 2s silence floor — right for a
                // lively waveform, structurally wrong for fixed VAD gates (during
                // sustained speech the floor rises and levels collapse, reading
                // ongoing talk as silence). `audioEnergy.avg` is the raw
                // per-buffer RMS; fromRMS puts it on the same absolute dB curve
                // the recorder and Apple Speech feed the detector.
                // (audioEnergy lives on the concrete AudioProcessor; the protocol
                // only exposes the relative view. WhisperKit's default processor
                // is always AudioProcessor; on a custom one vadLevel degrades to
                // nil and the engine falls back to the display level.)
                let absoluteRMS = (kit.audioProcessor as? AudioProcessor)?.audioEnergy.last?.avg
                let snapshot = WhisperKitStreamState(
                    from: new,
                    vadLevel: absoluteRMS.map { AudioLevel.fromRMS($0) }
                )
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
    /// The latest buffer's level on the ABSOLUTE AudioLevel curve (fromRMS), for
    /// the silence auto-stop — `peakEnergy`'s silence-referenced scale can't
    /// carry fixed thresholds. Instantaneous (no trailing-window max-hold, which
    /// would stretch every blip 0.3s into a silence run).
    let vadLevel: Float?
    /// How many buffer samples the realtime loop had decoded as of this state —
    /// anything beyond it in the audio buffer is captured but NOT transcribed
    /// yet. Read at stop to decide whether a final flush decode is needed.
    let decodedSampleCount: Int
    /// Where the confirmed transcript ends (seconds); the flush decode clips
    /// from here, mirroring the realtime loop's own windowing.
    let confirmedEndSeconds: Float

    init(from state: AudioStreamTranscriber.State, vadLevel: Float?) {
        let confirmed = state.confirmedSegments.map(\.text).joined(separator: " ")
        let unconfirmed = state.unconfirmedSegments.map(\.text).joined(separator: " ")
        self.confirmedText = confirmed
        self.fullText = (confirmed + " " + unconfirmed)
        self.decodedSampleCount = state.lastBufferSize
        self.confirmedEndSeconds = state.lastConfirmedSegmentEndSeconds
        // `bufferEnergy` is the cumulative per-buffer relative-energy history,
        // refreshed every ~0.1s. Read the RECENT window (not the all-time max, which
        // freezes the bars) and map it with the relative-energy curve (NOT fromRMS,
        // which double-compresses the already-0…1 value). See AudioLevel.
        self.peakEnergy = AudioLevel.liveLevel(fromEnergyHistory: state.bufferEnergy)
        self.vadLevel = vadLevel
    }
}

/// Lifecycle wrapper around `AudioStreamTranscriber` so the engine can start/stop
/// and read the final transcript without importing WhisperKit. The transcriber's
/// `state` is private, so we cache the latest snapshot from the state callback.
final class WhisperKitStreamHandle {
    private var transcriber: AudioStreamTranscriber?
    /// The loaded kit + the session's decoding options, kept for the stop-time
    /// flush decode (`finalizeTail`). The engine caches the kit anyway, so this
    /// adds no model lifetime.
    private let kit: WhisperKit
    private let decodingOptions: DecodingOptions

    init(kit: WhisperKit, decodingOptions: DecodingOptions) {
        self.kit = kit
        self.decodingOptions = decodingOptions
    }

    /// Newest state snapshot. Written from the state-change callback, which fires
    /// on AudioStreamTranscriber's own executor (off-main), and read from the main
    /// actor at stop (`fullText()`) — lock-guarded because the two sides have no
    /// happens-before edge (a decode window completing right after stop still
    /// writes here).
    private let latestLock = NSLock()
    private var latestStorage: WhisperKitStreamState?
    fileprivate var latest: WhisperKitStreamState? {
        get {
            latestLock.lock(); defer { latestLock.unlock() }
            return latestStorage
        }
        set {
            latestLock.lock(); defer { latestLock.unlock() }
            latestStorage = newValue
        }
    }

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

    /// Ignore stop-time tails shorter than this (0.25 s @ 16 kHz): releasing the
    /// hotkey right at a decode boundary leaves a sliver of silence that isn't
    /// worth a decode pass.
    private static let minFlushSamples = 4_000

    /// Decode any audio captured after the realtime loop's last decode window.
    ///
    /// The loop only transcribes once ≥1 s of NEW audio has accumulated
    /// (AudioStreamTranscriber.transcribeCurrentBuffer), so releasing the hotkey
    /// right after speaking strands the trailing words in the buffer undecoded —
    /// for a mid-dictation refine, that's the entire spoken instruction, which
    /// made refine a no-op unless the user paused ~1 s before releasing.
    ///
    /// Called after `stop()` (mic already released). Mirrors the loop's own
    /// windowing: decode the full buffer clipped from the last CONFIRMED segment,
    /// replacing the unconfirmed tail with a fresh decode that includes the
    /// stranded audio. Returns the corrected full transcript, or nil when the
    /// loop already decoded everything (the common paused-before-release path —
    /// no added latency there).
    func finalizeTail() async -> String? {
        let snapshot = latest
        let samples = Array(kit.audioProcessor.audioSamples)
        let decoded = snapshot?.decodedSampleCount ?? 0
        guard samples.count > decoded + Self.minFlushSamples else { return nil }

        var options = decodingOptions
        options.clipTimestamps = [snapshot?.confirmedEndSeconds ?? 0]
        let kit = self.kit
        guard let results = try? await withTimeout(seconds: 15, operation: "Final flush decode", {
            try await kit.transcribe(audioArray: samples, decodeOptions: options)
        }) else { return nil }

        let tail = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmed = (snapshot?.confirmedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let full = (confirmed + " " + tail).trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? nil : full
    }
}

enum WhisperKitBridgeError: Error, LocalizedError {
    case tokenizerUnavailable
    case incompleteDownload(String)
    var errorDescription: String? {
        switch self {
        case .tokenizerUnavailable:
            return "WhisperKit tokenizer not loaded (model may still be loading)."
        case .incompleteDownload(let model):
            return "Downloaded model \"\(model)\" is missing required files."
        }
    }
}
#endif

import Foundation
import CoreAudio   // AudioDeviceID (the input-device id threaded to AudioStreamTranscriber)
import AVFoundation // AVAudioEngine (mid-session capture restart on the stream handle)

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

/// The streaming-decode invariant that keeps long dictations from truncating at
/// Whisper's 30 s window. Pure + public so `swift test` can pin it without
/// linking WhisperKit (the real `DecodingOptions` live behind `#if WHISPERKIT`).
///
/// **The failure this encodes.** `AudioStreamTranscriber` re-decodes a growing
/// buffer clipped from `lastConfirmedSegmentEndSeconds`, and each pass is capped
/// at `windowSamples` (480_000 = 30 s @ 16 kHz). That is only sustainable while
/// the confirmed end keeps ADVANCING. It advances only when segments get promoted
/// to `confirmedSegments`, which happens only when
/// `segments.count > requiredSegmentsForConfirmation`.
///
/// With `withoutTimestamps = true` the decoder emits `<|notimestamps|>`, so
/// `SegmentSeeker` finds no consecutive-timestamp pairs and lumps the entire
/// window into ONE segment — `1 > 2` is false, nothing is ever confirmed, the
/// clip point stays pinned at 0, and every decode re-reads the FIRST 30 s of
/// audio forever. Past ~30 s the transcript froze and later speech was dropped.
public enum WhisperKitStreamingDecodePolicy {
    /// WhisperKit's fixed encoder window: 30 s @ 16 kHz. The hard ceiling on a
    /// single decode pass, and therefore on a session whose clip point is stuck.
    public static let windowSamples = 480_000
    public static let sampleRate = 16_000

    /// `AudioStreamTranscriber`'s default `requiredSegmentsForConfirmation` —
    /// the live value for plain TRANSCRIBE sessions (we don't override it).
    public static let requiredSegmentsForConfirmation = 2

    /// The confirmation threshold `makeStreamHandle` passes for a session,
    /// by task.
    ///
    /// This is the streaming loop's dominant latency knob: every decode pass
    /// re-decodes from `lastConfirmedSegmentEndSeconds`, and confirmation
    /// always holds back the newest `requiredSegmentsForConfirmation`
    /// segments. Holding back 2 means the re-decoded tail settles at ~2–3
    /// segments of audio; on the TRANSLATE task each of those passes also has
    /// to re-GENERATE English for that whole tail (more tokens, lower
    /// confidence, more fallbacks than same-language transcribe), so after
    /// ~30–40 s of continuous speech the pass cost visibly outgrows the ≥1 s
    /// new-audio cadence and partials start lagging.
    ///
    /// Translate therefore holds back only 1 segment: the clip point advances
    /// a full segment sooner, roughly halving the steady-state re-decode
    /// window. The cost is that a segment freezes (is confirmed) one window
    /// earlier — an acceptable trade on the translate path, where the live
    /// preview is already a moving translation rather than verbatim text.
    /// Transcribe keeps the upstream default of 2.
    public static func requiredSegmentsForConfirmation(translate: Bool) -> Int {
        translate ? 1 : requiredSegmentsForConfirmation
    }

    /// Segments a window yields, given whether timestamp tokens were emitted.
    /// Without timestamps the seeker can't split, so the window is one segment.
    public static func segmentsPerWindow(timestampsEmitted: Bool) -> Int {
        timestampsEmitted ? requiredSegmentsForConfirmation + 1 : 1
    }

    /// Whether a window's segments can be promoted to `confirmedSegments` —
    /// i.e. whether the decode window will advance past this point at all.
    public static func advancesConfirmedEnd(timestampsEmitted: Bool) -> Bool {
        segmentsPerWindow(timestampsEmitted: timestampsEmitted) > requiredSegmentsForConfirmation
    }

    /// The longest dictation that survives with a given timestamp setting.
    /// `nil` = unbounded (the confirmed end advances with the speech).
    public static func maxTranscribableSeconds(timestampsEmitted: Bool) -> Double? {
        guard !advancesConfirmedEnd(timestampsEmitted: timestampsEmitted) else { return nil }
        return Double(windowSamples) / Double(sampleRate)
    }

    /// The value `makeStreamHandle` MUST pass for `withoutTimestamps` on the
    /// streaming path. False — timestamps are what let segments confirm. The
    /// preview stays clean via `skipSpecialTokens`, which filters every token
    /// `>= specialTokenBegin` (timestamps included) out of the decoded text.
    public static let withoutTimestamps = false
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
            // soup instead of words. This alone is what keeps the preview clean —
            // `skipSpecialTokens` filters every token >= specialTokenBegin (timestamp
            // tokens included) out of the decoded text, so it does NOT depend on
            // `withoutTimestamps`.
            skipSpecialTokens: true,
            // MUST stay false on the streaming path. `withoutTimestamps: true` makes
            // the decoder emit <|notimestamps|> and produce no timestamp tokens at
            // all; SegmentSeeker then finds no consecutive-timestamp pairs and lumps
            // the whole window into ONE segment. AudioStreamTranscriber only promotes
            // segments to `confirmedSegments` when `segments.count >
            // requiredSegmentsForConfirmation` (2), so a single segment is NEVER
            // confirmed — `lastConfirmedSegmentEndSeconds` stays pinned at 0, the
            // realtime loop's `clipTimestamps = [0]` re-decodes from time zero every
            // pass, and `segmentSize = min(windowSamples, …)` truncates that to
            // Whisper's 30 s window. Result: past ~30 s of continuous dictation the
            // transcript froze and every later word was silently dropped (and the
            // re-decode cost grew without bound). Emitting timestamps lets segments
            // split and confirm, so the window advances with the speech.
            withoutTimestamps: WhisperKitStreamingDecodePolicy.withoutTimestamps,
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
            // Task-aware confirmation lag — the streaming loop's dominant
            // latency knob (see WhisperKitStreamingDecodePolicy): translate
            // holds back 1 segment instead of 2 so the re-decoded tail stays
            // short and partials keep pace past the ~30–40 s mark.
            requiredSegmentsForConfirmation:
                WhisperKitStreamingDecodePolicy.requiredSegmentsForConfirmation(translate: task.translate),
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

    // MARK: Mid-session capture restart (AVAudioEngineConfigurationChange)

    /// The `AVAudioEngine` WhisperKit's `AudioProcessor` is currently capturing
    /// with — nil before capture starts, after stop, or on a custom (non-default)
    /// audio processor. Exposed so the engine can arm its
    /// `AVAudioEngineConfigurationChange` observer on the exact engine object.
    var captureAudioEngine: AVAudioEngine? {
        (kit.audioProcessor as? AudioProcessor)?.audioEngine
    }

    private struct CaptureRestartError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Tear down the (dead) capture engine and rebuild a fresh one feeding the
    /// SAME decode buffer. After an input-device disconnect/switch/format
    /// renegotiation AVAudioEngine stops rendering; the realtime decode loop
    /// keeps polling `audioSamples` regardless, so appending fresh capture there
    /// resumes the transcript with only the glitch itself lost.
    ///
    /// Mirrors `AudioProcessor.setupEngine` (internal to WhisperKit) with its
    /// public pieces: tap in the node's native format, resample to WhisperKit's
    /// 16 kHz mono, honor input suppression, and hand the samples to
    /// `processBuffer` — which also keeps `audioEnergy` (levels/VAD) and the
    /// buffer callback flowing.
    func restartCapture(inputDeviceID: AudioDeviceHandle?) throws {
        guard let processor = kit.audioProcessor as? AudioProcessor else {
            throw CaptureRestartError(
                message: "capture restart requires WhisperKit's default audio processor")
        }
        if let stale = processor.audioEngine {
            stale.inputNode.removeTap(onBus: 0)
            stale.stop()
        }
        processor.audioEngine = nil

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Route BEFORE reading the format (the format follows the device). The
        // caller resolved the device under AudioInputRoutingPolicy, so a routing
        // failure here is a hard error — never silently capture a different mic.
        if let deviceID = inputDeviceID {
            try input.auAudioUnit.setDeviceID(deviceID)
        }
        let format = input.outputFormat(forBus: 0)
        // 0 Hz / 0 ch (no input device) would make installTap raise an ObjC
        // NSException that Swift can't catch — guard it out.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureRestartError(message: "No audio input device available.")
        }
        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: desiredFormat) else {
            throw CaptureRestartError(
                message: "mic format \(format) can't convert to WhisperKit's 16 kHz mono")
        }
        let bufferSize = AVAudioFrameCount(processor.minBufferLength)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak processor] buffer, _ in
            guard let processor else { return }
            var resampled = buffer
            if !buffer.format.sampleRate.isEqual(to: Double(WhisperKit.sampleRate)) {
                guard let converted = try? AudioProcessor.resampleBuffer(buffer, with: converter)
                else { return } // drop an unconvertible buffer
                resampled = converted
            }
            var samples = AudioProcessor.convertBufferToArray(buffer: resampled)
            if processor.isInputSuppressed {
                samples = [Float](repeating: 0, count: samples.count)
            }
            processor.processBuffer(samples)
        }
        engine.prepare()
        try engine.start()
        processor.audioEngine = engine
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

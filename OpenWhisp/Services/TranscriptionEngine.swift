import Foundation

/// Which whisper.cpp execution path to use for a file transcription.
///
/// Foundation-only (string-free enum) so it lives in OpenWhispCore and can be
/// named by the `FileTranscriptionEngine` protocol and by AppState without
/// pulling in the concrete engine.
public enum WhisperBackend {
    /// Spawn the `whisper-cli` binary per request.
    case cli
    /// POST to a warm `whisper-server` over loopback HTTP.
    case serverAPI
}

/// Platform-agnostic file-based transcription seam (Phase 2.5 core extraction).
///
/// Models the request/response engine (whisper.cpp): hand it a WAV path, get a
/// result back via `onTranscriptionComplete`/`onTranscriptionError` keyed by the
/// request's UUID. The warm-server lifecycle and progress/worker-status reporting
/// are part of the contract so AppState can drive them without naming the concrete
/// macOS `WhisperEngine`. A port keeps whisper.cpp (cross-platform C++) but
/// supplies its own process/HTTP plumbing.
public protocol FileTranscriptionEngine: AnyObject {
    /// A finished transcription: (requestID, text).
    var onTranscriptionComplete: ((UUID, String) -> Void)? { get set }
    /// A failed transcription: (requestID, message).
    var onTranscriptionError: ((UUID, String) -> Void)? { get set }
    /// Coarse progress percent (0–100) for the active request.
    var onProgress: ((Int) -> Void)? { get set }
    /// Human-readable warm-server/worker status for the UI.
    var onWorkerStatus: ((String) -> Void)? { get set }

    /// Transcribe a single WAV file. Async — does not block the caller; the
    /// result arrives via the completion/error callbacks.
    func transcribe(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        deleteWhenDone: Bool,
        backend: WhisperBackend,
        prompt: String
    )

    /// Pre-warm the persistent server for the given binary/model so the first
    /// real request is fast.
    func warmServer(binaryPath: String, modelPath: String)
    /// Tear down the persistent server.
    func stopServer()

    /// Reset any per-dictation state (called at the start of each session). Default
    /// is a no-op; WhisperKit uses it to forget the auto-detected language so each
    /// new dictation re-detects rather than sticking to the previous one.
    func resetSession()
}

extension FileTranscriptionEngine {
    /// Default: most engines hold no per-session state.
    public func resetSession() {}


    /// Convenience matching the engine's own defaults, so call sites that don't
    /// care about `deleteWhenDone` can omit it when calling through the protocol.
    public func transcribe(
        requestID: UUID,
        binaryPath: String,
        modelPath: String,
        language: String,
        wavPath: String,
        backend: WhisperBackend,
        prompt: String
    ) {
        transcribe(
            requestID: requestID,
            binaryPath: binaryPath,
            modelPath: modelPath,
            language: language,
            wavPath: wavPath,
            deleteWhenDone: true,
            backend: backend,
            prompt: prompt
        )
    }
}

/// Platform-agnostic streaming transcription seam (Phase 2.5 core extraction).
///
/// Models the live recognizer (Apple Speech on macOS): `start` begins listening,
/// partial/final hypotheses and audio level arrive via callbacks, `stop` ends.
/// macOS-only today (no good on-device equivalent elsewhere — see
/// WINDOWS_PORT.md), but behind a protocol so AppState's session orchestration
/// doesn't name `AppleSpeechEngine`. Authorization stays a concrete-type concern
/// (it returns platform permission types).
public protocol StreamingTranscriptionEngine: AnyObject {
    /// Interim hypothesis as the user speaks.
    var onPartial: ((String) -> Void)? { get set }
    /// Final recognized text for the utterance.
    var onFinal: ((String) -> Void)? { get set }
    /// A recognition error message.
    var onError: ((String) -> Void)? { get set }
    /// Normalized (0–1) live audio levels. `display` drives the waveform and may
    /// be on an engine-tuned scale (WhisperKit's is RELATIVE to a rolling silence
    /// floor, which keeps the bars lively). `vad` MUST be on the absolute
    /// `AudioLevel.fromDB`/`fromRMS` curve — it feeds the fixed-threshold silence
    /// auto-stop, where a self-referencing scale would make the gates meaningless
    /// (the floor rises during speech, reading ongoing talk as "silence").
    /// Engines whose display level is already absolute pass the same value twice.
    var onLevelChanged: ((_ display: Float, _ vad: Float) -> Void)? { get set }
    /// Fired once per session when capture is GENUINELY live — the mic tap is
    /// installed and the engine is consuming audio. `start()` returning is not
    /// that signal: WhisperKit and Parakeet only ENQUEUE their start on a serial
    /// lifecycle chain, and the model load (or first-run download, up to minutes)
    /// happens before any tap exists. Callers must keep the "Starting…"/arming
    /// cue until this fires — flipping to "Listening" at `start()` return
    /// silently drops everything spoken during the load gap. Fires on the main
    /// actor. Never fires for a session that fails to start (`onError` ends it).
    var onStarted: (() -> Void)? { get set }

    /// Pin the input device (an opaque platform UID, e.g. the CoreAudio device UID
    /// stored as `microphoneID`) for the NEXT `start()`. The empty string means
    /// "follow the system default input". Call before `start()`; a device pinned
    /// while a stream is running takes effect on the next session.
    ///
    /// If the pinned (non-empty) device can't be resolved at `start()` time, the
    /// engine surfaces an error via `onError` rather than silently capturing the
    /// system default — that silent fallback was the bug where selecting a
    /// non-default mic still recorded the built-in one.
    func selectDevice(_ deviceID: String)

    /// Begin streaming recognition for `language` ("auto" = current locale).
    ///
    /// `prompt` carries the session's vocabulary/bias context (the same
    /// comma-joined term string the file path uses — custom vocabulary + screen
    /// bias terms). It exists so live-dictation biasing is *expressible*; before
    /// MAK-69 the streaming seam had no channel for it, which meant the setting
    /// could be offered and then silently dropped on the live path.
    ///
    /// Contract: an engine that cannot honor `prompt` on its streaming path MUST
    /// declare that via `EngineCapabilities.honorsStreamingVocabulary` (which is
    /// `false` for it), and callers gate on that — AppState passes a non-empty
    /// `prompt` here ONLY when the active engine honors streaming vocabulary. So a
    /// discarded `prompt` is never a silent surprise: it's a declared no-op the UI
    /// already told the user about. Engines free to ignore `prompt` on that basis:
    /// Parakeet (batch-only biasing) and SpeechAnalyzer (unwired).
    func start(language: String, prompt: String) throws
    /// Stop streaming. `cancel` discards any pending final result.
    func stop(cancel: Bool)
}

extension StreamingTranscriptionEngine {
    /// Convenience for call sites (and the test fake) that carry no bias context.
    /// Not a way to smuggle a prompt past the capability gate — it forwards the
    /// empty string, which every engine honors trivially (it's a no-op).
    public func start(language: String) throws {
        try start(language: language, prompt: "")
    }
}

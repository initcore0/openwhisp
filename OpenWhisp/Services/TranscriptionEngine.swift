import Foundation

/// Which whisper.cpp execution path to use for a file transcription.
///
/// Foundation-only (string-free enum) so it lives in OpenWhispCore and can be
/// named by the `FileTranscriptionEngine` protocol and by AppState without
/// pulling in the concrete engine.
enum WhisperBackend {
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
protocol FileTranscriptionEngine: AnyObject {
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
    func resetSession() {}


    /// Convenience matching the engine's own defaults, so call sites that don't
    /// care about `deleteWhenDone` can omit it when calling through the protocol.
    func transcribe(
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
protocol StreamingTranscriptionEngine: AnyObject {
    /// Interim hypothesis as the user speaks.
    var onPartial: ((String) -> Void)? { get set }
    /// Final recognized text for the utterance.
    var onFinal: ((String) -> Void)? { get set }
    /// A recognition error message.
    var onError: ((String) -> Void)? { get set }
    /// Normalized (0–1) live audio level for the waveform.
    var onLevelChanged: ((Float) -> Void)? { get set }

    /// Begin streaming recognition for `language` ("auto" = current locale).
    func start(language: String) throws
    /// Stop streaming. `cancel` discards any pending final result.
    func stop(cancel: Bool)
}

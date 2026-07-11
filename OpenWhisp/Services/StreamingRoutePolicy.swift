import Foundation

/// Decides whether a dictation session runs on the realtime streaming path
/// (a `StreamingTranscriptionEngine` owns the mic and emits partials) or the
/// recorded file path (AudioRecorder → FileTranscriptionEngine).
///
/// Pure and in OpenWhispCore so the routing gate is unit-tested — the exact
/// wiring a "tested core, dead gate" regression hides in (see memory:
/// wiring-review-lessons). AppState.startDictation is a thin caller.
enum StreamingRoutePolicy {
    /// Engines that ALWAYS stream (they have no file path at all).
    private static let streamingOnlyEngines: Set<String> = ["appleSpeech", "parakeet"]

    /// - Parameters:
    ///   - engine: the `transcriptionEngine` setting value.
    ///   - liveMode: the user wants live output (outputMode is liveChunks/preview).
    static func usesStreamingSession(engine: String, liveMode: Bool) -> Bool {
        if streamingOnlyEngines.contains(engine) { return true }
        // WhisperKit streams only when a live preview is wanted; otherwise its
        // file engine transcribes the recorded WAV.
        return engine == "whisperKit" && liveMode
    }

    /// Whether the engine needs Apple Speech-framework authorization in addition
    /// to microphone access before `start()`.
    static func needsSpeechAuthorization(engine: String) -> Bool {
        engine == "appleSpeech"
    }
}

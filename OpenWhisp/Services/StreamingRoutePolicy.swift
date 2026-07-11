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

    /// A streaming partial/final callback carries the session generation it was
    /// bound to. It should be honored only while that generation is still the
    /// active one. Returns true when the callback is STALE (a newer session has
    /// begun) and must be dropped.
    ///
    /// This closes the late-final hole: Apple Speech synthesizes a final ~0.8s
    /// after stop, so on a quick cancel+restart a leftover final from the previous
    /// engine session can land during the successor. Without a per-generation
    /// fence, `isAppleSpeechSession` (a plain bool the successor also sets true)
    /// lets it through — pasting the old transcript and completing the new session
    /// early. Both handlers gate on this.
    static func isStaleStreamingCallback(callbackSessionID: UUID, activeSessionID: UUID) -> Bool {
        callbackSessionID != activeSessionID
    }

    /// What a deferred mic-grant callback should do when it finally runs.
    ///
    /// The grant callback is async: by the time it fires, the session it belongs to
    /// may have been cancelled/restarted. Three cases:
    /// - **drop**: a NEWER session already began (`callbackSessionID` no longer the
    ///   active one). This callback is stale — it must simply return and touch
    ///   nothing, because aborting here would tear down the CURRENT successor
    ///   session (the bug: a stale callback calling `abortSessionBeforeStart`).
    /// - **abort**: still this session's own callback, but the user released/stopped
    ///   before the grant landed (`pendingStop`). Tear the half-started session down.
    /// - **proceed**: still active and no stop pending — start the engine.
    enum GrantCallbackAction: Equatable {
        case proceed
        case abort
        case drop
    }

    static func grantCallbackAction(
        callbackSessionID: UUID,
        activeSessionID: UUID,
        pendingStop: Bool
    ) -> GrantCallbackAction {
        if callbackSessionID != activeSessionID { return .drop }
        if pendingStop { return .abort }
        return .proceed
    }
}

/// Which concrete `FileTranscriptionEngine` backs a transcriptionEngine setting.
/// Pure so the `AppState.makeFileEngine` routing — the seam that decides what
/// transcribes meetings, queued files, watch folders, and history re-transcribes
/// — is unit-tested; the factory is a thin switch over this.
enum FileEngineChoice: Equatable {
    /// whisper.cpp (whisper-cli / whisper-server). Also the fallback for
    /// engines with no file path of their own (Apple Speech never reaches the
    /// file path — startDictation routes it to streaming — so its value here
    /// is inert by construction).
    case whisperCpp
    /// WhisperKit CoreML (its own openai_whisper-* model namespace).
    case whisperKit
    /// Parakeet TDT v3 batch CoreML (MAK-46) — multilingual file/meeting path.
    case parakeet

    static func choice(for engine: String) -> FileEngineChoice {
        switch engine {
        case "whisperKit": return .whisperKit
        case "parakeet":   return .parakeet
        default:           return .whisperCpp
        }
    }
}

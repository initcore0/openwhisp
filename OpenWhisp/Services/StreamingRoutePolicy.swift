import Foundation

/// Decides whether a dictation session runs on the realtime streaming path
/// (a `StreamingTranscriptionEngine` owns the mic and emits partials) or the
/// recorded file path (AudioRecorder → FileTranscriptionEngine).
///
/// Pure and in OpenWhispCore so the routing gate is unit-tested — the exact
/// wiring a "tested core, dead gate" regression hides in (see memory:
/// wiring-review-lessons). AppState.startDictation is a thin caller.
public enum StreamingRoutePolicy {
    /// Engines that ALWAYS stream (they have no file path at all).
    private static let streamingOnlyEngines: Set<String> = ["appleSpeech", "parakeet"]

    /// - Parameters:
    ///   - engine: the `transcriptionEngine` setting value.
    ///   - liveMode: the user wants live output (outputMode is liveChunks/preview).
    public static func usesStreamingSession(engine: String, liveMode: Bool) -> Bool {
        if streamingOnlyEngines.contains(engine) { return true }
        // WhisperKit streams only when a live preview is wanted; otherwise its
        // file engine transcribes the recorded WAV.
        return engine == "whisperKit" && liveMode
    }

    /// Whether the engine needs Apple Speech-framework authorization in addition
    /// to microphone access before `start()`.
    public static func needsSpeechAuthorization(engine: String) -> Bool {
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
    public static func isStaleStreamingCallback(callbackSessionID: UUID, activeSessionID: UUID) -> Bool {
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
    public enum GrantCallbackAction: Equatable {
        case proceed
        case abort
        case drop
    }

    public static func grantCallbackAction(
        callbackSessionID: UUID,
        activeSessionID: UUID,
        pendingStop: Bool
    ) -> GrantCallbackAction {
        if callbackSessionID != activeSessionID { return .drop }
        if pendingStop { return .abort }
        return .proceed
    }

    /// What the engine's "capture actually began" signal (`onStarted`) — or its
    /// timeout fallback — should do when it lands.
    ///
    /// `engine.start()` returning is NOT capture: WhisperKit/Parakeet only
    /// enqueue their start on a serial lifecycle chain, and the model load (or
    /// first-run download) runs before any mic tap exists. The session therefore
    /// stays in the arming state ("Starting…", isArming) until `onStarted`
    /// fires, and this decides what that (possibly late) callback does:
    /// - **drop**: a newer session began, or this session already left arming
    ///   (the timeout fallback fired first, or the session ended — finishSessionUI
    ///   clears isArming at every terminal). Touch nothing.
    /// - **beginListening**: flip the UI live (isArming=false, isRecording=true,
    ///   "Listening...").
    /// - **beginListeningThenStop**: same, but the user released the hotkey while
    ///   the engine was still arming (`pendingStop`) — go live and immediately
    ///   run the stop so the mic never keeps capturing unattended. Mirrors the
    ///   recorder path's `.recording` + pendingStop handling.
    public enum CaptureStartedAction: Equatable {
        case beginListening
        case beginListeningThenStop
        case drop
    }

    public static func captureStartedAction(
        callbackSessionID: UUID,
        activeSessionID: UUID,
        isArming: Bool,
        pendingStop: Bool
    ) -> CaptureStartedAction {
        if callbackSessionID != activeSessionID { return .drop }
        if !isArming { return .drop }
        return pendingStop ? .beginListeningThenStop : .beginListening
    }

    /// Arming-timeout fallback (seconds): if `onStarted` hasn't fired this long
    /// after `start()` was issued, flip to Listening anyway so a signal-wiring
    /// bug can't wedge the session at "Starting…" forever. Deliberately generous
    /// — a cold model load can be slow, and flipping early re-opens the
    /// speak-into-the-gap hole this signal exists to close. A first-run model
    /// DOWNLOAD can outlast even this; the flip is then optimistic, which is
    /// still strictly better than the old flip-at-enqueue behavior.
    public static let captureStartTimeout: TimeInterval = 15
}

/// Which concrete `FileTranscriptionEngine` backs a transcriptionEngine setting.
/// Pure so the `AppState.makeFileEngine` routing — the seam that decides what
/// transcribes meetings, queued files, watch folders, and history re-transcribes
/// — is unit-tested; the factory is a thin switch over this.
public enum FileEngineChoice: Equatable {
    /// whisper.cpp (whisper-cli / whisper-server). Also the fallback for
    /// engines with no file path of their own (Apple Speech never reaches the
    /// file path — startDictation routes it to streaming — so its value here
    /// is inert by construction).
    case whisperCpp
    /// WhisperKit CoreML (its own openai_whisper-* model namespace).
    case whisperKit
    /// Parakeet TDT v3 batch CoreML (MAK-46) — multilingual file/meeting path.
    case parakeet

    public static func choice(for engine: String) -> FileEngineChoice {
        switch engine {
        case "whisperKit": return .whisperKit
        case "parakeet":   return .parakeet
        default:           return .whisperCpp
        }
    }
}

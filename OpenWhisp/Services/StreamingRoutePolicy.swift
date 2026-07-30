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
        // WhisperKit and SpeechAnalyzer stream only when a live preview is wanted;
        // otherwise their file engines transcribe the recorded WAV. Routing the
        // file/meeting path to SpeechAnalyzer's batch engine is the biggest,
        // lowest-risk win (MAK-59) — live dictation is opt-in via output mode.
        return (engine == "whisperKit" || engine == "speechAnalyzer") && liveMode
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

    /// Stuck-session stop-fallback poll interval (seconds). 2.0 (not 0.9):
    /// AppleSpeechEngine's own 0.8s fallback guarantees a final for the Apple
    /// path, so the fallback is a stuck-session guard — with a wide margin so a
    /// busy main thread can't let it fire first and clobber the engine's genuine
    /// final (which arrives via an extra Task hop) with a stale partial.
    public static let stopFallbackInterval: TimeInterval = 2
    /// Hard cap (seconds) on how long the stop fallback keeps waiting for an
    /// engine that reports `isFinalizing`. A finalize that outlasts this is
    /// treated as hung and the session completes with the last partial — the
    /// stuck-session guarantee the fallback exists for. Generous on purpose: a
    /// real decode-backlog drain is far faster than realtime (Parakeet RTFx ~5),
    /// so only a genuine hang ever reaches it.
    public static let stopFallbackMaxWait: TimeInterval = 30

    /// The stuck-session fallback armed by a streaming stop (AppState's
    /// `stopAppleSpeech`): if the engine's genuine final never arrives, complete
    /// the session with the last streamed partial rather than wedging at
    /// "Finalizing...".
    ///
    /// Re-arming poll loop, NOT a one-shot deadline — the one-shot was the
    /// tail-word-loss bug: a long dictation leaves Parakeet's `runStop` draining
    /// the queued audio feed through the decoder (then `finish()`), which can
    /// outlast any fixed window; the timer fired first with the STALE partial,
    /// set the did-complete flag, and the genuine final (holding the tail words)
    /// was dropped by the completion guard. While the engine reports
    /// `isFinalizing`, the fallback re-arms instead of firing.
    ///
    /// One extra GRACE poll after finalizing ends: the engine clears its
    /// finalizing state when its stop chain returns, but the final it delivered
    /// still rides a main-actor Task hop into the completion handler — completing
    /// in that gap would clobber it. By the next poll the hop has long landed and
    /// `isSessionStillWaiting` reports the session done.
    ///
    /// - Parameters:
    ///   - sleep: injectable wait (tests script it; production sleeps for real).
    ///   - isSessionStillWaiting: the caller's session fence — still the same
    ///     session, still finalizing, no final handled yet. `false` ends the loop
    ///     silently (the timer's job is done or moot).
    ///   - isEngineFinalizing: the active engine's `isFinalizing`.
    ///   - completeFallback: complete the session with the stale partial. Called
    ///     at most once, as the loop's last act.
    @MainActor
    public static func runStopFallback(
        interval: TimeInterval = stopFallbackInterval,
        maxWait: TimeInterval = stopFallbackMaxWait,
        sleep: (TimeInterval) async -> Void = {
            try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        isSessionStillWaiting: () -> Bool,
        isEngineFinalizing: () -> Bool,
        completeFallback: () -> Void
    ) async {
        var elapsed: TimeInterval = 0
        var wasFinalizing = false
        while true {
            await sleep(interval)
            elapsed += interval
            guard isSessionStillWaiting() else { return }
            let finalizing = isEngineFinalizing()
            if (finalizing || wasFinalizing) && elapsed < maxWait {
                // `wasFinalizing` is what grants the single grace poll: it holds
                // fire for exactly one interval after finalizing ends, then (if
                // the final still never landed) the fallback fires after all.
                wasFinalizing = finalizing
                continue
            }
            completeFallback()
            return
        }
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
    /// Apple SpeechAnalyzer batch file transcription (macOS 26, MAK-59) — the
    /// on-device Speech-framework analyzer over a recorded WAV. This is the
    /// primary path SpeechAnalyzer takes (meetings, queue, watch folders,
    /// re-transcribe): auto-punctuating and ~2× faster than Whisper.
    case speechAnalyzer

    public static func choice(for engine: String) -> FileEngineChoice {
        switch engine {
        case "whisperKit":     return .whisperKit
        case "parakeet":       return .parakeet
        case "speechAnalyzer": return .speechAnalyzer
        default:               return .whisperCpp
        }
    }
}
